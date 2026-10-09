/// What a lexer sees: the whole document's UTF-16 units, the bounds of the
/// line it is on, and the sink it writes to.
///
/// A lexer is handed a sub-range `[from, to)` of ONE line and must never read
/// outside `[lineStart, lineEnd)` — except `nextLine`, and only when its
/// language declares lookahead. Reading anything else would make the output
/// depend on text the incremental pass does not know to re-lex.
public struct LexContext: ~Copyable {
    let text: UnsafeBufferPointer<UInt16>
    public internal(set) var lineStart: Int = 0
    public internal(set) var lineEnd: Int = 0
    /// How many following lines `forEachFollowingLine` may visit.
    var lookaheadLines = 0
    /// True on the document's first line (front matter, shebangs).
    var isFirstLine = false
    var sink = TokenSink()

    init(text: UnsafeBufferPointer<UInt16>) {
        self.text = text
    }

    @inline(__always) subscript(_ index: Int) -> UInt16 { text[index] }

    /// The content ranges of the lines after this one, at most
    /// `lookaheadLines` of them, stopping BEFORE the first blank line. The
    /// session's restart rule relies on both limits: a line's tokens can only
    /// depend on lines it could reach here. `body` returns false to stop.
    func forEachFollowingLine(_ body: (Range<Int>) -> Bool) {
        guard lookaheadLines > 0 else { return }
        var (_, next) = SyntaxHighlighter.lineBounds(text, from: lineEnd)
        var visited = 0
        while let start = next, visited < lookaheadLines {
            let bounds = SyntaxHighlighter.lineBounds(text, from: start)
            var index = start
            while index < bounds.contentEnd, isSpace(text[index]) { index += 1 }
            if index == bounds.contentEnd { return }
            if !body(start..<bounds.contentEnd) { return }
            visited += 1
            next = bounds.next
        }
    }

    /// Unit at `index`, or 0 outside the current line.
    @inline(__always) func at(_ index: Int) -> UInt16 {
        index >= lineStart && index < lineEnd ? text[index] : 0
    }

    @inline(__always) mutating func emit(_ start: Int, _ end: Int, _ scope: SyntaxScope) {
        sink.emit(start, end, scope)
    }

    /// Does the line contain `word` (ASCII) at `index`?
    func matches(_ word: StaticString, at index: Int, caseInsensitive: Bool = false) -> Bool {
        let count = word.utf8CodeUnitCount
        guard index >= lineStart, index + count <= lineEnd else { return false }
        return word.withUTF8Buffer { bytes in
            for offset in 0..<count {
                var unit = text[index + offset]
                var byte = UInt16(bytes[offset])
                if caseInsensitive {
                    unit = asciiLower(unit)
                    byte = asciiLower(byte)
                }
                if unit != byte { return false }
            }
            return true
        }
    }

    func matches(_ word: [UInt16], at index: Int, caseInsensitive: Bool = false) -> Bool {
        guard index >= lineStart, index + word.count <= lineEnd else { return false }
        for offset in 0..<word.count {
            let unit = text[index + offset]
            if caseInsensitive ? asciiLower(unit) != asciiLower(word[offset]) : unit != word[offset] {
                return false
            }
        }
        return true
    }

    /// First index in `[from, to)` where `word` starts, or nil.
    func find(_ word: StaticString, from: Int, to: Int, caseInsensitive: Bool = false) -> Int? {
        let count = word.utf8CodeUnitCount
        guard count > 0, to - from >= count else { return nil }
        var index = from
        while index + count <= to {
            if matches(word, at: index, caseInsensitive: caseInsensitive) { return index }
            index += 1
        }
        return nil
    }

    func skipSpaces(_ from: Int, _ to: Int) -> Int {
        var index = from
        while index < to, isSpace(text[index]) { index += 1 }
        return index
    }

    func scanIdentifier(_ from: Int, _ to: Int, extra: UInt16 = 0, extra2: UInt16 = 0) -> Int {
        var index = from
        while index < to {
            let unit = text[index]
            if isIdentifierPart(unit) || (extra != 0 && unit == extra) || (extra2 != 0 && unit == extra2) {
                index += 1
            } else {
                break
            }
        }
        return index
    }

    /// The first non-space unit at or after `from` on this line, or 0.
    func nextNonSpace(_ from: Int, _ to: Int) -> UInt16 {
        let index = skipSpaces(from, to)
        return index < to ? text[index] : 0
    }

    func isBlank(_ from: Int, _ to: Int) -> Bool { skipSpaces(from, to) >= to }

    func slice(_ from: Int, _ to: Int) -> [UInt16] { Array(text[from..<to]) }
}

/// Collects runs for one pass. Runs must arrive in order; an overlapping run
/// is clipped to what is left of it, and runs touching with the same scope on
/// the same line are merged. Never across lines, so a line's runs are a
/// function of that line alone — the equality of an incremental pass and a
/// clean one depends on it.
struct TokenSink {
    var runs: [SyntaxRun] = []
    var lineFloor = 0
    var lineCeiling = Int.max

    @inline(__always) mutating func emit(_ start: Int, _ end: Int, _ scope: SyntaxScope) {
        guard scope != .none else { return }
        var start = max(start, lineFloor)
        let end = min(end, lineCeiling)
        if let last = runs.last {
            if start < last.end { start = last.end }
            guard start < end else { return }
            if last.end == start, last.scope == scope, last.location >= lineFloor {
                runs[runs.count - 1].length = end - last.location
                return
            }
        }
        guard start < end else { return }
        runs.append(SyntaxRun(location: start, length: end - start, scope: scope))
    }
}

// MARK: - Character classes (UTF-16 units)

@inline(__always) func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 || u == 0x0C || u == 0x0B }
@inline(__always) func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
@inline(__always) func isHexDigit(_ u: UInt16) -> Bool {
    isDigit(u) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66)
}
@inline(__always) func isUpper(_ u: UInt16) -> Bool { u >= 0x41 && u <= 0x5A }
@inline(__always) func isLower(_ u: UInt16) -> Bool { u >= 0x61 && u <= 0x7A }
@inline(__always) func isAsciiLetter(_ u: UInt16) -> Bool { isUpper(u) || isLower(u) }
@inline(__always) func isAlnum(_ u: UInt16) -> Bool { isAsciiLetter(u) || isDigit(u) }
/// Letters, `_`, and every non-ASCII unit: identifiers in Swift, Rust, Python
/// and friends accept Unicode letters, and a lexer that stopped at `é` would
/// split `café` into two tokens.
@inline(__always) func isIdentifierStart(_ u: UInt16) -> Bool {
    isAsciiLetter(u) || u == 0x5F || (u >= 0x80 && !isUnicodeSpace(u))
}
@inline(__always) func isIdentifierPart(_ u: UInt16) -> Bool { isIdentifierStart(u) || isDigit(u) }
@inline(__always) func isUnicodeSpace(_ u: UInt16) -> Bool {
    u == 0xA0 || u == 0x2028 || u == 0x2029 || u == 0xFEFF || (u >= 0x2000 && u <= 0x200A) || u == 0x3000
}
@inline(__always) func asciiLower(_ u: UInt16) -> UInt16 { isUpper(u) ? u + 32 : u }

enum Ch {
    static let tab: UInt16 = 0x09, lf: UInt16 = 0x0A, cr: UInt16 = 0x0D, space: UInt16 = 0x20
    static let bang: UInt16 = 0x21, dquote: UInt16 = 0x22, hash: UInt16 = 0x23, dollar: UInt16 = 0x24
    static let percent: UInt16 = 0x25, amp: UInt16 = 0x26, squote: UInt16 = 0x27
    static let lparen: UInt16 = 0x28, rparen: UInt16 = 0x29, star: UInt16 = 0x2A, plus: UInt16 = 0x2B
    static let comma: UInt16 = 0x2C, minus: UInt16 = 0x2D, dot: UInt16 = 0x2E, slash: UInt16 = 0x2F
    static let colon: UInt16 = 0x3A, semicolon: UInt16 = 0x3B, lt: UInt16 = 0x3C, eq: UInt16 = 0x3D
    static let gt: UInt16 = 0x3E, question: UInt16 = 0x3F, at: UInt16 = 0x40
    static let lbracket: UInt16 = 0x5B, backslash: UInt16 = 0x5C, rbracket: UInt16 = 0x5D
    static let caret: UInt16 = 0x5E, underscore: UInt16 = 0x5F, backtick: UInt16 = 0x60
    static let lbrace: UInt16 = 0x7B, pipe: UInt16 = 0x7C, rbrace: UInt16 = 0x7D, tilde: UInt16 = 0x7E
}

@inline(__always) func u(_ c: Unicode.Scalar) -> UInt16 { UInt16(c.value) }
