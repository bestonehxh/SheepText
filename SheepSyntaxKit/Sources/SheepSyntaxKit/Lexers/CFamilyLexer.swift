/// One lexer for every brace language: Swift, JavaScript, TypeScript, Go,
/// Rust, Java, C, C#, Scala, and PHP's code sections. What differs between them
/// is data — which quotes open what, which words are keywords — and lives in
/// `CFamilySpec`. What is the same is the machine: a stack of frames (block
/// comment, multi-line string, interpolation, JSX) that survives line breaks,
/// and a one-token lookback that turns `.name(` into a method call and
/// `func name` into a definition.
///
/// Nothing here looks past the end of the current line.
enum CFamilyLexer {
    // Frame kinds.
    static let fCode: UInt8 = 1          // payload: closer (0 none, 1 `}`, 2 `)`) | depth << 2
    static let fComment: UInt8 = 2       // payload: nesting depth
    static let fString: UInt8 = 3        // payload: kind | extra << 8
    static let fJSXTag: UInt8 = 4
    static let fJSXChildren: UInt8 = 5
    static let fHeredoc: UInt8 = 6       // payload: 1 = nowdoc; terminator in state.text
    static let fHeredocPending: UInt8 = 7

    // String kinds.
    static let sDouble: UInt32 = 1
    static let sSingle: UInt32 = 2
    static let sTriple: UInt32 = 3
    static let sSwiftRaw: UInt32 = 4     // extra: hashes | 0x80 when triple-quoted
    static let sRustRaw: UInt32 = 5      // extra: hashes
    static let sBacktickRaw: UInt32 = 6
    static let sTemplate: UInt32 = 7
    static let sVerbatim: UInt32 = 8     // extra: 1 when interpolated ($@"…")
    static let sCSRaw: UInt32 = 9        // extra: quotes | dollars << 6
    static let sScalaInterp: UInt32 = 10
    static let sScalaInterpTriple: UInt32 = 11
    static let sCSInterp: UInt32 = 12

    static let closerNone: UInt32 = 0, closerBrace: UInt32 = 1, closerParen: UInt32 = 2

    enum Prev: Equatable {
        case start, value, op, dot, arrow, defFunction, defType, keyword
        var expressionExpected: Bool { self == .start || self == .op || self == .keyword }
    }

    static let maxDepth = 64

    // MARK: - Entry points

    static func lex(_ spec: CFamilySpec, _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        var prev = Prev.start
        var importPath = false
        while pos < to {
            guard let top = state.top else {
                pos = code(spec, &ctx, pos, to, &state, &prev, &importPath)
                continue
            }
            switch frameKind(top) {
            case fComment:
                pos = blockComment(spec, &ctx, pos, to, &state)
            case fString:
                pos = string(spec, &ctx, pos, to, &state)
                if state.top.map(frameKind) != fCode || pos >= to { prev = .value }
            case fJSXTag:
                pos = jsxTag(spec, &ctx, pos, to, &state)
            case fJSXChildren:
                pos = jsxChildren(spec, &ctx, pos, to, &state, &prev)
            case fHeredoc:
                pos = heredoc(spec, &ctx, pos, to, &state)
            default:
                pos = code(spec, &ctx, pos, to, &state, &prev, &importPath)
            }
        }
    }

    /// Drop the frames that cannot outlive a line: everything from the first
    /// single-line string up, and turn a pending heredoc into a live one.
    static func finishLine(_ spec: CFamilySpec, _ state: inout LexState) {
        guard !state.stack.isEmpty else { return }
        var keep = state.stack.count
        for (index, top) in state.stack.enumerated() where frameKind(top) == fString {
            if !isMultiline(spec, framePayload(top)) {
                keep = index
                break
            }
        }
        if keep < state.stack.count { state.stack.removeSubrange(keep...) }
        if let pending = state.stack.lastIndex(where: { frameKind($0) == fHeredocPending }) {
            state.stack[pending] = frame(fHeredoc, framePayload(state.stack[pending]))
            // A heredoc opened inside an expression that did not close takes
            // over: everything above it belongs to the heredoc's line.
            state.stack.removeSubrange((pending + 1)...)
        }
        if !state.stack.contains(where: { frameKind($0) == fHeredoc || frameKind($0) == fHeredocPending }) {
            state.text.removeAll()
        }
    }

    static func isMultiline(_ spec: CFamilySpec, _ payload: UInt32) -> Bool {
        let kind = payload & 0xFF
        switch kind {
        case sDouble: return spec.multilineStrings
        case sSingle: return spec.multilineStrings
        case sSwiftRaw: return (payload >> 8) & 0x80 != 0
        case sTriple, sRustRaw, sBacktickRaw, sTemplate, sVerbatim, sCSRaw, sScalaInterpTriple: return true
        default: return false
        }
    }

    // MARK: - Code

    private static func pushFrame(_ state: inout LexState, _ value: UInt32) -> Bool {
        guard state.stack.count < maxDepth else { return false }
        state.push(value)
        return true
    }

    private static func pushString(_ state: inout LexState, _ kind: UInt32, _ extra: UInt32 = 0) -> Bool {
        pushFrame(&state, frame(fString, kind | (extra << 8)))
    }

    /// Lex code until the frame stack changes or the range ends.
    static func code(
        _ spec: CFamilySpec, _ ctx: inout LexContext, _ from: Int, _ to: Int,
        _ state: inout LexState, _ prev: inout Prev, _ importPath: inout Bool
    ) -> Int {
        var pos = from
        while pos < to {
            let c = ctx[pos]
            let next = pos + 1 < to ? ctx[pos + 1] : 0

            if isSpace(c) { pos += 1; continue }

            // Comments.
            if c == Ch.slash && next == Ch.slash {
                ctx.emit(pos, to, .comment)
                return to
            }
            if c == Ch.slash && next == Ch.star {
                if pushFrame(&state, frame(fComment, 1)) {
                    ctx.emit(pos, pos + 2, .comment)
                    return pos + 2
                }
                ctx.emit(pos, to, .comment)
                return to
            }
            if c == Ch.hash && spec.hashComments && next != Ch.lbracket {
                ctx.emit(pos, to, .comment)
                return to
            }

            // Strings and characters.
            if c == Ch.dquote {
                if let end = openDoubleQuote(spec, &ctx, pos, to, &state, prefix: pos) { return end }
            }
            if c == Ch.squote {
                if spec.singleQuoteStrings {
                    if pushString(&state, sSingle) {
                        ctx.emit(pos, pos + 1, .string)
                        return pos + 1
                    }
                } else if spec.charLiterals {
                    pos = charOrLifetime(spec, &ctx, pos, to)
                    prev = .value
                    continue
                }
            }
            if c == Ch.backtick {
                switch spec.backtick {
                case .template:
                    if pushString(&state, sTemplate) {
                        ctx.emit(pos, pos + 1, .string)
                        return pos + 1
                    }
                case .raw:
                    if pushString(&state, sBacktickRaw) {
                        ctx.emit(pos, pos + 1, .string)
                        return pos + 1
                    }
                case .identifier:
                    var end = pos + 1
                    while end < to, ctx[end] != Ch.backtick { end += 1 }
                    pos = min(to, end + 1)
                    prev = .value
                    continue
                case .none:
                    break
                }
            }

            // Numbers.
            if isDigit(c) || (c == Ch.dot && isDigit(next) && prev != .value && prev != .dot) {
                let end = scanNumber(&ctx, pos, to)
                ctx.emit(pos, end, .number)
                pos = end
                prev = .value
                continue
            }

            // PHP variables.
            if c == Ch.dollar && spec.dollarVariables {
                var end = pos + 1
                while end < to, ctx[end] == Ch.dollar { end += 1 }
                let nameEnd = ctx.scanIdentifier(end, to)
                if nameEnd > end {
                    let isThis = nameEnd - end == 4 && ctx.matches("this", at: end)
                    ctx.emit(pos, nameEnd, isThis ? .variableBuiltin : .variableSpecial)
                    pos = nameEnd
                    prev = .value
                    continue
                }
            }

            // C# interpolated strings: $"…", $@"…", $"""…""".
            if c == Ch.dollar && spec.language == .csharp {
                var index = pos
                while index < to, ctx[index] == Ch.dollar { index += 1 }
                let dollars = UInt32(min(index - pos, 3))
                if index < to, ctx[index] == Ch.at, index + 1 < to, ctx[index + 1] == Ch.dquote {
                    if pushString(&state, sVerbatim, 1) {
                        ctx.emit(pos, index + 2, .string)
                        return index + 2
                    }
                }
                if index < to, ctx[index] == Ch.dquote,
                   let end = openDoubleQuote(spec, &ctx, index, to, &state, prefix: pos, dollars: dollars) {
                    return end
                }
            }

            // Swift `$0`, `$name`.
            if c == Ch.dollar && spec.language == .swift {
                let end = ctx.scanIdentifier(pos + 1, to)
                if end > pos + 1 {
                    ctx.emit(pos, end, isDigit(ctx[pos + 1]) ? .variableBuiltin : .variableSpecial)
                    pos = end
                    prev = .value
                    continue
                }
            }

            // Identifiers, keywords, string prefixes.
            if isIdentifierStart(c) || (c == Ch.dollar && spec.dollarIdentifiers) {
                pos = identifier(spec, &ctx, pos, to, &state, &prev, &importPath)
                if state.top.map(frameKind) != nil, stackChanged(state) { return pos }
                continue
            }

            // `@attribute`, `@decorator`, C# `@"verbatim"`.
            if c == Ch.at {
                if spec.language == .csharp {
                    if next == Ch.dquote {
                        if pushString(&state, sVerbatim) {
                            ctx.emit(pos, pos + 2, .string)
                            return pos + 2
                        }
                    }
                    if next == Ch.dollar, pos + 2 < to, ctx[pos + 2] == Ch.dquote {
                        if pushString(&state, sVerbatim, 1) {
                            ctx.emit(pos, pos + 3, .string)
                            return pos + 3
                        }
                    }
                    // `@class` — a verbatim identifier.
                    let end = ctx.scanIdentifier(pos + 1, to)
                    pos = max(pos + 1, end)
                    prev = .value
                    continue
                }
                if spec.annotations {
                    var end = ctx.scanIdentifier(pos + 1, to)
                    while end < to, ctx[end] == Ch.dot, end + 1 < to, isIdentifierStart(ctx[end + 1]) {
                        end = ctx.scanIdentifier(end + 1, to)
                    }
                    if end > pos + 1 {
                        ctx.emit(pos, end, .attribute)
                        pos = end
                        prev = .op
                        continue
                    }
                }
            }

            // `#`: directives, raw strings, attributes, private names.
            if c == Ch.hash {
                if let end = hash(spec, &ctx, pos, to, &state, &prev) {
                    if stackChanged(state) { return end }
                    pos = end
                    continue
                }
            }

            // JSX and heredocs.
            if c == Ch.lt {
                if spec.language.allowsJSX, prev.expressionExpected,
                   let end = jsxOpen(spec, &ctx, pos, to, &state) {
                    prev = .value
                    return end
                }
                if spec.language == .php, next == Ch.lt, pos + 2 < to, ctx[pos + 2] == Ch.lt,
                   let end = phpHeredocOpen(&ctx, pos, to, &state) {
                    pos = end
                    prev = .value
                    continue
                }
            }

            // Regular expression literals.
            if c == Ch.slash && spec.regexLiterals && prev.expressionExpected {
                if let end = scanRegex(&ctx, pos, to) {
                    ctx.emit(pos, end, .stringRegex)
                    pos = end
                    prev = .value
                    continue
                }
            }

            // Brackets that may close an interpolation.
            if c == Ch.lbrace || c == Ch.lparen || c == Ch.lbracket {
                adjustDepth(&state, c, +1)
                pos += 1
                prev = .op
                continue
            }
            if c == Ch.rbrace || c == Ch.rparen || c == Ch.rbracket {
                if let top = state.top, frameKind(top) == fCode {
                    let payload = framePayload(top)
                    let closer = payload & 3
                    let depth = payload >> 2
                    let closes = (closer == closerBrace && c == Ch.rbrace) || (closer == closerParen && c == Ch.rparen)
                    if closes {
                        if depth == 0 {
                            state.pop()
                            let inJSX = state.top.map { frameKind($0) == fJSXTag || frameKind($0) == fJSXChildren } ?? false
                            if !inJSX { ctx.emit(pos, pos + 1, .punctuationSpecial) }
                            prev = .value
                            return pos + 1
                        }
                        state.replaceTop(frame(fCode, closer | ((depth - 1) << 2)))
                    }
                }
                pos += 1
                prev = .value
                continue
            }

            // Member access.
            if c == Ch.dot {
                if next == Ch.dot { // `..`, `...`, `..<`
                    pos += 2
                    while pos < to, ctx[pos] == Ch.dot || ctx[pos] == Ch.lt { pos += 1 }
                    prev = .op
                    continue
                }
                pos += 1
                prev = .dot
                continue
            }
            if (c == Ch.question || c == Ch.bang) && next == Ch.dot && spec.language != .php {
                pos += 2
                prev = .dot
                continue
            }
            if c == Ch.minus && next == Ch.gt {
                pos += 2
                prev = spec.arrowIsMemberAccess ? .arrow : .op
                continue
            }
            if c == Ch.question && next == Ch.minus && pos + 2 < to && ctx[pos + 2] == Ch.gt && spec.language == .php {
                pos += 3
                prev = .arrow
                continue
            }

            // Everything else is an operator or punctuation.
            if c == Ch.semicolon || c == Ch.lbrace || c == Ch.eq { importPath = false }
            pos += 1
            prev = .op
        }
        return pos
    }

    /// Did the last step push or pop a frame? Code returns to `lex` whenever
    /// the innermost frame is no longer the one it was lexing.
    @inline(__always) private static func stackChanged(_ state: LexState) -> Bool {
        guard let top = state.top else { return false }
        return frameKind(top) != fCode && frameKind(top) != fHeredocPending
    }

    private static func adjustDepth(_ state: inout LexState, _ c: UInt16, _ delta: Int) {
        guard let top = state.top, frameKind(top) == fCode else { return }
        let payload = framePayload(top)
        let closer = payload & 3
        let matches = (closer == closerBrace && c == Ch.lbrace) || (closer == closerParen && c == Ch.lparen)
        guard matches else { return }
        let depth = Int(payload >> 2) + delta
        guard depth >= 0, depth < 0x3FFFFF else { return }
        state.replaceTop(frame(fCode, closer | (UInt32(depth) << 2)))
    }

    // MARK: Identifiers

    private static func identifier(
        _ spec: CFamilySpec, _ ctx: inout LexContext, _ start: Int, _ to: Int,
        _ state: inout LexState, _ prev: inout Prev, _ importPath: inout Bool
    ) -> Int {
        let end = ctx.scanIdentifier(start, to, extra: spec.dollarIdentifiers ? Ch.dollar : 0)
        let next = end < to ? ctx[end] : 0
        let length = end - start

        // `import java.util.List` / `package com.example` / `using System.IO`:
        // the path's segments are names, not member accesses.
        if importPath {
            if spec.words.lookup(ctx.text, start, end) == .keyword {
                ctx.emit(start, end, .keyword)
            } else if isUpper(ctx[start]), spec.language == .java || spec.language == .scala || spec.language == .swift {
                ctx.emit(start, end, .type)
            }
            prev = .value
            return end
        }
        if !spec.importWords.isEmpty, prev == .start || prev == .op,
           spec.importWords.contains(where: { $0.utf16.count == length && ctx.matches(Array($0.utf16), at: start) }) {
            ctx.emit(start, end, .keyword)
            importPath = true
            prev = .keyword
            return end
        }

        // String prefixes: Rust r"…" r#"…"# b"…" br"…", C# $"…", Scala s"…".
        if next == Ch.dquote || next == Ch.hash || next == Ch.squote {
            if let handled = stringPrefix(spec, &ctx, start, end, to, &state) {
                prev = .value
                return handled
            }
        }

        // Rust macros: `println!`, `vec!`, `macro_rules!`.
        if spec.macroBang, next == Ch.bang, !(end + 1 < to && ctx[end + 1] == Ch.eq) {
            ctx.emit(start, end + 1, .functionMacro)
            prev = ctx.matches("macro_rules", at: start) && length == 11 ? .defFunction : .value
            return end + 1
        }

        let afterSpace = ctx.skipSpaces(end, to)
        let following = afterSpace < to ? ctx[afterSpace] : 0

        if let scope = spec.words.lookup(ctx.text, start, end) {
            // A keyword used as a member name is a property: `foo.default`,
            // `obj.class`, Swift `.init(`.
            if prev == .dot || prev == .arrow {
                ctx.emit(start, end, following == Ch.lparen ? .functionMethod : .property)
                prev = .value
                return end
            }
            // JS object keys may be keywords: `{ default: 1, if: 2 }`.
            if spec.language.allowsJSX, following == Ch.colon,
               !(afterSpace + 1 < to && ctx[afterSpace + 1] == Ch.colon),
               scope == .keyword, prev == .op, isObjectKeyContext(&ctx, start) {
                ctx.emit(start, end, .property)
                prev = .value
                return end
            }
            ctx.emit(start, end, scope)
            if spec.functionIntroducers.lookup(ctx.text, start, end) != nil {
                prev = .defFunction
            } else if spec.typeIntroducers.lookup(ctx.text, start, end) != nil {
                prev = .defType
            } else {
                switch scope {
                case .boolean, .constantBuiltin, .variableBuiltin, .typeBuiltin: prev = .value
                default: prev = .keyword
                }
            }
            return end
        }

        let scope: SyntaxScope
        switch prev {
        case .defFunction:
            scope = .function
        case .defType:
            scope = .type
        case .dot, .arrow:
            if following == Ch.lparen
                || (spec.trailingClosures && following == Ch.lbrace)
                || (following == Ch.lt && spec.genericCalls && looksLikeGenericCall(&ctx, afterSpace, to)) {
                scope = .functionMethod
            } else {
                scope = .property
            }
        default:
            if following == Ch.lparen || (following == Ch.lt && spec.genericCalls && looksLikeGenericCall(&ctx, afterSpace, to)) {
                scope = isUpper(ctx[start]) && spec.capitalizedTypes && spec.constructorCalls ? .constructor : .function
            } else if spec.language.allowsJSX, following == Ch.colon, prev == .op,
                      !(afterSpace + 1 < to && ctx[afterSpace + 1] == Ch.colon),
                      isObjectKeyContext(&ctx, start) {
                scope = .property
            } else if spec.language == .javascript || spec.language == .typescript,
                      following == Ch.eq, afterSpace + 1 < to, ctx[afterSpace + 1] == Ch.gt {
                scope = .variableParameter
            } else {
                scope = classifyByShape(spec, &ctx, start, end, following: following, afterSpace: afterSpace, to: to)
            }
        }
        ctx.emit(start, end, scope)
        prev = .value
        return end
    }

    /// Is `start` the first token after `{` or `,` on this line? That is what
    /// makes `name:` an object key rather than a label or a ternary branch.
    private static func isObjectKeyContext(_ ctx: inout LexContext, _ start: Int) -> Bool {
        var index = start - 1
        while index >= ctx.lineStart, isSpace(ctx[index]) { index -= 1 }
        if index < ctx.lineStart { return true }
        let c = ctx[index]
        return c == Ch.lbrace || c == Ch.comma || c == Ch.lparen
    }

    /// `foo<Bar>(` — a generic call. Only a closing `>` followed by `(` on
    /// this line, with nothing but type-ish characters between, counts.
    private static func looksLikeGenericCall(_ ctx: inout LexContext, _ lt: Int, _ to: Int) -> Bool {
        var depth = 0
        var index = lt
        while index < to {
            let c = ctx[index]
            if c == Ch.lt { depth += 1 }
            else if c == Ch.gt {
                depth -= 1
                if depth == 0 { return index + 1 < to && ctx[index + 1] == Ch.lparen }
            } else if !(isIdentifierPart(c) || isSpace(c) || c == Ch.comma || c == Ch.dot
                        || c == Ch.colon || c == Ch.lbracket || c == Ch.rbracket || c == Ch.amp
                        || c == Ch.star || c == Ch.question || c == Ch.squote) {
                return false
            }
            index += 1
        }
        return false
    }

    private static func classifyByShape(
        _ spec: CFamilySpec, _ ctx: inout LexContext, _ start: Int, _ end: Int,
        following: UInt16, afterSpace: Int, to: Int
    ) -> SyntaxScope {
        let first = ctx[start]
        var hasLower = false
        var hasLetter = false
        for index in start..<end {
            let c = ctx[index]
            if isLower(c) { hasLower = true; break }
            if isUpper(c) { hasLetter = true }
        }
        if !hasLower && hasLetter && end - start >= 2 { return .constant }
        if spec.capitalizedTypes && isUpper(first) {
            switch spec.language {
            case .go:
                return goCapitalized(&ctx, start, following: following)
            case .csharp:
                return csharpCapitalized(&ctx, start, following: following, afterSpace: afterSpace, to: to)
            default:
                return .type
            }
        }
        if spec.language == .c, end - start > 2, ctx[end - 2] == Ch.underscore, ctx[end - 1] == u("t") {
            return .type
        }
        return .none
    }

    /// Go capitalises exported names of every kind. A capitalised name is a
    /// type when it is used as one: after `*`, `]`, `)` or another name
    /// (`p *Point`, `[]Point`, `func f() Point`, `var x Point`), or before
    /// `{` (a composite literal). `X: 1` is a field; `X, Y int` are fields.
    private static func goCapitalized(_ ctx: inout LexContext, _ start: Int, following: UInt16) -> SyntaxScope {
        if following == Ch.lbrace { return .type }
        if following == Ch.colon { return .property }
        var index = start - 1
        while index >= ctx.lineStart, isSpace(ctx[index]) { index -= 1 }
        guard index >= ctx.lineStart else { return .none }
        let before = ctx[index]
        if before == Ch.star || before == Ch.rbracket || before == Ch.rparen || isIdentifierPart(before) {
            return .type
        }
        return .none
    }

    /// C# PascalCases types, methods and properties alike. A capitalised name
    /// is a type when a name, `<`, `?` or `[` follows it (`List<int> x`,
    /// `Person p`, `int? x`), or a `.` (`Console.WriteLine`), or when it
    /// follows `new`, `:` or `<`. Otherwise it is a property.
    private static func csharpCapitalized(
        _ ctx: inout LexContext, _ start: Int, following: UInt16, afterSpace: Int, to: Int
    ) -> SyntaxScope {
        if isIdentifierStart(following) || following == Ch.lt || following == Ch.question
            || following == Ch.dot || (following == Ch.lbracket && afterSpace + 1 < to && ctx[afterSpace + 1] == Ch.rbracket) {
            return .type
        }
        var index = start - 1
        while index >= ctx.lineStart, isSpace(ctx[index]) { index -= 1 }
        if index >= ctx.lineStart {
            let before = ctx[index]
            if before == Ch.colon || before == Ch.lt || before == Ch.comma && following == Ch.gt { return .type }
            if index >= ctx.lineStart + 2, ctx.matches("new", at: index - 2) { return .type }
            if index >= ctx.lineStart + 1, ctx.matches("is", at: index - 1) || ctx.matches("as", at: index - 1) { return .type }
        }
        return .property
    }

    /// Prefixed string openers. Returns the new position, or nil when the
    /// identifier is just an identifier.
    private static func stringPrefix(
        _ spec: CFamilySpec, _ ctx: inout LexContext, _ start: Int, _ end: Int, _ to: Int,
        _ state: inout LexState
    ) -> Int? {
        let length = end - start
        let quote = ctx[end]
        switch spec.language {
        case .rust:
            let isRaw = (length == 1 && ctx[start] == u("r")) || (length == 2 && ctx.matches("br", at: start))
            let isByte = length == 1 && ctx[start] == u("b")
            if isRaw, quote == Ch.dquote || quote == Ch.hash {
                var index = end
                var hashes: UInt32 = 0
                while index < to, ctx[index] == Ch.hash { hashes += 1; index += 1 }
                guard index < to, ctx[index] == Ch.dquote else { return nil }
                if pushString(&state, sRustRaw, hashes) {
                    ctx.emit(start, index + 1, .string)
                    return index + 1
                }
            }
            if isByte, quote == Ch.dquote {
                if pushString(&state, sDouble) {
                    ctx.emit(start, end + 1, .string)
                    return end + 1
                }
            }
            if isByte, quote == Ch.squote {
                return charOrLifetime(spec, &ctx, end, to, prefixStart: start)
            }
        case .csharp:
            return nil
        case .scala:
            guard quote == Ch.dquote else { return nil }
            let triple = end + 2 < to && ctx[end + 1] == Ch.dquote && ctx[end + 2] == Ch.dquote
            ctx.emit(start, end, .function)
            if pushString(&state, triple ? sScalaInterpTriple : sScalaInterp) {
                let open = end + (triple ? 3 : 1)
                ctx.emit(end, open, .string)
                return open
            }
        case .c:
            // L"…", u8"…", u'…' — the prefix is part of the literal.
            let prefixes: [StaticString] = ["L", "u", "U", "u8", "R", "LR", "uR", "UR", "u8R"]
            guard prefixes.contains(where: { $0.utf8CodeUnitCount == length && ctx.matches($0, at: start) })
            else { return nil }
            if quote == Ch.dquote, pushString(&state, sDouble) {
                ctx.emit(start, end + 1, .string)
                return end + 1
            }
            if quote == Ch.squote {
                return charOrLifetime(spec, &ctx, end, to, prefixStart: start)
            }
        case .python:
            return nil
        default:
            return nil
        }
        return nil
    }

    /// `"`: plain, triple-quoted, or (C#) raw. `prefix` is where the literal's
    /// run begins (a C# `$` sits in front of the quote).
    private static func openDoubleQuote(
        _ spec: CFamilySpec, _ ctx: inout LexContext, _ pos: Int, _ to: Int,
        _ state: inout LexState, prefix: Int, dollars: UInt32 = 0
    ) -> Int? {
        var quotes = 0
        while pos + quotes < to, ctx[pos + quotes] == Ch.dquote { quotes += 1 }
        if spec.language == .csharp, quotes >= 3 {
            if pushString(&state, sCSRaw, UInt32(min(quotes, 63)) | (dollars << 6)) {
                ctx.emit(prefix, pos + quotes, .string)
                return pos + quotes
            }
            return nil
        }
        if spec.tripleQuotes, quotes >= 3 {
            if pushString(&state, sTriple) {
                ctx.emit(prefix, pos + 3, .string)
                return pos + 3
            }
            return nil
        }
        let kind = dollars > 0 ? sCSInterp : sDouble
        if pushString(&state, kind) {
            ctx.emit(prefix, pos + 1, .string)
            return pos + 1
        }
        return nil
    }

    /// A character literal, a Rust lifetime, or a Scala symbol.
    private static func charOrLifetime(
        _ spec: CFamilySpec, _ ctx: inout LexContext, _ pos: Int, _ to: Int, prefixStart: Int? = nil
    ) -> Int {
        let start = prefixStart ?? pos
        var index = pos + 1
        guard index < to else { return to }
        if ctx[index] == Ch.backslash {
            index += 2
            while index < to, ctx[index] != Ch.squote, index - pos < 16 { index += 1 }
            if index < to, ctx[index] == Ch.squote {
                ctx.emit(start, pos + 1, .character)
                emitEscapes(&ctx, pos + 1, index, .character)
                ctx.emit(index, index + 1, .character)
                return index + 1
            }
            return pos + 1
        }
        // One code point, then the closing quote.
        var width = 1
        if (0xD800...0xDBFF).contains(ctx[index]), index + 1 < to { width = 2 }
        if index + width < to, ctx[index + width] == Ch.squote, ctx[index] != Ch.squote {
            ctx.emit(start, index + width + 1, .character)
            return index + width + 1
        }
        if spec.lifetimes || spec.language == .scala, isIdentifierStart(ctx[index]) {
            let end = ctx.scanIdentifier(index, to)
            ctx.emit(pos, end, spec.lifetimes ? .label : .stringSymbol)
            return end
        }
        return pos + 1
    }

    // MARK: `#`

    private static func hash(
        _ spec: CFamilySpec, _ ctx: inout LexContext, _ pos: Int, _ to: Int,
        _ state: inout LexState, _ prev: inout Prev
    ) -> Int? {
        let next = pos + 1 < to ? ctx[pos + 1] : 0
        switch spec.language {
        case .c, .csharp:
            guard ctx.isBlank(ctx.lineStart, pos) else { return nil }
            let wordStart = ctx.skipSpaces(pos + 1, to)
            let wordEnd = ctx.scanIdentifier(wordStart, to)
            ctx.emit(pos, wordEnd, .keywordDirective)
            var index = ctx.skipSpaces(wordEnd, to)
            let isInclude = (wordEnd - wordStart == 7 && ctx.matches("include", at: wordStart))
                || (wordEnd - wordStart == 6 && ctx.matches("import", at: wordStart))
            if isInclude, index < to, ctx[index] == Ch.lt {
                var end = index + 1
                while end < to, ctx[end] != Ch.gt { end += 1 }
                ctx.emit(index, min(to, end + 1), .string)
                return min(to, end + 1)
            }
            if wordEnd - wordStart == 6, ctx.matches("define", at: wordStart), index < to, isIdentifierStart(ctx[index]) {
                let nameEnd = ctx.scanIdentifier(index, to)
                ctx.emit(index, nameEnd, nameEnd < to && ctx[nameEnd] == Ch.lparen ? .functionMacro : .constant)
                index = nameEnd
            }
            if spec.language == .csharp, wordEnd - wordStart == 6, ctx.matches("region", at: wordStart) {
                ctx.emit(pos, to, .keywordDirective)
                return to
            }
            prev = .start
            return index
        case .swift:
            // Raw strings: #"…"#, ##"…"##, #"""…"""#.
            var index = pos
            var hashes: UInt32 = 0
            while index < to, ctx[index] == Ch.hash { hashes += 1; index += 1 }
            if index < to, ctx[index] == Ch.dquote {
                let triple = index + 2 < to && ctx[index + 1] == Ch.dquote && ctx[index + 2] == Ch.dquote
                if pushString(&state, sSwiftRaw, hashes | (triple ? 0x80 : 0)) {
                    let open = index + (triple ? 3 : 1)
                    ctx.emit(pos, open, .string)
                    prev = .value
                    return open
                }
            }
            if isIdentifierStart(next) {
                let end = ctx.scanIdentifier(pos + 1, to)
                let isDirective = SwiftWords.directives.lookup(ctx.text, pos + 1, end) != nil
                ctx.emit(pos, end, isDirective ? .keywordDirective : .functionMacro)
                prev = isDirective ? .start : .value
                return end
            }
            return nil
        case .rust, .php:
            // Attributes: #[derive(Debug)], #![allow(dead_code)].
            var open = pos + 1
            if spec.language == .rust, open < to, ctx[open] == Ch.bang { open += 1 }
            guard open < to, ctx[open] == Ch.lbracket else { return nil }
            var depth = 0
            var index = open
            while index < to {
                let c = ctx[index]
                if c == Ch.lbracket { depth += 1 }
                if c == Ch.rbracket {
                    depth -= 1
                    if depth == 0 { index += 1; break }
                }
                if c == Ch.dquote {
                    index += 1
                    while index < to, ctx[index] != Ch.dquote {
                        if ctx[index] == Ch.backslash { index += 1 }
                        index += 1
                    }
                }
                index += 1
            }
            ctx.emit(pos, min(index, to), .attribute)
            prev = .op
            return min(index, to)
        case .javascript, .typescript:
            // Private names: `this.#count`, `#count = 0`, and a `#!` shebang.
            if next == Ch.bang, ctx.isFirstLine, pos == ctx.lineStart {
                ctx.emit(pos, to, .comment)
                return to
            }
            guard isIdentifierStart(next) else { return nil }
            let end = ctx.scanIdentifier(pos + 1, to)
            let following = ctx.nextNonSpace(end, to)
            ctx.emit(pos, end, following == Ch.lparen ? .functionMethod : .property)
            prev = .value
            return end
        default:
            return nil
        }
    }

    // MARK: - Block comments

    private static func blockComment(
        _ spec: CFamilySpec, _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState
    ) -> Int {
        var depth = framePayload(state.top ?? 0)
        var index = from
        while index < to {
            let c = ctx[index]
            if c == Ch.star, index + 1 < to, ctx[index + 1] == Ch.slash {
                index += 2
                depth -= 1
                if depth == 0 {
                    ctx.emit(from, index, .comment)
                    state.pop()
                    return index
                }
                continue
            }
            if spec.nestedComments, c == Ch.slash, index + 1 < to, ctx[index + 1] == Ch.star {
                depth += 1
                index += 2
                continue
            }
            index += 1
        }
        state.replaceTop(frame(fComment, depth))
        ctx.emit(from, to, .comment)
        return to
    }

    // MARK: - Strings

    private static func string(
        _ spec: CFamilySpec, _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState
    ) -> Int {
        let payload = framePayload(state.top ?? 0)
        let kind = payload & 0xFF
        let extra = payload >> 8
        var index = from
        var segment = from

        @inline(__always) func close(_ end: Int, _ ctx: inout LexContext, _ state: inout LexState) -> Int {
            ctx.emit(segment, end, .string)
            state.pop()
            return end
        }

        while index < to {
            let c = ctx[index]
            switch kind {
            case sDouble, sCSInterp, sScalaInterp:
                if c == Ch.dquote { return close(index + 1, &ctx, &state) }
            case sSingle:
                if c == Ch.squote { return close(index + 1, &ctx, &state) }
            case sTriple, sScalaInterpTriple:
                if c == Ch.dquote, index + 2 < to, ctx[index + 1] == Ch.dquote, ctx[index + 2] == Ch.dquote {
                    var end = index + 3
                    while end < to, ctx[end] == Ch.dquote { end += 1 }
                    return close(end, &ctx, &state)
                }
            case sSwiftRaw:
                let hashes = Int(extra & 0x7F)
                let triple = extra & 0x80 != 0
                let quotes = triple ? 3 : 1
                if c == Ch.dquote, countRun(&ctx, index, to, Ch.dquote) >= quotes,
                   countRun(&ctx, index + quotes, to, Ch.hash) >= hashes {
                    return close(index + quotes + hashes, &ctx, &state)
                }
            case sRustRaw:
                if c == Ch.dquote, countRun(&ctx, index + 1, to, Ch.hash) >= Int(extra) {
                    return close(index + 1 + Int(extra), &ctx, &state)
                }
            case sBacktickRaw, sTemplate:
                if c == Ch.backtick { return close(index + 1, &ctx, &state) }
            case sVerbatim:
                if c == Ch.dquote {
                    if index + 1 < to, ctx[index + 1] == Ch.dquote {
                        ctx.emit(segment, index, .string)
                        ctx.emit(index, index + 2, .stringEscape)
                        index += 2
                        segment = index
                        continue
                    }
                    return close(index + 1, &ctx, &state)
                }
            case sCSRaw:
                let quotes = Int(extra & 0x3F)
                if c == Ch.dquote, countRun(&ctx, index, to, Ch.dquote) >= quotes {
                    return close(index + quotes, &ctx, &state)
                }
            default:
                break
            }

            // Escapes.
            if c == Ch.backslash {
                let escapeStart = index
                var body = index + 1
                var allowed = false
                switch kind {
                case sDouble, sTemplate, sCSInterp, sScalaInterp:
                    allowed = true
                case sTriple:
                    allowed = spec.language != .scala
                case sSingle:
                    allowed = spec.language != .php
                        || (index + 1 < to && (ctx[index + 1] == Ch.backslash || ctx[index + 1] == Ch.squote))
                case sSwiftRaw:
                    let hashes = Int(extra & 0x7F)
                    if countRun(&ctx, index + 1, to, Ch.hash) >= hashes {
                        allowed = true
                        body = index + 1 + hashes
                    }
                default:
                    allowed = false
                }
                if allowed, body < to {
                    // Swift interpolation `\(` / `\#(`.
                    if spec.language == .swift, ctx[body] == Ch.lparen,
                       kind == sDouble || kind == sTriple || kind == sSwiftRaw {
                        ctx.emit(segment, escapeStart, .string)
                        ctx.emit(escapeStart, body + 1, .punctuationSpecial)
                        if pushFrame(&state, frame(fCode, closerParen)) { return body + 1 }
                        index = body + 1
                        segment = index
                        continue
                    }
                    ctx.emit(segment, escapeStart, .string)
                    let end = escapeEnd(&ctx, body, to)
                    ctx.emit(escapeStart, end, .stringEscape)
                    index = end
                    segment = end
                    continue
                }
                if allowed { index += 1; continue }
            }

            // Interpolation.
            switch kind {
            case sTemplate:
                if c == Ch.dollar, index + 1 < to, ctx[index + 1] == Ch.lbrace {
                    ctx.emit(segment, index, .string)
                    ctx.emit(index, index + 2, .punctuationSpecial)
                    if pushFrame(&state, frame(fCode, closerBrace)) { return index + 2 }
                }
            case sDouble where spec.language == .php:
                if let end = phpInterpolation(&ctx, index, to, &state, segment: segment) {
                    if end < 0 { return -end }
                    segment = end
                    index = end
                    continue
                }
            case sCSInterp, sVerbatim, sCSRaw:
                let interpolated = kind == sCSInterp || (kind == sVerbatim && extra & 1 != 0)
                    || (kind == sCSRaw && (extra >> 6) > 0)
                if interpolated, c == Ch.lbrace || c == Ch.rbrace {
                    if index + 1 < to, ctx[index + 1] == c, kind != sCSRaw {
                        ctx.emit(segment, index, .string)
                        ctx.emit(index, index + 2, .stringEscape)
                        index += 2
                        segment = index
                        continue
                    }
                    if c == Ch.lbrace {
                        var end = index + 1
                        if kind == sCSRaw { while end < to, ctx[end] == Ch.lbrace { end += 1 } }
                        ctx.emit(segment, index, .string)
                        ctx.emit(index, end, .punctuationSpecial)
                        if pushFrame(&state, frame(fCode, closerBrace)) { return end }
                    }
                }
            case sScalaInterp, sScalaInterpTriple:
                if c == Ch.dollar, index + 1 < to {
                    let n = ctx[index + 1]
                    if n == Ch.dollar {
                        ctx.emit(segment, index, .string)
                        ctx.emit(index, index + 2, .stringEscape)
                        index += 2
                        segment = index
                        continue
                    }
                    if n == Ch.lbrace {
                        ctx.emit(segment, index, .string)
                        ctx.emit(index, index + 2, .punctuationSpecial)
                        if pushFrame(&state, frame(fCode, closerBrace)) { return index + 2 }
                    }
                    if isIdentifierStart(n) {
                        ctx.emit(segment, index, .string)
                        let end = ctx.scanIdentifier(index + 1, to)
                        ctx.emit(index, index + 1, .punctuationSpecial)
                        index = end
                        segment = end
                        continue
                    }
                }
            default:
                break
            }
            index += 1
        }
        ctx.emit(segment, to, .string)
        return to
    }

    /// PHP `"…$name…"`, `"…{$expr}…"`, `"…${name}…"`. Returns the position to
    /// continue at, a NEGATED position when a code frame was pushed, or nil.
    private static func phpInterpolation(
        _ ctx: inout LexContext, _ index: Int, _ to: Int, _ state: inout LexState, segment: Int
    ) -> Int? {
        let c = ctx[index]
        let n = index + 1 < to ? ctx[index + 1] : 0
        if c == Ch.dollar, isIdentifierStart(n) {
            ctx.emit(segment, index, .string)
            var end = ctx.scanIdentifier(index + 1, to)
            ctx.emit(index, end, .variableSpecial)
            if end + 2 < to, ctx[end] == Ch.minus, ctx[end + 1] == Ch.gt, isIdentifierStart(ctx[end + 2]) {
                let propEnd = ctx.scanIdentifier(end + 2, to)
                ctx.emit(end + 2, propEnd, .property)
                end = propEnd
            }
            return end
        }
        if (c == Ch.lbrace && n == Ch.dollar) || (c == Ch.dollar && n == Ch.lbrace) {
            ctx.emit(segment, index, .string)
            let width = c == Ch.lbrace ? 1 : 2
            ctx.emit(index, index + width, .punctuationSpecial)
            guard state.stack.count < maxDepth else { return index + width }
            state.push(frame(fCode, closerBrace))
            return -(index + width)
        }
        return nil
    }

    // MARK: - PHP heredoc

    private static func phpHeredocOpen(_ ctx: inout LexContext, _ pos: Int, _ to: Int, _ state: inout LexState) -> Int? {
        var index = ctx.skipSpaces(pos + 3, to)
        var quote: UInt16 = 0
        if index < to, ctx[index] == Ch.squote || ctx[index] == Ch.dquote {
            quote = ctx[index]
            index += 1
        }
        let nameEnd = ctx.scanIdentifier(index, to)
        guard nameEnd > index else { return nil }
        var end = nameEnd
        if quote != 0 {
            guard end < to, ctx[end] == quote else { return nil }
            end += 1
        }
        guard state.stack.count < maxDepth else { return nil }
        ctx.emit(pos, end, .string)
        state.text = ctx.slice(index, nameEnd)
        state.push(frame(fHeredocPending, quote == Ch.squote ? 1 : 0))
        return end
    }

    private static func heredoc(
        _ spec: CFamilySpec, _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState
    ) -> Int {
        let nowdoc = framePayload(state.top ?? 0) == 1
        if from == ctx.lineStart {
            let start = ctx.skipSpaces(from, to)
            if ctx.matches(state.text, at: start),
               !(start + state.text.count < to && isIdentifierPart(ctx[start + state.text.count])) {
                let end = start + state.text.count
                ctx.emit(start, end, .string)
                state.pop()
                state.text.removeAll()
                return end
            }
        }
        var index = from
        var segment = from
        while index < to {
            if !nowdoc {
                if ctx[index] == Ch.backslash, index + 1 < to {
                    ctx.emit(segment, index, .string)
                    let end = escapeEnd(&ctx, index + 1, to)
                    ctx.emit(index, end, .stringEscape)
                    index = end
                    segment = end
                    continue
                }
                if let end = phpInterpolation(&ctx, index, to, &state, segment: segment) {
                    if end < 0 { return -end }
                    index = end
                    segment = end
                    continue
                }
            }
            index += 1
        }
        ctx.emit(segment, to, .string)
        return to
    }

    // MARK: - JSX

    /// `<Tag`, `<>` in an expression position. Returns nil when the `<` is a
    /// comparison or a TypeScript generic / type assertion.
    private static func jsxOpen(_ spec: CFamilySpec, _ ctx: inout LexContext, _ pos: Int, _ to: Int, _ state: inout LexState) -> Int? {
        guard pos + 1 < to else { return nil }
        let next = ctx[pos + 1]
        if next == Ch.gt {
            guard jsxRestLooksLikeMarkup(&ctx, pos + 2, to), state.stack.count < maxDepth else { return nil }
            state.push(frame(fJSXChildren))
            return pos + 2
        }
        guard isIdentifierStart(next) else { return nil }
        let nameEnd = jsxName(&ctx, pos + 1, to)
        // What follows the name decides it.
        let after = nameEnd < to ? ctx[nameEnd] : 0
        if after == Ch.gt {
            guard jsxRestLooksLikeMarkup(&ctx, nameEnd + 1, to) else { return nil }
        } else if after == Ch.slash {
            guard nameEnd + 1 < to, ctx[nameEnd + 1] == Ch.gt else { return nil }
        } else if isSpace(after) {
            let word = ctx.skipSpaces(nameEnd, to)
            if word < to {
                let w = ctx[word]
                guard isIdentifierStart(w) || w == Ch.lbrace || w == Ch.slash || w == Ch.gt else { return nil }
                if isIdentifierStart(w) {
                    let wordEnd = ctx.scanIdentifier(word, to, extra: Ch.minus)
                    if ctx.matches("extends", at: word), wordEnd - word == 7 { return nil }
                    let t = wordEnd < to ? ctx[wordEnd] : 0
                    guard t == Ch.eq || t == Ch.gt || t == Ch.slash || isSpace(t) || wordEnd >= to else { return nil }
                }
            }
        } else if after != 0 {
            return nil
        }
        guard state.stack.count < maxDepth - 1 else { return nil }
        let isComponent = isUpper(ctx[pos + 1])
        ctx.emit(pos + 1, nameEnd, isComponent ? .constructor : .tag)
        state.push(frame(fJSXTag))
        return nameEnd
    }

    private static func jsxName(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int {
        var end = from
        while end < to {
            let c = ctx[end]
            if isIdentifierPart(c) || c == Ch.dot || c == Ch.minus || c == Ch.colon || c == Ch.dollar { end += 1 } else { break }
        }
        return end
    }

    /// After an opening tag's `>`: the rest of the line must be empty, or
    /// hold more markup, or open an expression. `<Foo>bar` (a TypeScript type
    /// assertion) is none of those.
    private static func jsxRestLooksLikeMarkup(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Bool {
        let first = ctx.skipSpaces(from, to)
        if first >= to { return true }
        if ctx[first] == Ch.lbrace { return true }
        if ctx[first] == Ch.lparen { return false }
        var index = first
        while index < to {
            if ctx[index] == Ch.lt { return true }
            index += 1
        }
        return false
    }

    private static func jsxTag(_ spec: CFamilySpec, _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        var index = from
        while index < to {
            let c = ctx[index]
            if isSpace(c) { index += 1; continue }
            if c == Ch.slash, index + 1 < to, ctx[index + 1] == Ch.gt {
                state.pop()
                return index + 2
            }
            if c == Ch.gt {
                state.replaceTop(frame(fJSXChildren))
                return index + 1
            }
            if c == Ch.lbrace {
                if state.stack.count < maxDepth {
                    state.push(frame(fCode, closerBrace))
                    return index + 1
                }
                index += 1
                continue
            }
            if c == Ch.dquote || c == Ch.squote {
                var end = index + 1
                while end < to, ctx[end] != c { end += 1 }
                end = min(to, end + 1)
                ctx.emit(index, end, .string)
                index = end
                continue
            }
            if isIdentifierStart(c) {
                let end = jsxName(&ctx, index, to)
                ctx.emit(index, end, .tagAttribute)
                index = end
                continue
            }
            index += 1
        }
        return to
    }

    private static func jsxChildren(
        _ spec: CFamilySpec, _ ctx: inout LexContext, _ from: Int, _ to: Int,
        _ state: inout LexState, _ prev: inout Prev
    ) -> Int {
        var index = from
        while index < to {
            let c = ctx[index]
            if c == Ch.lbrace {
                if state.stack.count < maxDepth {
                    state.push(frame(fCode, closerBrace))
                    return index + 1
                }
            } else if c == Ch.lt, index + 1 < to {
                let n = ctx[index + 1]
                if n == Ch.slash {
                    let nameStart = index + 2
                    let nameEnd = jsxName(&ctx, nameStart, to)
                    if nameEnd > nameStart {
                        ctx.emit(nameStart, nameEnd, isUpper(ctx[nameStart]) ? .constructor : .tag)
                    }
                    var end = nameEnd
                    while end < to, ctx[end] != Ch.gt { end += 1 }
                    state.pop()
                    prev = .value
                    return min(to, end + 1)
                }
                if n == Ch.gt {
                    if state.stack.count < maxDepth { state.push(frame(fJSXChildren)) }
                    return index + 2
                }
                if isIdentifierStart(n), state.stack.count < maxDepth {
                    let nameEnd = jsxName(&ctx, index + 1, to)
                    ctx.emit(index + 1, nameEnd, isUpper(n) ? .constructor : .tag)
                    state.push(frame(fJSXTag))
                    return nameEnd
                }
            }
            index += 1
        }
        return to
    }

    // MARK: - Shared scanners

    static func countRun(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ unit: UInt16) -> Int {
        var index = from
        while index < to, ctx[index] == unit { index += 1 }
        return index - from
    }

    /// `body` is the first unit after the backslash.
    static func escapeEnd(_ ctx: inout LexContext, _ body: Int, _ to: Int) -> Int {
        guard body < to else { return to }
        let c = ctx[body]
        func hexRun(_ from: Int, max count: Int) -> Int {
            var index = from
            while index < to, index - from < count, isHexDigit(ctx[index]) { index += 1 }
            return index
        }
        if c == u("u") {
            if body + 1 < to, ctx[body + 1] == Ch.lbrace {
                var index = body + 2
                while index < to, ctx[index] != Ch.rbrace, index - body < 12 { index += 1 }
                return min(to, index + 1)
            }
            return hexRun(body + 1, max: 4)
        }
        if c == u("U") { return hexRun(body + 1, max: 8) }
        if c == u("x") { return hexRun(body + 1, max: 2) }
        if c >= 0x30 && c <= 0x37 {
            var index = body + 1
            while index < to, index - body < 3, ctx[index] >= 0x30, ctx[index] <= 0x37 { index += 1 }
            return index
        }
        if (0xD800...0xDBFF).contains(c), body + 1 < to { return body + 2 }
        return body + 1
    }

    static func emitEscapes(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ base: SyntaxScope) {
        var index = from
        var segment = from
        while index < to {
            if ctx[index] == Ch.backslash {
                ctx.emit(segment, index, base)
                let end = escapeEnd(&ctx, index + 1, to)
                ctx.emit(index, end, .stringEscape)
                index = end
                segment = end
            } else {
                index += 1
            }
        }
        ctx.emit(segment, to, base)
    }

    /// Integer, float, hex, binary, octal, with `_` separators, exponents and
    /// any alphanumeric suffix (`10u32`, `1.5f`, `100n`, `0xFFL`).
    static func scanNumber(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int {
        var index = from
        var isHex = false
        if ctx[index] == u("0"), index + 1 < to, ctx[index + 1] == u("x") || ctx[index + 1] == u("X") {
            isHex = true
            index += 2
        }
        while index < to {
            let c = ctx[index]
            if isAlnum(c) || c == Ch.underscore {
                let isExponent = isHex ? (c == u("p") || c == u("P")) : (c == u("e") || c == u("E"))
                index += 1
                if isExponent, index < to, ctx[index] == Ch.plus || ctx[index] == Ch.minus,
                   index + 1 < to, isDigit(ctx[index + 1]) {
                    index += 1
                }
                continue
            }
            if c == Ch.dot, index + 1 < to, isDigit(ctx[index + 1]) || (isHex && isHexDigit(ctx[index + 1])) {
                index += 1
                continue
            }
            break
        }
        return index
    }

    /// `/pattern/flags` on one line, honouring escapes and `[...]` classes.
    static func scanRegex(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int? {
        var index = from + 1
        guard index < to, ctx[index] != Ch.slash, ctx[index] != Ch.star else { return nil }
        var inClass = false
        while index < to {
            let c = ctx[index]
            if c == Ch.backslash { index += 2; continue }
            if c == Ch.lbracket { inClass = true }
            else if c == Ch.rbracket { inClass = false }
            else if c == Ch.slash && !inClass {
                index += 1
                while index < to, isAsciiLetter(ctx[index]) { index += 1 }
                return index
            }
            index += 1
        }
        return nil
    }
}
