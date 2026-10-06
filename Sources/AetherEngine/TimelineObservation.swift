import Foundation

/// One coherent reading on the same axis as seek(to:) and duration.
/// Clock evidence is not a per-frame display receipt. In particular a software
/// synchronizer can be reanchored before the retained old picture is replaced.
public struct TimelineObservation: Sendable, Equatable {
    public enum Evidence: String, Sendable, Equatable {
        case nativePresentationClock
        case softwarePresentationClock
        /// A real clock read after a software seek reanchor in this host lifetime.
        /// No existing callback proves which post-seek video frame is on screen.
        case softwareReanchoredClock
        case heldLastSample
        case unavailable
    }

    public let sessionEpoch: UInt64
    public let revision: UInt64
    public let positionSeconds: Double?
    /// Monotonic process uptime of the real sample. A held publication retains it.
    public let sampledAtUptime: TimeInterval?
    public let evidence: Evidence
    public let seekInFlight: Bool
    /// Recovery can remain pending after isSeeking becomes false and the API returns.
    public let seekRecoveryPending: Bool

    public init(sessionEpoch: UInt64, revision: UInt64, positionSeconds: Double?,
                sampledAtUptime: TimeInterval?, evidence: Evidence,
                seekInFlight: Bool, seekRecoveryPending: Bool) {
        self.sessionEpoch = sessionEpoch
        self.revision = revision
        self.positionSeconds = positionSeconds
        self.sampledAtUptime = sampledAtUptime
        self.evidence = evidence
        self.seekInFlight = seekInFlight
        self.seekRecoveryPending = seekRecoveryPending
    }

    static let unavailable = TimelineObservation(sessionEpoch: 0, revision: 0,
        positionSeconds: nil, sampledAtUptime: nil, evidence: .unavailable,
        seekInFlight: false, seekRecoveryPending: false)
}

/// Pure observation state; it has no authority over playback or seek scheduling.
struct TimelineObservationState {
    private(set) var value = TimelineObservation.unavailable

    mutating func beginEpoch() {
        precondition(value.sessionEpoch < UInt64.max, "timeline epoch exhausted")
        value = TimelineObservation(sessionEpoch: value.sessionEpoch + 1, revision: 0,
            positionSeconds: nil, sampledAtUptime: nil, evidence: .unavailable,
            seekInFlight: false, seekRecoveryPending: false)
    }

    mutating func record(position: Double, sampledAt: TimeInterval,
                         evidence: TimelineObservation.Evidence, epoch: UInt64,
                         seeking: Bool, recovering: Bool) {
        guard epoch == value.sessionEpoch else { return }
        guard position.isFinite, position >= 0, sampledAt.isFinite, sampledAt >= 0,
              evidence == .nativePresentationClock || evidence == .softwarePresentationClock
                || evidence == .softwareReanchoredClock else {
            status(seeking: seeking, recovering: recovering, available: false)
            return
        }
        // A callback queued before a newer sample cannot move freshness backwards.
        guard value.sampledAtUptime.map({ sampledAt >= $0 }) ?? true else { return }
        publish(position: position, sampledAt: sampledAt, evidence: evidence,
                seeking: seeking, recovering: recovering)
    }

    mutating func status(seeking: Bool, recovering: Bool, available: Bool) {
        let position = available ? value.positionSeconds : nil
        let sampledAt = available ? value.sampledAtUptime : nil
        let evidence: TimelineObservation.Evidence = position == nil ? .unavailable : .heldLastSample
        guard value.positionSeconds != position || value.evidence != evidence
                || value.seekInFlight != seeking || value.seekRecoveryPending != recovering else { return }
        publish(position: position, sampledAt: sampledAt, evidence: evidence,
                seeking: seeking, recovering: recovering)
    }

    private mutating func publish(position: Double?, sampledAt: TimeInterval?,
                                  evidence: TimelineObservation.Evidence,
                                  seeking: Bool, recovering: Bool) {
        precondition(value.revision < UInt64.max, "timeline revision exhausted")
        value = TimelineObservation(sessionEpoch: value.sessionEpoch, revision: value.revision + 1,
            positionSeconds: position, sampledAtUptime: sampledAt, evidence: evidence,
            seekInFlight: seeking, seekRecoveryPending: recovering)
    }
}

/// Internal host value. Native uses item seconds; software supplies mapped session seconds.
struct TimelineClockSample: Sendable {
    let seconds: Double
    let sampledAtUptime: TimeInterval
    let reanchored: Bool
}
