import Foundation

nonisolated struct CompareOptions: Sendable {
    /// Lower-cases each line before hashing (`LineHashing.normalize`).
    var ignoreCase: Bool = false

    /// Collapses runs of whitespace to one space and trims the ends before
    /// hashing (`LineHashing.normalize`).
    var ignoreChangedSpaces: Bool = false

    /// Percentage of shared characters at which an adjacent delete/insert pair
    /// is reported as one `.changed` block instead of separate add and remove
    /// blocks. Read by `TextComparator.appendChangedOrSplit`.
    var changedResemblPercent: Int = 50
}
