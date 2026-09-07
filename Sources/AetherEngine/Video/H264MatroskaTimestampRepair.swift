import Foundation

/// Numeric-only policy for a complete, IDR-bounded H.264 frame-coded sequence.
/// Matroska stores packets in coding order but must timestamp them in display order.
enum H264MatroskaTimestampRepair {
    struct Picture: Equatable {
        let pts: Int64
        let poc: Int64
    }
    struct Result: Equatable {
        let pts: [Int64]
        let decodeLead: Int64
    }

    static func repair(
        _ pictures: [Picture], nextPTS: Int64, videoDelay: Int,
        confirmedDecodeLead: Int64? = nil
    ) -> Result? {
        let minimum = confirmedDecodeLead == nil ? 9 : 2
        guard (1...16).contains(videoDelay), (minimum...512).contains(pictures.count),
              pictures.first?.poc == 0, nextPTS != Int64.min else { return nil }
        let times = pictures.map(\.pts)
        guard times.allSatisfy({ $0 != Int64.min }) else { return nil }
        var intervals: [Int64] = []
        for (a, b) in zip(times, times.dropFirst() + [nextPTS]) {
            let (step, overflow) = b.subtractingReportingOverflow(a)
            guard !overflow, step > 0 else { return nil }
            intervals.append(step)
        }
        // Do not use a container's advertised average FPS to retime a VFR stream. Require a
        // quantized near-CFR ladder, allowing only the distinct first-picture hold seen at an IDR.
        guard let shortest = intervals.dropFirst().min(),
              let longest = intervals.dropFirst().max(), shortest >= 2,
              longest - shortest <= 1, let first = intervals.first,
              first >= shortest / 2, first / 2 <= longest else { return nil }
        var ranks = Set<Int>()
        var reordered = false
        for (index, picture) in pictures.enumerated() {
            // Whole progressive frames have consecutive even POC. Fields, gaps, open-GOP
            // leading pictures, parser misses and duplicate POC must not be guessed at.
            guard picture.poc >= 0, picture.poc % 2 == 0,
                  picture.poc / 2 < Int64(pictures.count) else { return nil }
            let rank = Int(picture.poc / 2)
            guard ranks.insert(rank).inserted else { return nil }
            reordered = reordered || rank != index
        }
        guard reordered || confirmedDecodeLead != nil else { return nil }
        let (measuredLead, overflow) = longest.multipliedReportingOverflow(by: Int64(videoDelay))
        let lead = confirmedDecodeLead ?? measuredLead
        guard !overflow, lead > 0 else { return nil }
        var corrected: [Int64] = []
        for (index, picture) in pictures.enumerated() {
            let pts = times[Int(picture.poc / 2)]
            let (dts, underflow) = times[index].subtractingReportingOverflow(lead)
            guard !underflow, pts >= dts else { return nil }
            corrected.append(pts)
        }
        return Result(pts: corrected, decodeLead: lead)
    }
}
