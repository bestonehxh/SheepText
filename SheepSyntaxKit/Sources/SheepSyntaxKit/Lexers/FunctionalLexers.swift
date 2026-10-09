// Elixir and Haskell.

// MARK: - Elixir

/// Elixir: strings, charlists, heredocs and sigils all interpolate and may
/// span lines; atoms and keyword-list keys are symbols; `@attr` is an
/// attribute; `Module.Name` is a type.
enum ElixirLexer {
    private static let fString: UInt8 = 1   // payload: close | open << 8 | flags << 16 | depth << 20
    private static let fCode: UInt8 = 2     // `#{` — payload: brace depth
    private static let fHeredoc: UInt8 = 3  // payload: quote | flags << 16

    private static let interpolates: UInt32 = 1
    private static let asRegex: UInt32 = 2
    private static let asCharlist: UInt32 = 4

    private static let words = WordTable([
        (.keyword, [
            "after", "alias", "and", "case", "catch", "cond", "def", "defcallback", "defdelegate",
            "defexception", "defguard", "defguardp", "defimpl", "defmacro", "defmacrop", "defmodule",
            "defoverridable", "defp", "defprotocol", "defstruct", "do", "else", "end", "fn", "for", "if",
            "import", "in", "not", "or", "quote", "raise", "receive", "require", "rescue", "reraise", "super",
            "throw", "try", "unless", "unquote", "unquote_splicing", "use", "when", "with",
        ]),
        (.boolean, ["true", "false"]),
        (.constantBuiltin, ["nil"]),
        (.variableBuiltin, ["__MODULE__", "__DIR__", "__ENV__", "__CALLER__", "__STACKTRACE__"]),
    ])
    private static let definers = WordTable([(.keyword, [
        "def", "defp", "defmacro", "defmacrop", "defguard", "defguardp", "defdelegate",
    ])])

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        var prev = CFamilyLexer.Prev.start
        while pos < to {
            guard let top = state.top else {
                pos = code(&ctx, pos, to, &state, &prev)
                continue
            }
            switch frameKind(top) {
            case fString: pos = string(&ctx, pos, to, &state)
            case fHeredoc: pos = heredoc(&ctx, pos, to, &state)
            default: pos = code(&ctx, pos, to, &state, &prev)
            }
        }
    }

    private static func code(
        _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState, _ prev: inout CFamilyLexer.Prev
    ) -> Int {
        var pos = from
        while pos < to {
            let c = ctx[pos]
            let next = pos + 1 < to ? ctx[pos + 1] : 0
            if isSpace(c) { pos += 1; continue }
            if c == Ch.hash {
                ctx.emit(pos, to, .comment)
                return to
            }
            if c == Ch.dquote || c == Ch.squote {
                let flags = interpolates | (c == Ch.squote ? asCharlist : 0)
                if pos + 2 < to, ctx[pos + 1] == c, ctx[pos + 2] == c {
                    ctx.emit(pos, pos + 3, .string)
                    guard state.stack.count < 64 else { return to }
                    state.push(frame(fHeredoc, UInt32(c) | (flags << 16)))
                    return pos + 3
                }
                return open(&ctx, pos, pos + 1, to, &state, close: c, open: 0, flags: flags)
            }
            // Sigils: ~r/…/, ~s(…), ~w[…]a, ~S"""…""".
            if c == Ch.tilde, isAsciiLetter(next) {
                var index = pos + 1
                while index < to, isAsciiLetter(ctx[index]) { index += 1 }
                guard index < to else { pos = index; continue }
                let delimiter = ctx[index]
                var flags: UInt32 = isLower(next) ? interpolates : 0
                if next == u("r") || next == u("R") { flags |= asRegex }
                if (delimiter == Ch.dquote || delimiter == Ch.squote), index + 2 < to,
                   ctx[index + 1] == delimiter, ctx[index + 2] == delimiter {
                    ctx.emit(pos, index + 3, .string)
                    guard state.stack.count < 64 else { return to }
                    state.push(frame(fHeredoc, UInt32(delimiter) | (flags << 16)))
                    return index + 3
                }
                let close: UInt16
                switch delimiter {
                case Ch.lparen: close = Ch.rparen
                case Ch.lbracket: close = Ch.rbracket
                case Ch.lbrace: close = Ch.rbrace
                case Ch.lt: close = Ch.gt
                case Ch.slash, Ch.pipe, Ch.dquote, Ch.squote: close = delimiter
                default: pos = index; continue
                }
                return open(&ctx, pos, index + 1, to, &state, close: close,
                            open: close == delimiter ? 0 : delimiter, flags: flags)
            }
            // Atoms: :name, :"quoted", :+.
            if c == Ch.colon, next != Ch.colon, !(pos > ctx.lineStart && ctx[pos - 1] == Ch.colon) {
                if isIdentifierStart(next) {
                    var end = ctx.scanIdentifier(pos + 1, to)
                    if end < to, ctx[end] == Ch.question || ctx[end] == Ch.bang { end += 1 }
                    ctx.emit(pos, end, .stringSymbol)
                    pos = end
                    prev = .value
                    continue
                }
                if next == Ch.dquote {
                    ctx.emit(pos, pos + 1, .stringSymbol)
                    return open(&ctx, pos + 1, pos + 2, to, &state, close: Ch.dquote, open: 0, flags: interpolates)
                }
            }
            // Character literal `?a`.
            if c == Ch.question, pos + 1 < to, !isSpace(next), prev != .value {
                let end = next == Ch.backslash ? min(to, pos + 3) : pos + 2
                ctx.emit(pos, end, .character)
                pos = end
                prev = .value
                continue
            }
            if c == Ch.at, isIdentifierStart(next) {
                let end = ctx.scanIdentifier(pos + 1, to)
                ctx.emit(pos, end, .attribute)
                pos = end
                prev = .op
                continue
            }
            if c == Ch.amp, isDigit(next) {
                var end = pos + 1
                while end < to, isDigit(ctx[end]) { end += 1 }
                ctx.emit(pos, end, .variableBuiltin)
                pos = end
                prev = .value
                continue
            }
            if isDigit(c) {
                let end = CFamilyLexer.scanNumber(&ctx, pos, to)
                ctx.emit(pos, end, .number)
                pos = end
                prev = .value
                continue
            }
            if isIdentifierStart(c) {
                var end = ctx.scanIdentifier(pos, to)
                if end < to, ctx[end] == Ch.question || ctx[end] == Ch.bang { end += 1 }
                // Keyword-list key: `name: value`.
                if end + 1 <= to, end < to, ctx[end] == Ch.colon, end + 1 >= to || isSpace(ctx[end + 1]) {
                    ctx.emit(pos, end + 1, .stringSymbol)
                    pos = end + 1
                    prev = .op
                    continue
                }
                let following = ctx.nextNonSpace(end, to)
                let scope: SyntaxScope
                if isUpper(c) {
                    scope = .type
                } else if prev == .dot {
                    scope = .function
                } else if prev == .defFunction {
                    scope = .function
                } else if let word = words.lookup(ctx.text, pos, end) {
                    scope = word
                    if definers.lookup(ctx.text, pos, end) != nil {
                        ctx.emit(pos, end, scope)
                        pos = end
                        prev = .defFunction
                        continue
                    }
                } else if following == Ch.lparen || (end < to && ctx[end] == Ch.dot && end + 1 < to && ctx[end + 1] == Ch.lparen) {
                    scope = .function
                } else if ctx[pos] == Ch.underscore {
                    scope = .comment
                } else {
                    scope = .none
                }
                ctx.emit(pos, end, scope)
                pos = end
                prev = scope == .keyword ? .keyword : .value
                continue
            }
            if c == Ch.lbrace {
                if let top = state.top, frameKind(top) == fCode {
                    state.replaceTop(frame(fCode, framePayload(top) + 1))
                }
                pos += 1
                prev = .op
                continue
            }
            if c == Ch.rbrace {
                if let top = state.top, frameKind(top) == fCode {
                    let depth = framePayload(top)
                    if depth == 0 {
                        state.pop()
                        ctx.emit(pos, pos + 1, .punctuationSpecial)
                        return pos + 1
                    }
                    state.replaceTop(frame(fCode, depth - 1))
                }
                pos += 1
                prev = .value
                continue
            }
            prev = c == Ch.dot ? .dot : ((c == Ch.rparen || c == Ch.rbracket) ? .value : .op)
            pos += 1
        }
        return pos
    }

    private static func scope(_ flags: UInt32) -> SyntaxScope {
        flags & asRegex != 0 ? .stringRegex : .string
    }

    private static func open(
        _ ctx: inout LexContext, _ start: Int, _ bodyStart: Int, _ to: Int, _ state: inout LexState,
        close: UInt16, open: UInt16, flags: UInt32
    ) -> Int {
        ctx.emit(start, bodyStart, scope(flags))
        guard state.stack.count < 64 else { return to }
        state.push(frame(fString, UInt32(close) | (UInt32(open) << 8) | (flags << 16)))
        return bodyStart
    }

    /// Shared body scan: escapes and `#{`. Returns (position, closedAt?).
    private static func body(
        _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState, flags: UInt32, base: SyntaxScope,
        isClose: (inout LexContext, Int) -> Int?
    ) -> (Int, Bool) {
        var index = from
        var segment = from
        while index < to {
            if let end = isClose(&ctx, index) {
                var close = end
                if flags & asRegex != 0 { while close < to, isAsciiLetter(ctx[close]) { close += 1 } }
                ctx.emit(segment, close, base)
                return (close, true)
            }
            let c = ctx[index]
            if c == Ch.backslash, index + 1 < to {
                if flags & interpolates != 0 && flags & asRegex == 0 {
                    ctx.emit(segment, index, base)
                    let end = CFamilyLexer.escapeEnd(&ctx, index + 1, to)
                    ctx.emit(index, end, .stringEscape)
                    index = end
                    segment = end
                } else {
                    index += 2
                }
                continue
            }
            if flags & interpolates != 0, c == Ch.hash, index + 1 < to, ctx[index + 1] == Ch.lbrace {
                ctx.emit(segment, index, base)
                ctx.emit(index, index + 2, .punctuationSpecial)
                if state.stack.count < 64 {
                    state.push(frame(fCode, 0))
                    return (index + 2, false)
                }
            }
            index += 1
        }
        ctx.emit(segment, to, base)
        return (to, false)
    }

    private static func string(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        let payload = framePayload(state.top ?? 0)
        let close = UInt16(payload & 0xFF)
        let open = UInt16((payload >> 8) & 0xFF)
        let flags = (payload >> 16) & 0x0F
        var depth = (payload >> 20) & 0x0F
        let depthBefore = depth
        let stackCount = state.stack.count
        let (end, closed) = body(&ctx, from, to, &state, flags: flags, base: scope(flags)) { ctx, index in
            let c = ctx[index]
            if open != 0, c == open { depth = min(depth + 1, 15); return nil }
            if c == close {
                if depth == 0 { return index + 1 }
                depth -= 1
            }
            return nil
        }
        if closed {
            state.pop()
        } else if depth != depthBefore {
            let index = state.stack.count > stackCount ? stackCount - 1 : state.stack.count - 1
            state.stack[index] = frame(fString, (payload & ~(0x0F << 20)) | (depth << 20))
        }
        return end
    }

    private static func heredoc(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        let payload = framePayload(state.top ?? 0)
        let quote = UInt16(payload & 0xFF)
        let flags = (payload >> 16) & 0x0F
        let (end, closed) = body(&ctx, from, to, &state, flags: flags, base: scope(flags)) { ctx, index in
            let limit = ctx.lineEnd
            if ctx[index] == quote, index + 2 < limit, ctx[index + 1] == quote, ctx[index + 2] == quote {
                return index + 3
            }
            return nil
        }
        if closed { state.pop() }
        return end
    }
}

// MARK: - Haskell

/// Haskell: `--` and nested `{- -}` comments, `{-# pragmas #-}`, types and
/// constructors by capital letter, and a definition at column 0 is a function.
enum HaskellLexer {
    private static let fComment: UInt8 = 1   // payload: depth | pragma << 16

    private static let words = WordTable([
        (.keyword, [
            "as", "case", "class", "data", "default", "deriving", "do", "else", "family", "forall", "foreign",
            "hiding", "if", "import", "in", "infix", "infixl", "infixr", "instance", "let", "mdo", "module",
            "newtype", "of", "pattern", "proc", "qualified", "rec", "then", "type", "where",
        ]),
        (.boolean, ["True", "False"]),
    ])

    private static func isSymbol(_ c: UInt16) -> Bool {
        switch c {
        case Ch.bang, Ch.hash, Ch.dollar, Ch.percent, Ch.amp, Ch.star, Ch.plus, Ch.dot, Ch.slash, Ch.lt, Ch.eq,
             Ch.gt, Ch.question, Ch.at, Ch.backslash, Ch.caret, Ch.pipe, Ch.minus, Ch.tilde, Ch.colon:
            return true
        default:
            return false
        }
    }

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        if let top = state.top, frameKind(top) == fComment {
            pos = comment(&ctx, pos, to, &state)
        }
        var prevIdentifier = false
        while pos < to {
            let c = ctx[pos]
            let next = pos + 1 < to ? ctx[pos + 1] : 0
            if isSpace(c) { pos += 1; prevIdentifier = false; continue }

            if c == Ch.minus, next == Ch.minus {
                var end = pos
                while end < to, ctx[end] == Ch.minus { end += 1 }
                if end >= to || !isSymbol(ctx[end]) {
                    ctx.emit(pos, to, .comment)
                    return
                }
            }
            if c == Ch.lbrace, next == Ch.minus {
                let pragma = pos + 2 < to && ctx[pos + 2] == Ch.hash
                state.push(frame(fComment, 1 | (pragma ? 1 << 16 : 0)))
                ctx.emit(pos, pos + 2, pragma ? .keywordDirective : .comment)
                pos = comment(&ctx, pos + 2, to, &state)
                continue
            }
            if c == Ch.dquote {
                var end = pos + 1
                while end < to, ctx[end] != Ch.dquote {
                    if ctx[end] == Ch.backslash { end += 1 }
                    end += 1
                }
                end = min(to, end + 1)
                CFamilyLexer.emitEscapes(&ctx, pos, end, .string)
                pos = end
                prevIdentifier = false
                continue
            }
            if c == Ch.squote, !prevIdentifier {
                var end = pos + 1
                if end < to, ctx[end] == Ch.backslash { end += 2 } else { end += 1 }
                while end < to, ctx[end] != Ch.squote, end - pos < 12 { end += 1 }
                if end < to, ctx[end] == Ch.squote {
                    ctx.emit(pos, end + 1, .character)
                    pos = end + 1
                    continue
                }
            }
            if isDigit(c) {
                let end = CFamilyLexer.scanNumber(&ctx, pos, to)
                ctx.emit(pos, end, .number)
                pos = end
                prevIdentifier = false
                continue
            }
            if isIdentifierStart(c) {
                var end = pos
                while end < to, isIdentifierPart(ctx[end]) || ctx[end] == Ch.squote { end += 1 }
                // Qualified names: Data.Map.lookup — the module parts are types.
                if isUpper(c), end + 1 < to, ctx[end] == Ch.dot, isIdentifierStart(ctx[end + 1]) {
                    ctx.emit(pos, end, .type)
                    pos = end + 1
                    continue
                }
                let scope: SyntaxScope
                if let word = words.lookup(ctx.text, pos, end) {
                    scope = word
                } else if isUpper(c) {
                    scope = .type
                } else if pos == ctx.lineStart {
                    scope = .function
                } else if ctx.nextNonSpace(end, to) == Ch.colon, ctx.skipSpaces(end, to) + 1 < to,
                          ctx[ctx.skipSpaces(end, to) + 1] == Ch.colon {
                    scope = .function
                } else {
                    scope = .none
                }
                ctx.emit(pos, end, scope)
                pos = end
                prevIdentifier = true
                continue
            }
            if c == Ch.backtick {
                var end = pos + 1
                while end < to, ctx[end] != Ch.backtick { end += 1 }
                end = min(to, end + 1)
                ctx.emit(pos, end, .function)
                pos = end
                continue
            }
            prevIdentifier = c == Ch.rparen || c == Ch.rbracket
            pos += 1
        }
    }

    private static func comment(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        let payload = framePayload(state.top ?? 0)
        var depth = payload & 0xFFFF
        let pragma = payload >> 16 != 0
        let scope: SyntaxScope = pragma ? .keywordDirective : .comment
        var index = from
        while index < to {
            if ctx[index] == Ch.minus, index + 1 < to, ctx[index + 1] == Ch.rbrace {
                depth -= 1
                index += 2
                if depth == 0 {
                    ctx.emit(from, index, scope)
                    state.pop()
                    return index
                }
                continue
            }
            if ctx[index] == Ch.lbrace, index + 1 < to, ctx[index + 1] == Ch.minus {
                depth += 1
                index += 2
                continue
            }
            index += 1
        }
        ctx.emit(from, to, scope)
        state.replaceTop(frame(fComment, depth | (pragma ? 1 << 16 : 0)))
        return to
    }
}

// MARK: - Dockerfile

/// Dockerfile. `RUN`, `CMD` and `ENTRYPOINT` in shell form are Bash, and the
/// Bash state rides in `inner` so a quote or heredoc can span continuation
/// lines. Everything else is instruction + arguments with `$VARS`.
enum DockerfileLexer {
    private static let fContinuation: UInt8 = 1   // payload: instruction kind

    private static let kGeneric: UInt32 = 1
    private static let kShell: UInt32 = 2
    private static let kFrom: UInt32 = 3

    private static let instructions = WordTable([(.keyword, [
        "ADD", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM", "HEALTHCHECK", "LABEL",
        "MAINTAINER", "ONBUILD", "RUN", "SHELL", "STOPSIGNAL", "USER", "VOLUME", "WORKDIR",
    ])], caseInsensitive: true)

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        let first = ctx.skipSpaces(from, to)
        var kind = state.top.map { framePayload($0) } ?? 0

        if first < to, ctx[first] == Ch.hash, !(kind == kShell && BashLexer.isOpen(state.innerState)) {
            let isDirective = kind == 0 && isParserDirective(&ctx, first + 1, to)
            ctx.emit(first, to, isDirective ? .keywordDirective : .comment)
            return
        }

        var pos = first
        if kind == 0 {
            guard first < to else { return }
            let end = ctx.scanIdentifier(first, to)
            guard instructions.lookup(ctx.text, first, end) != nil else {
                pos = first
                generic(&ctx, pos, to)
                return
            }
            ctx.emit(first, end, .keyword)
            pos = end
            (kind, pos) = instructionKind(&ctx, first, end, to)
            if kind == kShell {
                state.innerState = LexState()
                let body = ctx.skipSpaces(pos, to)
                if body < to, ctx[body] == Ch.lbracket {
                    kind = kGeneric
                }
            }
        }

        switch kind {
        case kShell:
            pos = flags(&ctx, pos, to)
            var inner = state.innerState
            BashLexer.lex(&ctx, pos, to, &inner)
            state.innerState = inner
        case kFrom:
            fromInstruction(&ctx, pos, to)
        default:
            generic(&ctx, pos, to)
        }

        let continues = endsWithBackslash(&ctx, from, to)
            || (kind == kShell && BashLexer.isOpen(state.innerState))
        if continues {
            state.stack = [frame(fContinuation, kind)]
        } else {
            state.stack = []
            if kind == kShell { state.inner = [] }
        }
    }

    static func finishLine(_ state: inout LexState) {
        guard !state.inner.isEmpty else { return }
        var inner = state.innerState
        BashLexer.finishLine(&inner)
        state.innerState = inner
        if state.stack.isEmpty { state.inner = [] }
    }

    private static func instructionKind(_ ctx: inout LexContext, _ start: Int, _ end: Int, _ to: Int) -> (UInt32, Int) {
        let length = end - start
        if (length == 3 && ctx.matches("RUN", at: start, caseInsensitive: true))
            || (length == 3 && ctx.matches("CMD", at: start, caseInsensitive: true))
            || (length == 10 && ctx.matches("ENTRYPOINT", at: start, caseInsensitive: true)) {
            return (kShell, end)
        }
        if length == 4, ctx.matches("FROM", at: start, caseInsensitive: true) { return (kFrom, end) }
        if length == 7, ctx.matches("ONBUILD", at: start, caseInsensitive: true) {
            let next = ctx.skipSpaces(end, to)
            let nextEnd = ctx.scanIdentifier(next, to)
            if instructions.lookup(ctx.text, next, nextEnd) != nil {
                ctx.emit(next, nextEnd, .keyword)
                return instructionKind(&ctx, next, nextEnd, to)
            }
        }
        if length == 11, ctx.matches("HEALTHCHECK", at: start, caseInsensitive: true) {
            var index = flags(&ctx, end, to)
            index = ctx.skipSpaces(index, to)
            if ctx.matches("CMD", at: index, caseInsensitive: true) {
                ctx.emit(index, index + 3, .keyword)
                return (kShell, index + 3)
            }
        }
        return (kGeneric, end)
    }

    private static func isParserDirective(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Bool {
        let start = ctx.skipSpaces(from, to)
        let end = ctx.scanIdentifier(start, to)
        guard ctx.nextNonSpace(end, to) == Ch.eq else { return false }
        let length = end - start
        return (length == 6 && ctx.matches("syntax", at: start, caseInsensitive: true))
            || (length == 6 && ctx.matches("escape", at: start, caseInsensitive: true))
            || (length == 5 && ctx.matches("check", at: start, caseInsensitive: true))
    }

    private static func endsWithBackslash(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Bool {
        var end = to
        while end > from, isSpace(ctx[end - 1]) { end -= 1 }
        return end > from && (ctx[end - 1] == Ch.backslash || ctx[end - 1] == Ch.backtick)
    }

    /// `--mount=type=cache,target=/root --network=none`.
    private static func flags(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int {
        var index = ctx.skipSpaces(from, to)
        while index + 1 < to, ctx[index] == Ch.minus, ctx[index + 1] == Ch.minus {
            var nameEnd = index + 2
            while nameEnd < to, isIdentifierPart(ctx[nameEnd]) || ctx[nameEnd] == Ch.minus { nameEnd += 1 }
            ctx.emit(index, nameEnd, .attribute)
            var end = nameEnd
            while end < to, !isSpace(ctx[end]) { end += 1 }
            if end > nameEnd + 1 { variables(&ctx, nameEnd + 1, end, base: .string) }
            index = ctx.skipSpaces(end, to)
        }
        return index
    }

    private static func fromInstruction(_ ctx: inout LexContext, _ start: Int, _ to: Int) {
        var index = flags(&ctx, start, to)
        var end = index
        while end < to, !isSpace(ctx[end]) { end += 1 }
        variables(&ctx, index, end, base: .string)
        index = ctx.skipSpaces(end, to)
        if ctx.matches("AS", at: index, caseInsensitive: true), index + 2 < to, isSpace(ctx[index + 2]) {
            ctx.emit(index, index + 2, .keyword)
            let name = ctx.skipSpaces(index + 2, to)
            var nameEnd = name
            while nameEnd < to, !isSpace(ctx[nameEnd]) { nameEnd += 1 }
            ctx.emit(name, nameEnd, .label)
        }
    }

    /// Arguments of every other instruction: flags, `key=value`, strings,
    /// numbers, variables, JSON arrays.
    private static func generic(_ ctx: inout LexContext, _ from: Int, _ to: Int) {
        var index = flags(&ctx, from, to)
        while index < to {
            let c = ctx[index]
            if isSpace(c) || c == Ch.lbracket || c == Ch.rbracket || c == Ch.comma { index += 1; continue }
            if c == Ch.backslash, ctx.skipSpaces(index + 1, to) == to { break }
            if c == Ch.dquote || c == Ch.squote {
                var end = index + 1
                while end < to, ctx[end] != c {
                    if ctx[end] == Ch.backslash { end += 1 }
                    end += 1
                }
                end = min(to, end + 1)
                variables(&ctx, index, end, base: .string)
                index = end
                continue
            }
            // key=value
            var end = index
            while end < to, !isSpace(ctx[end]), ctx[end] != Ch.eq { end += 1 }
            if end < to, ctx[end] == Ch.eq, end > index {
                ctx.emit(index, end, .property)
                index = end + 1
                continue
            }
            while end < to, !isSpace(ctx[end]) { end += 1 }
            if isDigit(c) {
                var digits = index
                while digits < to, isDigit(ctx[digits]) || (ctx[digits] == Ch.dot && digits + 1 < to && isDigit(ctx[digits + 1])) {
                    digits += 1
                }
                ctx.emit(index, digits, .number)
                variables(&ctx, digits, end, base: .none)
            } else {
                variables(&ctx, index, end, base: .none)
            }
            index = end
        }
    }

    /// `$VAR` / `${VAR:-default}` inside a word.
    private static func variables(_ ctx: inout LexContext, _ from: Int, _ to: Int, base: SyntaxScope) {
        var index = from
        var segment = from
        while index < to {
            if ctx[index] == Ch.dollar, index + 1 < to {
                var end = index + 1
                if ctx[end] == Ch.lbrace {
                    while end < to, ctx[end] != Ch.rbrace { end += 1 }
                    end = min(to, end + 1)
                } else {
                    end = ctx.scanIdentifier(end, to)
                }
                if end > index + 1 {
                    ctx.emit(segment, index, base)
                    ctx.emit(index, end, .variableSpecial)
                    index = end
                    segment = end
                    continue
                }
            }
            index += 1
        }
        ctx.emit(segment, to, base)
    }
}
