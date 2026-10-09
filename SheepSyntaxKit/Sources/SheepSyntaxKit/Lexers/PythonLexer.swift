/// Python. The only thing that crosses a line is a triple-quoted string.
enum PythonLexer {
    private static let fTriple: UInt8 = 1   // payload: quote | raw << 8 | f-string << 9

    private static let words = WordTable([
        (.keyword, [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
            "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
            "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
        ]),
        (.boolean, ["True", "False"]),
        (.constantBuiltin, ["None", "NotImplemented", "Ellipsis", "__debug__"]),
        (.variableBuiltin, ["self", "cls"]),
    ])

    private static let builtins = WordTable([(.functionBuiltin, [
        "abs", "aiter", "all", "anext", "any", "ascii", "bin", "bool", "breakpoint", "bytearray", "bytes",
        "callable", "chr", "classmethod", "compile", "complex", "delattr", "dict", "dir", "divmod",
        "enumerate", "eval", "exec", "filter", "float", "format", "frozenset", "getattr", "globals",
        "hasattr", "hash", "help", "hex", "id", "input", "int", "isinstance", "issubclass", "iter", "len",
        "list", "locals", "map", "max", "memoryview", "min", "next", "object", "oct", "open", "ord", "pow",
        "print", "property", "range", "repr", "reversed", "round", "set", "setattr", "slice", "sorted",
        "staticmethod", "str", "sum", "super", "tuple", "type", "vars", "zip", "__import__",
    ])])

    private static let builtinTypes = WordTable([(.typeBuiltin, [
        "int", "float", "str", "bool", "bytes", "bytearray", "list", "dict", "set", "frozenset", "tuple",
        "object", "complex", "type", "memoryview", "range",
    ])])

    private static let softKeywords = WordTable([(.keyword, ["match", "case", "type"])])

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        if let top = state.top, frameKind(top) == fTriple {
            pos = tripleString(&ctx, pos, to, &state)
        }
        code(&ctx, pos, to, &state)
    }

    private static func code(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        var prev = CFamilyLexer.Prev.start
        var parenDepth = 0
        let firstToken = ctx.skipSpaces(from, to)

        while pos < to {
            let c = ctx[pos]
            if isSpace(c) { pos += 1; continue }

            if c == Ch.hash {
                ctx.emit(pos, to, .comment)
                return
            }

            // Strings, with any prefix.
            if c == Ch.dquote || c == Ch.squote {
                pos = openString(&ctx, pos, pos, to, &state, prefix: 0)
                if !state.stack.isEmpty { return }
                prev = .value
                continue
            }

            if isDigit(c) || (c == Ch.dot && pos + 1 < to && isDigit(ctx[pos + 1])) {
                let end = CFamilyLexer.scanNumber(&ctx, pos, to)
                ctx.emit(pos, end, .number)
                pos = end
                prev = .value
                continue
            }

            // Decorators: `@name.attr(...)` as the first thing on a line.
            if c == Ch.at && pos == firstToken {
                var end = ctx.scanIdentifier(pos + 1, to)
                while end < to, ctx[end] == Ch.dot { end = ctx.scanIdentifier(end + 1, to) }
                ctx.emit(pos, end, .attribute)
                pos = end
                prev = .op
                continue
            }

            if isIdentifierStart(c) {
                let end = ctx.scanIdentifier(pos, to)
                // String prefix: r"", b'', f"", rb"", Rf''…
                if end < to, end - pos <= 2, ctx[end] == Ch.dquote || ctx[end] == Ch.squote,
                   let flags = prefixFlags(&ctx, pos, end) {
                    pos = openString(&ctx, end, pos, to, &state, prefix: flags)
                    if !state.stack.isEmpty { return }
                    prev = .value
                    continue
                }
                let afterSpace = ctx.skipSpaces(end, to)
                let following = afterSpace < to ? ctx[afterSpace] : 0
                let scope: SyntaxScope
                if prev == .dot {
                    scope = following == Ch.lparen ? .functionMethod : .property
                    prev = .value
                } else if let keyword = words.lookup(ctx.text, pos, end) {
                    scope = keyword
                    if ctx.matches("def", at: pos), end - pos == 3 { prev = .defFunction }
                    else if ctx.matches("class", at: pos), end - pos == 5 { prev = .defType }
                    else { prev = keyword == .keyword ? .keyword : .value }
                } else if pos == firstToken, softKeywords.lookup(ctx.text, pos, end) != nil,
                          following != 0, following != Ch.eq, following != Ch.dot, following != Ch.lparen,
                          following != Ch.comma, following != Ch.rparen, following != Ch.colon,
                          following != Ch.lbracket {
                    scope = .keyword
                    prev = .keyword
                } else if prev == .defFunction {
                    scope = .function
                    prev = .value
                } else if prev == .defType {
                    scope = .type
                    prev = .value
                } else if following != Ch.lparen, builtinTypes.lookup(ctx.text, pos, end) != nil {
                    scope = .typeBuiltin
                    prev = .value
                } else if following == Ch.lparen {
                    if builtins.lookup(ctx.text, pos, end) != nil {
                        scope = .functionBuiltin
                    } else {
                        scope = isUpper(c) ? .constructor : .function
                    }
                    prev = .value
                } else if following == Ch.eq, parenDepth > 0,
                          !(afterSpace + 1 < to && ctx[afterSpace + 1] == Ch.eq) {
                    scope = .variableParameter
                    prev = .value
                } else {
                    scope = shape(&ctx, pos, end)
                    prev = .value
                }
                ctx.emit(pos, end, scope)
                pos = end
                continue
            }

            if c == Ch.dot {
                pos += 1
                prev = .dot
                continue
            }
            if c == Ch.lparen || c == Ch.lbracket || c == Ch.lbrace { parenDepth += 1 }
            if c == Ch.rparen || c == Ch.rbracket || c == Ch.rbrace { parenDepth = max(0, parenDepth - 1) }
            pos += 1
            prev = (c == Ch.rparen || c == Ch.rbracket || c == Ch.rbrace) ? .value : .op
        }
    }

    static func shape(_ ctx: inout LexContext, _ start: Int, _ end: Int) -> SyntaxScope {
        var hasLower = false
        var hasUpper = false
        for index in start..<end {
            if isLower(ctx[index]) { hasLower = true; break }
            if isUpper(ctx[index]) { hasUpper = true }
        }
        if hasUpper && !hasLower && end - start >= 2 { return .constant }
        if isUpper(ctx[start]) { return .type }
        return .none
    }

    /// raw = 1, f-string = 2, bytes = 4. nil when the letters are not a prefix.
    private static func prefixFlags(_ ctx: inout LexContext, _ start: Int, _ end: Int) -> UInt32? {
        var flags: UInt32 = 0
        for index in start..<end {
            switch asciiLower(ctx[index]) {
            case u("r"): flags |= 1
            case u("f"), u("t"): flags |= 2
            case u("b"): flags |= 4
            case u("u"): break
            default: return nil
            }
        }
        return flags
    }

    /// `quotePos` is the opening quote; the run starts at `runStart`.
    private static func openString(
        _ ctx: inout LexContext, _ quotePos: Int, _ runStart: Int, _ to: Int,
        _ state: inout LexState, prefix: UInt32
    ) -> Int {
        let quote = ctx[quotePos]
        let triple = quotePos + 2 < to && ctx[quotePos + 1] == quote && ctx[quotePos + 2] == quote
        if triple {
            ctx.emit(runStart, quotePos + 3, .string)
            state.push(frame(fTriple, UInt32(quote) | ((prefix & 3) << 8)))
            return tripleString(&ctx, quotePos + 3, to, &state)
        }
        ctx.emit(runStart, quotePos + 1, .string)
        return stringBody(&ctx, quotePos + 1, to, quote: quote, triple: false, flags: prefix, state: &state)
    }

    private static func tripleString(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        let payload = framePayload(state.top ?? 0)
        let quote = UInt16(payload & 0xFF)
        let flags = (payload >> 8) & 3
        return stringBody(&ctx, from, to, quote: quote, triple: true, flags: flags, state: &state)
    }

    /// Scan a string body. Pops the triple frame when it closes; a single-line
    /// string simply ends at the line end.
    private static func stringBody(
        _ ctx: inout LexContext, _ from: Int, _ to: Int, quote: UInt16, triple: Bool,
        flags: UInt32, state: inout LexState
    ) -> Int {
        let raw = flags & 1 != 0
        let format = flags & 2 != 0
        var index = from
        var segment = from
        while index < to {
            let c = ctx[index]
            if c == quote {
                if !triple {
                    ctx.emit(segment, index + 1, .string)
                    return index + 1
                }
                if index + 2 < to, ctx[index + 1] == quote, ctx[index + 2] == quote {
                    ctx.emit(segment, index + 3, .string)
                    state.pop()
                    return index + 3
                }
            }
            if c == Ch.backslash, index + 1 < to {
                if raw {
                    index += 2
                    continue
                }
                ctx.emit(segment, index, .string)
                var end = CFamilyLexer.escapeEnd(&ctx, index + 1, to)
                if ctx[index + 1] == u("N"), end < to, ctx[end] == Ch.lbrace {
                    while end < to, ctx[end] != Ch.rbrace { end += 1 }
                    end = min(to, end + 1)
                }
                ctx.emit(index, end, .stringEscape)
                index = end
                segment = end
                continue
            }
            if format, c == Ch.lbrace {
                if index + 1 < to, ctx[index + 1] == Ch.lbrace {
                    ctx.emit(segment, index, .string)
                    ctx.emit(index, index + 2, .stringEscape)
                    index += 2
                    segment = index
                    continue
                }
                // A replacement field: code up to the matching `}` on this line.
                ctx.emit(segment, index, .string)
                var depth = 0
                var end = index
                while end < to {
                    let d = ctx[end]
                    if d == Ch.lbrace { depth += 1 }
                    if d == Ch.rbrace { depth -= 1; if depth == 0 { break } }
                    if d == quote && !triple { break }
                    end += 1
                }
                ctx.emit(index, index + 1, .punctuationSpecial)
                var scratch = LexState()
                let exprEnd = min(end, to)
                if exprEnd > index + 1 {
                    code(&ctx, index + 1, formatSpecStart(&ctx, index + 1, exprEnd), &scratch)
                }
                if end < to, ctx[end] == Ch.rbrace {
                    ctx.emit(end, end + 1, .punctuationSpecial)
                    index = end + 1
                } else {
                    index = exprEnd
                }
                segment = index
                continue
            }
            if format, c == Ch.rbrace, index + 1 < to, ctx[index + 1] == Ch.rbrace {
                ctx.emit(segment, index, .string)
                ctx.emit(index, index + 2, .stringEscape)
                index += 2
                segment = index
                continue
            }
            index += 1
        }
        ctx.emit(segment, to, .string)
        return to
    }

    /// Where `{value!r:>10}`'s conversion/format spec begins, so it is not
    /// lexed as code.
    private static func formatSpecStart(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int {
        var depth = 0
        var index = from
        while index < to {
            let c = ctx[index]
            if c == Ch.lparen || c == Ch.lbracket || c == Ch.lbrace { depth += 1 }
            if c == Ch.rparen || c == Ch.rbracket || c == Ch.rbrace { depth -= 1 }
            if depth == 0, c == Ch.bang, index + 1 < to, ctx[index + 1] != Ch.eq { return index }
            if depth == 0, c == Ch.colon { return index }
            index += 1
        }
        return to
    }
}
