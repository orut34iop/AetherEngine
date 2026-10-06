import Foundation

/// Build with TimelineObservation.swift + Native/SWClockAnchorPolicy.swift only.
/// This is a pure state/axis check, not engine or physical presentation acceptance.
@main struct TimelineObservationCheck {
    static func main() {
        var state = TimelineObservationState()
        state.beginEpoch()
        let epoch = state.value.sessionEpoch
        state.record(position: 42, sampledAt: 10, evidence: .nativePresentationClock,
                     epoch: epoch, seeking: false, recovering: false)
        precondition(state.value.positionSeconds == 42 && state.value.revision == 1)
        state.status(seeking: true, recovering: true, available: true)
        precondition(state.value.evidence == .heldLastSample && state.value.sampledAtUptime == 10)
        state.status(seeking: false, recovering: true, available: true)
        precondition(!state.value.seekInFlight && state.value.seekRecoveryPending)
        let held = state.value
        state.record(position: 99, sampledAt: 9, evidence: .nativePresentationClock,
                     epoch: epoch, seeking: false, recovering: false)
        precondition(state.value == held)
        state.beginEpoch()
        let newEpoch = state.value.sessionEpoch
        state.record(position: 99, sampledAt: 11, evidence: .nativePresentationClock,
                     epoch: epoch, seeking: false, recovering: false)
        precondition(state.value.positionSeconds == nil)
        state.record(position: 45, sampledAt: 12, evidence: .softwareReanchoredClock,
                     epoch: newEpoch, seeking: false, recovering: false)
        precondition(state.value.evidence == .softwareReanchoredClock)
        state.record(position: .infinity, sampledAt: 13, evidence: .nativePresentationClock,
                     epoch: newEpoch, seeking: false, recovering: false)
        precondition(state.value.evidence == .unavailable && state.value.sampledAtUptime == nil)
        precondition(SWClockAnchorPolicy.sessionSeconds(forSource: 60.5, sessionZeroSeconds: 60) == 0.5)
        precondition(SWClockAnchorPolicy.sessionSeconds(forSource: 2, sessionZeroSeconds: 0) == 2)
        precondition(SWClockAnchorPolicy.sessionSeconds(forSource: 59, sessionZeroSeconds: 60) == 0)
        let source = SWClockAnchorPolicy.sourceSeconds(forSession: 42, sessionZeroSeconds: 21_600)
        precondition(SWClockAnchorPolicy.sessionSeconds(forSource: source, sessionZeroSeconds: 21_600) == 42)
        print("PASS: coherent timeline state, freshness, epoch fence, software reanchor evidence and source-axis mapping")
    }
}
