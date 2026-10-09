// JSON, YAML and TOML.

// MARK: - JSON

/// JSON and JSONC. A string followed by `:` is a key. Only a `/* */` comment
/// crosses a line.
enum JSONLexer {
    private static let fComment: UInt8 = 1

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        if state.top != nil {
            guard let end = ctx.find("*/", from: pos, to: to) else {
                ctx.emit(pos, to, .comment)
                return
            }
            ctx.emit(pos, end + 2, .comment)
            state.pop()
            pos = end + 2
        }
        while pos < to {
            let c = ctx[pos]
            if isSpace(c) { pos += 1; continue }
            if c == Ch.slash, pos + 1 < to {
                if ctx[pos + 1] == Ch.slash {
                    ctx.emit(pos, to, .comment)
                    return
                }
                if ctx[pos + 1] == Ch.star {
                    if let end = ctx.find("*/", from: pos + 2, to: to) {
                        ctx.emit(pos, end + 2, .comment)
                        pos = end + 2
                        continue
                    }
                    ctx.emit(pos, to, .comment)
                    state.push(frame(fComment))
                    return
                }
            }
            if c == Ch.dquote || c == Ch.squote {
                var end = pos + 1
                while end < to, ctx[end] != c {
                    if ctx[end] == Ch.backslash { end += 1 }
                    end += 1
                }
                end = min(to, end + 1)
                let isKey = ctx.nextNonSpace(end, to) == Ch.colon
                if isKey {
                    ctx.emit(pos, end, .property)
                } else {
                    CFamilyLexer.emitEscapes(&ctx, pos, end, .string)
                }
                pos = end
                continue
            }
            if isDigit(c) || (c == Ch.minus && pos + 1 < to && isDigit(ctx[pos + 1])) {
                let end = CFamilyLexer.scanNumber(&ctx, c == Ch.minus ? pos + 1 : pos, to)
                ctx.emit(pos, end, .number)
                pos = end
                continue
            }
            if isAsciiLetter(c) {
                let end = ctx.scanIdentifier(pos, to)
                let length = end - pos
                if (length == 4 && ctx.matches("true", at: pos)) || (length == 5 && ctx.matches("false", at: pos)) {
                    ctx.emit(pos, end, .boolean)
                } else if length == 4, ctx.matches("null", at: pos) {
                    ctx.emit(pos, end, .constantBuiltin)
                } else if ctx.nextNonSpace(end, to) == Ch.colon {
                    ctx.emit(pos, end, .property)
                }
                pos = end
                continue
            }
            pos += 1
        }
    }
}

// MARK: - YAML

/// YAML. Keys, scalars, anchors, tags, comments; block scalars (`|`, `>`)
/// and quoted scalars cross lines, and so does a flow collection's depth.
enum YAMLLexer {
    private static let fBlockScalar: UInt8 = 1   // payload: parent indent + 1 (0 = not yet known)
    private static let fQuoted: UInt8 = 2        // payload: quote char
    private static let fFlow: UInt8 = 3          // payload: depth

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        let indent = ctx.skipSpaces(from, to) - from

        if let top = state.top, frameKind(top) == fBlockScalar {
            let parent = Int(framePayload(top)) - 1
            if ctx.isBlank(from, to) { return }
            if indent > parent {
                ctx.emit(from + indent, to, .string)
                return
            }
            state.pop()
        }
        if let top = state.top, frameKind(top) == fQuoted {
            let quote = UInt16(framePayload(top))
            let end = quotedBody(&ctx, pos, to, quote)
            if end < 0 {
                return
            }
            state.pop()
            pos = end
        }

        let inFlow = { (state: LexState) -> Bool in state.top.map { frameKind($0) == fFlow } ?? false }

        // Directives and document markers.
        if pos == ctx.lineStart, !inFlow(state) {
            if ctx[safe: pos, to] == Ch.percent {
                ctx.emit(pos, to, .keywordDirective)
                return
            }
            if (ctx.matches("---", at: pos) || ctx.matches("...", at: pos)),
               pos + 3 >= to || isSpace(ctx[pos + 3]) {
                ctx.emit(pos, pos + 3, .punctuationSpecial)
                pos += 3
            }
        }

        var keyAllowed = !inFlow(state)
        var parentColumn = indent
        while pos < to {
            let c = ctx[pos]
            if isSpace(c) { pos += 1; continue }

            if c == Ch.hash, pos == ctx.lineStart || isSpace(ctx[pos - 1]) {
                ctx.emit(pos, to, .comment)
                return
            }

            // Sequence entries: `- item`.
            if c == Ch.minus, !inFlow(state), pos + 1 >= to || isSpace(ctx[pos + 1]) {
                ctx.emit(pos, pos + 1, .punctuationListMarker)
                parentColumn = pos - ctx.lineStart
                pos += 1
                keyAllowed = true
                continue
            }
            if c == Ch.question, pos + 1 >= to || isSpace(ctx[pos + 1]) {
                pos += 1
                continue
            }

            if c == Ch.lbracket || c == Ch.lbrace {
                let depth = inFlow(state) ? framePayload(state.top!) + 1 : 1
                if inFlow(state) { state.replaceTop(frame(fFlow, depth)) } else { state.push(frame(fFlow, depth)) }
                keyAllowed = c == Ch.lbrace
                pos += 1
                continue
            }
            if c == Ch.rbracket || c == Ch.rbrace {
                if let top = state.top, frameKind(top) == fFlow {
                    let depth = framePayload(top)
                    if depth <= 1 { state.pop() } else { state.replaceTop(frame(fFlow, depth - 1)) }
                }
                pos += 1
                continue
            }
            if c == Ch.comma {
                keyAllowed = inFlow(state)
                pos += 1
                continue
            }

            // Anchors, aliases, tags.
            if c == Ch.amp || c == Ch.star || c == Ch.bang {
                var end = pos + 1
                while end < to, !isSpace(ctx[end]), ctx[end] != Ch.comma, ctx[end] != Ch.rbracket, ctx[end] != Ch.rbrace {
                    end += 1
                }
                ctx.emit(pos, end, c == Ch.bang ? .type : .label)
                pos = end
                continue
            }

            // Block scalar indicator.
            if c == Ch.pipe || c == Ch.gt {
                var end = pos + 1
                while end < to, ctx[end] == Ch.plus || ctx[end] == Ch.minus || isDigit(ctx[end]) { end += 1 }
                let rest = ctx.skipSpaces(end, to)
                if rest >= to || ctx[rest] == Ch.hash {
                    ctx.emit(pos, end, .punctuationSpecial)
                    if rest < to { ctx.emit(rest, to, .comment) }
                    state.push(frame(fBlockScalar, UInt32(min(parentColumn, 0xFFFF) + 1)))
                    return
                }
            }

            // Quoted scalars (may be keys).
            if c == Ch.dquote || c == Ch.squote {
                let end = quotedBody(&ctx, pos + 1, to, c, open: pos)
                if end < 0 {
                    state.push(frame(fQuoted, UInt32(c)))
                    return
                }
                if keyAllowed, isKeyColon(&ctx, end, to) {
                    // Re-emitting over the string is a no-op in the sink, so
                    // the key colour has to win before the body is emitted.
                    retag(&ctx, pos, end, .property)
                    parentColumn = pos - ctx.lineStart
                    pos = end + 1
                    keyAllowed = false
                    continue
                }
                pos = end
                keyAllowed = false
                continue
            }

            // Plain scalar: up to `: `, ` #`, or (in flow) `,]}`.
            var end = pos
            var colon = -1
            while end < to {
                let d = ctx[end]
                if d == Ch.colon, end + 1 >= to || isSpace(ctx[end + 1]) || (inFlow(state) && (ctx[end + 1] == Ch.comma || ctx[end + 1] == Ch.rbrace)) {
                    colon = end
                    break
                }
                if d == Ch.hash, end > pos, isSpace(ctx[end - 1]) { break }
                if inFlow(state), d == Ch.comma || d == Ch.rbracket || d == Ch.rbrace { break }
                end += 1
            }
            var scalarEnd = end
            while scalarEnd > pos, isSpace(ctx[scalarEnd - 1]) { scalarEnd -= 1 }
            if colon >= 0, keyAllowed {
                ctx.emit(pos, scalarEnd, .property)
                parentColumn = pos - ctx.lineStart
                pos = colon + 1
                keyAllowed = false
                continue
            }
            if colon >= 0 {
                // `a: b: c` — the rest is one scalar.
                end = to
                var hash = pos
                while hash < to {
                    if ctx[hash] == Ch.hash, hash > pos, isSpace(ctx[hash - 1]) { break }
                    hash += 1
                }
                end = hash
                scalarEnd = end
                while scalarEnd > pos, isSpace(ctx[scalarEnd - 1]) { scalarEnd -= 1 }
            }
            ctx.emit(pos, scalarEnd, scalarScope(&ctx, pos, scalarEnd))
            pos = max(end, pos + 1)
            keyAllowed = false
        }
    }

    private static func isKeyColon(_ ctx: inout LexContext, _ end: Int, _ to: Int) -> Bool {
        let colon = ctx.skipSpaces(end, to)
        guard colon < to, ctx[colon] == Ch.colon else { return false }
        return colon + 1 >= to || isSpace(ctx[colon + 1]) || ctx[colon + 1] == Ch.comma || ctx[colon + 1] == Ch.rbrace
    }

    /// Replace the runs of `[start, end)` with one run of `scope`.
    private static func retag(_ ctx: inout LexContext, _ start: Int, _ end: Int, _ scope: SyntaxScope) {
        while let last = ctx.sink.runs.last, last.location >= start, last.location >= ctx.sink.lineFloor {
            ctx.sink.runs.removeLast()
        }
        ctx.emit(start, end, scope)
    }

    /// Emits a quoted body starting at `from`. Returns the end, or the
    /// negated line end when the scalar continues on the next line.
    private static func quotedBody(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ quote: UInt16, open: Int? = nil) -> Int {
        let start = open ?? from
        var index = from
        var segment = start
        while index < to {
            let c = ctx[index]
            if quote == Ch.squote, c == Ch.squote {
                if index + 1 < to, ctx[index + 1] == Ch.squote {
                    ctx.emit(segment, index, .string)
                    ctx.emit(index, index + 2, .stringEscape)
                    index += 2
                    segment = index
                    continue
                }
                ctx.emit(segment, index + 1, .string)
                return index + 1
            }
            if quote == Ch.dquote {
                if c == Ch.backslash, index + 1 < to {
                    ctx.emit(segment, index, .string)
                    let end = CFamilyLexer.escapeEnd(&ctx, index + 1, to)
                    ctx.emit(index, end, .stringEscape)
                    index = end
                    segment = end
                    continue
                }
                if c == Ch.dquote {
                    ctx.emit(segment, index + 1, .string)
                    return index + 1
                }
            }
            index += 1
        }
        ctx.emit(segment, to, .string)
        return -to
    }

    private static let booleans = WordTable([(.boolean, [
        "true", "false", "yes", "no", "on", "off",
    ])], caseInsensitive: true)
    private static let nulls = WordTable([(.constantBuiltin, ["null", "~"])], caseInsensitive: true)

    static func scalarScope(_ ctx: inout LexContext, _ start: Int, _ end: Int) -> SyntaxScope {
        guard end > start else { return .none }
        if booleans.lookup(ctx.text, start, end) != nil { return .boolean }
        if nulls.lookup(ctx.text, start, end) != nil || (end - start == 1 && ctx[start] == Ch.tilde) {
            return .constantBuiltin
        }
        if isNumber(&ctx, start, end) { return .number }
        return .string
    }

    /// Integers, floats, hex/octal, `.inf`, `.nan`, with an optional sign.
    static func isNumber(_ ctx: inout LexContext, _ start: Int, _ end: Int) -> Bool {
        var index = start
        if ctx[index] == Ch.plus || ctx[index] == Ch.minus { index += 1 }
        guard index < end else { return false }
        let special: [StaticString] = [".inf", ".Inf", ".INF", ".nan", ".NaN", ".NAN"]
        for word in special where word.utf8CodeUnitCount == end - index && ctx.matches(word, at: index) { return true }
        if ctx[index] == u("0"), index + 1 < end, ctx[index + 1] == u("x") || ctx[index + 1] == u("o") {
            guard index + 2 < end else { return false }
            for i in (index + 2)..<end where !isHexDigit(ctx[i]) && ctx[i] != Ch.underscore { return false }
            return true
        }
        var sawDigit = false
        var sawDot = false
        var sawExponent = false
        while index < end {
            let c = ctx[index]
            if isDigit(c) { sawDigit = true }
            else if c == Ch.underscore && sawDigit {}
            else if c == Ch.dot && !sawDot && !sawExponent { sawDot = true }
            else if (c == u("e") || c == u("E")) && sawDigit && !sawExponent {
                sawExponent = true
                if index + 1 < end, ctx[index + 1] == Ch.plus || ctx[index + 1] == Ch.minus { index += 1 }
            } else { return false }
            index += 1
        }
        return sawDigit
    }
}

// MARK: - TOML

/// TOML: `[table]` headers, `key = value`, four string forms (two of them
/// multi-line), dates, numbers. An array may run over many lines, and inside
/// it nothing is a key.
enum TOMLLexer {
    private static let fMultiline: UInt8 = 1   // payload: quote char
    private static let fArray: UInt8 = 2       // payload: bracket depth

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        if let top = state.top, frameKind(top) == fMultiline {
            let quote = UInt16(framePayload(top))
            let end = multiline(&ctx, pos, to, quote)
            if end < 0 { return }
            state.pop()
            pos = end
        }

        var arrayDepth = state.top.map { frameKind($0) == fArray ? Int(framePayload($0)) : 0 } ?? 0
        var inlineTableDepth = 0
        var expectKey = arrayDepth == 0
        let first = ctx.skipSpaces(pos, to)

        // Table headers.
        if arrayDepth == 0, first < to, ctx[first] == Ch.lbracket, pos == ctx.lineStart {
            var end = first
            while end < to, ctx[end] == Ch.lbracket { end += 1 }
            var close = end
            while close < to, ctx[close] != Ch.rbracket {
                if ctx[close] == Ch.dquote || ctx[close] == Ch.squote {
                    let q = ctx[close]
                    close += 1
                    while close < to, ctx[close] != q { close += 1 }
                }
                close += 1
            }
            ctx.emit(end, min(close, to), .type)
            pos = close
            while pos < to, ctx[pos] == Ch.rbracket { pos += 1 }
            expectKey = false
        }

        while pos < to {
            let c = ctx[pos]
            if isSpace(c) { pos += 1; continue }
            if c == Ch.hash {
                ctx.emit(pos, to, .comment)
                break
            }
            if c == Ch.dquote || c == Ch.squote {
                let triple = pos + 2 < to && ctx[pos + 1] == c && ctx[pos + 2] == c
                if triple {
                    ctx.emit(pos, pos + 3, .string)
                    let end = multiline(&ctx, pos + 3, to, c)
                    if end < 0 {
                        state.stack = arrayDepth > 0 ? [frame(fArray, UInt32(arrayDepth))] : []
                        state.push(frame(fMultiline, UInt32(c)))
                        return
                    }
                    pos = end
                    expectKey = false
                    continue
                }
                var end = pos + 1
                while end < to, ctx[end] != c {
                    if c == Ch.dquote, ctx[end] == Ch.backslash { end += 1 }
                    end += 1
                }
                end = min(to, end + 1)
                if expectKey {
                    ctx.emit(pos, end, .property)
                } else if c == Ch.dquote {
                    CFamilyLexer.emitEscapes(&ctx, pos, end, .string)
                } else {
                    ctx.emit(pos, end, .string)
                }
                pos = end
                continue
            }
            if c == Ch.eq {
                expectKey = false
                pos += 1
                continue
            }
            if c == Ch.lbracket {
                arrayDepth += 1
                pos += 1
                continue
            }
            if c == Ch.rbracket {
                arrayDepth = max(0, arrayDepth - 1)
                pos += 1
                continue
            }
            if c == Ch.lbrace {
                inlineTableDepth += 1
                expectKey = true
                pos += 1
                continue
            }
            if c == Ch.rbrace {
                inlineTableDepth = max(0, inlineTableDepth - 1)
                pos += 1
                continue
            }
            if c == Ch.comma {
                expectKey = inlineTableDepth > 0
                pos += 1
                continue
            }
            if c == Ch.dot {
                pos += 1
                continue
            }
            // Bare keys and bare values.
            var end = pos
            while end < to {
                let d = ctx[end]
                if isAlnum(d) || d == Ch.underscore || d == Ch.minus || d == Ch.plus || d == Ch.colon
                    || (d == Ch.dot && !expectKey) || d >= 0x80 {
                    end += 1
                } else if d == Ch.space, !expectKey, end + 1 < to, isDigit(ctx[end + 1]), end > pos, isDigit(ctx[end - 1]) {
                    end += 1 // `1979-05-27 07:32:00`
                } else {
                    break
                }
            }
            if end == pos { pos += 1; continue }
            if expectKey {
                ctx.emit(pos, end, .property)
            } else {
                ctx.emit(pos, end, valueScope(&ctx, pos, end))
            }
            pos = end
        }

        state.stack = arrayDepth > 0 ? [frame(fArray, UInt32(min(arrayDepth, 0xFFFF)))] : []
    }

    private static func valueScope(_ ctx: inout LexContext, _ start: Int, _ end: Int) -> SyntaxScope {
        let length = end - start
        if (length == 4 && ctx.matches("true", at: start)) || (length == 5 && ctx.matches("false", at: start)) {
            return .boolean
        }
        var index = start
        if ctx[index] == Ch.plus || ctx[index] == Ch.minus { index += 1 }
        if index < end, ctx.matches("inf", at: index) || ctx.matches("nan", at: index), end - index == 3 { return .number }
        guard index < end, isDigit(ctx[index]) else { return .none }
        // Dates and times carry `-` or `:` after digits.
        var dashes = 0
        var colons = 0
        for i in index..<end {
            if ctx[i] == Ch.minus { dashes += 1 }
            if ctx[i] == Ch.colon { colons += 1 }
        }
        if dashes >= 2 || colons >= 1 { return .stringSpecial }
        return .number
    }

    /// Emits a multi-line string body. Returns the end, or a negated line end
    /// when the string continues.
    private static func multiline(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ quote: UInt16) -> Int {
        var index = from
        var segment = from
        while index < to {
            let c = ctx[index]
            if quote == Ch.dquote, c == Ch.backslash, index + 1 < to {
                ctx.emit(segment, index, .string)
                let end = CFamilyLexer.escapeEnd(&ctx, index + 1, to)
                ctx.emit(index, end, .stringEscape)
                index = end
                segment = end
                continue
            }
            if c == quote, index + 2 < to, ctx[index + 1] == quote, ctx[index + 2] == quote {
                var end = index + 3
                while end < to, ctx[end] == quote, end - index < 5 { end += 1 }
                ctx.emit(segment, end, .string)
                return end
            }
            index += 1
        }
        ctx.emit(segment, to, .string)
        return -to
    }
}

extension LexContext {
    /// Unit at `index` if it is before `to`, else 0.
    subscript(safe index: Int, _ to: Int) -> UInt16 {
        index < to && index >= lineStart ? text[index] : 0
    }
}
