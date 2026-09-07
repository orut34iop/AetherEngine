import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Both policies share packet ownership/seek semantics, not their detection rules.
protocol H264TimestampRepairSession: AnyObject {
    var isDecided: Bool { get }
    var decodeTimestampOffset: Int64? { get }
    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) throws -> Bool
    func dequeue() -> UnsafeMutablePointer<AVPacket>?
    func enqueueFront(_ packet: UnsafeMutablePointer<AVPacket>)
    func endOfStream() throws
    func noteSeek()
    func diagnostic(sourceSeekable: Bool, isISOBaseMediaFile: Bool, isH264: Bool)
        -> H264CompositionOffsetRepairDiagnostic
}

/// Some Matroska writers label coding order as presentation order. Unlike missing MP4 ctts,
/// FFmpeg may synthesize different DTS here, so PTS!=DTS does NOT establish healthy timing.
/// Hold one bounded IDR-to-IDR sequence and permute its existing timestamp slots by parsed POC.
/// This preserves the original presentation-time set, audio axis and rational rounding exactly;
/// the decoder continues receiving the original compressed packets in their original order.
final class H264MatroskaTimestampRepairSession: H264TimestampRepairSession {
    private struct Entry {
        let packet: UnsafeMutablePointer<AVPacket>
        let poc: Int64?
    }
    enum RepairError: Error { case sequenceNoLongerRepairable }
    private let streamIndex: Int32
    private let videoDelay: Int
    private let timeBase: AVRational
    private let framing: VideoNALFraming
    private let reader: H264PictureOrderReader
    private var pending: [Entry] = []
    private var ready: [UnsafeMutablePointer<AVPacket>] = []
    private var readyIndex = 0
    private var bytes = 0
    private var videoCount = 0
    private var lastPTS: Int64?
    private var lead: Int64?
    private var off = false
    private var failed = false
    private var outcome: H264CompositionOffsetRepairOutcome = .sampling
    private var reason: H264CompositionOffsetRepairReason = .sampling
    private var sampledCount = 0
    private var sampledPackets = 0
    private var sampledBytes = 0
    private var sampledRegressions = 0
    private var repairedCount = 0
    private var unrepairedCount = 0

    init?(stream: UnsafeMutablePointer<AVStream>, streamIndex: Int32) {
        guard let par = stream.pointee.codecpar,
              par.pointee.codec_id == AV_CODEC_ID_H264,
              (1...16).contains(par.pointee.video_delay),
              let reader = H264PictureOrderReader(codecParameters: par, timeBase: stream.pointee.time_base)
        else { return nil }
        self.reader = reader
        self.streamIndex = streamIndex
        videoDelay = Int(par.pointee.video_delay)
        timeBase = stream.pointee.time_base
        framing = A53SEIParser.nalFraming(codec: .h264, extradata: par.pointee.extradata, size: Int(par.pointee.extradata_size))
    }

    deinit { releasePackets() }
    var isDecided: Bool { off || lead != nil }
    var decodeTimestampOffset: Int64? { lead.map { -$0 } }

    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) throws -> Bool {
        if failed {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&owned)
            throw RepairError.sequenceNoLongerRepairable
        }
        guard !off else { return false }
        var poc: Int64?
        if packet.pointee.stream_index == streamIndex {
            poc = reader.pictureOrderCount(for: packet)
            let key = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
            var idr = false
            if key, let data = packet.pointee.data, packet.pointee.size > 0 {
                A53SEIParser.forEachNAL(data, Int(packet.pointee.size), framing) { nal, size in
                    if size > 0, nal[0] & 0x80 == 0, nal[0] & 31 == 5 { idr = true }
                }
            }
            if idr, poc == 0, videoCount > 0 {
                // Own the boundary packet even if validation fails; callers never free a taken
                // packet. On success it becomes the first packet of the next sequence.
                do { try finishSequence(nextPTS: packet.pointee.pts) }
                catch { var owned: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&owned); throw error }
                if off { ready.append(packet); return true }
            }
            let invalid = poc == nil || !reader.isFramePicture || packet.pointee.pts == Int64.min
                || (videoCount == 0 && (!idr || poc != 0))
                || (key && (!idr || poc != 0))
            let hasPresentationOffsets = lastPTS.map { packet.pointee.pts < $0 } == true
            let duplicateTime = lastPTS == packet.pointee.pts
            pending.append(Entry(packet: packet, poc: poc))
            bytes += Int(max(0, packet.pointee.size))
            videoCount += 1
            lastPTS = packet.pointee.pts
            if invalid || duplicateTime { try refuse(healthy: false); return true }
            if hasPresentationOffsets { try refuse(healthy: true); return true }
        } else {
            pending.append(Entry(packet: packet, poc: nil))
            bytes += Int(max(0, packet.pointee.size))
        }
        // Bound all streams, not only video. Healthy reordered MKV exits at its first PTS
        // regression; only a positive coding-order ladder pays the complete sequence hold.
        if bytes >= 32 << 20 || pending.count >= 1024 || videoCount > 512 {
            try refuse(healthy: false)
        }
        return true
    }

    private func finishSequence(nextPTS: Int64) throws {
        let video = pending.filter { $0.packet.pointee.stream_index == streamIndex }
        let pictures = video.map {
            H264MatroskaTimestampRepair.Picture(pts: $0.packet.pointee.pts, poc: $0.poc ?? -1)
        }
        if lead == nil {
            sampledCount = video.count; sampledPackets = pending.count; sampledBytes = bytes
            sampledRegressions = zip(pictures, pictures.dropFirst()).filter { $1.poc < $0.poc }.count
        }
        // A final one-picture IDR after a confirmed repair needs no permutation.
        if pictures.count == 1, pictures[0].poc == 0, let lead {
            let (dts, overflow) = pictures[0].pts.subtractingReportingOverflow(lead)
            guard !overflow else { try refuse(healthy: false); return }
            video[0].packet.pointee.dts = dts
            repairedCount += 1
            publishPending()
            return
        }
        guard let result = H264MatroskaTimestampRepair.repair(
            pictures, nextPTS: nextPTS, videoDelay: videoDelay, confirmedDecodeLead: lead
        ) else { try refuse(healthy: false); return }
        if lead == nil {
            lead = result.decodeLead
            outcome = .repairing
            reason = .confirmedMatroskaCodingOrder
            EngineLog.emit("[Demuxer] Matroska H264 coding-order timestamps confirmed: pictures=\(sampledCount) poc_regressions=\(sampledRegressions) decode_lead=\(result.decodeLead) time_base=\(timeBase.num)/\(timeBase.den)", category: .demux)
        }
        for (index, entry) in video.enumerated() {
            // The policy checked subtraction and PTS>=DTS for the entire sequence BEFORE any
            // mutation. Packet bytes, duration, side data, flags, and audio/subtitles are untouched.
            entry.packet.pointee.dts = pictures[index].pts - result.decodeLead
            entry.packet.pointee.pts = result.pts[index]
            repairedCount += 1
        }
        publishPending()
    }

    private func refuse(healthy: Bool) throws {
        if lead != nil {
            // Once the index is published on a repaired axis, reverting mid-stream would silently
            // corrupt it. Stop with an explicit error, never emit a partly rewritten sequence.
            unrepairedCount += videoCount
            failed = true
            outcome = .inconclusive
            reason = .matroskaSequenceChanged
            releasePackets()
            EngineLog.emit("[Demuxer] Matroska H264 timestamp repair stopped: sequence no longer satisfies confirmed policy", category: .demux)
            throw RepairError.sequenceNoLongerRepairable
        }
        outcome = healthy ? .healthy : .inconclusive
        reason = healthy ? .compositionOffsetsPresent : .matroskaSequenceUnproven
        off = true
        publishPending()
    }

    private func publishPending() {
        ready.append(contentsOf: pending.map(\.packet))
        pending.removeAll(keepingCapacity: true)
        bytes = 0; videoCount = 0; lastPTS = nil
    }

    func dequeue() -> UnsafeMutablePointer<AVPacket>? {
        guard readyIndex < ready.count else { return nil }
        let packet = ready[readyIndex]
        readyIndex += 1
        if readyIndex == ready.count { ready.removeAll(keepingCapacity: true); readyIndex = 0 }
        return packet
    }

    func enqueueFront(_ packet: UnsafeMutablePointer<AVPacket>) { ready.insert(packet, at: readyIndex) }

    func endOfStream() throws {
        if failed { throw RepairError.sequenceNoLongerRepairable }
        guard !pending.isEmpty else { return }
        let video = pending.filter { $0.packet.pointee.stream_index == streamIndex }
        guard let last = video.last else { publishPending(); return }
        // The last packet's decode duration is used only as a bounded validation sentinel. It
        // never becomes a new presentation time and never changes a packet duration.
        let duration = max(1, last.packet.pointee.duration)
        let (end, overflow) = last.packet.pointee.pts.addingReportingOverflow(duration)
        guard !overflow else { try refuse(healthy: false); return }
        try finishSequence(nextPTS: end)
    }

    func noteSeek() {
        releasePackets()
        reader.reset()
        failed = false
        if lead != nil { outcome = .repairing; reason = .confirmedMatroskaCodingOrder }
        // Keep the confirmed decode lead (and the container index axis) across every seek.
    }

    private func releasePackets() {
        for entry in pending { var owned: UnsafeMutablePointer<AVPacket>? = entry.packet; trackedPacketFree(&owned) }
        for packet in ready.dropFirst(readyIndex) { var owned: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&owned) }
        pending.removeAll(keepingCapacity: true); ready.removeAll(keepingCapacity: true)
        readyIndex = 0; bytes = 0; videoCount = 0; lastPTS = nil
    }

    func diagnostic(sourceSeekable: Bool, isISOBaseMediaFile: Bool, isH264: Bool)
        -> H264CompositionOffsetRepairDiagnostic {
        H264CompositionOffsetRepairDiagnostic(
            outcome: outcome, reason: reason, sourceSeekable: sourceSeekable,
            isISOBaseMediaFile: isISOBaseMediaFile, isH264: isH264, videoDelay: videoDelay,
            sampleCount: sampledCount, heldPacketCount: sampledPackets, heldBytes: sampledBytes,
            firstKeyframe: sampledCount > 0 ? true : nil, firstPictureOrderCount: sampledCount > 0 ? 0 : nil,
            streamTimeBaseNumerator: timeBase.num, streamTimeBaseDenominator: timeBase.den,
            pictureOrderRegressionCount: sampledRegressions, planDecodeLead: lead,
            planShift: lead == nil ? nil : 0, planPictureOrderStep: lead == nil ? nil : 2,
            repairedPictures: repairedCount, unrepairedPictures: unrepairedCount
        )
    }
}
