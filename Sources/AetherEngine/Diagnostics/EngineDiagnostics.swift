import Foundation
import Combine

/// Separate ObservableObject for liveTelemetry (AetherEngine#29).
/// Keeping it on the engine itself caused 1 Hz objectWillChange storms that blinked native Menu on tvOS.
/// Stats overlays observe this object; everything else observes the engine and is unaffected by telemetry samples.
@MainActor
public final class EngineDiagnostics: ObservableObject {

    /// 1 Hz snapshot while playing/paused; nil while idle. Cleared in stopInternal so sessions don't inherit stale numbers.
    @Published public internal(set) var liveTelemetry: LiveTelemetry?

    /// Route-aware session-only fMP4 cache state. Updated at session lifecycle transitions and by
    /// the 1 Hz sampler while active; cleanup completion remains visible after live telemetry stops.
    @Published public internal(set) var sessionCacheStatus: SessionCacheStatus = .inactive

    /// One bounded tvOS display-mode sample captured after playback starts. This is structured so hosts
    /// can persist the numeric cadence evidence without installing the raw `EngineLog.handler`, whose
    /// unrelated lines may contain source URLs or request credentials.
    @Published public internal(set) var displayModeDiagnostic: DisplayModeDiagnostic?

    /// One identity-free verdict from the main VOD demuxer's H.264 composition-offset check.
    /// Hosts may persist this value without subscribing to the global EngineLog stream, whose
    /// unrelated messages can contain source URLs or request headers.
    @Published public internal(set) var h264CompositionOffsetRepairDiagnostic:
        H264CompositionOffsetRepairDiagnostic?
}

public enum H264CompositionOffsetRepairOutcome: String, Equatable, Sendable {
    case notEvaluated = "not_evaluated"
    case notEligible = "not_eligible"
    case sampling
    case healthy
    case inconclusive
    case repairing
}

/// Stable, content-independent reason codes for `H264CompositionOffsetRepairDiagnostic`.
public enum H264CompositionOffsetRepairReason: String, Equatable, Sendable {
    case notEvaluated = "not_evaluated"
    case stillExtraction = "still_extraction"
    case sourceNotSeekable = "source_not_seekable"
    case formatContextUnavailable = "format_context_unavailable"
    case noVideoStream = "no_video_stream"
    case videoStreamDiscarded = "video_stream_discarded"
    case unsupportedContainer = "unsupported_container"
    case nonH264 = "non_h264"
    case noReorderDelay = "no_reorder_delay"
    case parserUnavailable = "parser_unavailable"
    case sampling
    case compositionOffsetsPresent = "composition_offsets_present"
    case confirmedMissingOffsets = "confirmed_missing_offsets"
    case reorderDelayOutOfRange = "reorder_delay_out_of_range"
    case insufficientSamples = "insufficient_samples"
    case timestampsNotUniformPTSEqualsDTS = "timestamps_not_uniform_pts_equals_dts"
    case sampleNotPictureOrderOrigin = "sample_not_picture_order_origin"
    case decodeTimestampsNotAdvancing = "decode_timestamps_not_advancing"
    case nonuniformDecodeLadder = "nonuniform_decode_ladder"
    case noDecodeStep = "no_decode_step"
    case noPictureOrderRegression = "no_picture_order_regression"
    case negativePictureOrderCount = "negative_picture_order_count"
    case noPictureOrderStep = "no_picture_order_step"
    case pictureOrderNotAligned = "picture_order_not_aligned"
    case pictureOrderCollision = "picture_order_collision"
    case pictureOrderWindowNotFilled = "picture_order_window_not_filled"
    case unclassifiedInconclusive = "unclassified_inconclusive"
}

/// A bounded snapshot of the MP4/H.264 composition-offset decision and its numeric evidence.
/// It deliberately carries no URL, path, media identifier, request header, packet bytes, or title.
public struct H264CompositionOffsetRepairDiagnostic: Equatable, Sendable {
    public let outcome: H264CompositionOffsetRepairOutcome
    public let reason: H264CompositionOffsetRepairReason
    public let sourceSeekable: Bool
    public let isISOBaseMediaFile: Bool
    public let isH264: Bool
    public let videoDelay: Int?
    public let sampleCount: Int
    public let heldPacketCount: Int
    public let heldBytes: Int
    public let ptsEqualsDTSCount: Int
    public let parserMissCount: Int
    public let firstKeyframe: Bool?
    public let firstPictureOrderCount: Int64?
    public let minimumDecodeStep: Int64?
    public let maximumDecodeStep: Int64?
    /// Exact stream metadata and the bounded sampled decode-step pattern. These numeric fields make
    /// a rejected fractional cadence diagnosable without exposing source identity or packet data.
    public let streamTimeBaseNumerator: Int32?
    public let streamTimeBaseDenominator: Int32?
    public let codedFrameRateNumerator: Int32?
    public let codedFrameRateDenominator: Int32?
    public let averageFrameRateNumerator: Int32?
    public let averageFrameRateDenominator: Int32?
    public let streamFrameCount: Int64?
    public let codedCadenceNumerator: Int64?
    public let codedCadenceDenominator: Int64?
    public let averageCadenceNumerator: Int64?
    public let averageCadenceDenominator: Int64?
    public let streamStartTime: Int64?
    public let ladderStartTime: Int64?
    public let firstDecodeTimestamp: Int64?
    public let decodeStepPattern: [Int64]
    public let pictureOrderRegressionCount: Int
    public let planStep: Int64?
    public let planDecodeLead: Int64?
    public let planShift: Int64?
    public let planPictureOrderStep: Int64?
    public let repairedPictures: Int
    public let unrepairedPictures: Int

    public init(
        outcome: H264CompositionOffsetRepairOutcome,
        reason: H264CompositionOffsetRepairReason,
        sourceSeekable: Bool,
        isISOBaseMediaFile: Bool,
        isH264: Bool,
        videoDelay: Int? = nil,
        sampleCount: Int = 0,
        heldPacketCount: Int = 0,
        heldBytes: Int = 0,
        ptsEqualsDTSCount: Int = 0,
        parserMissCount: Int = 0,
        firstKeyframe: Bool? = nil,
        firstPictureOrderCount: Int64? = nil,
        minimumDecodeStep: Int64? = nil,
        maximumDecodeStep: Int64? = nil,
        streamTimeBaseNumerator: Int32? = nil,
        streamTimeBaseDenominator: Int32? = nil,
        codedFrameRateNumerator: Int32? = nil,
        codedFrameRateDenominator: Int32? = nil,
        averageFrameRateNumerator: Int32? = nil,
        averageFrameRateDenominator: Int32? = nil,
        streamFrameCount: Int64? = nil,
        codedCadenceNumerator: Int64? = nil,
        codedCadenceDenominator: Int64? = nil,
        averageCadenceNumerator: Int64? = nil,
        averageCadenceDenominator: Int64? = nil,
        streamStartTime: Int64? = nil,
        ladderStartTime: Int64? = nil,
        firstDecodeTimestamp: Int64? = nil,
        decodeStepPattern: [Int64] = [],
        pictureOrderRegressionCount: Int = 0,
        planStep: Int64? = nil,
        planDecodeLead: Int64? = nil,
        planShift: Int64? = nil,
        planPictureOrderStep: Int64? = nil,
        repairedPictures: Int = 0,
        unrepairedPictures: Int = 0
    ) {
        self.outcome = outcome
        self.reason = reason
        self.sourceSeekable = sourceSeekable
        self.isISOBaseMediaFile = isISOBaseMediaFile
        self.isH264 = isH264
        self.videoDelay = videoDelay
        self.sampleCount = sampleCount
        self.heldPacketCount = heldPacketCount
        self.heldBytes = heldBytes
        self.ptsEqualsDTSCount = ptsEqualsDTSCount
        self.parserMissCount = parserMissCount
        self.firstKeyframe = firstKeyframe
        self.firstPictureOrderCount = firstPictureOrderCount
        self.minimumDecodeStep = minimumDecodeStep
        self.maximumDecodeStep = maximumDecodeStep
        self.streamTimeBaseNumerator = streamTimeBaseNumerator
        self.streamTimeBaseDenominator = streamTimeBaseDenominator
        self.codedFrameRateNumerator = codedFrameRateNumerator
        self.codedFrameRateDenominator = codedFrameRateDenominator
        self.averageFrameRateNumerator = averageFrameRateNumerator
        self.averageFrameRateDenominator = averageFrameRateDenominator
        self.streamFrameCount = streamFrameCount
        self.codedCadenceNumerator = codedCadenceNumerator
        self.codedCadenceDenominator = codedCadenceDenominator
        self.averageCadenceNumerator = averageCadenceNumerator
        self.averageCadenceDenominator = averageCadenceDenominator
        self.streamStartTime = streamStartTime
        self.ladderStartTime = ladderStartTime
        self.firstDecodeTimestamp = firstDecodeTimestamp
        self.decodeStepPattern = decodeStepPattern
        self.pictureOrderRegressionCount = pictureOrderRegressionCount
        self.planStep = planStep
        self.planDecodeLead = planDecodeLead
        self.planShift = planShift
        self.planPictureOrderStep = planPictureOrderStep
        self.repairedPictures = repairedPictures
        self.unrepairedPictures = unrepairedPictures
    }
}

/// Safe numeric read-back of the content cadence, requested display criteria, active panel refresh rate,
/// and AVPlayer's reported video output rate. Nil means that platform or playback path did not expose the
/// measurement; no source identity, URL, headers, or media metadata are carried.
public struct DisplayModeDiagnostic: Equatable, Sendable {
    public let backend: String
    public let contentFrameRate: Double?
    public let requestedRefreshRate: Double?
    public let measuredRefreshRate: Double?
    public let nominalRefreshRate: Double?
    public let playerFrameRate: Double?

    public init(
        backend: String,
        contentFrameRate: Double?,
        requestedRefreshRate: Double?,
        measuredRefreshRate: Double?,
        nominalRefreshRate: Double?,
        playerFrameRate: Double?
    ) {
        self.backend = backend
        self.contentFrameRate = contentFrameRate
        self.requestedRefreshRate = requestedRefreshRate
        self.measuredRefreshRate = measuredRefreshRate
        self.nominalRefreshRate = nominalRefreshRate
        self.playerFrameRate = playerFrameRate
    }
}
