/// Everything a lexer needs to know about the lines above the one it is on.
///
/// This is the whole of the incremental design: a line's tokens are a pure
/// function of (its incoming `LexState`, its own text) — plus the next line's
/// text for the one language that declares `lookahead`. The session stores the
/// incoming state of every line, re-lexes from the first edited line, and stops
/// as soon as a line past the edit leaves with the state the old text left it
/// with. Everything below that line is provably unchanged.
///
/// So the state must be small and must compare by value. Most lines of most
/// files carry `LexState()` — no allocation at all.
public struct LexState: Hashable, Sendable {
    /// Lexer-defined frames, innermost last: an open block comment and its
    /// depth, an unterminated multi-line string, a template literal's `${`…
    public var stack: [UInt32] = []
    /// Lexer-defined text: a heredoc's terminator word, a fence's info string.
    public var text: [UInt16] = []
    /// The state of an embedded language (a markdown fence's Swift, a
    /// `<script>` body's JavaScript), at most one element.
    public var inner: [LexState] = []

    public init() {}

    var top: UInt32? { stack.last }

    mutating func push(_ frame: UInt32) { stack.append(frame) }

    @discardableResult
    mutating func pop() -> UInt32? { stack.popLast() }

    mutating func replaceTop(_ frame: UInt32) {
        if stack.isEmpty { stack.append(frame) } else { stack[stack.count - 1] = frame }
    }

    var innerState: LexState {
        get { inner.first ?? LexState() }
        set {
            if newValue == LexState() {
                inner.removeAll()
            } else if inner.isEmpty {
                inner.append(newValue)
            } else {
                inner[0] = newValue
            }
        }
    }
}

/// A frame is 8 bits of kind and 24 bits of payload.
@inline(__always) func frame(_ kind: UInt8, _ payload: UInt32 = 0) -> UInt32 {
    UInt32(kind) | (payload << 8)
}
@inline(__always) func frameKind(_ frame: UInt32) -> UInt8 { UInt8(truncatingIfNeeded: frame) }
@inline(__always) func framePayload(_ frame: UInt32) -> UInt32 { frame >> 8 }
