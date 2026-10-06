import Foundation
import Combine
import Testing
@testable import AetherEngine

/// Public event-path tests. These prove token propagation, not physical landing.
struct SeekRequestIdentityTests {
    @Test("legacy log text is unchanged and caller identity is a bounded opaque field")
    func eventDescriptionCompatibility() {
        let legacy = SeekEvent(id: 7, origin: .deferred, outcome: .began, target: 42)
        #expect(legacy.description == "seek#7 deferred began target=42.00")
        let request = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let correlated = SeekEvent(id: 7, origin: .deferred, outcome: .began,
                                   target: 42, requestID: request)
        #expect(correlated.description == legacy.description + " request=00000000-0000-4000-8000-000000000001")
    }

    @MainActor @Test("standalone rejection preserves the caller token; legacy calls remain nil")
    func rejectionAndLegacy() async throws {
        let engine = try AetherEngine()
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }
        let request = UUID()
        await engine.seek(to: 42, requestID: request)
        await engine.seek(to: 42)
        #expect(events.count == 2)
        #expect(events[0].requestID == request)
        #expect(events[1].requestID == nil)
        #expect(events.allSatisfy { $0.outcome == .rejected(.noActiveSession) })
        #expect(events[0].id != events[1].id)
    }

    @MainActor @Test("deferred replay changes attempt ID but preserves application request identity")
    func deferredReplay() async throws {
        let engine = try AetherEngine()
        engine.duration = 600
        engine.state = .loading
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }
        let request = UUID()
        await engine.seek(to: 42, requestID: request)
        #expect(engine.pendingPreReadySeek?.requestID == request)
        // An optimistic target is never a timeline sample.
        #expect(engine.clock.currentTime == 42)
        #expect(engine.clock.timelineObservation.positionSeconds == nil)
        engine.state = .playing
        for _ in 0..<200 {
            if events.count >= 4 { break }
            await Task.yield()
        }
        #expect(events.count == 4)
        guard events.count == 4 else { return }
        #expect(events.allSatisfy { $0.requestID == request })
        #expect(events[0].origin == .deferred)
        #expect(events[1].outcome == .superseded)
        #expect(events[2].origin == .programmatic)
        #expect(events[0].id != events[2].id)
        #expect(events[2].id == events[3].id)
        // No actual host means no presentation-clock observation, even if the
        // pre-existing hostless seek path emits its historical landed event.
        #expect(engine.clock.timelineObservation.positionSeconds == nil)
    }

    @MainActor @Test("equal target values never merge application identities")
    func identicalTargetsAndDiscard() async throws {
        let engine = try AetherEngine()
        engine.state = .loading
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }
        let a = UUID(), b = UUID()
        await engine.seek(to: 42, requestID: a)
        await engine.seek(to: 42, requestID: b)
        engine.state = .error("load failed")
        #expect(events.map(\.requestID) == [a, a, b, b])
        #expect(events.map(\.outcome) == [.began, .superseded, .began, .rejected(.noActiveSession)])
        #expect(events[0].id == events[1].id)
        #expect(events[2].id == events[3].id)
        #expect(events[0].id != events[2].id)
    }

    @MainActor @Test("late stalled landing and stop close the original ticket identity")
    func lateLandingAndStop() async throws {
        let engine = try AetherEngine()
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }
        let a = UUID(), b = UUID()
        engine.programmaticSeekTicket = AetherEngine.SeekTicket(
            id: 77, target: 42, origin: .programmatic, requestID: a)
        engine.reportSeekStalled()
        engine.closeSeekTicket(&engine.programmaticSeekTicket, with: .landed(renderedTime: 43))
        engine.state = .loading
        await engine.seek(to: 90, requestID: b)
        engine.stop()
        #expect(events[0].requestID == a && events[1].requestID == a)
        #expect(events[0].id == 77 && events[1].id == 77)
        #expect(events[0].outcome == .stalled)
        #expect(events.last?.requestID == b)
        #expect(events.last?.outcome == .rejected(.noActiveSession))
    }

    @MainActor @Test("an independent engine-origin seek never inherits a caller token")
    func internalSeekHasNoBorrowedToken() async throws {
        let engine = try AetherEngine()
        engine.state = .loading
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }
        let request = UUID()
        await engine.seek(to: 42, requestID: request)
        await engine.seek(to: 42, origin: .host)
        #expect(events.map(\.requestID) == [request, request, nil])
        #expect(engine.pendingPreReadySeek?.requestID == nil)
    }
}
