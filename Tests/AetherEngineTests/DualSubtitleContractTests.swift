import CoreGraphics
import Foundation
import Testing

@testable import AetherEngine

@MainActor
@Suite("Dual-subtitle public contract", .serialized)
struct DualSubtitleContractTests {

    private func track(_ id: Int, codec: String) -> TrackInfo {
        TrackInfo(
            id: id, name: "Track \(id)", codec: codec, language: "eng",
            isDefault: false)
    }

    private func waitForSidecars(_ engine: AetherEngine) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while engine.isLoadingSubtitles || engine.isLoadingSecondarySubtitles {
            try #require(ContinuousClock.now < deadline, "sidecar decode timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("secondary identity and bitmap capability are explicit public state")
    func publicStateDefaults() throws {
        let engine = try AetherEngine()
        #expect(engine.activeSecondarySubtitleTrackIndex == nil)
        #expect(engine.secondaryBitmapSupported == false)
        #expect(engine.secondarySidecarASSHeader == nil)
    }

    @Test("primary and secondary identities are independent and one id cannot occupy both roles")
    func identitiesAreIndependentAndExclusive() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://media.example/movie.mkv")!
        engine.subtitleTracks = [track(1, codec: "subrip"), track(2, codec: "ass")]

        engine.selectSubtitleTrack(index: 1)
        engine.selectSecondarySubtitleTrack(index: 2)
        #expect(engine.activeSubtitleTrackIndex == 1)
        #expect(engine.activeSecondarySubtitleTrackIndex == 2)

        engine.selectSecondarySubtitleTrack(index: 1)
        #expect(engine.activeSubtitleTrackIndex == 1)
        #expect(engine.activeSecondarySubtitleTrackIndex == 2)

        engine.selectSubtitleTrack(index: 2)
        #expect(engine.activeSubtitleTrackIndex == 1)
        #expect(engine.activeSecondarySubtitleTrackIndex == 2)

        engine.clearSubtitle()
        #expect(engine.activeSubtitleTrackIndex == nil)
        #expect(engine.activeSecondarySubtitleTrackIndex == 2)
        #expect(engine.isSecondarySubtitleActive)
    }

    @Test("secondary bitmap selection fails closed without disturbing either role")
    func bitmapFailsClosed() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://media.example/movie.mkv")!
        engine.subtitleTracks = [
            track(1, codec: "subrip"),
            track(2, codec: "ass"),
            track(3, codec: "hdmv_pgs_subtitle"),
        ]
        engine.selectSubtitleTrack(index: 1)
        engine.selectSecondarySubtitleTrack(index: 2)

        engine.selectSecondarySubtitleTrack(index: 3)

        #expect(engine.activeSubtitleTrackIndex == 1)
        #expect(engine.activeSecondarySubtitleTrackIndex == 2)
        #expect(engine.subtitleDrainTargets[.secondary] == 2)

        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        #expect(AetherEngine.secondarySubtitleCuesSupported([
            SubtitleCue(
                id: 1, startTime: 0, endTime: 1,
                body: .image(SubtitleImage(cgImage: image, position: .zero)))
        ]) == false)
        #expect(AetherEngine.secondarySubtitleCuesSupported([
            SubtitleCue(id: 2, startTime: 0, endTime: 1, body: .text("safe"))
        ]))
    }

    @Test("two registered text streams publish to their own channel and clear independently")
    func twoExternalTextStreamsPublishIndependently() async throws {
        let url = try MultiSubtitleContainerFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        let primary = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: url, name: "English", language: "eng",
            sourceStreamIndex: MultiSubtitleContainerFixture.englishStreamIndex))
        let secondary = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: url, name: "Spanish", language: "spa",
            sourceStreamIndex: MultiSubtitleContainerFixture.spanishStreamIndex))

        engine.selectSubtitleTrack(index: primary.id)
        engine.selectSecondarySubtitleTrack(index: secondary.id)
        try await waitForSidecars(engine)

        #expect(engine.activeSubtitleTrackIndex == primary.id)
        #expect(engine.activeSecondarySubtitleTrackIndex == secondary.id)
        #expect(engine.subtitleCues.compactMap(\.text) == MultiSubtitleContainerFixture.englishLines)
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)

        engine.clearSubtitle()
        #expect(engine.subtitleCues.isEmpty)
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
        #expect(engine.activeSecondarySubtitleTrackIndex == secondary.id)
    }

    @Test("secondary ASS preserves raw events and its own script header when requested")
    func secondaryASSPreservesMarkupAndHeader() async throws {
        let url = try MultiASSPlayResFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true))
        let primary = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: url, name: "English ASS", language: "eng", formatHint: "ass",
            sourceStreamIndex: MultiASSPlayResFixture.englishStreamIndex))
        let secondary = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: url, name: "Spanish ASS", language: "spa", formatHint: "ass",
            sourceStreamIndex: MultiASSPlayResFixture.spanishStreamIndex))

        engine.selectSubtitleTrack(index: primary.id)
        engine.selectSecondarySubtitleTrack(index: secondary.id)
        try await waitForSidecars(engine)

        #expect(engine.sidecarASSHeader?.contains("PlayResX: 640") == true)
        #expect(engine.secondarySidecarASSHeader?.contains("PlayResX: 1920") == true)
        guard case .text(let primaryRaw) = try #require(engine.subtitleCues.first).body,
              case .text(let secondaryRaw) = try #require(engine.secondarySubtitleCues.first).body
        else {
            Issue.record("preserved ASS cues must publish raw event lines on both channels")
            return
        }
        #expect(primaryRaw.contains(#"{\pos(320,240)}"#))
        #expect(secondaryRaw.contains(#"{\pos(320,240)}"#))

        engine.loadedURL = URL(string: "https://media.example/movie.mkv")!
        engine.subtitleTracks.append(track(3, codec: "subrip"))
        engine.selectSecondarySubtitleTrack(index: 3)
        #expect(engine.activeSecondarySubtitleTrackIndex == 3)
        #expect(engine.secondarySidecarASSHeader == nil)
    }

    @Test("implicit media headers are same-origin only; explicit external headers stay track-bound")
    func externalHeaderOriginPolicy() {
        let media = URL(string: "https://Media.Example:443/movie.mkv")!
        let mediaHeaders = ["Authorization": "Media secret"]
        #expect(AetherEngine.resolvedSubtitleHeaders(
            for: URL(string: "https://media.example/subtitles/en.srt")!,
            explicit: nil, mediaURL: media, mediaHeaders: mediaHeaders) == mediaHeaders)
        #expect(AetherEngine.resolvedSubtitleHeaders(
            for: URL(string: "https://cdn.example/en.srt")!,
            explicit: nil, mediaURL: media, mediaHeaders: mediaHeaders).isEmpty)
        #expect(AetherEngine.resolvedSubtitleHeaders(
            for: URL(string: "https://media.example:8443/en.srt")!,
            explicit: nil, mediaURL: media, mediaHeaders: mediaHeaders).isEmpty)

        let explicit = ["X-Subtitle-Token": "track secret"]
        #expect(AetherEngine.resolvedSubtitleHeaders(
            for: URL(string: "https://cdn.example/en.srt")!,
            explicit: explicit, mediaURL: media, mediaHeaders: mediaHeaders) == explicit)
    }
}
