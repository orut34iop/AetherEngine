import Foundation

/// Compressed VOD packet prefetch, independent of renderer pacing. The producer owns source reads;
/// the consumer gets byte-identical packet envelopes from a bounded disk FIFO. No main-thread I/O.
/// Seek invalidates both the FIFO and time coverage; old reads can finish but cannot publish.
final class SoftwarePacketReadAhead: @unchecked Sendable {
    struct Stream: Sendable {
        let index: Int32
        let numerator: Int32
        let denominator: Int32
    }
    struct Snapshot: Sendable {
        let packetCount: Int
        let bytes: Int
        let frontier: Double?
        let generation: UInt64
        let seeking: Bool
        let sourceEnded: Bool
    }
    enum ReadError: Error { case interrupted, closed, corruptFIFO }

    private let condition = NSCondition()
    /// Never acquired by a main-thread API. Serializes reset with append/pop, including the
    /// generation check, so an old consumer cannot pop and discard the first NEW-generation packet.
    private let operations = NSLock()
    private let fifo: SoftwarePacketDiskFIFO
    private let readSource: @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?
    private let beforeConsumerOperation: (@Sendable () -> Void)?
    private let video: Stream
    private let audio: Stream?
    private let byteBudget: Int
    private let forwardSeconds: Double
    private let worker = DispatchQueue(label: "engine.sw.packet-prefetch", qos: .utility)
    private var generation: UInt64 = 0
    private var resetPending = false
    private var seeking = false
    private var closed = false
    private var started = false
    private var ended = false
    private var failure: Error?
    private var count = 0
    private var bytes = 0
    private var sourceClock: Double
    private var videoCoverage = SoftwarePacketCoverage()
    private var audioCoverage = SoftwarePacketCoverage()

    /// Construct only off-main: creating the FIFO touches the temporary volume.
    init(video: Stream, audio: Stream?, byteBudget: Int, forwardSeconds: Double,
         initialSourceClock: Double, fifo: SoftwarePacketDiskFIFO,
         beforeConsumerOperation: (@Sendable () -> Void)? = nil,
         readSource: @escaping @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?) {
        self.video = video
        self.audio = audio
        self.byteBudget = max(1, byteBudget)
        self.forwardSeconds = max(1, forwardSeconds)
        self.sourceClock = initialSourceClock
        self.fifo = fifo
        self.beforeConsumerOperation = beforeConsumerOperation
        self.readSource = readSource
    }

    func start() {
        condition.lock()
        guard !started, !closed else { condition.unlock(); return }
        started = true
        condition.unlock()
        worker.async { self.produce() }
    }

    var snapshot: Snapshot {
        condition.lock(); defer { condition.unlock() }
        return Snapshot(packetCount: count, bytes: bytes,
                        frontier: seeking || closed ? nil : frontierLocked(),
                        generation: generation, seeking: seeking, sourceEnded: ended)
    }

    /// Main-thread safe: metadata only. Decode/render backpressure still belongs to the old loop.
    func updatePlayhead(_ seconds: Double) {
        guard seconds.isFinite else { return }
        condition.lock()
        sourceClock = seconds
        pruneLocked(&videoCoverage, stream: video)
        if let audio { pruneLocked(&audioCoverage, stream: audio) }
        condition.broadcast()
        condition.unlock()
    }

    /// Call BEFORE Demuxer.seekBounded. It prevents any subsequent source read until endSeek.
    /// An already-blocked read uses the existing demuxer's deadline/interrupt/seek serialization.
    @discardableResult
    func beginSeek() -> UInt64 {
        condition.lock(); defer { condition.unlock() }
        generation &+= 1
        seeking = true
        resetPending = true
        count = 0; bytes = 0
        ended = false; failure = nil
        videoCoverage.reset(); audioCoverage.reset()
        condition.broadcast()
        return generation
    }

    func endSeek(_ token: UInt64, sourceClock: Double) {
        condition.lock(); defer { condition.unlock() }
        guard token == generation, !closed else { return }
        self.sourceClock = sourceClock
        seeking = false
        condition.broadcast()
    }

    /// Does not wait for a remote read or a disk operation. The host closes the Demuxer as usual,
    /// unblocking its reader; the worker then releases only its own unique FIFO directory.
    func close() {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true
        generation &+= 1
        count = 0; bytes = 0
        videoCoverage.reset(); audioCoverage.reset()
        let needsCleanup = !started
        condition.broadcast()
        condition.unlock()
        if needsCleanup { worker.async { try? self.fifo.close() } }
    }

    /// Consumer thread only. nil means true EOF; a seek wake is explicitly different from EOF.
    func read() throws -> SoftwareStoredPacket? {
        condition.lock()
        let token = generation
        while count == 0, !ended, failure == nil, !closed, !seeking, token == generation {
            condition.wait()
        }
        if closed { condition.unlock(); throw ReadError.closed }
        if seeking || token != generation { condition.unlock(); throw ReadError.interrupted }
        if count == 0 {
            let error = failure
            condition.unlock()
            if let error { throw error }
            return nil
        }
        condition.unlock()

        beforeConsumerOperation?()  // deterministic generation-race test seam; nil in production
        operations.lock()
        defer { operations.unlock() }
        condition.lock()
        let valid = !closed && !seeking && token == generation
        condition.unlock()
        guard valid else { throw ReadError.interrupted }
        guard let data = try fifo.pop() else { throw ReadError.corruptFIFO }
        let packet = try SoftwareStoredPacket.decode(data)
        condition.lock()
        defer { condition.unlock() }
        guard !closed, !seeking, token == generation else { throw ReadError.interrupted }
        count -= 1
        bytes -= data.count
        condition.broadcast()
        return packet
    }

    private func frontierLocked() -> Double? {
        let videoEnd = videoCoverage.frontierSeconds(
            containing: sourceClock, timeBaseNumerator: video.numerator,
            timeBaseDenominator: video.denominator)
        let audioEnd = audio.flatMap { stream in
            audioCoverage.frontierSeconds(containing: sourceClock,
                timeBaseNumerator: stream.numerator, timeBaseDenominator: stream.denominator)
        }
        return SoftwarePacketCoverage.combinedFrontier(
            video: videoEnd, audio: audioEnd, requiresAudio: audio != nil)
    }

    private func pruneLocked(_ coverage: inout SoftwarePacketCoverage, stream: Stream) {
        guard stream.numerator > 0, stream.denominator > 0 else { return }
        let tick = floor(sourceClock * Double(stream.denominator) / Double(stream.numerator))
        guard tick.isFinite, tick > Double(Int64.min), tick < Double(Int64.max) else { return }
        coverage.prune(before: Int64(tick))
    }

    private func produce() {
        defer { try? fifo.close() }
        while true {
            condition.lock()
            while !closed && !resetPending && (seeking || ended || failure != nil || shouldParkLocked()) {
                condition.wait()
            }
            if closed { condition.unlock(); return }
            let token = generation
            let reset = resetPending
            condition.unlock()

            if reset {
                operations.lock()
                do {
                    try fifo.reset()
                    condition.lock()
                    if token == generation { resetPending = false }
                    condition.broadcast()
                    condition.unlock()
                } catch { recordFailure(error, token: token) }
                operations.unlock()
                continue
            }

            autoreleasepool {
                producePacket(token: token)
            }
        }
    }

    private func producePacket(token: UInt64) {
        do {
            let packet = try readSource { [self] in
                condition.lock(); defer { condition.unlock() }
                return token == generation && !closed && !seeking
            }
            guard let packet else {
                condition.lock()
                if token == generation, !seeking, !closed { ended = true }
                condition.broadcast()
                condition.unlock()
                return
            }
            let data = try packet.encoded()
            operations.lock()
            condition.lock()
            let valid = token == generation && !closed && !seeking
            condition.unlock()
            if valid {
                do {
                    try fifo.append(data)
                    condition.lock()
                    if token == generation, !closed, !seeking {
                        count += 1; bytes += data.count
                        if packet.streamIndex == video.index {
                            videoCoverage.insert(pts: packet.pts, duration: packet.duration)
                        } else if packet.streamIndex == audio?.index {
                            audioCoverage.insert(pts: packet.pts, duration: packet.duration)
                        }
                    }
                    condition.broadcast()
                    condition.unlock()
                } catch { recordFailure(error, token: token) }
            }
            operations.unlock()
        } catch { recordFailure(error, token: token) }
    }

    private func shouldParkLocked() -> Bool {
        // One source packet can cross the byte budget, never an unbounded batch. A source without
        // valid PTS/duration still has a hard byte bound; unknown coverage is not guessed from bitrate.
        guard count > 0 else { return false }
        return bytes >= byteBudget || (frontierLocked().map { $0 - sourceClock >= forwardSeconds } ?? false)
    }

    private func recordFailure(_ error: Error, token: UInt64) {
        condition.lock(); defer { condition.unlock() }
        guard token == generation, !closed else { return }
        failure = error
        resetPending = false
        condition.broadcast()
    }
}
