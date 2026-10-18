import Foundation
import Testing
@testable import AetherEngine

/// Matroska TrueHD reaches the read-ahead with no packet duration and millisecond timestamps that
/// repeat (0.83 ms frames on a 1/1000 time base). The duration model rejected every such packet, so
/// audio coverage stayed empty, the combined A/V frontier was nil, and no seek ever hit the packet
/// cache: on the TV every TrueHD seek, even back to a spot just played, refetched from the source.
@Suite("Software VOD read-ahead audio coverage without durations")
struct SoftwarePacketReadAheadAudioCoverageTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    /// 25 fps video (40 ticks) interleaved with 1200 Hz audio frames on a 1/1000 time base, 4 s,
    /// then EOF. `audioGapAt` (seconds) drops one second of audio there.
    private func runToEnd(audioDuration: Int64, audioGapAt: Double? = nil) throws -> SoftwarePacketReadAhead {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readahead-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var packets: [SoftwareStoredPacket] = []
        var audioFrame = 0
        for picture in 0..<100 {
            let videoPTS = Int64(picture * 40)
            packets.append(SoftwareStoredPacket(
                pts: videoPTS, dts: videoPTS, duration: 40, position: 0, streamIndex: 0, flags: 0x1,
                timeBaseNumerator: 1, timeBaseDenominator: 1000, bytes: Data(repeating: 7, count: 64),
                sideData: []))
            // 48 audio frames of 1/1200 s per 40 ms picture.
            for _ in 0..<48 {
                let seconds = Double(audioFrame) / 1200
                audioFrame += 1
                if let gap = audioGapAt, seconds >= gap, seconds < gap + 1 { continue }
                let audioPTS = Int64((seconds * 1000).rounded(.down))
                packets.append(SoftwareStoredPacket(
                    pts: audioPTS, dts: audioPTS, duration: audioDuration, position: 0, streamIndex: 1,
                    flags: 0x1, timeBaseNumerator: 1, timeBaseDenominator: 1000,
                    bytes: Data(repeating: 3, count: 16), sideData: []))
            }
        }
        let counter = Counter()
        let all = packets
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        let source = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: .init(index: 1, numerator: 1, denominator: 1000),
            byteBudget: 64 << 20, forwardSeconds: 100, initialSourceClock: 0, fifo: fifo
        ) { _ in
            let index = counter.next() - 1
            return index < all.count ? all[index] : nil
        }
        source.start()
        let deadline = Date().addingTimeInterval(10)
        while !source.snapshot.sourceEnded, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(source.snapshot.sourceEnded)
        return source
    }

    private func seekHits(_ source: SoftwarePacketReadAhead, to seconds: Double) throws -> Bool {
        let token = source.beginSeek(to: seconds)
        return try source.prepareSeek(token, to: seconds)
    }

    @Test("duration-less, repeating-millisecond audio still makes a retained seek a cache hit")
    func durationlessAudioHits() throws {
        let source = try runToEnd(audioDuration: 0)
        defer { source.close() }
        #expect(try seekHits(source, to: 2.0))
    }

    @Test("audio with durations keeps hitting as before")
    func durationAudioHits() throws {
        let source = try runToEnd(audioDuration: 1)
        defer { source.close() }
        #expect(try seekHits(source, to: 2.0))
    }

    @Test("a real hole in duration-less audio is not bridged")
    func audioHoleMisses() throws {
        let source = try runToEnd(audioDuration: 0, audioGapAt: 1.5)
        defer { source.close() }
        #expect(try seekHits(source, to: 2.0) == false)
    }
}
extension SoftwarePacketReadAheadAudioCoverageTests {
    private final class Packets: @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0
        let values: [SoftwareStoredPacket]
        init(_ values: [SoftwareStoredPacket]) { self.values = values }
        func next() -> SoftwareStoredPacket? {
            lock.lock(); defer { lock.unlock() }
            guard index < values.count else { return nil }
            defer { index += 1 }
            return values[index]
        }
    }

    @Test("A huge increasing audio PTS cannot trap in the read-ahead worker", .timeLimit(.minutes(1)))
    func overflowingSuccessor() async throws {
        func packet(_ pts: Int64, stream: Int32, duration: Int64) -> SoftwareStoredPacket {
            SoftwareStoredPacket(pts: pts, dts: pts, duration: duration, position: 0,
                streamIndex: stream, flags: 1, timeBaseNumerator: 1, timeBaseDenominator: 1000,
                bytes: Data(repeating: 1, count: 16), sideData: [])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-overflow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packets = Packets([
            packet(0, stream: 0, duration: 40),
            packet(Int64.min + 1, stream: 1, duration: 0),
            packet(Int64.max - 1, stream: 1, duration: 0),
            packet(40, stream: 0, duration: 40),
        ])
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        let reader = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: .init(index: 1, numerator: 1, denominator: 1000),
            byteBudget: 1 << 20, forwardSeconds: 100, initialSourceClock: 0, fifo: fifo
        ) { _ in packets.next() }
        defer { reader.close() }
        reader.start()
        try await waitFor { reader.snapshot.sourceEnded }
        let token = reader.beginSeek(to: 0.02)
        #expect(try reader.prepareSeek(token, to: 0.02) == false,
                "Overflow must not invent audio coverage over the video interval")
    }
}
