import Testing
import Foundation
@testable import AetherEngine

@MainActor
struct PreparedExternalSubtitleTests {
    private func file(_ text: String, ext: String = "srt") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture.\(ext)")
        try Data(text.utf8).write(to: url)
        return url
    }
    private var text: String { "1\n00:02:01,000 --> 00:02:03,000\nFixture\n\n" }
    private func player() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.state = .paused
        engine.activeSubtitleTrackIndex = 7
        engine.subtitleCues = [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("Old"))]
        return engine
    }

    @Test func prepareDoesNotChangeOldSelectionAndCommitDoesNotReadFile() async throws {
        let engine = try player()
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prepared = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        #expect(engine.activeSubtitleTrackIndex == 7)
        #expect(engine.subtitleCues.first?.text == "Old")
        #expect(engine.subtitleTracks.isEmpty)
        #expect(prepared.cueCount == 1)
        try FileManager.default.removeItem(at: url)
        let track = try engine.commitExternalSubtitle(prepared)
        #expect(track.isExternal)
        #expect(engine.activeSubtitleTrackIndex == track.id)
        #expect(engine.subtitleCues.first?.text == "Fixture")
        #expect(engine.state == .paused)
        #expect(throws: ExternalSubtitlePreparationError.self) { try engine.commitExternalSubtitle(prepared) }
    }

    @Test func invalidAndPlaylistFilesNeverClearOldSubtitle() async throws {
        for payload in ["not a subtitle", "", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nhttps://127.0.0.1:1/video.m3u8\n"] {
            let engine = try player()
            let url = try file(payload)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            await #expect(throws: ExternalSubtitlePreparationError.self) {
                try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
            }
            #expect(engine.activeSubtitleTrackIndex == 7)
            #expect(engine.subtitleCues.first?.text == "Old")
            #expect(engine.subtitleTracks.isEmpty)
        }
    }

    @Test func stoppedGenerationAndNewIntentRejectPreparedCandidate() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        let first = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        engine.loadGeneration += 1
        #expect(throws: ExternalSubtitlePreparationError.self) { try engine.commitExternalSubtitle(first) }
        let second = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        engine.clearSubtitle()
        #expect(throws: ExternalSubtitlePreparationError.self) { try engine.commitExternalSubtitle(second) }
        #expect(engine.activeSubtitleTrackIndex == nil)
        #expect(engine.subtitleTracks.isEmpty)
    }

    @Test func exactRegisteredIDAndRemovedAssetAreRespected() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        let descriptor = ExternalSubtitleTrack(url: url)
        let first = engine.registerExternalSubtitleTrack(descriptor)
        let second = engine.registerExternalSubtitleTrack(descriptor)
        engine.activeSecondarySubtitleTrackIndex = first.id
        let candidate = try await engine.prepareExternalSubtitle(id: second.id)
        #expect(try engine.commitExternalSubtitle(candidate).id == second.id)
        let removed = try await engine.prepareExternalSubtitle(id: second.id)
        engine.removeExternalSubtitleTrack(id: second.id)
        #expect(throws: ExternalSubtitlePreparationError.self) { try engine.commitExternalSubtitle(removed) }
    }

    @Test func secondaryRemainsWhenPrimaryCommits() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        engine.activeSecondarySubtitleTrackIndex = 8
        engine.secondarySubtitleCues = [SubtitleCue(id: 2, startTime: 0, endTime: 10, body: .text("Secondary"))]
        let candidate = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        try engine.commitExternalSubtitle(candidate)
        #expect(engine.activeSecondarySubtitleTrackIndex == 8)
        #expect(engine.secondarySubtitleCues.first?.text == "Secondary")
    }
}
