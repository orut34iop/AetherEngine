import Foundation

@main
struct H264MatroskaTimestampTests {
    typealias Policy = H264MatroskaTimestampRepair

    static func main() throws {
        // Numeric-only shape from the reported source: compressed order I P B B B P B B.
        // The first 40 ms interval is real input evidence, not a guessed constant FPS.
        let times: [Int64] = [0, 40, 73, 107, 140, 173, 207, 240, 274, 307, 340, 374]
        let pocs: [Int64] = [0, 8, 2, 4, 6, 14, 10, 12, 20, 16, 18, 22]
        let source = zip(times, pocs).map { Policy.Picture(pts: $0, poc: $1) }
        guard let repaired = Policy.repair(source, nextPTS: 407, videoDelay: 1) else {
            fatalError("reported MKV's complete coding-order timestamp ladder must be repaired")
        }
        precondition(repaired.pts == pocs.map { times[Int($0 / 2)] })
        precondition(repaired.pts.sorted() == times, "never invent or drop a presentation time")
        precondition(repaired.decodeLead == 34)
        for (index, pts) in repaired.pts.enumerated() {
            precondition(pts >= times[index] - repaired.decodeLead)
        }
        let seek = source.map { Policy.Picture(pts: $0.pts + 698712, poc: $0.poc) }
        precondition(Policy.repair(seek, nextPTS: 699119, videoDelay: 1)?.pts
            == repaired.pts.map { $0 + 698712 }, "seek cannot zero-base the picture axis")
        let healthy = zip(repaired.pts, pocs).map { Policy.Picture(pts: $0, poc: $1) }
        precondition(Policy.repair(healthy, nextPTS: 407, videoDelay: 1) == nil)
        let noReorder = times.enumerated().map { Policy.Picture(pts: $0.element, poc: Int64($0.offset * 2)) }
        precondition(Policy.repair(noReorder, nextPTS: 407, videoDelay: 1) == nil)
        var invalid = source
        invalid[4] = .init(pts: 140, poc: 4)
        precondition(Policy.repair(invalid, nextPTS: 407, videoDelay: 1) == nil)
        invalid = source
        invalid[4] = .init(pts: 140, poc: 7)
        precondition(Policy.repair(invalid, nextPTS: 407, videoDelay: 1) == nil)
        precondition(Policy.repair(Array(source.prefix(8)), nextPTS: 274, videoDelay: 1) == nil)
        precondition(Policy.repair(source, nextPTS: 407, videoDelay: 0) == nil)
        precondition(Policy.repair(source, nextPTS: 300, videoDelay: 1) == nil)
        let missing = source.map { Policy.Picture(pts: Int64.min, poc: $0.poc) }
        precondition(Policy.repair(missing, nextPTS: 407, videoDelay: 1) == nil)
        let overflow = source.map { Policy.Picture(pts: $0.pts, poc: Int64.max) }
        precondition(Policy.repair(overflow, nextPTS: 407, videoDelay: 1) == nil)
        let vfr = source.enumerated().map { Policy.Picture(pts: $0.element.pts + ($0.offset > 5 ? 500 : 0), poc: $0.element.poc) }
        precondition(Policy.repair(vfr, nextPTS: 907, videoDelay: 1) == nil)
        let tail: [Policy.Picture] = [.init(pts: 1000, poc: 0), .init(pts: 1033, poc: 4), .init(pts: 1067, poc: 2)]
        precondition(Policy.repair(tail, nextPTS: 1100, videoDelay: 1, confirmedDecodeLead: 34)?.pts == [1000, 1067, 1033])
        precondition(Policy.repair(tail, nextPTS: 1100, videoDelay: 1, confirmedDecodeLead: 33) == nil)
        print("PASS: MKV presentation-time permutation, first-frame hold, seek translation, mux invariant; healthy, no-B, truncated, duplicate/field POC, VFR, missing timestamps and overflow fail closed")
        struct Fixture: Decodable {
            struct Packet: Decodable { let pts: Int64; let poc: Int64 }
            let video_delay: Int
            let packets: [Packet]
        }
        for path in CommandLine.arguments.dropFirst() {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let packets = fixture.packets
            let origins = packets.indices.filter { packets[$0].poc == 0 }
            var count = 0
            for (start, end) in zip(origins, origins.dropFirst()) {
                let group = packets[start..<end].map { Policy.Picture(pts: $0.pts, poc: $0.poc) }
                guard let result = Policy.repair(group, nextPTS: packets[end].pts, videoDelay: fixture.video_delay) else {
                    fatalError("measured complete GOP failed timestamp repair at numeric packet index \(start)")
                }
                precondition(result.pts.sorted() == group.map(\.pts))
                print("measured_gop=\(count) pictures=\(group.count) anchor=\(group[0].pts) lead=\(result.decodeLead) preserved_times=true")
                count += 1
            }
            precondition(count > 0)
        }
    }
}
