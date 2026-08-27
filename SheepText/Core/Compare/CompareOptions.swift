import Foundation

nonisolated struct CompareOptions: Sendable {
    var ignoreCase: Bool = false
    var ignoreChangedSpaces: Bool = false
    var shiftBoundaries: Bool = true
    var detectCharDiffs: Bool = true
    var changedResemblPercent: Int = 50
}
