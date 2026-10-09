/// Ruby. Strings, `%` literals and regexes may all span lines and all may
/// interpolate `#{…}`, so a string is a frame; so is `=begin…=end`, a
/// heredoc body and the `__END__` data section.
enum RubyLexer {
    private static let fString: UInt8 = 1     // payload: close | open << 8 | flags << 16
    private static let fCode: UInt8 = 2       // `#{` interpolation; payload: brace depth
    private static let fComment: UInt8 = 3    // =begin … =end
    private static let fHeredoc: UInt8 = 4    // payload: 1 squiggly/dash, 2 raw; terminator in state.text
    private static let fHeredocPending: UInt8 = 5
    private static let fData: UInt8 = 6       // after __END__

    // String flags (in the payload's top byte).
    private static let interpolates: UInt32 = 1
    private static let asRegex: UInt32 = 2
    private static let asSymbol: UInt32 = 4
    private static let asWords: UInt32 = 8

    private static let words = WordTable([
        (.keyword, [
            "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
            "else", "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo",
            "rescue", "retry", "return", "then", "undef", "unless", "until", "when", "while", "yield",
            "__method__", "__FILE__", "__LINE__", "__dir__", "__ENCODING__",
        ]),
        (.boolean, ["true", "false"]),
        (.constantBuiltin, ["nil"]),
        (.variableBuiltin, ["self", "super"]),
        (.functionBuiltin, [
            "attr", "attr_accessor", "attr_reader", "attr_writer", "catch", "define_method", "extend",
            "fail", "format", "gets", "include", "lambda", "loop", "module_function", "p", "pp", "prepend",
            "print", "printf", "private", "private_constant", "proc", "protected", "public", "puts",
            "raise", "rand", "require", "require_relative", "sleep", "sprintf", "throw", "using",
        ]),
    ])

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        var prev = CFamilyLexer.Prev.start
        var blockParams = false
        while pos < to {
            guard let top = state.top else {
                pos = code(&ctx, pos, to, &state, &prev, &blockParams)
                continue
            }
            switch frameKind(top) {
            case fString:
                pos = string(&ctx, pos, to, &state)
                prev = .value
            case fComment:
                if pos == ctx.lineStart, ctx.matches("=end", at: pos) {
                    state.pop()
                }
                ctx.emit(pos, to, .comment)
                pos = to
            case fData:
                ctx.emit(pos, to, .comment)
                pos = to
            case fHeredoc:
                pos = heredoc(&ctx, pos, to, &state)
            default:
                pos = code(&ctx, pos, to, &state, &prev, &blockParams)
            }
        }
    }

    static func finishLine(_ state: inout LexState) {
        if let pending = state.stack.lastIndex(where: { frameKind($0) == fHeredocPending }) {
            state.stack[pending] = frame(fHeredoc, framePayload(state.stack[pending]))
            state.stack.removeSubrange((pending + 1)...)
        }
    }

    private static func code(
        _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState,
        _ prev: inout CFamilyLexer.Prev, _ blockParams: inout Bool
    ) -> Int {
        var pos = from
        while pos < to {
            let c = ctx[pos]
            let next = pos + 1 < to ? ctx[pos + 1] : 0
            if isSpace(c) { pos += 1; continue }

            if pos == ctx.lineStart {
                if ctx.matches("=begin", at: pos) {
                    state.push(frame(fComment))
                    ctx.emit(pos, to, .comment)
                    return to
                }
                if ctx.matches("__END__", at: pos), pos + 7 == to {
                    state.push(frame(fData))
                    ctx.emit(pos, to, .keywordDirective)
                    return to
                }
            }

            if c == Ch.hash {
                ctx.emit(pos, to, .comment)
                return to
            }

            if c == Ch.dquote || c == Ch.backtick {
                return openString(&ctx, pos, pos + 1, to, &state, close: c, open: 0, flags: interpolates)
            }
            if c == Ch.squote {
                return openString(&ctx, pos, pos + 1, to, &state, close: c, open: 0, flags: 0)
            }

            // `%w[…]`, `%i(…)`, `%q{…}`, `%r|…|`, `%(…)`.
            if c == Ch.percent, prev.expressionExpected || prev == .start {
                var index = pos + 1
                var flags: UInt32 = interpolates
                if index < to, isAsciiLetter(ctx[index]) {
                    switch ctx[index] {
                    case u("q"): flags = 0
                    case u("Q"): flags = interpolates
                    case u("w"): flags = asWords
                    case u("W"): flags = interpolates | asWords
                    case u("i"): flags = asSymbol | asWords
                    case u("I"): flags = interpolates | asSymbol | asWords
                    case u("r"): flags = interpolates | asRegex
                    case u("s"): flags = asSymbol
                    case u("x"): flags = interpolates
                    default: flags = 0xFF
                    }
                    index += 1
                }
                if flags != 0xFF, index < to, !isAlnum(ctx[index]), !isSpace(ctx[index]) {
                    let open = ctx[index]
                    let close = closingDelimiter(open)
                    return openString(&ctx, pos, index + 1, to, &state, close: close,
                                      open: close == open ? 0 : open, flags: flags)
                }
            }

            // Heredocs: <<~EOS, <<-EOS, <<EOS, <<~'EOS'.
            if c == Ch.lt, next == Ch.lt,
               prev.expressionExpected || (prev == .value && pos + 2 < to
                   && (ctx[pos + 2] == Ch.tilde || ctx[pos + 2] == Ch.minus)),
               let end = heredocOpen(&ctx, pos, to, &state) {
                pos = end
                prev = .value
                continue
            }

            // Regex literal.
            if c == Ch.slash, prev.expressionExpected {
                return openString(&ctx, pos, pos + 1, to, &state, close: Ch.slash, open: 0,
                                  flags: interpolates | asRegex)
            }

            // Symbols: :name, :"quoted", :+.
            if c == Ch.colon, next != Ch.colon, pos == 0 || ctx.at(pos - 1) != Ch.colon {
                if isIdentifierStart(next) {
                    var end = ctx.scanIdentifier(pos + 1, to)
                    if end < to, ctx[end] == Ch.question || ctx[end] == Ch.bang || ctx[end] == Ch.eq { end += 1 }
                    ctx.emit(pos, end, .stringSymbol)
                    pos = end
                    prev = .value
                    continue
                }
                if next == Ch.dquote {
                    return openString(&ctx, pos, pos + 2, to, &state, close: Ch.dquote, open: 0,
                                      flags: interpolates | asSymbol)
                }
            }

            // Character literal `?a`.
            if c == Ch.question, prev.expressionExpected, pos + 1 < to, !isSpace(next),
               pos + 2 >= to || !isIdentifierPart(ctx[pos + 2]) {
                ctx.emit(pos, pos + 2, .character)
                pos += 2
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

            // @ivar, @@cvar, $global.
            if c == Ch.at || c == Ch.dollar {
                var start = pos + 1
                if c == Ch.at, next == Ch.at { start += 1 }
                var end = ctx.scanIdentifier(start, to)
                if c == Ch.dollar, end == start, start < to { end = start + 1 }
                if end > start {
                    ctx.emit(pos, end, c == Ch.dollar ? .variableBuiltin : .property)
                    pos = end
                    prev = .value
                    continue
                }
            }

            // Block parameters: `{ |a, b|` and `do |x|`.
            if c == Ch.pipe, blockParams {
                var end = pos + 1
                while end < to, ctx[end] != Ch.pipe {
                    if isIdentifierStart(ctx[end]) {
                        let wordEnd = ctx.scanIdentifier(end, to)
                        ctx.emit(end, wordEnd, .variableParameter)
                        end = wordEnd
                        continue
                    }
                    end += 1
                }
                blockParams = false
                pos = min(to, end + 1)
                prev = .op
                continue
            }
            blockParams = false

            if isIdentifierStart(c) {
                var end = ctx.scanIdentifier(pos, to)
                if end < to, ctx[end] == Ch.question || ctx[end] == Ch.bang,
                   !(end + 1 < to && ctx[end + 1] == Ch.eq) {
                    end += 1
                }
                let afterSpace = ctx.skipSpaces(end, to)
                let following = afterSpace < to ? ctx[afterSpace] : 0

                // Hash-key symbols: `name: value`.
                if end < to, ctx[end] == Ch.colon, !(end + 1 < to && ctx[end + 1] == Ch.colon), prev != .dot {
                    ctx.emit(pos, end + 1, .stringSymbol)
                    pos = end + 1
                    prev = .op
                    continue
                }

                let scope: SyntaxScope
                if prev == .dot {
                    scope = .functionMethod
                    prev = .value
                } else if prev == .defFunction {
                    // `def self.name`: `self` stays a keyword, the name follows the dot.
                    if ctx.matches("self", at: pos), end - pos == 4, following == Ch.dot {
                        scope = .variableBuiltin
                    } else {
                        scope = .function
                        prev = .value
                    }
                } else if let word = words.lookup(ctx.text, pos, end) {
                    scope = word
                    let length = end - pos
                    if length == 3, ctx.matches("def", at: pos) { prev = .defFunction }
                    else if (length == 5 && ctx.matches("class", at: pos)) || (length == 6 && ctx.matches("module", at: pos)) {
                        prev = .defType
                    } else if length == 2, ctx.matches("do", at: pos) {
                        blockParams = following == Ch.pipe
                        prev = .keyword
                    } else {
                        prev = word == .keyword || word == .functionBuiltin ? .keyword : .value
                    }
                } else if prev == .defType || isUpper(c) {
                    scope = PythonLexer.shape(&ctx, pos, end) == .constant ? .constant : .type
                    prev = .value
                } else if following == Ch.lparen {
                    scope = .function
                    prev = .value
                } else {
                    scope = .none
                    prev = .value
                }
                ctx.emit(pos, end, scope)
                pos = end
                continue
            }

            if c == Ch.lbrace {
                if let top = state.top, frameKind(top) == fCode {
                    state.replaceTop(frame(fCode, framePayload(top) + 1))
                }
                blockParams = ctx.nextNonSpace(pos + 1, to) == Ch.pipe
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
            if c == Ch.dot {
                if next == Ch.dot {
                    pos += 2
                    prev = .op
                    continue
                }
                pos += 1
                prev = .dot
                continue
            }
            if c == Ch.amp, next == Ch.dot {
                pos += 2
                prev = .dot
                continue
            }
            if c == Ch.colon, next == Ch.colon {
                pos += 2
                prev = .op
                continue
            }
            pos += 1
            prev = (c == Ch.rparen || c == Ch.rbracket) ? .value : .op
        }
        return pos
    }

    private static func closingDelimiter(_ open: UInt16) -> UInt16 {
        switch open {
        case Ch.lparen: return Ch.rparen
        case Ch.lbracket: return Ch.rbracket
        case Ch.lbrace: return Ch.rbrace
        case Ch.lt: return Ch.gt
        default: return open
        }
    }

    private static func scope(_ flags: UInt32) -> SyntaxScope {
        if flags & asRegex != 0 { return .stringRegex }
        if flags & asSymbol != 0 { return .stringSymbol }
        return .string
    }

    private static func openString(
        _ ctx: inout LexContext, _ start: Int, _ bodyStart: Int, _ to: Int, _ state: inout LexState,
        close: UInt16, open: UInt16, flags: UInt32
    ) -> Int {
        ctx.emit(start, min(bodyStart, to), scope(flags))
        guard state.stack.count < 64, close < 0x80, open < 0x80 else { return to }
        state.push(frame(fString, UInt32(close) | (UInt32(open) << 8) | (flags << 16)))
        return bodyStart
    }

    private static func string(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        let payload = framePayload(state.top ?? 0)
        let close = UInt16(payload & 0xFF)
        let open = UInt16((payload >> 8) & 0xFF)
        let flags = (payload >> 16) & 0x0F
        var depth = (payload >> 20) & 0x0F
        let base = scope(flags)
        var index = from
        var segment = from
        while index < to {
            let c = ctx[index]
            if c == Ch.backslash, index + 1 < to {
                let escapes = flags & interpolates != 0 || ctx[index + 1] == close || ctx[index + 1] == Ch.backslash
                if escapes, flags & asRegex == 0 {
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
            if open != 0, c == open {
                depth = min(depth + 1, 15)
            } else if c == close {
                if depth == 0 {
                    var end = index + 1
                    if flags & asRegex != 0 {
                        while end < to, isAsciiLetter(ctx[end]) { end += 1 }
                    }
                    ctx.emit(segment, end, base)
                    state.pop()
                    return end
                }
                depth -= 1
            }
            if flags & interpolates != 0, c == Ch.hash, index + 1 < to, ctx[index + 1] == Ch.lbrace {
                ctx.emit(segment, index, base)
                ctx.emit(index, index + 2, .punctuationSpecial)
                state.replaceTop(frame(fString, (payload & ~(0x0F << 20)) | (depth << 20)))
                if state.stack.count < 64 {
                    state.push(frame(fCode, 0))
                    return index + 2
                }
            }
            index += 1
        }
        ctx.emit(segment, to, base)
        state.replaceTop(frame(fString, (payload & ~(0x0F << 20)) | (depth << 20)))
        return to
    }

    private static func heredocOpen(_ ctx: inout LexContext, _ pos: Int, _ to: Int, _ state: inout LexState) -> Int? {
        var index = pos + 2
        var mode: UInt32 = 0
        if index < to, ctx[index] == Ch.tilde || ctx[index] == Ch.minus {
            mode = 1
            index += 1
        }
        var quote: UInt16 = 0
        if index < to, ctx[index] == Ch.squote || ctx[index] == Ch.dquote || ctx[index] == Ch.backtick {
            quote = ctx[index]
            index += 1
        }
        let nameEnd = ctx.scanIdentifier(index, to)
        guard nameEnd > index else { return nil }
        // Unquoted identifiers must look like a terminator: `<<EOS`, not `a << b`.
        if quote == 0 {
            for i in index..<nameEnd where isLower(ctx[i]) { return nil }
        }
        var end = nameEnd
        if quote != 0 {
            guard end < to, ctx[end] == quote else { return nil }
            end += 1
        }
        guard state.stack.count < 64 else { return nil }
        ctx.emit(pos, end, .string)
        state.text = ctx.slice(index, nameEnd)
        state.push(frame(fHeredocPending, mode | (quote == Ch.squote ? 2 : 0)))
        return end
    }

    private static func heredoc(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        let mode = framePayload(state.top ?? 0)
        if from == ctx.lineStart {
            let start = mode & 1 != 0 ? ctx.skipSpaces(from, to) : from
            if ctx.matches(state.text, at: start), ctx.skipSpaces(start + state.text.count, to) == to {
                ctx.emit(start, start + state.text.count, .string)
                state.pop()
                state.text.removeAll()
                return to
            }
        }
        let raw = mode & 2 != 0
        var index = from
        var segment = from
        while index < to {
            let c = ctx[index]
            if !raw, c == Ch.backslash, index + 1 < to {
                ctx.emit(segment, index, .string)
                let end = CFamilyLexer.escapeEnd(&ctx, index + 1, to)
                ctx.emit(index, end, .stringEscape)
                index = end
                segment = end
                continue
            }
            if !raw, c == Ch.hash, index + 1 < to, ctx[index + 1] == Ch.lbrace {
                ctx.emit(segment, index, .string)
                ctx.emit(index, index + 2, .punctuationSpecial)
                // Interpolation inside a heredoc: lex to the matching brace on
                // this line with a scratch state.
                var depth = 0
                var end = index + 2
                while end < to {
                    if ctx[end] == Ch.lbrace { depth += 1 }
                    if ctx[end] == Ch.rbrace { if depth == 0 { break }; depth -= 1 }
                    end += 1
                }
                var scratch = LexState()
                var prev = CFamilyLexer.Prev.start
                var params = false
                _ = code(&ctx, index + 2, end, &scratch, &prev, &params)
                if end < to { ctx.emit(end, end + 1, .punctuationSpecial) }
                index = min(to, end + 1)
                segment = index
                continue
            }
            index += 1
        }
        ctx.emit(segment, to, .string)
        return to
    }
}
