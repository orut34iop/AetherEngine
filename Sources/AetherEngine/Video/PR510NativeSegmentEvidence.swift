import Foundation

/// Temporary, internal evidence capture for the isolated PR #510 diagnostic branch.
/// This writes only the session initialization bytes. Existing media caching is unchanged.
enum PR510NativeSegmentEvidence {
    static let maximumInitBytes = 1 << 20
    static let filename = "diagnostic-init.mp4"

    /// Call under the owning cache's lock. Never recreate an evicted/closed directory,
    /// throw into playback, publish source URLs, or replace evidence with oversized data.
    static func writeInit(_ data: Data, sessionDirectory: URL, sessionClosed: Bool) -> String {
        guard !sessionClosed else { return "closed" }
        guard !data.isEmpty, data.count <= maximumInitBytes else { return "size_rejected" }
        do {
            try data.write(to: sessionDirectory.appendingPathComponent(filename), options: .atomic)
            return "stored"
        } catch {
            return "write_failed"
        }
    }
}
