import Foundation
import Testing
@testable import AetherEngine

@Suite("Software VOD resident ranges", .timeLimit(.minutes(2)))
struct SoftwareResidentRangesTests {
    private final class Input: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [SoftwareStoredPacket]
        private var index = 0
        init(_ packets: [SoftwareStoredPacket]) { self.packets = packets }
        func next() -> SoftwareStoredPacket? {
            lock.lock(); defer { lock.unlock() }
            guard index < packets.count else { return nil }
            defer { index += 1 }; return packets[index]
        }
    }
    private func packet(_ pts: Int64, stream: Int32 = 0, duration: Int64 = 40,
                        key: Bool = true) -> SoftwareStoredPacket {
        .init(pts: pts, dts: pts, duration: duration, position: 0, streamIndex: stream,
              flags: key ? 1 : 0, timeBaseNumerator: 1, timeBaseDenominator: 1000,
              bytes: Data(repeating: 7, count: 100), sideData: [])
    }
    private func source(_ packets: [SoftwareStoredPacket], audio: Bool = false,
                        reorder: Int? = nil, budget: Int = 1_000_000,
                        chunkBytes: Int = 1024) throws -> SoftwarePacketReadAhead {
        let input = Input(packets)
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: chunkBytes, retainConsumed: true)
        let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: audio ? .init(index: 1, numerator: 1, denominator: 1000) : nil,
            byteBudget: budget, forwardSeconds: 3600, initialSourceClock: 0,
            fifo: fifo, videoReorderDepth: reorder) { _ in input.next() }
        source.start()
        return source
    }
    private func ended(_ source: SoftwarePacketReadAhead) throws {
        let deadline = Date().addingTimeInterval(5)
        while !source.snapshot.sourceEnded, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        #expect(source.snapshot.sourceEnded)
    }

    @Test("Backward and forward cache hits preserve the same spans through begin, prepare and settle")
    func cachedSeeks() throws {
        let source = try source((0..<100).map { packet(Int64($0) * 40) })
        defer { source.close() }
        try ended(source)
        #expect(source.residentRanges == [0...4])
        for target in [3.0, 1, 2.5, 0.5] {
            source.updatePlayhead(target)
            let token = source.beginSeek(to: target)
            #expect(source.residentRanges == [0...4])
            #expect(try source.prepareSeek(token, to: target))
            #expect(source.residentRanges == [0...4])
            source.endSeek(token, sourceClock: target)
            #expect(source.residentRanges == [0...4])
        }
        let miss = source.beginSeek(to: 8)
        #expect(try !source.prepareSeek(miss, to: 8))
        #expect(source.residentRanges.isEmpty)
        source.close()
        #expect(source.residentRanges.isEmpty)
    }

    @Test("Required audio intersects video, keeps holes, and missing selected audio proves nothing")
    func audioIntersection() throws {
        let video = (0..<100).map { packet(Int64($0) * 40) }
        let audio = [packet(500, stream: 1, duration: 500), packet(2000, stream: 1, duration: 1000)]
        let source = try source(video + audio, audio: true)
        defer { source.close() }
        try ended(source)
        #expect(source.residentRanges == [0.5...1, 2...3])
        let missing = try self.source(video, audio: true)
        defer { missing.close() }
        try ended(missing)
        #expect(missing.residentRanges.isEmpty)
    }

    @Test("Successor PTS retains reorder semantics, a discontinuity, and no invented final frame")
    func reorderedVideo() throws {
        let pts: [Int64] = [0, 120, 40, 80, 160, 2000, 2120, 2040, 2080]
        let source = try source(pts.map { packet($0, duration: 0) }, reorder: 4)
        defer { source.close() }
        try ended(source)
        #expect(source.residentRanges == [0...0.16, 2...2.12])
        let invalid = try self.source(([Int64](stride(from: 0, to: 2000, by: 40)) + [0])
            .map { packet($0) }, reorder: 4)
        defer { invalid.close() }
        try ended(invalid)
        #expect(invalid.residentRanges.isEmpty)
    }

    @Test("Real FIFO eviction shortens backward coverage without changing the read bytes")
    func diskEviction() throws {
        let packets = (0..<100).map { packet(Int64($0) * 40) }
        let source = try source(packets, budget: 1400, chunkBytes: 512)
        defer { source.close() }
        for packet in packets {
            #expect(try source.read() == packet)
            source.updatePlayhead(Double(packet.pts) / 1000)
        }
        try ended(source)
        let spans = source.residentRanges
        #expect(!spans.isEmpty)
        #expect((spans.first?.lowerBound ?? 0) > 3)
        #expect(spans.last?.upperBound == 4)
        let miss = source.beginSeek(to: 0.1)
        #expect(try !source.prepareSeek(miss, to: 0.1))
        #expect(source.residentRanges.isEmpty)
    }

    @Test("Evicted reordered timestamps and metadata pressure only shorten coverage")
    func residencyWatermarks() {
        var value = SoftwarePacketResidency(maximumChunks: 2)
        value.insert(chunkID: 0, pts: 900, duration: 40, numerator: 1, denominator: 1000, isVideo: true)
        value.insert(chunkID: 1, pts: 100, duration: 40, numerator: 1, denominator: 1000, isVideo: true)
        value.insert(chunkID: 1, pts: 1100, duration: 40, numerator: 1, denominator: 1000, isVideo: false)
        value.evict(before: 1)
        #expect(value.videoFloor == 0.94)
        #expect(value.audioFloor == -.infinity)
        value.insert(chunkID: 2, pts: 1200, duration: 0, numerator: 1, denominator: 1000, isVideo: true)
        value.insert(chunkID: 3, pts: 1300, duration: 0, numerator: 1, denominator: 1000, isVideo: true)
        #expect(value.videoFloor == 0.94)
        #expect(value.audioFloor == 1.14)
        value.evict(before: 4)
        #expect(value.videoFloor == 1.301)
    }

    @Test("Invalid discarded timestamps fail closed and reset begins a separate residency lifetime")
    func invalidWatermark() {
        var value = SoftwarePacketResidency()
        value.insert(chunkID: 0, pts: .max, duration: 40, numerator: 1, denominator: 1000, isVideo: true)
        value.evict(before: 1)
        #expect(value.videoFloor == .infinity)
        value = SoftwarePacketResidency()
        #expect(value.videoFloor == -.infinity)
    }

    private enum SourceFailure: Error { case unavailable }
    private final class FailingInput: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [SoftwareStoredPacket]
        private var index = 0
        private var failAtEnd = true
        let reachedEnd = DispatchSemaphore(value: 0)
        let releaseEnd = DispatchSemaphore(value: 0)
        init(_ packets: [SoftwareStoredPacket]) { self.packets = packets }
        func next() throws -> SoftwareStoredPacket? {
            lock.lock()
            if index < packets.count {
                let packet = packets[index]; index += 1
                lock.unlock(); return packet
            }
            let fail = failAtEnd
            lock.unlock()
            if fail {
                reachedEnd.signal(); releaseEnd.wait()
                throw SourceFailure.unavailable
            }
            return nil
        }
        func replace(_ packets: [SoftwareStoredPacket]) {
            lock.lock(); defer { lock.unlock() }
            self.packets = packets; index = 0; failAtEnd = false
        }
    }

    @Test("A source failure preserves committed coverage and cached seeks, but never becomes EOF",
           arguments: [false, true])
    func retainedAfterSourceFailure(reordered: Bool) throws {
        let packets = (0..<100).map { packet(Int64($0) * 40, key: $0 == 0) }
        let input = FailingInput(packets)
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 1024, retainConsumed: true)
        let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: nil, byteBudget: 1_000_000, forwardSeconds: 3600, initialSourceClock: 0,
            fifo: fifo, videoReorderDepth: reordered ? 4 : nil) { _ in try input.next() }
        defer { input.releaseEnd.signal(); source.close() }
        source.start()
        #expect(input.reachedEnd.wait(timeout: .now() + 5) == .success)
        let before = source.residentRanges
        #expect(!before.isEmpty)
        let epoch = source.snapshot.sourceEpoch
        input.releaseEnd.signal()
        let deadline = Date().addingTimeInterval(5)
        while !source.producerParkedForTesting, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        #expect(source.producerParkedForTesting)
        #expect(!source.snapshot.sourceEnded)
        #expect(source.residentRanges == before)
        // A failure cannot flush unresolved successor PTS as though it proved a normal EOF.
        if reordered { #expect((before.last?.upperBound ?? 4) < 3.96) }
        for expected in packets { #expect(try source.read() == expected) }
        #expect(throws: SourceFailure.self) { _ = try source.read() }
        for target in [0.5, 2.0, 1.0] {
            let token = source.beginSeek(to: target)
            #expect(try source.prepareSeek(token, to: target))
            source.endSeek(token, sourceClock: target)
            #expect(source.snapshot.sourceEpoch == epoch)
            #expect(source.residentRanges == before)
            for expected in packets { #expect(try source.read() == expected) }
            #expect(throws: SourceFailure.self) { _ = try source.read() }
            #expect(!source.snapshot.sourceEnded)
        }
        // A miss still resets the failed source lifetime and accepts only the new epoch's data.
        let replacement = (0..<100).map { packet(10_000 + Int64($0) * 40, key: $0 == 0) }
        let miss = source.beginSeek(to: 10)
        #expect(try !source.prepareSeek(miss, to: 10))
        #expect(source.residentRanges.isEmpty)
        input.replace(replacement)
        source.endSeek(miss, sourceClock: 10)
        try ended(source)
        #expect(source.snapshot.sourceEpoch == epoch + 1)
        #expect(source.residentRanges.first?.lowerBound == 10)
        for expected in replacement { #expect(try source.read() == expected) }
        #expect(try source.read() == nil)
    }

    @Test("A storage append failure still invalidates retained coverage and cached seeks")
    func storageFailureRemainsClosed() throws {
        let packets = (0..<10).map { packet(Int64($0) * 40) }
        let input = Input(packets)
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 1024, retainConsumed: true)
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: nil, byteBudget: 1_000_000, forwardSeconds: 3600, initialSourceClock: 0,
            fifo: fifo) { _ in
                if let packet = input.next() { return packet }
                reached.signal(); release.wait()
                return packets[0]
            }
        defer { release.signal(); source.close() }
        source.start()
        #expect(reached.wait(timeout: .now() + 5) == .success)
        #expect(source.residentRanges == [0...0.4])
        try fifo.close()
        release.signal()
        let deadline = Date().addingTimeInterval(5)
        while !source.producerParkedForTesting, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        #expect(source.producerParkedForTesting)
        #expect(!source.snapshot.sourceEnded)
        #expect(source.residentRanges.isEmpty)
        let miss = source.beginSeek(to: 0.1)
        #expect(try !source.prepareSeek(miss, to: 0.1))
        #expect(source.snapshot.cacheSeekHits == 0)
    }

    @Test("Source origin mapping preserves gaps, clips negatives and rejects unknown origins")
    func displayMapping() {
        let spans = [90.0...105, 110...120]
        #expect(SoftwarePlaybackHost.displayResidentRanges(spans, sessionZeroSeconds: 100) == [0...5, 10...20])
        #expect(SoftwarePlaybackHost.displayResidentRanges(spans, sessionZeroSeconds: .nan).isEmpty)
        #expect(SoftwarePlaybackHost.displayResidentRanges(spans, sessionZeroSeconds: 200).isEmpty)
    }

    @Test("Large inexact timestamps do not manufacture display ranges")
    func exactness() {
        var coverage = SoftwarePacketCoverage()
        coverage.insert(pts: 9_007_199_254_740_993, duration: 4)
        #expect(coverage.rangesSeconds(timeBaseNumerator: 1, timeBaseDenominator: 1).isEmpty)
    }
}

@MainActor
@Suite("Software resident range publication", .timeLimit(.minutes(2)))
struct SoftwareResidentRangePublicationTests {
    @Test("A blocked sampler leaves main responsive, coalesces ticks, and cannot publish after seek/stop")
    func delayedSnapshots() async {
        let publisher = SoftwareResidentRangePublication()
        let release = DispatchSemaphore(value: 0)
        var old: Task<Void, Never>?
        var received: [[ClosedRange<Double>]] = []
        await withCheckedContinuation { started in
            old = publisher.sample {
                #expect(!Thread.isMainThread)
                started.resume()
                release.wait()
                return [0...100]
            } publish: { received.append($0) }
            #expect(publisher.sample({ [0...999] }, publish: { received.append($0) }) == nil)
        }
        // This main-actor turn can run while the background read is blocked. A new seek or stop
        // invalidates it; a new session/seek can immediately publish without waiting for that read.
        publisher.invalidate()
        let replacement = publisher.sample({ [200...220] }, publish: { received.append($0) })
        await replacement?.value
        #expect(received == [[200...220]])
        release.signal()
        await old?.value
        #expect(received == [[200...220]])
    }

    @Test("Paused growth, eviction and a reset publish without a clock tick")
    func pausedUpdates() async {
        let publisher = SoftwareResidentRangePublication()
        var received: [[ClosedRange<Double>]] = []
        for spans: [ClosedRange<Double>] in [[10...30], [10...60], [20...60], [], [80...90]] {
            let work = publisher.sample({ spans }, publish: { received.append($0) })
            await work?.value
        }
        #expect(received == [[10...30], [10...60], [20...60], [], [80...90]])
    }
}
