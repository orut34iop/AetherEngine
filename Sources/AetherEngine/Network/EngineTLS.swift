import Foundation

/// Host-app TLS trust policy for the engine's outbound HTTP connections.
///
/// URLSession enforces system certificate trust, which the in-demuxer network
/// stacks this engine replaces never did. A media server fronted by a
/// self-signed or private-CA certificate therefore keeps working in a host
/// whose own API layer bypasses trust, while every engine fetch fails its
/// handshake before a byte is read and the open surfaces as bare invalid data.
/// The host opts in per exact HTTPS origin; every other challenge keeps the
/// system's default handling.
public enum EngineTLS {

    /// Exact HTTPS origin eligible for an explicit failed-server-trust bypass.
    /// Paths, queries and fragments are deliberately absent: URL origin
    /// identity is scheme + case-insensitive host + effective port.
    public struct Origin: Hashable, Sendable {
        public let scheme: String
        public let host: String
        public let port: Int

        /// Build an origin from an absolute HTTPS URL. The path, query,
        /// fragment and user-info do not participate in origin identity.
        public init?(url: URL) {
            guard let scheme = url.scheme, let host = url.host else { return nil }
            self.init(scheme: scheme, host: host, port: url.port)
        }

        /// Build an exact HTTPS origin. A nil port resolves to 443.
        public init?(scheme: String, host: String, port: Int? = nil) {
            let normalizedScheme = scheme.lowercased()
            guard normalizedScheme == "https" else { return nil }

            var normalizedHost = host.lowercased()
            while normalizedHost.hasSuffix(".") { normalizedHost.removeLast() }
            guard !normalizedHost.isEmpty else { return nil }

            let effectivePort = port ?? 443
            guard (1...65_535).contains(effectivePort) else { return nil }

            self.scheme = normalizedScheme
            self.host = normalizedHost
            self.port = effectivePort
        }

        fileprivate init?(protectionSpace: URLProtectionSpace) {
            guard let scheme = protectionSpace.protocol else { return nil }
            self.init(
                scheme: scheme,
                host: protectionSpace.host,
                port: protectionSpace.port > 0 ? protectionSpace.port : nil)
        }
    }

    /// Origins whose server certificates may bypass failed system trust.
    ///
    /// Read per challenge, so replacing or clearing the set applies to the
    /// next connection without rebuilding sessions. A redirect or playlist
    /// sub-resource is evaluated against its own protection-space origin and
    /// therefore does not inherit the source origin's approval.
    public static var allowedUntrustedCertificateOrigins: Set<Origin> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _allowedUntrustedCertificateOrigins
        }
        set {
            lock.lock()
            _allowedUntrustedCertificateOrigins = newValue
            lock.unlock()
        }
    }

    /// Decides whether to accept a server certificate that failed system
    /// trust evaluation, for the origin the challenge came from.
    ///
    /// nil, the default, keeps the system's default handling everywhere. The
    /// blunt answer is one line (`{ _ in true }`), and a host holding a LAN
    /// address behind a private certificate alongside a WAN address with a
    /// real one can answer for each rather than relaxing both. A host that
    /// wants to pin an SPKI hash reads the protection space and decides.
    ///
    /// Read per challenge, so replacing it applies from the next connection
    /// without rebuilding sessions. Called off the main actor, from whichever
    /// queue the session raised the challenge on, so it has to be
    /// thread-safe. Lock-guarded like `EngineLog.handler`.
    public static var serverTrustEvaluator: (@Sendable (URLProtectionSpace) -> Bool)? {
        get { lock.lock(); defer { lock.unlock() }; return _evaluator }
        set { lock.lock(); _evaluator = newValue; lock.unlock() }
    }

    nonisolated(unsafe) private static var _evaluator: (@Sendable (URLProtectionSpace) -> Bool)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _allowedUntrustedCertificateOrigins: Set<Origin> = []

    /// Whether `url` names an origin explicitly approved for failed server
    /// trust. Used by the native-remote-HLS route to decide whether AVPlayer
    /// must be placed behind the engine-owned loopback proxy.
    public static func allowsUntrustedCertificate(for url: URL) -> Bool {
        guard let origin = Origin(url: url) else { return false }
        return isAllowed(origin)
    }

    private static func isAllowed(_ origin: Origin) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _allowedUntrustedCertificateOrigins.contains(origin)
    }

    /// Session-level delegate for the owned sessions that otherwise run
    /// without one (disc reader, HLS ingest readers, audio tap fetcher) and
    /// the fallback for tasks that missed a per-task delegate.
    static let sessionDelegate = SessionTrustDelegate()

    /// Single disposition shared by the session-level delegate and AVIOReader
    /// per-task delegates. Anything other than an explicitly approved exact-
    /// origin server-trust challenge is left to default handling, so client
    /// certificates, HTTP auth, redirects and sibling origins fail closed.
    static func resolve(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
            (Origin(protectionSpace: challenge.protectionSpace).map(isAllowed) == true
                || serverTrustEvaluator?(challenge.protectionSpace) == true),
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    final class SessionTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?)
                -> Void
        ) {
            EngineTLS.resolve(challenge, completionHandler: completionHandler)
        }
    }
}
