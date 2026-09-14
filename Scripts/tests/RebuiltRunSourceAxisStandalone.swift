import Foundation

@main struct RebuiltRunSourceAxisStandalone {
    static func main() {
        var table = EpochAxisTable()
        precondition(table.sourceAxis(at: 0) == nil)
        table.record(EpochAxis(presented: 600.333333, carried: 600.208333, isRecut: false), at: 0)
        check(table.sourceAxis(at: 0), 600.333333, "opening presentation")
        check(table.sourceAxis(at: 36), 600.208333, "2:49 cached landing keeps source origin")
        let recut = EpochAxis(presented: 598, carried: 600.208333, isRecut: true)
        table.record(recut, at: 36)
        check(recut.placedOffset, 0, "recut adds no AVPlayer displacement")
        check(table.sourceAxis(at: 36), 600.208333, "recut keeps normalization")
        check(table.sourceAxis(at: 82), 600.208333, "5:29 keeps normalization")
        table.record(EpochAxis(presented: 601, carried: 600.25, isRecut: false), at: 70)
        let captured = table.opening(at: 70)!
        table.record(EpochAxis(presented: 599, carried: 600, isRecut: false), at: 30)
        check(table.sourceAxis(at: 75), 600, "backward rewrite replaces later epochs")
        check(table.sourceAxis(at: 20), 600.208333, "earlier cached bytes retained")
        check(captured.carried, 600.25, "captured placement retains its original normalization")
        let offset = EpochAxis(presented: 591, carried: 600, isRecut: false)
        let zero = EpochAxis(presented: -9, carried: 0, isRecut: false)
        check(offset.placedOffset, -9, "placement excludes source origin")
        check(offset.placedOffset, zero.placedOffset, "zero and offset origins have equal displacement")
        var zeroTable = EpochAxisTable()
        zeroTable.record(zero, at: 13)
        check(zeroTable.sourceAxis(at: 13), -9, "zero-origin opening unchanged")
        check(zeroTable.sourceAxis(at: 19), 0, "zero-origin continuation unchanged")
        print("PASS: active EpochAxisTable (offset PGS, recut, cached seek, rewrite, captured epoch, zero-origin)")
    }
    static func check(_ actual: Double?, _ expected: Double, _ label: String) {
        precondition(abs((actual ?? .nan) - expected) < 0.000001, label)
    }
}
