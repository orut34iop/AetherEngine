import Darwin
import Foundation

/// A session-owned, disk-backed FIFO of opaque compressed-packet records.
///
/// Payloads and record lengths live on disk, not in an in-memory packet index. Only head/tail
/// offsets and aggregate counters are retained, independent of the number of packets/chunks.
/// Call all I/O methods from background workers: the lock intentionally serializes disk access
/// with reset/close. The caller owns byte/time backpressure and packet serialization.
final class SoftwarePacketDiskFIFO: @unchecked Sendable {
    struct StaleSweepResult: Sendable {
        let inspectedCount: Int
        let removedCount: Int
        let failureCount: Int
    }

    struct Snapshot: Sendable {
        let count: Int
        /// Payload bytes not yet popped; excludes record headers and the consumed head prefix.
        let byteCount: Int
        /// Logical file bytes, including headers and any consumed prefix of the current chunk.
        let diskByteCount: Int
        let chunkCount: Int
        let isClosed: Bool
        let hasFailure: Bool
    }

    enum Failure: Error, Equatable {
        case invalidChunkTarget
        case closed
        case corruptRecord
        case capacityExceeded
        case sessionLeaseLost
    }

    static let directoryPrefix = "aether-software-packets-"
    private static let liveMarkerName = "session.lock"

    /// Always an explicitly created, unique child, never the caller's parent directory.
    let storageDirectory: URL
    let staleSweepResult: StaleSweepResult
    private let chunkTargetBytes: Int
    private let lock = NSLock()
    private var writer: FileHandle?
    private var reader: FileHandle?
    /// An open-file-description lock also protects against other sessions in this process.
    /// Unlike an age-only marker, the kernel releases it when a process crashes.
    private var leaseFD: Int32 = -1
    private var pendingChunkID: UInt64?
    private var headID: UInt64 = 0
    private var tailID: UInt64 = 0
    private var headOffset: UInt64 = 0
    private var tailBytes: UInt64 = 0
    private var sealedHeadBytes: UInt64?
    private var recordCount = 0
    private var payloadBytes = 0
    private var diskBytes = 0
    private var chunks = 0
    private var isClosed = false
    /// A partial disk operation cannot be retried as if it had succeeded. Only reset recovers it.
    private var failure: (any Error)?

    init(chunkTargetBytes: Int = 4 * 1024 * 1024,
         parentDirectory: URL = FileManager.default.temporaryDirectory,
         now: Date = Date(),
         leaseAcquisition: ((URL) throws -> Int32)? = nil) throws {
        guard chunkTargetBytes >= 8 else { throw Failure.invalidChunkTarget }
        self.chunkTargetBytes = chunkTargetBytes
        storageDirectory = parentDirectory.appendingPathComponent(
            "\(Self.directoryPrefix)\(UUID().uuidString)", isDirectory: true)
        // mkdir, not createDirectory's existing-directory success: cleanup must own this root.
        guard mkdir(storageDirectory.path, 0o700) == 0 else { throw Self.posixError() }
        do {
            // The injectable acquisition is used only by focused interrupted-init tests.
            leaseFD = try (leaseAcquisition ?? Self.acquireNewLease)(storageDirectory)
            guard leaseFD >= 0 else { throw Failure.sessionLeaseLost }
        } catch {
            try? FileManager.default.removeItem(at: storageDirectory)
            if leaseFD >= 0 { Darwin.close(leaseFD) }
            throw error
        }
        staleSweepResult = Self.sweepStaleSessionDirs(parentDirectory: parentDirectory,
            currentSession: storageDirectory.lastPathComponent, now: now)
    }

    deinit {
        try? close()
        // A failed best-effort removal must not leak the advisory lease descriptor.
        if leaseFD >= 0 { Darwin.close(leaseFD) }
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(count: recordCount, byteCount: payloadBytes, diskByteCount: diskBytes,
                        chunkCount: chunks, isClosed: isClosed, hasFailure: failure != nil)
    }

    func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireUsable()
        do {
            let recordBytes = try checkedSum(data.count, 8)
            let nextCount = try checkedSum(recordCount, 1)
            let nextPayloadBytes = try checkedSum(payloadBytes, data.count)
            let nextDiskBytes = try checkedSum(diskBytes, recordBytes)
            if writer == nil {
                try openFirstChunk()
            } else if tailBytes > 0,
                      UInt64(recordBytes) > UInt64(chunkTargetBytes) - min(tailBytes, UInt64(chunkTargetBytes)) {
                try openNextChunk()
            }
            guard let writer else { throw Failure.corruptRecord }
            var length = UInt64(data.count).bigEndian
            let header = withUnsafeBytes(of: &length) { Data($0) }
            try writer.write(contentsOf: header)
            try writer.write(contentsOf: data)
            tailBytes += UInt64(recordBytes)
            recordCount = nextCount
            payloadBytes = nextPayloadBytes
            diskBytes = nextDiskBytes
        } catch {
            failure = error
            throw error
        }
    }

    func pop() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        try requireUsable()
        guard recordCount > 0 else { return nil }
        do {
            if reader == nil { reader = try FileHandle(forReadingFrom: chunkURL(headID)) }
            guard let reader else { throw Failure.corruptRecord }
            let limit: UInt64
            if headID == tailID {
                limit = tailBytes
            } else if let sealedHeadBytes {
                limit = sealedHeadBytes
            } else {
                limit = try reader.seekToEnd()
                sealedHeadBytes = limit
                try reader.seek(toOffset: headOffset)
            }
            guard headOffset <= limit, limit - headOffset >= 8 else { throw Failure.corruptRecord }
            let header = try readExactly(8, from: reader)
            let length = header.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard length <= UInt64(payloadBytes), length <= limit - headOffset - 8 else {
                throw Failure.corruptRecord
            }
            let data = try readExactly(Int(length), from: reader)
            let nextOffset = headOffset + 8 + length
            if nextOffset == limit {
                try reclaimHead(byteCount: limit)
            } else {
                headOffset = nextOffset
            }
            recordCount -= 1
            payloadBytes -= Int(length)
            return data
        } catch {
            failure = error
            throw error
        }
    }

    /// Discards this session's contents, including any partial record left by a failed operation.
    func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw Failure.closed }
        do {
            try closePacketHandles()
            if try restoreWhollyMissingDirectory() {
                // The OS already discarded all chunks; the replacement has its own live lease.
                clearCounters()
                failure = nil
                return
            }
            try verifyLeaseIdentity()
            if chunks > 0 {
                for id in headID...tailID { try removeChunkIfPresent(id) }
            }
            if let pendingChunkID { try removeChunkIfPresent(pendingChunkID) }
            clearCounters()
            failure = nil
        } catch {
            failure = error
            throw error
        }
    }

    /// Idempotent; a failed cleanup can be retried, but the store stays closed in either case.
    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        do {
            try removeOwnedStorage()
            clearCounters()
            if leaseFD >= 0 {
                Darwin.close(leaseFD)
                leaseFD = -1
            }
        } catch {
            failure = error
            throw error
        }
    }

    private func requireUsable() throws {
        guard !isClosed else { throw Failure.closed }
        if let failure { throw failure }
    }

    private func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw Failure.capacityExceeded }
        return sum
    }

    private func chunkURL(_ id: UInt64) -> URL {
        storageDirectory.appendingPathComponent("\(id).packets", isDirectory: false)
    }

    private func makeWriter(_ id: UInt64) throws -> FileHandle {
        let url = chunkURL(id)
        pendingChunkID = id
        // Never truncate an unexpected existing file, even inside our own unique directory.
        try Data().write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        pendingChunkID = nil
        return handle
    }

    private func openFirstChunk() throws {
        writer = try makeWriter(0)
        headID = 0
        tailID = 0
        chunks = 1
    }

    private func openNextChunk() throws {
        guard tailID < UInt64.max else { throw Failure.capacityExceeded }
        let previousWriter = writer
        writer = nil
        try previousWriter?.close()
        let nextWriter = try makeWriter(tailID + 1)
        if headID == tailID { sealedHeadBytes = tailBytes }
        tailID += 1
        tailBytes = 0
        writer = nextWriter
        chunks += 1
    }

    private func readExactly(_ length: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        result.reserveCapacity(length)
        while result.count < length {
            guard let part = try handle.read(upToCount: length - result.count), !part.isEmpty else {
                throw Failure.corruptRecord
            }
            result.append(part)
        }
        return result
    }

    private func reclaimHead(byteCount: UInt64) throws {
        let previousReader = reader
        reader = nil
        try previousReader?.close()
        if headID == tailID {
            let previousWriter = writer
            writer = nil
            try previousWriter?.close()
        }
        try FileManager.default.removeItem(at: chunkURL(headID))
        diskBytes -= Int(byteCount)
        chunks -= 1
        headOffset = 0
        sealedHeadBytes = nil
        if chunks == 0 {
            headID = 0
            tailID = 0
            tailBytes = 0
        } else {
            headID += 1
        }
    }

    private func closePacketHandles() throws {
        var firstError: (any Error)?
        let handles = [reader, writer]
        reader = nil
        writer = nil
        for handle in handles {
            do { try handle?.close() } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private func removeOwnedStorage() throws {
        var firstError: (any Error)?
        do { try closePacketHandles() } catch { firstError = error }
        do {
            try FileManager.default.removeItem(at: storageDirectory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // A repeated close, or recovery after an externally purged temporary directory.
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    private func removeChunkIfPresent(_ id: UInt64) throws {
        let url = chunkURL(id)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw Self.posixError()
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.corruptRecord }
        try FileManager.default.removeItem(at: url)
    }

    private func verifyLeaseIdentity() throws {
        var held = stat()
        var named = stat()
        guard leaseFD >= 0, fstat(leaseFD, &held) == 0,
              lstat(storageDirectory.appendingPathComponent(Self.liveMarkerName).path, &named) == 0,
              named.st_mode & S_IFMT == S_IFREG,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else {
            throw Failure.sessionLeaseLost
        }
    }

    /// Normal reset never removes/replaces the marker. An OS-purged root is different: its
    /// unlinked lease no longer protects a path, so rebuild and acquire the replacement first.
    private func restoreWhollyMissingDirectory() throws -> Bool {
        var info = stat()
        if lstat(storageDirectory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.sessionLeaseLost }
            return false
        }
        guard errno == ENOENT else { throw Self.posixError() }
        guard mkdir(storageDirectory.path, 0o700) == 0 else { throw Self.posixError() }
        do {
            let replacement = try Self.acquireNewLease(storageDirectory)
            if leaseFD >= 0 { Darwin.close(leaseFD) }
            leaseFD = replacement
        } catch {
            try? FileManager.default.removeItem(at: storageDirectory)
            throw error
        }
        return true
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func acquireNewLease(_ directory: URL) throws -> Int32 {
        let path = directory.appendingPathComponent(liveMarkerName).path
        let fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = posixError()
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    /// Bounded crash-remnant cleanup, never a recursive search of the caller's temporary root.
    /// Only our UUID-named direct-child directories older than one day are candidates. Keep the
    /// candidate's advisory lease held until removal finishes; age alone never proves abandonment.
    static func sweepStaleSessionDirs(parentDirectory: URL, currentSession: String? = nil,
                                     now: Date = Date(), maxEntries: Int = 64,
                                     maxRemovals: Int = 8) -> StaleSweepResult {
        guard maxEntries > 0, maxRemovals > 0,
              let entries = FileManager.default.enumerator(at: parentDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
            return StaleSweepResult(inspectedCount: 0, removedCount: 0, failureCount: 0)
        }
        var inspected = 0
        var removed = 0
        var failures = 0
        while inspected < maxEntries, removed < maxRemovals,
              let entry = entries.nextObject() as? URL {
            inspected += 1
            let name = entry.lastPathComponent
            guard name != currentSession, name.hasPrefix(directoryPrefix),
                  UUID(uuidString: String(name.dropFirst(directoryPrefix.count))) != nil else { continue }
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { failures += 1; continue }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            guard info.st_mode & S_IFMT == S_IFDIR,
                  now.timeIntervalSince1970 - modified >= 86_400 else { continue }
            let dirFD = open(entry.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dirFD >= 0 else { failures += 1; continue }
            defer { Darwin.close(dirFD) }
            // O_CREAT also lets us lease a root abandoned between mkdir and marker creation.
            let markerFD = openat(dirFD, liveMarkerName,
                                  O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard markerFD >= 0 else { failures += 1; continue }
            defer { Darwin.close(markerFD) }
            guard flock(markerFD, LOCK_EX | LOCK_NB) == 0 else {
                if errno != EWOULDBLOCK && errno != EAGAIN { failures += 1 }
                continue
            }
            // Recheck identity rather than following a replaced directory or marker symlink.
            var held = stat()
            var named = stat()
            guard fstat(dirFD, &held) == 0, lstat(entry.path, &named) == 0,
                  named.st_mode & S_IFMT == S_IFDIR,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino else {
                failures += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: entry)
                removed += 1
            } catch { failures += 1 }
        }
        return StaleSweepResult(inspectedCount: inspected, removedCount: removed, failureCount: failures)
    }

    private func clearCounters() {
        headID = 0
        tailID = 0
        headOffset = 0
        tailBytes = 0
        sealedHeadBytes = nil
        recordCount = 0
        payloadBytes = 0
        diskBytes = 0
        chunks = 0
        pendingChunkID = nil
    }
}
