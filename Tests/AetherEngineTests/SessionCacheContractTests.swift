import Foundation
import Testing
@testable import AetherEngine

@Suite("Session cache public contract")
struct SessionCachePublicContractTests {
    @Test("LoadOptions carries an exact caller-requested session budget")
    func loadOptionsBudget() {
        let auto = LoadOptions(sessionCacheByteBudget: 512 << 20)
        let disk = LoadOptions(sessionCacheByteBudget: 16 << 30)
        let disabled = LoadOptions(sessionCacheByteBudget: 0)
        #expect(auto.sessionCacheByteBudget == 512 << 20)
        #expect(disk.sessionCacheByteBudget == 16 << 30)
        #expect(disabled.sessionCacheByteBudget == 0)
    }

    @Test("Exact requests clamp to one quarter of free tmp capacity")
    func requestedBudgetClampsToVolume() {
        let result = HLSVideoEngine.resolveSessionCacheBudget(
            requestedBytes: 8 << 30,
            volumeAvailableBytes: 16 << 30,
            capRelaxed: true
        )
        #expect(result.requestedBytes == 8 << 30)
        #expect(result.volumeSafetyLimitBytes == 4 << 30)
        #expect(result.baseEffectiveBytes == 4 << 30)
    }

    @Test("Unknown capacity keeps the conservative 2 GiB safety ceiling")
    func unknownCapacityIsConservative() {
        let result = HLSVideoEngine.resolveSessionCacheBudget(
            requestedBytes: 16 << 30,
            volumeAvailableBytes: nil,
            capRelaxed: true
        )
        #expect(result.requestedBytes == 16 << 30)
        #expect(result.baseEffectiveBytes == 2 << 30)
    }

    @Test("Zero expresses window-only caching")
    func zeroBudgetIsWindowOnly() {
        let result = HLSVideoEngine.resolveSessionCacheBudget(
            requestedBytes: 0,
            volumeAvailableBytes: 100 << 30,
            capRelaxed: false
        )
        #expect(result.baseEffectiveBytes == 0)
    }

    @Test("Native remote HLS reports unsupported rather than zero-byte support")
    func nativeRemoteHLSIsUnsupported() {
        let status = SessionCacheStatus.nativeRemoteHLS(requestedBudgetBytes: 512 << 20)
        #expect(status.route == .nativeRemoteHLS)
        #expect(status.capability == .unsupported)
        #expect(status.requestedBudgetBytes == 512 << 20)
        #expect(status.currentResidentBytes == 0)
    }
}

@Suite("Session cache lifecycle and pressure contract")
struct SessionCacheLifecycleContractTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-cache-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Runtime hard window raises effective bytes instead of starving playback")
    func hardWindowRaisesEffectiveBudget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SegmentCache(
            forwardWindow: 1_000,
            backwardWindow: 20,
            retentionBudgetBytes: 50,
            baseDirectory: root,
            sessionID: "current"
        )
        defer { _ = cache.close(reason: .sessionStopped) }
        cache.declareTarget(0)
        for index in 0...10 {
            #expect(cache.store(index: index, data: Data(repeating: 1, count: 10)))
        }
        let status = cache.status(
            route: .loopbackFMP4,
            requestedBudgetBytes: 50,
            baseEffectiveBudgetBytes: 50,
            volumeSafetyLimitBytes: 1_000
        )
        #expect(status.playbackSafeFloorBytes == 110)
        #expect(status.effectiveBudgetBytes == 110)
        #expect(status.hardWindowFloorExceeded)
    }

    @Test("Producer park is observable and releases when the consumer advances")
    func producerParkStatus() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SegmentCache(
            forwardWindow: 1_000,
            backwardWindow: 2,
            retentionBudgetBytes: 50,
            baseDirectory: root,
            sessionID: "current"
        )
        defer { _ = cache.close(reason: .sessionStopped) }
        cache.declareTarget(0)
        for index in 0...10 { _ = cache.store(index: index, data: Data(repeating: 1, count: 10)) }
        #expect(cache.awaitPrefetchDiskHeadroom(head: 11, budgetBytes: 50, timeout: 0.01) == false)
        #expect(cache.producerParked)
        cache.declareTarget(9)
        #expect(cache.awaitPrefetchDiskHeadroom(head: 11, budgetBytes: 50, timeout: 0.01))
        #expect(cache.producerParked == false)
    }

    @Test("Close deletes the session directory and records its reason")
    func closeDeletesSession() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SegmentCache(baseDirectory: root, sessionID: "current")
        #expect(cache.store(index: 0, data: Data(repeating: 1, count: 32)))
        let result = cache.close(reason: .sourceChanged)
        #expect(result == .succeeded)
        #expect(FileManager.default.fileExists(atPath: cache.sessionDir.path) == false)
        #expect(cache.lastCleanupReason == .sourceChanged)
    }

    @Test("A failed session directory makes writes fail closed without false accounting")
    func writeFailureFailsClosed() throws {
        let rootFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-cache-file-\(UUID().uuidString)")
        try Data([1]).write(to: rootFile)
        defer { try? FileManager.default.removeItem(at: rootFile) }
        let cache = SegmentCache(baseDirectory: rootFile, sessionID: "impossible")
        #expect(cache.store(index: 0, data: Data(repeating: 1, count: 32)) == false)
        #expect(cache.totalBytes == 0)
        #expect(cache.lastFailure == .writeFailed)
        _ = cache.close(reason: .loadFailed)
    }

    @Test("A failed staging-file adopt cannot leave phantom resident bytes")
    func adoptFailureDropsMissingDestinationAccounting() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SegmentCache(baseDirectory: root, sessionID: "current")
        defer { _ = cache.close(reason: .sessionStopped) }
        #expect(cache.store(index: 0, data: Data(repeating: 1, count: 32)))
        let missing = root.appendingPathComponent("missing-staging.m4s")
        #expect(cache.adopt(index: 0, stagingPath: missing, byteCount: 64) == false)
        #expect(cache.totalBytes == 0)
        #expect(cache.peek(index: 0) == nil)
        #expect(cache.lastFailure == .adoptFailed)
    }

    @Test("Bounded stale sweep removes only expired siblings and preserves current and fresh")
    func boundedStaleSweep() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let current = root.appendingPathComponent("current", isDirectory: true)
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        var stale: [URL] = []
        for index in 0..<5 {
            let url = root.appendingPathComponent("stale-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-7_200 - Double(index))],
                ofItemAtPath: url.path
            )
            stale.append(url)
        }

        let first = SegmentCache.sweepStaleSessionDirs(
            baseDir: root,
            currentSession: "current",
            now: now,
            maxEntries: 7,
            maxRemovals: 2
        )
        #expect(first.inspectedCount <= 7)
        #expect(first.removedCount == 2)
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(stale.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 3)
    }
}
