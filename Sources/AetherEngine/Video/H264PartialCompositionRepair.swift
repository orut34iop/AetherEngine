import Foundation

/// A mixed MP4 can carry valid ctts at the head and zero offsets in a later IDR sequence.
/// Restore that sequence's display ownership of the ORIGINAL timestamp slots, the way #511 does
/// for Matroska: the slot is READ from the file, never fitted to a cadence, so an interval change
/// inside the sequence is reproduced rather than guessed away.
///
/// The slot a picture needs is a packet away, not a plan away. A picture coded ahead of its own
/// slot waits exactly the mini-GOP the reorder created, so nothing is held for the length of a
/// sequence and no sequence is too long to repair.
enum H264PartialCompositionRepair {
    /// A picture cannot sit further from its own slot than the reorder delay the container
    /// declares. `video_delay` is the honest bound; this is only the ceiling on believing it.
    static let maximumReorderDepth = 16
    /// A sequence past this is not a GOP any more, and the ladder is one Int64 per picture.
    static let maximumPictures = 1 << 16
    /// Interleaving, not reordering, decides how many foreign packets sit inside the wait. A
    /// container that puts more than this between two video packets gives up its repair rather
    /// than its playback.
    static let maximumHeldPackets = 1024
    static let maximumHeldBytes = 32 << 20
    /// A candidate sequence has to show its reordering before anything is rewritten. A stream
    /// that reorders at all shows it within its reorder delay; this is slack, not a policy.
    static let maximumProofPictures = 64

    /// A missing-offset head has no healthy packet to corroborate its lead. Require
    /// the container start/index distance to equal the observed reorder head, then
    /// dry-run the existing slots. Never fit an average rate to variable timestamps.
    static func missingHeadForwardDepth(
        dts: [Int64], pts: [Int64], pocs: [Int64], keys: [Bool],
        streamStart: Int64, ladderStart: Int64, reorderDepth: Int
    ) -> Int? {
        guard dts.count >= 12, dts.count <= maximumProofPictures,
              pts.count == dts.count, pocs.count == dts.count, keys.count == dts.count,
              (1...maximumReorderDepth).contains(reorderDepth), reorderDepth < dts.count,
              streamStart != Int64.min, ladderStart != Int64.min,
              dts.first == ladderStart, keys.first == true, pocs.first == 0,
              !keys.dropFirst().contains(true), pts == dts else { return nil }
        let (lead, overflow) = streamStart.subtractingReportingOverflow(ladderStart)
        let (observed, headOverflow) = dts[reorderDepth].subtractingReportingOverflow(ladderStart)
        guard !overflow, !headOverflow, lead > 0, lead == observed else { return nil }
        var ladder = SlotLadder()
        for timestamp in dts { guard ladder.append(dts: timestamp) else { return nil } }
        var ranks: [Int] = []
        for poc in pocs {
            guard poc >= 0, poc % 2 == 0, poc / 2 < Int64(maximumPictures) else { return nil }
            ranks.append(Int(poc / 2))
        }
        guard Set(ranks).count == ranks.count,
              zip(ranks, ranks.dropFirst()).contains(where: { $1 < $0 }) else { return nil }
        var high = 0
        var closedPrefix = false
        var forward = reorderDepth
        for (index, rank) in ranks.enumerated() {
            high = max(high, rank)
            if index >= 8, high == index { closedPrefix = true }
            guard index - rank <= reorderDepth, rank - index <= maximumReorderDepth else { return nil }
            forward = max(forward, rank - index)
        }
        guard closedPrefix else { return nil }
        for (index, rank) in ranks.enumerated() {
            if ladder.claim(rank: rank, decodeIndex: index, lead: lead,
                            reorderDepth: reorderDepth, forwardDepth: forward) == .refuse { return nil }
        }
        return forward
    }

    enum Claim: Equatable {
        /// The slot is still ahead of the reader. The picture waits, and so does everything
        /// behind it, because the container's own order is what leaves this demuxer.
        case wait
        case time(Int64)
        /// Not a shape this policy owns. The caller hands the packets back as they arrived.
        case refuse
    }

    /// The decode slots of one coded video sequence, in the order they are read.
    struct SlotLadder {
        private var slots: [Int64] = []
        private var claimed: [Bool] = []

        var count: Int { slots.count }
        var isEmpty: Bool { slots.isEmpty }

        /// Records the next decode slot. False when the ladder stops being one: a slot that does
        /// not rise is not a decode ladder, and a missing timestamp is not a slot at all.
        mutating func append(dts: Int64) -> Bool {
            guard dts != Int64.min, slots.count < Self.limit else { return false }
            if let last = slots.last, dts <= last { return false }
            slots.append(dts)
            claimed.append(false)
            return true
        }

        /// The presentation time the picture at `decodeIndex` owns, given its display `rank`.
        /// `.wait` while its slot is still ahead of the reader, which is the mini-GOP.
        mutating func claim(rank: Int, decodeIndex: Int, lead: Int64, reorderDepth: Int,
                            forwardDepth: Int? = nil) -> Claim {
            let forward = forwardDepth ?? reorderDepth
            guard lead > 0, rank >= 0, decodeIndex >= 0, decodeIndex < slots.count,
                  (1...H264PartialCompositionRepair.maximumReorderDepth).contains(forward),
                  decodeIndex - rank <= reorderDepth, rank - decodeIndex <= forward,
                  rank < Self.limit else { return .refuse }
            guard rank < slots.count else { return .wait }
            // One slot, one picture. A rank claimed twice is a sequence this policy cannot own.
            guard !claimed[rank] else { return .refuse }
            let (pts, overflow) = slots[rank].addingReportingOverflow(lead)
            guard !overflow, pts >= slots[decodeIndex] else { return .refuse }
            claimed[rank] = true
            return .time(pts)
        }

        private static var limit: Int { H264PartialCompositionRepair.maximumPictures }
    }
}
