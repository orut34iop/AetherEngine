import Foundation

extension AetherEngine {
    /// A host replacement, native item attach or teardown retires every old sample.
    @discardableResult
    func beginTimelineObservationEpoch() -> UInt64 {
        timelineObservationState.beginEpoch()
        publishTimelineObservation()
        return timelineObservationState.value.sessionEpoch
    }

    var timelineObservationAvailable: Bool {
        switch state {
        case .playing, .paused, .seeking: return true
        case .idle, .loading, .ended, .error: return false
        }
    }

    func refreshTimelineObservation(available: Bool? = nil) {
        timelineObservationState.status(seeking: isSeeking,
            recovering: pendingRecoverySeekClockTarget != nil,
            available: (available ?? true) && timelineObservationAvailable)
        publishTimelineObservation()
    }

    func recordTimelineObservation(_ sample: TimelineClockSample, epoch: UInt64,
                                   evidence: TimelineObservation.Evidence) {
        guard epoch == timelineObservationState.value.sessionEpoch else { return }
        switch state {
        case .idle, .ended, .error:
            refreshTimelineObservation(available: false)
            return
        case .loading, .playing, .paused, .seeking: break
        }
        timelineObservationState.record(position: sample.seconds,
            sampledAt: sample.sampledAtUptime, evidence: evidence, epoch: epoch,
            seeking: isSeeking, recovering: pendingRecoverySeekClockTarget != nil)
        publishTimelineObservation()
    }

    private func publishTimelineObservation() {
        let observation = timelineObservationState.value
        if clock.timelineObservation != observation { clock.timelineObservation = observation }
    }
}
