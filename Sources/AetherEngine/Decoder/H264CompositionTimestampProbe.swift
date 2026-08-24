import Foundation
import Libavcodec
import Libavutil

/// Detects seekable MP4/H.264 VOD whose container omitted composition timestamps even though the
/// bitstream uses reordered pictures. Stream-copying that shape into HLS-fMP4 preserves `PTS == DTS`;
/// AVPlayer then presents each future reference picture before the B pictures that precede it, producing
/// a small but continuous forward/backward judder. libavcodec's decoded `best_effort_timestamp` repairs
/// the presentation axis from picture order, so a confirmed source is routed through the software host.
enum H264CompositionTimestampProbe {

    enum Verdict: Equatable, Sendable {
        case notApplicable
        case healthy
        case repairWithBestEffortPTS
        case inconclusive
    }

    struct Evidence: Equatable, Sendable {
        var videoPackets = 0
        var validTimestampPairs = 0
        var nonKeyPackets = 0
        var sawCompositionOffset = false
        var decodedFrames = 0
        var validBestEffortFrames = 0
        var bestEffortAdvances = 0
        var bestEffortRegressions = 0
        var rawPTSRegressions = 0
        var rawPTSDiffersFromBestEffort = 0
    }

    struct Result: Sendable {
        let verdict: Verdict
        let evidence: Evidence
        let reason: String
        let consumedInput: Bool

        init(
            verdict: Verdict,
            evidence: Evidence,
            reason: String,
            consumedInput: Bool = false
        ) {
            self.verdict = verdict
            self.evidence = evidence
            self.reason = reason
            self.consumedInput = consumedInput
        }

        var summary: String {
            let e = evidence
            return "verdict=\(verdict) reason=\(reason) consumed=\(consumedInput ? 1 : 0) "
                + "packets=\(e.videoPackets) "
                + "valid_pairs=\(e.validTimestampPairs) nonkey=\(e.nonKeyPackets) "
                + "decoded=\(e.decodedFrames) best_valid=\(e.validBestEffortFrames) "
                + "best_advances=\(e.bestEffortAdvances) best_regressions=\(e.bestEffortRegressions) "
                + "raw_regressions=\(e.rawPTSRegressions) raw_best_differences=\(e.rawPTSDiffersFromBestEffort)"
        }
    }

    static let videoPacketTarget = 64
    static let minimumTimestampPairs = 32
    static let minimumNonKeyPackets = 16
    static let minimumDecodedFrames = 16
    static let minimumBestEffortAdvances = 8
    static let packetBudget = 600
    static let wallClockBudget: TimeInterval = 3.0

    /// Pure evidence decision, split out so every fail-closed threshold has focused coverage.
    static func classify(_ evidence: Evidence) -> Verdict {
        if evidence.sawCompositionOffset { return .healthy }
        guard evidence.validTimestampPairs >= minimumTimestampPairs,
              evidence.nonKeyPackets >= minimumNonKeyPackets,
              evidence.decodedFrames >= minimumDecodedFrames,
              evidence.validBestEffortFrames >= minimumDecodedFrames,
              evidence.bestEffortAdvances >= minimumBestEffortAdvances,
              evidence.bestEffortRegressions == 0 else {
            return .inconclusive
        }
        if evidence.rawPTSRegressions > 0 || evidence.rawPTSDiffersFromBestEffort >= 2 {
            return .repairWithBestEffortPTS
        }
        return .healthy
    }

    static func isMeaningfulRawPTSRegression(
        previous: Int64,
        current: Int64,
        nominalFrameTicks: Int64
    ) -> Bool {
        current < previous
            && previous - current >= max(1, nominalFrameTicks / 2)
    }

    /// Reads a bounded head sample and decodes only enough frames to prove that the raw frame PTS
    /// regresses while libavcodec's best-effort presentation clock stays monotonic. This moves the
    /// demuxer read position; the caller must seek it back before handing it to a playback host.
    static func run(
        demuxer: Demuxer,
        streamIndex: Int32,
        packetBudget: Int = H264CompositionTimestampProbe.packetBudget,
        wallClockBudget: TimeInterval = H264CompositionTimestampProbe.wallClockBudget
    ) -> Result {
        let empty = Evidence()
        guard demuxer.isISOBaseMediaFile else {
            return Result(verdict: .notApplicable, evidence: empty, reason: "not ISO-BMFF")
        }
        guard streamIndex >= 0,
              let stream = demuxer.stream(at: streamIndex),
              let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_id == AV_CODEC_ID_H264,
              codecpar.pointee.field_order == AV_FIELD_PROGRESSIVE,
              codecpar.pointee.video_delay > 0 else {
            return Result(
                verdict: .notApplicable, evidence: empty,
                reason: "requires progressive H.264 with reorder delay")
        }
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_H264),
              let context = avcodec_alloc_context3(codec) else {
            return Result(verdict: .inconclusive, evidence: empty, reason: "decoder unavailable")
        }
        var ownedContext: UnsafeMutablePointer<AVCodecContext>? = context
        defer { avcodec_free_context(&ownedContext) }

        guard avcodec_parameters_to_context(context, codecpar) >= 0 else {
            return Result(verdict: .inconclusive, evidence: empty, reason: "parameters_to_context failed")
        }
        context.pointee.pkt_timebase = stream.pointee.time_base
        context.pointee.get_format = { _, formats in
            guard let formats else { return AV_PIX_FMT_NONE }
            var index = 0
            while formats[index] != AV_PIX_FMT_NONE {
                if formats[index] != AV_PIX_FMT_VIDEOTOOLBOX { return formats[index] }
                index += 1
            }
            return AV_PIX_FMT_YUV420P
        }
        context.pointee.skip_loop_filter = AVDISCARD_ALL
        context.pointee.thread_count = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
        context.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE

        var options: OpaquePointer?
        av_dict_set(&options, "hwaccel", "none", 0)
        let openResult = avcodec_open2(context, codec, &options)
        av_dict_free(&options)
        guard openResult >= 0 else {
            return Result(
                verdict: .inconclusive, evidence: empty,
                reason: "decoder open failed (\(openResult))")
        }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let decodedFrame = frame else {
            return Result(verdict: .inconclusive, evidence: empty, reason: "frame alloc failed")
        }
        defer { av_frame_free(&frame) }

        let rate = stream.pointee.avg_frame_rate.num > 0 && stream.pointee.avg_frame_rate.den > 0
            ? stream.pointee.avg_frame_rate : stream.pointee.r_frame_rate
        let timeBase = stream.pointee.time_base
        let nominalFrameTicks: Int64 = {
            guard rate.num > 0, rate.den > 0, timeBase.num > 0, timeBase.den > 0 else { return 1 }
            let ticks = Double(rate.den) * Double(timeBase.den)
                / (Double(rate.num) * Double(timeBase.num))
            return max(1, Int64(ticks.rounded()))
        }()
        var evidence = Evidence()
        var packetsRead = 0
        var lastRawPTS: Int64?
        var lastBestEffortPTS: Int64?
        let deadline = Date(timeIntervalSinceNow: wallClockBudget)

        func drainFrames() {
            while avcodec_receive_frame(context, decodedFrame) >= 0 {
                evidence.decodedFrames += 1
                let rawPTS = decodedFrame.pointee.pts
                let bestPTS = decodedFrame.pointee.best_effort_timestamp

                if rawPTS != Int64.min {
                    if let lastRawPTS,
                       isMeaningfulRawPTSRegression(
                           previous: lastRawPTS,
                           current: rawPTS,
                           nominalFrameTicks: nominalFrameTicks) {
                        evidence.rawPTSRegressions += 1
                    }
                    lastRawPTS = rawPTS
                }
                if bestPTS != Int64.min {
                    evidence.validBestEffortFrames += 1
                    if let lastBestEffortPTS {
                        if bestPTS < lastBestEffortPTS {
                            evidence.bestEffortRegressions += 1
                        } else if bestPTS > lastBestEffortPTS {
                            evidence.bestEffortAdvances += 1
                        }
                    }
                    lastBestEffortPTS = bestPTS
                }
                if rawPTS != Int64.min, bestPTS != Int64.min, rawPTS != bestPTS {
                    evidence.rawPTSDiffersFromBestEffort += 1
                }
                av_frame_unref(decodedFrame)
            }
        }

        while evidence.videoPackets < videoPacketTarget,
              packetsRead < packetBudget,
              Date() < deadline {
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                break
            }
            guard let packet else { break }
            packetsRead += 1
            var ownedPacket: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&ownedPacket) }
            guard packet.pointee.stream_index == streamIndex else { continue }

            evidence.videoPackets += 1
            if (packet.pointee.flags & AV_PKT_FLAG_KEY) == 0 {
                evidence.nonKeyPackets += 1
            }
            let pts = packet.pointee.pts
            let dts = packet.pointee.dts
            if pts != Int64.min, dts != Int64.min {
                evidence.validTimestampPairs += 1
                if pts != dts {
                    evidence.sawCompositionOffset = true
                    return Result(
                        verdict: .healthy,
                        evidence: evidence,
                        reason: "observed PTS-DTS offset",
                        consumedInput: true
                    )
                }
            }

            var sendResult = avcodec_send_packet(context, packet)
            if sendResult == FFmpegErr.eagain {
                drainFrames()
                sendResult = avcodec_send_packet(context, packet)
            }
            if sendResult >= 0 { drainFrames() }
        }

        let verdict = classify(evidence)
        let reason: String
        switch verdict {
        case .repairWithBestEffortPTS:
            reason = "missing composition offsets with decoded PTS regression"
        case .healthy:
            reason = "decoded presentation timestamps are coherent"
        case .inconclusive:
            reason = "sample did not meet fail-closed evidence thresholds"
        case .notApplicable:
            reason = "not applicable"
        }
        return Result(
            verdict: verdict,
            evidence: evidence,
            reason: reason,
            consumedInput: packetsRead > 0
        )
    }
}
