import Foundation

// WebVTTCueSettings also references this UI-facing value type. The focused store
// test never invokes placement; avoid importing the full player/runtime graph.
struct SubtitleTextPlacement {
    let alignment: Int
    let position: CGPoint?
}

@main
struct SubtitlePacketDiagnosticsTests {
    static func main() {
        let store = SubtitlePacketStore(perStreamByteCap: 4, aggregateByteCap: 8)
        func snapshot() -> String {
            store.diagnosticWindow(streamIndex: 3, from: 100, through: 200)
        }
        precondition(snapshot().contains("stored=0 windowPackets=0 firstPTS=none"))
        store.append(streamIndex: 3, ptsSeconds: 737, durationSeconds: 1, payload: Data([1,2,3]))
        precondition(snapshot().contains("stored=1 windowPackets=0 firstPTS=737.00"))
        // Distinguish a missing window caused by immediate backward-refill eviction
        // from a reader that has never supplied the current window at all.
        store.append(streamIndex: 3, ptsSeconds: 174, durationSeconds: 1, payload: Data([4,5]))
        precondition(snapshot().contains("bytes=3 cap=4 capEvictions=1"))
        store.clear()
        store.append(streamIndex: 3, ptsSeconds: 174, durationSeconds: 1, payload: Data([4,5]))
        precondition(snapshot().contains("stored=1 windowPackets=1 firstPTS=174.00"))
        precondition(snapshot().contains("capEvictions=0 pendingBytes=0"))
        precondition(!snapshot().contains("payload"))
        print("PASS: subtitle packet window diagnostics (empty, future-only, eviction, recovery, clear)")
    }
}
