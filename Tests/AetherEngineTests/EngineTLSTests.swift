import Foundation
import Testing

@testable import AetherEngine

// Self-signed and private-CA media servers fail URLSession's system trust.
// A host may approve one exact HTTPS origin, but that approval must not become
// process-global trust for a sibling host, port, scheme, or redirect.
@Suite("EngineTLS policy", .serialized)
struct EngineTLSTestSuite {

@Suite("Trust resolution")
struct ResolutionTests {

    private final class RecordingSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func challenge(
        method: String, host: String = "server.example", port: Int = 443,
        protocol scheme: String = "https"
    ) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            host: host, port: port, protocol: scheme,
            realm: nil, authenticationMethod: method)
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: RecordingSender())
    }

    private func disposition(
        origins: Set<EngineTLS.Origin>, method: String,
        host: String = "server.example", port: Int = 443,
        protocol scheme: String = "https"
    ) -> URLSession.AuthChallengeDisposition {
        let previous = EngineTLS.allowedUntrustedCertificateOrigins
        defer { EngineTLS.allowedUntrustedCertificateOrigins = previous }
        EngineTLS.allowedUntrustedCertificateOrigins = origins

        var got: URLSession.AuthChallengeDisposition?
        EngineTLS.resolve(challenge(
            method: method, host: host, port: port, protocol: scheme
        )) { disposition, _ in
            got = disposition
        }
        return got ?? .performDefaultHandling
    }

    @Test("An empty policy keeps default handling for server trust")
    func emptyPolicyKeepsDefaultTrust() {
        #expect(
            disposition(origins: [], method: NSURLAuthenticationMethodServerTrust)
                == .performDefaultHandling)
    }

    @Test("Non-trust challenges keep default handling even when opted in")
    func httpAuthUntouched() {
        let origin = EngineTLS.Origin(
            url: URL(string: "https://server.example")!)!
        #expect(
            disposition(origins: [origin], method: NSURLAuthenticationMethodHTTPBasic)
                == .performDefaultHandling)
    }

    @Test("Opted-in server trust without an evaluable trust object stays on default handling")
    func optedInWithoutTrustObject() {
        // A challenge built outside a live handshake carries no SecTrust, so
        // the resolver must fall through rather than send a nil credential.
        let origin = EngineTLS.Origin(
            url: URL(string: "https://server.example")!)!
        #expect(
            disposition(origins: [origin], method: NSURLAuthenticationMethodServerTrust)
                == .performDefaultHandling)
    }

    @Test("The policy defaults empty")
    func defaultsEmpty() {
        #expect(EngineTLS.allowedUntrustedCertificateOrigins.isEmpty)
    }

    @Test("Origins normalize host case, trailing dot, path and the HTTPS default port")
    func originNormalization() {
        let explicit = EngineTLS.Origin(
            url: URL(string: "https://SERVER.Example.:443/library/movie.mkv?token=secret")!)
        let implicit = EngineTLS.Origin(
            url: URL(string: "https://server.example/other")!)
        #expect(explicit == implicit)
        #expect(explicit?.scheme == "https")
        #expect(explicit?.host == "server.example")
        #expect(explicit?.port == 443)
    }

    @Test("Non-HTTPS and invalid-port URLs cannot become certificate-bypass origins")
    func rejectsInvalidOrigins() {
        #expect(EngineTLS.Origin(url: URL(string: "http://server.example")!) == nil)
        #expect(EngineTLS.Origin(scheme: "https", host: "server.example", port: 0) == nil)
        #expect(EngineTLS.Origin(scheme: "https", host: "", port: 443) == nil)
    }

    @Test("Approval matches scheme, host and effective port exactly")
    func exactOriginMatching() {
        let approvedURL = URL(string: "https://server.example:8443/base")!
        let origin = EngineTLS.Origin(url: approvedURL)!
        let previous = EngineTLS.allowedUntrustedCertificateOrigins
        defer { EngineTLS.allowedUntrustedCertificateOrigins = previous }
        EngineTLS.allowedUntrustedCertificateOrigins = [origin]

        #expect(EngineTLS.allowsUntrustedCertificate(for: approvedURL))
        #expect(EngineTLS.allowsUntrustedCertificate(
            for: URL(string: "https://SERVER.EXAMPLE:8443/child")!))
        #expect(!EngineTLS.allowsUntrustedCertificate(
            for: URL(string: "https://sibling.example:8443/child")!))
        #expect(!EngineTLS.allowsUntrustedCertificate(
            for: URL(string: "https://server.example/child")!))
        #expect(!EngineTLS.allowsUntrustedCertificate(
            for: URL(string: "http://server.example:8443/child")!))
    }

    @Test("Replacing and clearing the policy revokes future connections")
    func replacementRevokesOldOrigin() {
        let firstURL = URL(string: "https://first.example")!
        let secondURL = URL(string: "https://second.example:9443")!
        let previous = EngineTLS.allowedUntrustedCertificateOrigins
        defer { EngineTLS.allowedUntrustedCertificateOrigins = previous }

        EngineTLS.allowedUntrustedCertificateOrigins = [
            EngineTLS.Origin(url: firstURL)!
        ]
        #expect(EngineTLS.allowsUntrustedCertificate(for: firstURL))

        EngineTLS.allowedUntrustedCertificateOrigins = [
            EngineTLS.Origin(url: secondURL)!
        ]
        #expect(!EngineTLS.allowsUntrustedCertificate(for: firstURL))
        #expect(EngineTLS.allowsUntrustedCertificate(for: secondURL))

        EngineTLS.allowedUntrustedCertificateOrigins = []
        #expect(!EngineTLS.allowsUntrustedCertificate(for: secondURL))
    }
}

}
