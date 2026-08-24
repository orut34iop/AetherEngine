import Testing
import Foundation
@testable import AetherEngine

/// AetherEngine#88: selecting an external id through the unified selectSubtitleTrack routes onto
/// the sidecar decode path and publishes the external id as the active track (the old sidecar API
/// nilled it, so hosts could not highlight an external selection).
@MainActor
struct ExternalSubtitleSelectionTests {

    private func makeTrack(_ name: String = "x") -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(url: URL(string: "https://s/\(name).srt")!, name: name, language: "de")
    }

    @Test("selecting an external id activates it and publishes activeSubtitleTrackIndex")
    func selectExternal() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(makeTrack())
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.isSubtitleActive)
        #expect(engine.activeSubtitleTrackIndex == info.id)
        #expect(engine.activeEmbeddedSubtitleStreamIndex == -1)
    }

    @Test("external selection works without a loaded URL (no loadedURL guard on the external path)")
    func selectExternalWithoutLoad() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(makeTrack())
        #expect(engine.loadedURL == nil)
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.isSubtitleActive)
    }

    @Test("unknown external-range id no-ops")
    func unknownIDNoop() throws {
        let engine = try AetherEngine()
        engine.selectSubtitleTrack(index: AetherEngine.externalSubtitleTrackIDBase + 7)
        #expect(!engine.isSubtitleActive)
    }

    @Test("secondary channel publishes a registered external id after decode")
    func secondaryExternal() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("secondary-external-\(UUID().uuidString).srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nhello\n".write(
            to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url, name: "local"))
        engine.selectSecondarySubtitleTrack(index: info.id)
        let deadline = ContinuousClock.now + .seconds(5)
        while engine.isLoadingSecondarySubtitles {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.isSecondarySubtitleActive)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == info.id)
        #expect(engine.activeSecondarySubtitleTrackIndex == info.id)
        #expect(engine.activeSecondaryEmbeddedSubtitleStreamIndex == -1)
    }

    @Test("explicit clear latches hostExplicitSubtitleAction; a late add does not re-enable")
    func lateAddGate() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preferredSubtitleLanguages: ["de"]))
        engine.clearSubtitle()
        #expect(engine.hostExplicitSubtitleAction)
        _ = engine.addExternalSubtitleTrack(makeTrack())
        #expect(!engine.isSubtitleActive)
    }

    @Test("without an explicit action, a late add matching the preference auto-selects")
    func lateAddAutoSelect() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preferredSubtitleLanguages: ["de"]))
        let info = engine.addExternalSubtitleTrack(makeTrack())
        #expect(engine.activeSubtitleTrackIndex == info.id)
        #expect(engine.isSubtitleActive)
    }
}
