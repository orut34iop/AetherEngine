import Foundation

@main
struct PR510NativeSegmentEvidenceTests {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pr510-init-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(PR510NativeSegmentEvidence.filename)
        let original = Data([0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70, 0, 1, 2, 3, 4, 5, 6, 7])
        precondition(PR510NativeSegmentEvidence.writeInit(original,
            sessionDirectory: root, sessionClosed: false) == "stored")
        let stored = try Data(contentsOf: file)
        precondition(stored == original, "evidence must preserve exact init bytes")

        let oversized = Data(repeating: 7, count: PR510NativeSegmentEvidence.maximumInitBytes + 1)
        for rejected in [Data(), oversized] {
            precondition(PR510NativeSegmentEvidence.writeInit(rejected,
                sessionDirectory: root, sessionClosed: false) == "size_rejected")
            let unchanged = try Data(contentsOf: file)
            precondition(unchanged == original, "rejected input must preserve existing evidence")
        }
        precondition(PR510NativeSegmentEvidence.writeInit(Data([9]),
            sessionDirectory: root, sessionClosed: true) == "closed")
        let afterClose = try Data(contentsOf: file)
        precondition(afterClose == original)

        let absent = root.appendingPathComponent("absent", isDirectory: true)
        precondition(PR510NativeSegmentEvidence.writeInit(original,
            sessionDirectory: absent, sessionClosed: false) == "write_failed")
        precondition(!FileManager.default.fileExists(atPath: absent.path),
            "capture must not resurrect a removed cache directory")
        print("PASS PR510 init evidence: exact bytes, bounded input, closed session, missing directory")
    }
}
