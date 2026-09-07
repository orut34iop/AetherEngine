import Foundation

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}

private final class PendingRead: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    private let result = Locked<Result<SoftwareStoredPacket?, Error>?>(nil)
    init(_ source: SoftwarePacketReadAhead) {
        DispatchQueue.global().async {
            let answer = Result { try source.read() }
            self.result.withValue { $0 = answer }
            self.completed.signal()
        }
    }
    func finish() -> Result<SoftwareStoredPacket?, Error> {
        requireSignal(completed, "consumer read did not complete")
        return result.withValue { $0! }
    }
}

private func requireSignal(_ semaphore: DispatchSemaphore, _ message: String) {
    precondition(semaphore.wait(timeout: .now() + 5) == .success, message)
}

private func eventually(_ message: String, _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() {
        precondition(Date() < deadline, message)
        Thread.sleep(forTimeInterval: 0.001)
    }
}

private func check(_ condition: @autoclosure () throws -> Bool,
                   _ message: String = "assertion failed") rethrows {
    let result = try condition()
    precondition(result, message)
}

@main
struct SoftwarePacketReadAheadTests {
    static let video = SoftwarePacketReadAhead.Stream(index: 0, numerator: 1, denominator: 1)
    static let audio = SoftwarePacketReadAhead.Stream(index: 1, numerator: 1, denominator: 1)
    enum SourceFailure: Error { case rejected, deliberate }

    static func packet(_ pts: Int64, stream: Int32 = 0, duration: Int64 = 1,
                       marker: UInt8 = 7, payloadSize: Int = 8) -> SoftwareStoredPacket {
        SoftwareStoredPacket(pts: pts, dts: pts - 2, duration: duration,
            position: 123_456 + pts, streamIndex: stream, flags: 0x21,
            timeBaseNumerator: 1, timeBaseDenominator: 1,
            bytes: Data(repeating: marker, count: payloadSize),
            sideData: [.init(type: 0, bytes: Data([0, 1, 0, 255])),
                       .init(type: 70, bytes: Data()), .init(type: UInt32.max, bytes: Data([9]))])
    }

    static func make(_ root: URL, audio: SoftwarePacketReadAhead.Stream? = nil,
                     budget: Int = 1_000_000, seconds: Double = 100, clock: Double = 0,
                     beforeConsumerOperation: (@Sendable () -> Void)? = nil,
                     read: @escaping @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?) throws
        -> (SoftwarePacketReadAhead, SoftwarePacketDiskFIFO) {
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 1024, parentDirectory: root)
        let source = SoftwarePacketReadAhead(video: video, audio: audio,
            byteBudget: budget, forwardSeconds: seconds, initialSourceClock: clock, fifo: fifo,
            beforeConsumerOperation: beforeConsumerOperation, readSource: read)
        return (source, fifo)
    }

    static func close(_ source: SoftwarePacketReadAhead, _ fifo: SoftwarePacketDiskFIFO) {
        source.close()
        eventually("worker did not close its FIFO") { fifo.snapshot.isClosed }
        precondition(!FileManager.default.fileExists(atPath: fifo.storageDirectory.path))
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aether-packet-read-ahead-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try roundTripAndEOF(root)
        try queuedSeekReset(root)
        try blockedReadAndRapidSeeks(root)
        try sourceLockAdmission(root)
        try closeUnblocksConsumer(root)
        try byteBound(root)
        try timeBoundAndPlayhead(root)
        try selectedAVCoverage(root)
        try delayedOldConsumer(root)
        try explicitFailure(root)
        try closeBeforeStart(root)
        try check(FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        print("PASS: packet metadata/side-data, EOF/errors, seek reset/rapid seeks, source-lock admission, close wake, byte/time bounds, A/V gaps, delayed old consumer")
    }

    static func roundTripAndEOF(_ root: URL) throws {
        let unknownTiming = SoftwareStoredPacket(pts: Int64.min, dts: Int64.max, duration: 0,
            position: -1, streamIndex: -1, flags: Int32.min,
            timeBaseNumerator: 1001, timeBaseDenominator: 30_000, bytes: Data(),
            sideData: [.init(type: UInt32.max, bytes: Data([0, 0, 255]))])
        let packets = [packet(0), packet(1, marker: 8), packet(2, stream: 1, marker: 9), unknownTiming]
        for packet in packets { try check(SoftwareStoredPacket.decode(packet.encoded()) == packet) }
        let index = Locked(0)
        let (source, fifo) = try make(root) { accepts in
            try index.withValue { current in
                guard accepts() else { throw SourceFailure.rejected }
                guard current < packets.count else { return nil }
                defer { current += 1 }
                return packets[current]
            }
        }
        source.start()
        for packet in packets { try check(PendingRead(source).finish().get() == packet) }
        try check(PendingRead(source).finish().get() == nil)
        precondition(source.snapshot.sourceEnded && source.snapshot.packetCount == 0)
        precondition(source.snapshot.bytes == 0)
        close(source, fifo)
    }

    static func queuedSeekReset(_ root: URL) throws {
        let next = Locked(packet(0, marker: 11))
        let (source, fifo) = try make(root, budget: 1) { accepts in
            try next.withValue { value in
                guard accepts() else { throw SourceFailure.rejected }
                return value
            }
        }
        source.start()
        eventually("old packet did not queue") { source.snapshot.packetCount == 1 }
        let token = source.beginSeek()
        precondition(source.snapshot.frontier == nil && source.snapshot.packetCount == 0)
        let expected = packet(10, marker: 22)
        next.withValue { $0 = expected }
        source.endSeek(token, sourceClock: 10)
        try check(PendingRead(source).finish().get() == expected)
        close(source, fifo)
    }

    static func blockedReadAndRapidSeeks(_ root: URL) throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let calls = Locked(0)
        let old = packet(0, marker: 31)
        let fresh = packet(20, marker: 32)
        let (source, fifo) = try make(root, budget: 1) { accepts in
            let call = try calls.withValue { value in
                guard accepts() else { throw SourceFailure.rejected }
                defer { value += 1 }; return value
            }
            if call == 0 {
                // A source read has returned its old packet under the source lock, but its
                // caller has not yet handed it back to the producer for publication.
                entered.signal(); requireSignal(release, "blocked source was not released")
                return old
            }
            return fresh
        }
        source.start()
        requireSignal(entered, "source did not enter old read")
        let first = source.beginSeek()
        let second = source.beginSeek()
        source.endSeek(first, sourceClock: 10)
        precondition(source.snapshot.seeking, "older seek cleared newer hold")
        source.endSeek(second, sourceClock: 20)
        release.signal()
        try check(PendingRead(source).finish().get() == fresh, "old blocked read escaped")
        precondition(source.snapshot.generation == second)
        close(source, fifo)
    }

    static func sourceLockAdmission(_ root: URL) throws {
        let beforeLock = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let attempts = Locked(0)
        let admitted = Locked(0)
        let sourceReadLock = NSLock()
        let expected = packet(40, marker: 41)
        let (source, fifo) = try make(root, budget: 1) { accepts in
            let call = attempts.withValue { value in defer { value += 1 }; return value }
            if call == 0 { beforeLock.signal(); requireSignal(resume, "admission was not resumed") }
            sourceReadLock.lock(); defer { sourceReadLock.unlock() }
            guard accepts() else { throw SourceFailure.rejected }
            admitted.withValue { $0 += 1 }
            return expected
        }
        source.start()
        requireSignal(beforeLock, "source did not pause before serialization lock")
        let token = source.beginSeek()
        sourceReadLock.lock() // mirrors the real Demuxer seek's serialization boundary
        sourceReadLock.unlock()
        source.endSeek(token, sourceClock: 40)
        resume.signal()
        eventually("fresh generation did not queue") { source.snapshot.packetCount == 1 }
        precondition(attempts.withValue { $0 } == 2)
        precondition(admitted.withValue { $0 } == 1, "stale invocation advanced post-seek source")
        try check(PendingRead(source).finish().get() == expected)
        close(source, fifo)
    }

    static func closeUnblocksConsumer(_ root: URL) throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let (source, fifo) = try make(root) { accepts in
            guard accepts() else { throw SourceFailure.rejected }
            entered.signal(); requireSignal(release, "closed source was not released")
            return packet(0)
        }
        source.start()
        requireSignal(entered, "source was not blocked")
        let pending = PendingRead(source)
        source.close()
        switch pending.finish() {
        case .failure(SoftwarePacketReadAhead.ReadError.closed): break
        default: preconditionFailure("close did not wake consumer with explicit closed error")
        }
        precondition(source.snapshot.frontier == nil && source.snapshot.packetCount == 0)
        release.signal()
        close(source, fifo)
    }

    static func byteBound(_ root: URL) throws {
        let calls = Locked(0)
        let secondCall = DispatchSemaphore(value: 0)
        let sample = packet(0, payloadSize: 4096)
        let (source, fifo) = try make(root, budget: 1) { accepts in
            try calls.withValue { value in
                guard accepts() else { throw SourceFailure.rejected }
                value += 1
                if value == 2 { secondCall.signal() }
                return sample
            }
        }
        source.start()
        eventually("byte-bound packet did not arrive") { source.snapshot.packetCount == 1 }
        try check(source.snapshot.bytes == sample.encoded().count)
        precondition(secondCall.wait(timeout: .now() + 0.1) == .timedOut,
                     "prefetch exceeded one-packet byte-budget overshoot while consumer paused")
        try check(PendingRead(source).finish().get() == sample)
        requireSignal(secondCall, "consumer drain did not release byte backpressure")
        close(source, fifo)
    }

    static func timeBoundAndPlayhead(_ root: URL) throws {
        let next = Locked(Int64(0))
        let thirdCall = DispatchSemaphore(value: 0)
        let (source, fifo) = try make(root, seconds: 2) { accepts in
            try next.withValue { value in
                guard accepts() else { throw SourceFailure.rejected }
                if value == 2 { thirdCall.signal() }
                defer { value += 1 }; return packet(value)
            }
        }
        source.start()
        eventually("time-bound coverage did not fill") { source.snapshot.frontier == 2 }
        precondition(source.snapshot.packetCount == 2)
        precondition(thirdCall.wait(timeout: .now() + 0.1) == .timedOut,
                     "prefetch exceeded time target while consumer/playhead paused")
        source.updatePlayhead(1)
        requireSignal(thirdCall, "playhead advance did not release time backpressure")
        eventually("new time target did not fill") { source.snapshot.frontier == 3 }
        close(source, fifo)
    }

    static func selectedAVCoverage(_ root: URL) throws {
        // Decode-order B-picture gap and slower selected audio each limit the frontier.
        let packets = [packet(0), packet(2), packet(0, stream: 1), packet(1), packet(2, stream: 1)]
        let index = Locked(0)
        let (source, fifo) = try make(root, audio: audio) { accepts in
            try index.withValue { value in
                guard accepts() else { throw SourceFailure.rejected }
                guard value < packets.count else { return nil }
                defer { value += 1 }; return packets[value]
            }
        }
        source.start()
        eventually("A/V test source did not end") { source.snapshot.sourceEnded }
        precondition(source.snapshot.frontier == 1, "missing audio interval was bridged")
        source.updatePlayhead(1)
        precondition(source.snapshot.frontier == nil, "clock in selected-audio gap got false coverage")
        source.updatePlayhead(2)
        precondition(source.snapshot.frontier == 3)
        close(source, fifo)
    }

    static func delayedOldConsumer(_ root: URL) throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let hookCalls = Locked(0)
        let next = Locked(packet(0, marker: 51))
        let (source, fifo) = try make(root, budget: 1, beforeConsumerOperation: {
            let first = hookCalls.withValue { value in defer { value += 1 }; return value == 0 }
            if first { entered.signal(); requireSignal(release, "old consumer was not released") }
        }) { accepts in
            try next.withValue { value in
                guard accepts() else { throw SourceFailure.rejected }; return value
            }
        }
        source.start()
        eventually("old consumer fixture did not queue") { source.snapshot.packetCount == 1 }
        let oldConsumer = PendingRead(source)
        requireSignal(entered, "old consumer did not pause before operations lock")
        let token = source.beginSeek()
        let expected = packet(60, marker: 61)
        next.withValue { $0 = expected }
        source.endSeek(token, sourceClock: 60)
        eventually("new packet did not arrive after delayed reset") {
            source.snapshot.packetCount == 1 && source.snapshot.frontier == 61
        }
        release.signal()
        switch oldConsumer.finish() {
        case .failure(SoftwarePacketReadAhead.ReadError.interrupted): break
        default: preconditionFailure("old consumer escaped its generation")
        }
        precondition(source.snapshot.packetCount == 1, "old consumer consumed the new generation")
        try check(PendingRead(source).finish().get() == expected)
        close(source, fifo)
    }

    static func explicitFailure(_ root: URL) throws {
        let (source, fifo) = try make(root) { accepts in
            guard accepts() else { throw SourceFailure.rejected }
            throw SourceFailure.deliberate
        }
        source.start()
        switch PendingRead(source).finish() {
        case .failure(SourceFailure.deliberate): break
        default: preconditionFailure("source error was turned into EOF")
        }
        precondition(!source.snapshot.sourceEnded)
        close(source, fifo)
    }

    static func closeBeforeStart(_ root: URL) throws {
        let (source, fifo) = try make(root) { _ in preconditionFailure("closed source started") }
        close(source, fifo)
        source.start()
        precondition(fifo.snapshot.isClosed)
    }
}
