import Foundation

@main struct RebuiltRunSourceAxisStandalone {
    static func main() {
        var axis = RebuiltRunSourceAxis()
        axis.record(index: 0, presentationShift: 600.333333,
                    normalizationShift: 600.208333, isRecut: false)
        check(axis.shift(at: 0), 600.333333, "opening presentation shift")
        check(axis.shift(at: 36), 600.208333, "cached landing must retain source origin")
        let sourceAt169 = 169 + (axis.shift(at: 36) ?? 0)
        precondition(sourceAt169 > 737.42, "169-second display must address original PGS timestamps")
        axis.record(index: 36, presentationShift: 598.0,
                    normalizationShift: 600.208333, isRecut: true)
        check(axis.shift(at: 36), 600.208333, "recut placed at tfdt retains normalization")
        check(axis.measuredWorth(at: 36, composedWorth: 0, rebuilt: true),
              600.208333, "rebuilt placement must not discard normalization")
        check(axis.measuredWorth(at: 36, composedWorth: 0, rebuilt: false),
              0, "placement within existing run must not double source origin")
        check(axis.shift(at: 82), 600.208333, "329-second display retains normalization")
        axis.record(index: 70, presentationShift: 601, normalizationShift: 600.25, isRecut: false)
        check(axis.shift(at: 75), 600.25, "new epoch normalization")
        axis.record(index: 30, presentationShift: 599, normalizationShift: 600, isRecut: false)
        check(axis.shift(at: 75), 600, "backward rewrite removes superseded epochs")
        check(axis.shift(at: 20), 600.208333, "rewrite preserves earlier cached bytes")
        var zero = RebuiltRunSourceAxis()
        precondition(zero.shift(at: 0) == nil, "unknown bytes must not claim a zero source axis")
        zero.record(index: 13, presentationShift: -9, normalizationShift: 0, isRecut: false)
        check(zero.shift(at: 13), -9, "AE481 opening offset preserved")
        check(zero.shift(at: 19), 0, "AE481 ordinary rebuilt run remains zero")
        zero.record(index: 20, presentationShift: -3, normalizationShift: 0, isRecut: true)
        check(zero.shift(at: 20), 0, "zero-origin recut unchanged")
        print("PASS: rebuilt-run source axis (offset PGS, recut, cached seek, rewrite, zero-origin)")
    }
    static func check(_ actual: Double?, _ expected: Double, _ label: String) {
        precondition(abs((actual ?? .nan) - expected) < 0.000001, label)
    }
}
