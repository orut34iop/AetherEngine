import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

func av_packet_free_safe(_ packet: UnsafeMutablePointer<AVPacket>) {
    var owned: UnsafeMutablePointer<AVPacket>? = packet
    trackedPacketFree(&owned)
}

// Test-only snapshot: no dependency on the independent software packet-cache proposal.
struct TimestampPacketSnapshot: Codable, Sendable, Equatable {
    struct SideData: Codable, Sendable, Equatable {
        let type: UInt32
        let bytes: Data
    }
    let pts: Int64
    let dts: Int64
    let duration: Int64
    let position: Int64
    let streamIndex: Int32
    let flags: Int32
    let timeBaseNumerator: Int32
    let timeBaseDenominator: Int32
    let bytes: Data
    let sideData: [SideData]

}
extension TimestampPacketSnapshot {
    enum PacketError: Error { case invalidPacket, allocationFailed }

    init(copying packet: UnsafeMutablePointer<AVPacket>) throws {
        let p = packet.pointee
        guard p.size >= 0, p.side_data_elems >= 0,
              p.size == 0 || p.data != nil,
              p.side_data_elems == 0 || p.side_data != nil else { throw PacketError.invalidPacket }
        var sides: [SideData] = []
        for index in 0..<Int(p.side_data_elems) {
            let side = p.side_data[index]
            guard side.size == 0 || side.data != nil else { throw PacketError.invalidPacket }
            sides.append(SideData(type: side.type.rawValue,
                                  bytes: side.size == 0 ? Data() : Data(bytes: side.data, count: side.size)))
        }
        self.init(pts: p.pts, dts: p.dts, duration: p.duration, position: p.pos,
                  streamIndex: p.stream_index, flags: p.flags,
                  timeBaseNumerator: p.time_base.num, timeBaseDenominator: p.time_base.den,
                  bytes: p.size == 0 ? Data() : Data(bytes: p.data, count: Int(p.size)), sideData: sides)
    }

}

@main
struct H264TimestampRuntimeTests {
    enum Failure: Error { case open, decoder, demux, decode, session, boundedRead }
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { throw Failure.open }
        av_log_set_level(AV_LOG_QUIET)
        var format: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&format, CommandLine.arguments[1], nil, nil) >= 0, let format else { throw Failure.open }
        defer { var owned: UnsafeMutablePointer<AVFormatContext>? = format; avformat_close_input(&owned) }
        guard avformat_find_stream_info(format, nil) >= 0 else { throw Failure.open }
        let index = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard index >= 0, let stream = format.pointee.streams[Int(index)],
              let par = stream.pointee.codecpar, par.pointee.codec_id == AV_CODEC_ID_H264 else { throw Failure.open }
        let name = format.pointee.iformat.flatMap { $0.pointee.name }.map(String.init(cString:)) ?? ""
        let matroska = name.contains("matroska")
        let expectedRepair = ProcessInfo.processInfo.environment["AETHER_EXPECT_TIMESTAMP_REPAIR"]
            .map { $0 == "1" } ?? matroska
        guard let session: any H264TimestampRepairSession = matroska
            ? H264MatroskaTimestampRepairSession(stream: stream, streamIndex: index)
            : H264CompositionOffsetRepairSession(containerFormatName: name, stream: stream, streamIndex: index, ladderStart: 0)
        else { throw Failure.session }
        let raw = try decoder(par, timeBase: stream.pointee.time_base)
        let fixed = try decoder(par, timeBase: stream.pointee.time_base)
        defer {
            var a: UnsafeMutablePointer<AVCodecContext>? = raw; avcodec_free_context(&a)
            var b: UnsafeMutablePointer<AVCodecContext>? = fixed; avcodec_free_context(&b)
        }
        var inputs: [UInt: TimestampPacketSnapshot] = [:]
        var previousLead: Int64?
        let positions = CommandLine.arguments.dropFirst(2).compactMap(Double.init)
        for position in positions.isEmpty ? [0] : positions {
            if position > 0 {
                let target = Int64(position / av_q2d(stream.pointee.time_base))
                guard av_seek_frame(format, index, target, AVSEEK_FLAG_BACKWARD) >= 0 else { throw Failure.demux }
            }
            session.noteSeek()
            avcodec_flush_buffers(raw); avcodec_flush_buffers(fixed)
            var rawPTS: [Int64] = [], fixedPTS: [Int64] = []
            var videoRead = 0, reads = 0, delivered = 0, stop = false
            func emit(_ packet: UnsafeMutablePointer<AVPacket>) throws {
                defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&owned) }
                let expected = inputs.removeValue(forKey: UInt(bitPattern: packet))!
                let actual = try TimestampPacketSnapshot(copying: packet)
                // Exact packet payload/side-data/flags/duration/audio preservation, not just a
                // model calculation. Only the selected video PTS/DTS may differ.
                if packet.pointee.stream_index == index {
                    precondition(actual.bytes == expected.bytes && actual.sideData == expected.sideData)
                    precondition(actual.duration == expected.duration && actual.flags == expected.flags)
                    precondition(actual.position == expected.position && actual.streamIndex == expected.streamIndex)
                    if !expectedRepair { precondition(actual == expected) }
                    try decode(fixed, packet: packet, into: &fixedPTS)
                } else { precondition(actual == expected) }
                delivered += 1
            }
            while !stop {
                while let packet = session.dequeue() { try emit(packet) }
                guard reads < 10000, videoRead < 2000 else { throw Failure.boundedRead }
                guard let packet = trackedPacketAlloc() else { throw Failure.demux }
                let status = av_read_frame(format, packet)
                if status < 0 {
                    var owned: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&owned)
                    guard status == -541478725 else { throw Failure.demux }
                    stop = true
                    break
                }
                reads += 1
                inputs[UInt(bitPattern: packet)] = try TimestampPacketSnapshot(copying: packet)
                if packet.pointee.stream_index == index {
                    let key = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
                    stop = videoRead >= 180 && key
                    videoRead += 1
                    try decode(raw, packet: packet, into: &rawPTS)
                }
                if try !session.ingest(packet) { try emit(packet) }
            }
            try session.endOfStream()
            while let packet = session.dequeue() { try emit(packet) }
            try decode(raw, packet: nil, into: &rawPTS)
            try decode(fixed, packet: nil, into: &fixedPTS)
            precondition(inputs.isEmpty && PacketBalanceTracker.alive == 0)
            let rawRegressions = zip(rawPTS, rawPTS.dropFirst()).filter { $1 <= $0 }.count
            let fixedRegressions = zip(fixedPTS, fixedPTS.dropFirst()).filter { $1 <= $0 }.count
            precondition(rawPTS.count == fixedPTS.count && !fixedPTS.isEmpty)
            precondition(fixedRegressions == 0)
            if expectedRepair {
                precondition(rawRegressions > 0 && session.decodeTimestampOffset != nil)
                if matroska { precondition(rawPTS.sorted() == fixedPTS, "every original presentation slot is preserved") }
                if let previousLead { precondition(previousLead == session.decodeTimestampOffset) }
                previousLead = session.decodeTimestampOffset
            } else { precondition(rawRegressions == 0 && session.decodeTimestampOffset == nil) }
            print("PASS source_kind=\(matroska ? "matroska" : "mp4") seek=\(position) decoded=\(fixedPTS.count) original_regressions=\(rawRegressions) repaired_regressions=\(fixedRegressions) packets=\(delivered) reason=\(session.summary) decode_offset=\(session.decodeTimestampOffset ?? 0) packet_balance=0")
        }
        if matroska && expectedRepair { try lifecycleChecks(format: format, stream: stream, index: index) }
    }

    static func lifecycleChecks(format: UnsafeMutablePointer<AVFormatContext>, stream: UnsafeMutablePointer<AVStream>, index: Int32) throws {
        guard let session = H264MatroskaTimestampRepairSession(stream: stream, streamIndex: index) else { throw Failure.session }
        // Seek with both unpublished input and a partly consumed ready queue. Those old packets
        // must be freed rather than replayed into the new source position.
        for goal in [3, 170] {
            guard av_seek_frame(format, index, 0, AVSEEK_FLAG_BACKWARD) >= 0 else { throw Failure.demux }
            session.noteSeek()
            for _ in 0..<goal {
                guard let packet = trackedPacketAlloc(), av_read_frame(format, packet) >= 0 else { throw Failure.demux }
                if try !session.ingest(packet) { av_packet_free_safe(packet) }
            }
            if let first = session.dequeue() { av_packet_free_safe(first) }
            session.noteSeek()
            precondition(session.dequeue() == nil && PacketBalanceTracker.alive == 0)
        }
        // After activation, an unparseable sequence is an explicit failure; no changed-axis
        // half-sequence or leaked packet is allowed to escape.
        guard let malformed = trackedPacketAlloc() else { throw Failure.demux }
        malformed.pointee.stream_index = index
        do { _ = try session.ingest(malformed); throw Failure.session }
        catch H264MatroskaTimestampRepairSession.RepairError.sequenceNoLongerRepairable { }
        precondition(PacketBalanceTracker.alive == 0)
        guard let bounded = H264MatroskaTimestampRepairSession(stream: stream, streamIndex: index) else { throw Failure.session }
        for _ in 0..<1024 {
            guard let packet = trackedPacketAlloc() else { throw Failure.demux }
            packet.pointee.stream_index = index + 1
            let taken = try bounded.ingest(packet)
            precondition(taken)
        }
        precondition(bounded.isDecided)
        var released = 0
        while let packet = bounded.dequeue() { av_packet_free_safe(packet); released += 1 }
        precondition(released == 1024 && PacketBalanceTracker.alive == 0)
        print("PASS lifecycle=seek-during-sampling,seek-with-ready-and-pending,active-fail-closed,all-stream-packet-budget packet_balance=0")
    }

    static func decoder(_ parameters: UnsafeMutablePointer<AVCodecParameters>, timeBase: AVRational) throws
        -> UnsafeMutablePointer<AVCodecContext> {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_H264), let context = avcodec_alloc_context3(codec) else { throw Failure.decoder }
        guard avcodec_parameters_to_context(context, parameters) >= 0 else { throw Failure.decoder }
        context.pointee.pkt_timebase = timeBase
        context.pointee.thread_count = 1
        guard avcodec_open2(context, codec, nil) >= 0 else { throw Failure.decoder }
        return context
    }

    static func decode(_ decoder: UnsafeMutablePointer<AVCodecContext>, packet: UnsafeMutablePointer<AVPacket>?, into pts: inout [Int64]) throws {
        guard avcodec_send_packet(decoder, packet) >= 0, let frame = av_frame_alloc() else { throw Failure.decode }
        defer { var owned: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&owned) }
        while true {
            let status = avcodec_receive_frame(decoder, frame)
            if status == -35 || status == -541478725 { return }
            guard status >= 0 else { throw Failure.decode }
            pts.append(frame.pointee.pts)
            av_frame_unref(frame)
        }
    }
}
