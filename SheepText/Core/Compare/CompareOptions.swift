import Foundation

/// `Equatable` is load-bearing, not decoration: `CompareEngine` memoises each
/// side's hashed lines and its row array, and both keys include the options. The
/// row memo used to be keyed on the two texts alone, which is only safe while
/// `computeRows` hard-codes the options — the moment they become user-settable
/// the cache would serve the answer for the previous setting.
nonisolated struct CompareOptions: Sendable, Equatable {
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
