import Foundation
import Testing
@testable import AetherEngine

struct TimelineObservationTests {
    @Test("holding a sample changes status without manufacturing freshness")
    func heldSampleKeepsFreshness() {
        var state = TimelineObservationState()
        state.beginEpoch()
        state.record(position: 12, sampledAt: 100, evidence: .nativePresentationClock,
                     epoch: 1, seeking: false, recovering: false)
        state.status(seeking: true, recovering: true, available: true)
        #expect(state.value.evidence == .heldLastSample)
        #expect(state.value.positionSeconds == 12)
        #expect(state.value.sampledAtUptime == 100)
        #expect(state.value.seekInFlight && state.value.seekRecoveryPending)
        state.status(seeking: false, recovering: true, available: true)
        #expect(!state.value.seekInFlight && state.value.seekRecoveryPending)
        #expect(state.value.sampledAtUptime == 100)
    }

    @Test("retired epochs and out-of-order samples cannot overwrite the successor")
    func epochAndFreshnessFence() {
        var state = TimelineObservationState()
        state.beginEpoch()
        state.record(position: 12, sampledAt: 100, evidence: .nativePresentationClock,
                     epoch: 1, seeking: false, recovering: false)
        state.beginEpoch()
        let empty = state.value
        state.record(position: 90, sampledAt: 200, evidence: .nativePresentationClock,
                     epoch: 1, seeking: false, recovering: false)
        #expect(state.value == empty)
        state.record(position: 4, sampledAt: 201, evidence: .softwarePresentationClock,
                     epoch: 2, seeking: false, recovering: false)
        let current = state.value
        state.record(position: 99, sampledAt: 199, evidence: .nativePresentationClock,
                     epoch: 2, seeking: false, recovering: false)
        #expect(state.value == current)
    }

    @Test("software reanchor remains clock-only and invalid input publishes no fabricated zero")
    func evidenceAndInvalidity() {
        var state = TimelineObservationState()
        state.beginEpoch()
        state.record(position: 42, sampledAt: 100, evidence: .softwareReanchoredClock,
                     epoch: 1, seeking: false, recovering: false)
        #expect(state.value.evidence == .softwareReanchoredClock)
        state.record(position: .nan, sampledAt: 101, evidence: .nativePresentationClock,
                     epoch: 1, seeking: false, recovering: false)
        #expect(state.value.positionSeconds == nil)
        #expect(state.value.sampledAtUptime == nil)
        #expect(state.value.evidence == .unavailable)
    }

    @Test("source origins fold to session seconds without changing zero-based playback")
    func softwareDisplayAxis() {
        #expect(SWClockAnchorPolicy.sessionSeconds(forSource: 61.5, sessionZeroSeconds: 60) == 1.5)
        #expect(SWClockAnchorPolicy.sessionSeconds(forSource: 2, sessionZeroSeconds: 0) == 2)
        #expect(SWClockAnchorPolicy.sessionSeconds(forSource: 50, sessionZeroSeconds: 60) == 0)
        let display = 42.0
        let source = SWClockAnchorPolicy.sourceSeconds(forSession: display, sessionZeroSeconds: 21_600)
        #expect(SWClockAnchorPolicy.sessionSeconds(forSource: source, sessionZeroSeconds: 21_600) == display)
    }

    @MainActor @Test("an engine publishes one coherent value and revokes it on stop")
    func engineObservationLifecycle() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        let epoch = engine.beginTimelineObservationEpoch()
        engine.recordTimelineObservation(TimelineClockSample(seconds: 12,
            sampledAtUptime: 100, reanchored: false), epoch: epoch, evidence: .nativePresentationClock)
        #expect(engine.clock.timelineObservation.positionSeconds == 12)
        engine.setPendingRecoverySeekTarget(90)
        #expect(engine.clock.timelineObservation.seekRecoveryPending)
        #expect(engine.clock.timelineObservation.sampledAtUptime == 100)
        engine.stop()
        let stopped = engine.clock.timelineObservation
        #expect(stopped.sessionEpoch > epoch)
        #expect(stopped.positionSeconds == nil)
        engine.recordTimelineObservation(TimelineClockSample(seconds: 90,
            sampledAtUptime: 101, reanchored: false), epoch: epoch, evidence: .nativePresentationClock)
        #expect(engine.clock.timelineObservation == stopped)
    }
}
