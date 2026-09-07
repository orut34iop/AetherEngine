import Testing
@testable import AetherEngine

@Suite("Matroska H264 coding-order timestamps")
struct H264MatroskaTimestampRepairTests {
    typealias Policy = H264MatroskaTimestampRepair
    let times: [Int64] = [0, 40, 73, 107, 140, 173, 207, 240, 274, 307, 340, 374]
    let pocs: [Int64] = [0, 8, 2, 4, 6, 14, 10, 12, 20, 16, 18, 22]
    var pictures: [Policy.Picture] { zip(times, pocs).map { .init(pts: $0, poc: $1) } }

    @Test func repairsOnlyTimeOwnership() throws {
        let result = try #require(Policy.repair(pictures, nextPTS: 407, videoDelay: 1))
        #expect(result.pts == pocs.map { times[Int($0 / 2)] })
        #expect(result.pts.sorted() == times)
        #expect(result.decodeLead == 34)
        for (index, pts) in result.pts.enumerated() { #expect(pts >= times[index] - result.decodeLead) }
        let seek = pictures.map { Policy.Picture(pts: $0.pts + 698712, poc: $0.poc) }
        #expect(Policy.repair(seek, nextPTS: 699119, videoDelay: 1)?.pts == result.pts.map { $0 + 698712 })
    }

    @Test func healthyAndUnprovenStayUntouched() {
        let healthy = pocs.map { Policy.Picture(pts: times[Int($0 / 2)], poc: $0) }
        #expect(Policy.repair(healthy, nextPTS: 407, videoDelay: 1) == nil)
        #expect(Policy.repair(Array(pictures.prefix(8)), nextPTS: 274, videoDelay: 1) == nil)
        var collision = pictures
        collision[4] = .init(pts: 140, poc: 4)
        #expect(Policy.repair(collision, nextPTS: 407, videoDelay: 1) == nil)
        let variable = pictures.enumerated().map { Policy.Picture(pts: $0.element.pts + ($0.offset > 5 ? 500 : 0), poc: $0.element.poc) }
        #expect(Policy.repair(variable, nextPTS: 907, videoDelay: 1) == nil)
    }

    @Test func confirmedAxisHandlesShortTailWithoutChangingDecodeLead() throws {
        let tail: [Policy.Picture] = [.init(pts: 1000, poc: 0), .init(pts: 1033, poc: 4), .init(pts: 1067, poc: 2)]
        let result = try #require(Policy.repair(tail, nextPTS: 1100, videoDelay: 1, confirmedDecodeLead: 34))
        #expect(result.pts == [1000, 1067, 1033])
        #expect(result.decodeLead == 34)
        #expect(Policy.repair(tail, nextPTS: 1100, videoDelay: 1, confirmedDecodeLead: 33) == nil)
    }
}
