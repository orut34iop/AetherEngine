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
}
