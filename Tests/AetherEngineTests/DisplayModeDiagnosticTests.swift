import Testing
@testable import AetherEngine

@Suite("Structured display-mode diagnostic")
@MainActor
struct DisplayModeDiagnosticTests {
    @Test("publishes only the bounded numeric cadence sample")
    func publication() {
        let diagnostics = EngineDiagnostics()
        let sample = DisplayModeDiagnostic(
            backend: "native",
            contentFrameRate: 30_000.0 / 1_001.0,
            requestedRefreshRate: 29.97,
            measuredRefreshRate: 59.94,
            nominalRefreshRate: 59.94,
            playerFrameRate: 29.97
        )

        diagnostics.displayModeDiagnostic = sample

        #expect(diagnostics.displayModeDiagnostic == sample)
        #expect(sample.backend == "native")
        #expect(sample.contentFrameRate == 30_000.0 / 1_001.0)
        #expect(sample.measuredRefreshRate == 59.94)
    }
}
