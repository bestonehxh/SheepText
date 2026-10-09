/// Keyword lookup without building a `String` per identifier.
///
/// Every keyword any language here has is ASCII and at most 24 characters, so
/// a word packs losslessly into three `UInt64`s plus its length. An identifier
/// that is longer or contains a non-ASCII unit cannot be in any table and is
/// rejected before hashing.
struct WordTable: Sendable {
    private struct Key: Hashable, Sendable {
        var a: UInt64 = 0
        var b: UInt64 = 0
        var c: UInt64 = 0
        var length: UInt8 = 0
    }

    private var map: [Key: SyntaxScope] = [:]
    let caseInsensitive: Bool

    init(caseInsensitive: Bool = false) {
        self.caseInsensitive = caseInsensitive
    }

    init(_ groups: [(SyntaxScope, [String])], caseInsensitive: Bool = false) {
        self.caseInsensitive = caseInsensitive
        for (scope, words) in groups { add(words, as: scope) }
    }

    mutating func add(_ words: [String], as scope: SyntaxScope) {
        for word in words {
            let units = Array(word.utf16)
            guard let key = Self.key(units.count, fold: caseInsensitive, { units[$0] }) else {
                preconditionFailure("keyword \(word) cannot be packed")
            }
            map[key] = scope
        }
    }

    func contains(_ word: String) -> Bool {
        let units = Array(word.utf16)
        guard let key = Self.key(units.count, fold: caseInsensitive, { units[$0] }) else { return false }
        return map[key] != nil
    }

    @inline(__always)
    func lookup(_ text: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> SyntaxScope? {
        guard end > start, end - start <= 24 else { return nil }
        guard let key = Self.key(end - start, fold: caseInsensitive, { text[start + $0] }) else { return nil }
        return map[key]
    }

    @inline(__always)
    private static func key(_ count: Int, fold: Bool = false, _ unit: (Int) -> UInt16) -> Key? {
        guard count <= 24 else { return nil }
        var key = Key()
        key.length = UInt8(count)
        for index in 0..<count {
            var value = unit(index)
            guard value < 0x80 else { return nil }
            if fold { value = asciiLower(value) }
            let shift = UInt64((index % 8) * 8)
            switch index / 8 {
            case 0: key.a |= UInt64(value) << shift
            case 1: key.b |= UInt64(value) << shift
            default: key.c |= UInt64(value) << shift
            }
        }
        return key
    }
}

