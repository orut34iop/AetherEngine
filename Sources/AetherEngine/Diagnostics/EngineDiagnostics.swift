import Foundation
import Combine

/// Separate ObservableObject for liveTelemetry (AetherEngine#29).
/// Keeping it on the engine itself caused 1 Hz objectWillChange storms that blinked native Menu on tvOS.
/// Stats overlays observe this object; everything else observes the engine and is unaffected by telemetry samples.
@MainActor
public final class EngineDiagnostics: ObservableObject {

    /// 1 Hz snapshot while playing/paused; nil while idle. Cleared in stopInternal so sessions don't inherit stale numbers.
    @Published public internal(set) var liveTelemetry: LiveTelemetry?

    /// Route-aware session-only fMP4 cache state. Updated at session lifecycle transitions and by
    /// the 1 Hz sampler while active; cleanup completion remains visible after live telemetry stops.
    @Published public internal(set) var sessionCacheStatus: SessionCacheStatus = .inactive

    /// One bounded tvOS display-mode sample captured after playback starts. This is structured so hosts
    /// can persist the numeric cadence evidence without installing the raw `EngineLog.handler`, whose
    /// unrelated lines may contain source URLs or request credentials.
    @Published public internal(set) var displayModeDiagnostic: DisplayModeDiagnostic?
}

/// Safe numeric read-back of the content cadence, requested display criteria, active panel refresh rate,
/// and AVPlayer's reported video output rate. Nil means that platform or playback path did not expose the
/// measurement; no source identity, URL, headers, or media metadata are carried.
public struct DisplayModeDiagnostic: Equatable, Sendable {
    public let backend: String
    public let contentFrameRate: Double?
    public let requestedRefreshRate: Double?
    public let measuredRefreshRate: Double?
    public let nominalRefreshRate: Double?
    public let playerFrameRate: Double?

    public init(
        backend: String,
        contentFrameRate: Double?,
        requestedRefreshRate: Double?,
        measuredRefreshRate: Double?,
        nominalRefreshRate: Double?,
        playerFrameRate: Double?
    ) {
        self.backend = backend
        self.contentFrameRate = contentFrameRate
        self.requestedRefreshRate = requestedRefreshRate
        self.measuredRefreshRate = measuredRefreshRate
        self.nominalRefreshRate = nominalRefreshRate
        self.playerFrameRate = playerFrameRate
    }
}
