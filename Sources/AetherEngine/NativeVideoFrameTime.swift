import CoreMedia

/// Presentation time of one muxed video frame on the native path, on both axes (#260).
///
/// A host that renders its own overlay (libass, a burned-in badge) needs two things the engine holds
/// together and nothing else does: the media instant a frame represents (`source`, the axis subtitle
/// cues and chapters live on) and the instant the compositor will show it (`item`, the axis
/// `AVPlayerItem.currentTime()` and its timebase read). Both are reported for the same frame so a
/// consumer never has to reconstruct one from the other through a convention. `PresentationAxisMap`
/// converts arbitrary positions between the axes; this reports the frames themselves.
///
/// Frames arrive in **decode order**, so with B-frames `source` is not monotonic across successive
/// callbacks. Sort by `source` before using the sequence as a frame-boundary list.
public struct NativeVideoFrameTime: Sendable, Equatable {

    /// Demuxed presentation timestamp, in the source video time base.
    public let source: CMTime

    /// Presentation timestamp as written into the segment, in the muxer time base. This is the value
    /// after the final-stage sanitizer, so on sources it repairs (SSAI splices with a restarting
    /// clock) it differs from a plain rescale of `source`.
    public let item: CMTime

    /// Absolute index of the segment this frame was muxed into, so a consumer can evict its own table
    /// alongside the segment bytes.
    public let segmentIndex: Int

    /// `AV_PKT_FLAG_KEY` on the source packet.
    public let isKeyframe: Bool

    /// Producer epoch. Moves on at every producer (re)start; a restart re-muxes segments from its
    /// start index forward under a fresh shift, so entries from an older epoch describe bytes AVPlayer
    /// may no longer be able to reach. Drop a table's older epochs when this changes.
    ///
    /// Strictly increasing process-wide, across `load()` calls as well as within one session (#314):
    /// the next item continues the sequence rather than restarting it, so a report that arrives from
    /// the superseded producer while the next session is coming up always ranks below that session's
    /// first, and the same "higher retires, lower is stale" rule sorts both cases. Successive epochs
    /// are not consecutive and the values carry no meaning beyond their order.
    public let epoch: UInt64

    /// Source-axis decode time after producer repair, before muxer rescale; nil if unavailable.
    public let sourceDecode: CMTime?
    /// Decode time returned by the final muxer timestamp sanitizer; nil if unavailable.
    public let itemDecode: CMTime?
    /// Video sample duration handed to the muxer, on its time base; nil if unavailable.
    public let sampleDuration: CMTime?
    /// Bit n means H.264 NAL type n was observed in this packet. nil on non-H.264
    /// or unreadable packets. A container keyframe flag is not proof of an IDR (bit 5).
    public let h264NALTypeMask: UInt32?
    /// libavformat write result; a negative value means the muxer refused this packet.
    public let muxWriteResult: Int32?

    public init(source: CMTime, item: CMTime, segmentIndex: Int, isKeyframe: Bool, epoch: UInt64,
                sourceDecode: CMTime? = nil, itemDecode: CMTime? = nil,
                sampleDuration: CMTime? = nil, h264NALTypeMask: UInt32? = nil,
                muxWriteResult: Int32? = nil) {
        self.source = source
        self.item = item
        self.segmentIndex = segmentIndex
        self.isKeyframe = isKeyframe
        self.epoch = epoch
        self.sourceDecode = sourceDecode
        self.itemDecode = itemDecode
        self.sampleDuration = sampleDuration
        self.h264NALTypeMask = h264NALTypeMask
        self.muxWriteResult = muxWriteResult
    }
}

/// Called on the producer's pump thread, once per muxed video frame. Must not block: the pump also
/// fetches and muxes, so time spent here is time the segment is not being produced.
public typealias NativeVideoFrameTimeObserver = @Sendable (NativeVideoFrameTime) -> Void
