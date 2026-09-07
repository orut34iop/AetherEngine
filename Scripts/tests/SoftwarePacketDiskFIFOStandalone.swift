import Darwin
import Foundation

@main
struct SoftwarePacketDiskFIFOTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aether-disk-fifo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("unrelated")
        try Data([42]).write(to: sentinel, options: .withoutOverwriting)

        try expectFailure { _ = try SoftwarePacketDiskFIFO(chunkTargetBytes: 7, parentDirectory: root) }
        try roundTrip(root)
        try lifecycle(root)
        try boundedMetadata(root)
        try diskFailures(root)
        try concurrentAccess(root)
        try staleCleanup(root)
        try interruptedInitialization(root)
        try check(try Data(contentsOf: sentinel) == Data([42]), "cleanup touched an unrelated file")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(remaining == ["unrelated"], "owned storage leaked: \(remaining)")
        print("PASS: disk FIFO roundtrip, cross-chunk, partial drain, oversized/empty records, reset/close, failures, constant metadata, concurrent access, bounded stale cleanup/live leases/symlink isolation/interrupted init")
    }

    static func roundTrip(_ root: URL) throws {
        let store = try SoftwarePacketDiskFIFO(chunkTargetBytes: 40, parentDirectory: root)
        defer { try? store.close() }
        let records = [Data([1, 2]), Data(repeating: 3, count: 9), Data(repeating: 4, count: 80),
                       Data(), Data(repeating: 5, count: 12)]
        for record in records { try store.append(record) }
        precondition(store.snapshot.count == 5)
        precondition(store.snapshot.byteCount == 103)
        precondition(store.snapshot.chunkCount == 3)
        precondition(store.snapshot.diskByteCount == 143)
        try check(try store.pop() == records[0])
        precondition(store.snapshot.chunkCount == 3, "partially consumed chunk was prematurely deleted")
        try check(try store.pop() == records[1])
        precondition(store.snapshot.chunkCount == 2, "consumed chunk was not reclaimed")
        precondition(store.snapshot.diskByteCount == 116)
        for record in records.dropFirst(2) { try check(try store.pop() == record) }
        try check(try store.pop() == nil)
        precondition(store.snapshot.count == 0 && store.snapshot.byteCount == 0)
        precondition(store.snapshot.chunkCount == 0 && store.snapshot.diskByteCount == 0)
        try check(try FileManager.default.contentsOfDirectory(atPath: store.storageDirectory.path) == ["session.lock"])

        // Repeated appends to a chunk whose reader is already open must observe the new tail.
        try store.append(Data([6]))
        try store.append(Data([7]))
        try check(try store.pop() == Data([6]))
        try store.append(Data([8]))
        try check(try store.pop() == Data([7]))
        try check(try store.pop() == Data([8]))
        try store.append(Data([9]))
        try check(try store.pop() == Data([9]), "append after complete drain failed")
    }

    static func lifecycle(_ root: URL) throws {
        let store = try SoftwarePacketDiskFIFO(chunkTargetBytes: 16, parentDirectory: root)
        let directory = store.storageDirectory
        let marker = directory.appendingPathComponent("session.lock")
        let initialInode = try FileManager.default.attributesOfItem(atPath: marker.path)[.systemFileNumber] as? NSNumber
        let nonChunk = directory.appendingPathComponent("diagnostic-note")
        try Data([55]).write(to: nonChunk)
        try store.append(Data([1]))
        try store.append(Data([2]))
        try check(try store.pop() == Data([1]))
        try store.reset()
        let resetInode = try FileManager.default.attributesOfItem(atPath: marker.path)[.systemFileNumber] as? NSNumber
        precondition(initialInode != nil && resetInode == initialInode, "reset replaced the live lease inode")
        try check(try Data(contentsOf: nonChunk) == Data([55]), "reset removed a non-chunk file")
        let markerFD = open(marker.path, O_RDONLY | O_NOFOLLOW)
        precondition(markerFD >= 0)
        defer { Darwin.close(markerFD) }
        precondition(flock(markerFD, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK,
                     "reset released its live lease")
        precondition(store.storageDirectory == directory)
        precondition(store.snapshot.count == 0 && store.snapshot.chunkCount == 0)
        try check(try store.pop() == nil)
        try store.append(Data([3]))
        try check(try store.pop() == Data([3]))
        try store.close()
        precondition(flock(markerFD, LOCK_EX | LOCK_NB) == 0, "close did not release its live lease")
        try store.close()
        precondition(store.snapshot.isClosed)
        precondition(!FileManager.default.fileExists(atPath: directory.path))
        try expectFailure { try store.append(Data()) }
        try expectFailure { _ = try store.pop() }
        try expectFailure { try store.reset() }
    }

    static func boundedMetadata(_ root: URL) throws {
        let store = try SoftwarePacketDiskFIFO(chunkTargetBytes: 90_000, parentDirectory: root)
        defer { try? store.close() }
        for index in 0..<20_000 { try store.append(Data([UInt8(index % 251)])) }
        precondition(store.snapshot.count == 20_000 && store.snapshot.chunkCount == 2)
        // Exactly two chunk files, not 20,000 per-record files or resident record descriptors.
        try check(try FileManager.default.contentsOfDirectory(atPath: store.storageDirectory.path).count == 3)
        for index in 0..<20_000 {
            try check(try store.pop() == Data([UInt8(index % 251)]))
            if index == 9_999 { precondition(store.snapshot.chunkCount == 1) }
        }
        precondition(store.snapshot.chunkCount == 0 && store.snapshot.diskByteCount == 0)
    }

    static func diskFailures(_ root: URL) throws {
        let missingParent = root.appendingPathComponent("does-not-exist", isDirectory: true)
        try expectFailure { _ = try SoftwarePacketDiskFIFO(parentDirectory: missingParent) }
        let store = try SoftwarePacketDiskFIFO(chunkTargetBytes: 16, parentDirectory: root)
        defer { try? store.close() }

        // A removed temp directory must produce an explicit append failure, never accepted data.
        try FileManager.default.removeItem(at: store.storageDirectory)
        try expectFailure { try store.append(Data([1])) }
        precondition(store.snapshot.hasFailure && store.snapshot.count == 0)
        try expectFailure { _ = try store.pop() }
        try store.reset()
        precondition(!store.snapshot.hasFailure)

        // Failure while rolling over leaves prior accepted records visible in the failure
        // snapshot, and blocks reads until the caller explicitly chooses to discard/reset.
        try store.append(Data([9]))
        let nextChunk = store.storageDirectory.appendingPathComponent("1.packets")
        try Data([77]).write(to: nextChunk, options: .withoutOverwriting)
        try expectFailure { try store.append(Data([10])) }
        precondition(store.snapshot.count == 1 && store.snapshot.byteCount == 1)
        try expectFailure { _ = try store.pop() }
        try check(try Data(contentsOf: nextChunk) == Data([77]))
        try store.reset()
        try store.append(Data([2]))
        let chunk = store.storageDirectory.appendingPathComponent("0.packets")
        let handle = try FileHandle(forWritingTo: chunk)
        try handle.truncate(atOffset: 8)
        try handle.close()
        try expectFailure { _ = try store.pop() }
        precondition(store.snapshot.hasFailure && store.snapshot.count == 1,
                     "truncated record was silently lost")
        try expectFailure { try store.append(Data([3])) }
        try store.reset()
        try store.append(Data([4]))
        try check(try store.pop() == Data([4]))

        // Unexpected files are not overwritten. Reset removes only the owned session directory.
        try Data([88]).write(to: chunk, options: .withoutOverwriting)
        try expectFailure { try store.append(Data([5])) }
        try check(try Data(contentsOf: chunk) == Data([88]))
        try store.reset()
    }

    static func concurrentAccess(_ root: URL) throws {
        let store = try SoftwarePacketDiskFIFO(chunkTargetBytes: 128, parentDirectory: root)
        defer { try? store.close() }
        // Serial execution order across producers is deliberately unspecified; every record
        // must survive exactly once. FIFO order itself is checked by the sequential tests.
        DispatchQueue.concurrentPerform(iterations: 8) { producer in
            for index in 0..<100 {
                let value = Data("\(producer):\(index)".utf8)
                do { try store.append(value) } catch { fatalError("concurrent append: \(error)") }
            }
        }
        precondition(store.snapshot.count == 800)
        var seen = Set<Data>()
        while let data = try store.pop() { precondition(seen.insert(data).inserted) }
        precondition(seen.count == 800 && store.snapshot.chunkCount == 0)

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for index in 0..<2_000 {
                do { try store.append(Data("serial:\(index)".utf8)) }
                catch { fatalError("concurrent producer: \(error)") }
            }
        }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            var index = 0
            while index < 2_000 {
                do {
                    if let record = try store.pop() {
                        precondition(record == Data("serial:\(index)".utf8), "concurrent FIFO reordered")
                        index += 1
                    } else {
                        Thread.sleep(forTimeInterval: 0.0001)
                    }
                } catch { fatalError("concurrent consumer: \(error)") }
            }
        }
        precondition(group.wait(timeout: .now() + 10) == .success, "concurrent workers did not finish")
        precondition(store.snapshot.count == 0 && store.snapshot.diskByteCount == 0)
    }

    static func staleCleanup(_ root: URL) throws {
        let testRoot = root.appendingPathComponent("sweep", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let now = Date()
        let old = now.addingTimeInterval(-90_000)
        let stale = try makeOrphan(testRoot, modified: old)
        let noMarker = try makeOrphan(testRoot, modified: old, marker: false)
        let fresh = try makeOrphan(testRoot, modified: now)
        let almostOld = try makeOrphan(testRoot, modified: now.addingTimeInterval(-86_399.5))
        let current = try makeOrphan(testRoot, modified: old)
        let active = try SoftwarePacketDiskFIFO(parentDirectory: testRoot, now: now)
        defer { try? active.close() }
        // Init already swept eligible stale siblings, while fresh ones remain.
        precondition(!FileManager.default.fileExists(atPath: stale.path))
        precondition(!FileManager.default.fileExists(atPath: noMarker.path))
        // current was not designated until the explicit sweep below, so recreate it.
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: current.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: active.storageDirectory.path)
        let foreign = testRoot.appendingPathComponent("foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let sentinel = foreign.appendingPathComponent("keep")
        try Data([99]).write(to: sentinel)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: foreign.path)
        let symlink = testRoot.appendingPathComponent("\(SoftwarePacketDiskFIFO.directoryPrefix)\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: foreign)
        let matchingFile = testRoot.appendingPathComponent("\(SoftwarePacketDiskFIFO.directoryPrefix)\(UUID().uuidString)")
        try Data([33]).write(to: matchingFile)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: matchingFile.path)
        let markerSymlink = try makeOrphan(testRoot, modified: old, marker: false)
        try FileManager.default.createSymbolicLink(at: markerSymlink.appendingPathComponent("session.lock"),
                                                 withDestinationURL: sentinel)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: markerSymlink.path)
        let removable = try makeOrphan(testRoot, modified: old)

        let result = SoftwarePacketDiskFIFO.sweepStaleSessionDirs(parentDirectory: testRoot,
            currentSession: current.lastPathComponent, now: now)
        precondition(result.removedCount == 1 && result.inspectedCount <= 64)
        precondition(result.failureCount == 1, "symlink marker should fail closed")
        precondition(!FileManager.default.fileExists(atPath: removable.path))
        for kept in [fresh, almostOld, current, active.storageDirectory, foreign, symlink, matchingFile, markerSymlink] {
            precondition(FileManager.default.fileExists(atPath: kept.path), "sweep removed protected \(kept.lastPathComponent)")
        }
        try check(try Data(contentsOf: sentinel) == Data([99]))
        try active.append(Data([4]))
        try active.reset()
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: active.storageDirectory.path)
        _ = SoftwarePacketDiskFIFO.sweepStaleSessionDirs(parentDirectory: testRoot, now: now)
        precondition(FileManager.default.fileExists(atPath: active.storageDirectory.path),
                     "old live session lost protection after reset")

        let boundedRoot = testRoot.appendingPathComponent("bounded", isDirectory: true)
        try FileManager.default.createDirectory(at: boundedRoot, withIntermediateDirectories: false)
        for _ in 0..<6 { _ = try makeOrphan(boundedRoot, modified: old) }
        let limited = SoftwarePacketDiskFIFO.sweepStaleSessionDirs(parentDirectory: boundedRoot,
            now: now, maxEntries: 2, maxRemovals: 1)
        precondition(limited.inspectedCount <= 2 && limited.removedCount == 1)
        try check(try FileManager.default.contentsOfDirectory(atPath: boundedRoot.path).count == 5)
    }

    static func makeOrphan(_ root: URL, modified: Date, marker: Bool = true) throws -> URL {
        let directory = root.appendingPathComponent("\(SoftwarePacketDiskFIFO.directoryPrefix)\(UUID().uuidString)",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("0.packets"))
        if marker { try Data().write(to: directory.appendingPathComponent("session.lock")) }
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: directory.path)
        return directory
    }

    static func interruptedInitialization(_ root: URL) throws {
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        try expectFailure {
            _ = try SoftwarePacketDiskFIFO(parentDirectory: root, leaseAcquisition: { directory in
                precondition(FileManager.default.fileExists(atPath: directory.path))
                try Data([1]).write(to: directory.appendingPathComponent("session.lock"))
                throw SoftwarePacketDiskFIFO.Failure.sessionLeaseLost
            })
        }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        precondition(before == after, "failed initialization leaked its owned directory")
    }

    static func expectFailure(_ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            return
        }
        preconditionFailure("expected an explicit failure")
    }

    static func check(_ condition: @autoclosure () throws -> Bool,
                      _ message: String = "assertion failed") throws {
        let result = try condition()
        precondition(result, message)
    }
}
