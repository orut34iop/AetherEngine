import Foundation

public enum ExternalSubtitlePreparationError: Error, Sendable {
    case unsupportedFormat, empty, resourceLimit, decodeFailed, cancelled, stale, conflict
}

/// A single-use candidate. The engine retains no candidate; dropping the host's
/// handle releases its decoded data. It cannot outlive a load/stop generation.
@MainActor
public final class PreparedExternalSubtitle {
    fileprivate let owner: ObjectIdentifier
    fileprivate let generation: UInt64
    fileprivate let intent: UInt64
    fileprivate var registeredID: Int?
    fileprivate let track: ExternalSubtitleTrack
    fileprivate var result: SidecarDecodeResult?
    public let cueCount: Int

    fileprivate init(owner: AetherEngine, generation: UInt64,
                     track: ExternalSubtitleTrack, result: SidecarDecodeResult) {
        self.owner = ObjectIdentifier(owner)
        self.generation = generation
        intent = owner.externalSubtitleIntentGeneration
        self.track = track
        self.result = result
        cueCount = result.cues.count
    }

    public func discard() { result = nil }
}

extension AetherEngine {
    /// Decode only an already downloaded, bounded text sidecar. No track,
    /// preference, cue, translation or playback state changes during preparation.
    public func prepareExternalSubtitle(_ track: ExternalSubtitleTrack) async throws -> PreparedExternalSubtitle {
        let generation = loadGeneration
        let intent = externalSubtitleIntentGeneration
        guard state == .playing || state == .paused else { throw ExternalSubtitlePreparationError.stale }
        guard track.url.isFileURL, track.sourceStreamIndex == nil,
              ["srt", "vtt", "ass", "ssa"].contains((track.formatHint ?? track.url.pathExtension).lowercased()) else {
            throw ExternalSubtitlePreparationError.unsupportedFormat
        }
        do {
            let values = try track.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 4 * 1024 * 1024 else {
                throw ExternalSubtitlePreparationError.resourceLimit
            }
            try Task.checkCancellation()
            let decoded = try await SubtitleDecoder.decodeFile(
                url: track.url, httpHeaders: [:], preserveASSMarkup: false, boundedText: true)
            try Task.checkCancellation()
            guard generation == loadGeneration, intent == externalSubtitleIntentGeneration,
                  state == .playing || state == .paused else {
                throw ExternalSubtitlePreparationError.stale
            }
            guard !decoded.cues.isEmpty else { throw ExternalSubtitlePreparationError.empty }
            return PreparedExternalSubtitle(owner: self, generation: generation, track: track, result: decoded)
        } catch let error as ExternalSubtitlePreparationError { throw error }
        catch is CancellationError { throw ExternalSubtitlePreparationError.cancelled }
        catch SubtitleDecoderError.unsupportedTextCodec { throw ExternalSubtitlePreparationError.unsupportedFormat }
        catch SubtitleDecoderError.textLimitExceeded { throw ExternalSubtitlePreparationError.resourceLimit }
        catch { throw ExternalSubtitlePreparationError.decodeFailed }
    }

    /// Re-selecting an existing host sidecar obeys the same preparation contract.
    public func prepareExternalSubtitle(id: Int) async throws -> PreparedExternalSubtitle {
        guard let track = externalSubtitleRegistry[id] else { throw ExternalSubtitlePreparationError.stale }
        let prepared = try await prepareExternalSubtitle(track)
        guard externalSubtitleRegistry[id] == track else { throw ExternalSubtitlePreparationError.stale }
        prepared.registeredID = id
        return prepared
    }

    /// All rejection checks precede publication. A successful commit performs
    /// no file/network reads and does not suspend or re-decode the candidate.
    @discardableResult
    public func commitExternalSubtitle(_ prepared: PreparedExternalSubtitle,
                                       secondary: Bool = false) throws -> TrackInfo {
        guard !Task.isCancelled else { throw ExternalSubtitlePreparationError.cancelled }
        guard prepared.owner == ObjectIdentifier(self), prepared.generation == loadGeneration,
              prepared.intent == externalSubtitleIntentGeneration,
              state == .playing || state == .paused,
              let decoded = prepared.result else { throw ExternalSubtitlePreparationError.stale }
        let existingID = prepared.registeredID
        if let existingID, externalSubtitleRegistry[existingID] != prepared.track {
            throw ExternalSubtitlePreparationError.stale
        }
        let other = secondary ? activeSubtitleTrackIndex : activeSecondarySubtitleTrackIndex
        if let existingID, existingID == other { throw ExternalSubtitlePreparationError.conflict }
        let info: TrackInfo
        if let existingID, let existing = subtitleTracks.first(where: { $0.id == existingID }) {
            info = existing
        } else {
            var admitted = prepared.track
            admitted.boundedHostText = true
            info = registerExternalSubtitleTrack(admitted)
        }
        prepared.result = nil
        hostExplicitSubtitleAction = true
        externalSubtitleIntentGeneration &+= 1
        if secondary {
            clearSecondarySubtitle()
            activeSecondaryExternalSubtitleTrackID = info.id
            activeSecondarySubtitleTrackIndex = info.id
            loadedSecondarySidecarURL = prepared.track.url
            isSecondarySubtitleActive = true
            secondarySubtitleCues = decoded.cues
            secondarySidecarASSHeader = decoded.assHeader
            isLoadingSecondarySubtitles = false
        } else {
            cancelSidecarTask()
            clearSubtitleDrainTarget(channel: .primary, reason: .sidecarSelected)
            activeEmbeddedSubtitleStreamIndex = -1
            pgsStaleArrivalGates[.primary]?.reset()
            liveSubtitleFetchTask?.cancel()
            liveSubtitleFetchTask = nil
            activeSubtitleTrackIndex = info.id
            loadedSidecarURL = prepared.track.url
            isSubtitleActive = true
            subtitleCues = decoded.cues
            sidecarASSHeader = decoded.assHeader
            isLoadingSubtitles = false
        }
        return info
    }
}
