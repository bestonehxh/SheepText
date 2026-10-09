/// HTML and XML. HTML hands `<script>` bodies to JavaScript (or TypeScript,
/// or JSON, by `type`/`lang`) and `<style>` bodies to CSS; the embedded
/// language's own state rides in `LexState.inner`, so a block comment opened
/// on one line of a script closes correctly on another.
enum MarkupLexer {
    enum Dialect: Sendable { case html, xml }

    private static let fComment: UInt8 = 1
    private static let fTag: UInt8 = 2         // payload: kind | quote << 8 | awaitingValue << 16 | typeAttribute << 17
    private static let fRaw: UInt8 = 3         // payload: kind
    private static let fCDATA: UInt8 = 4
    private static let fInstruction: UInt8 = 5
    private static let fDeclaration: UInt8 = 6

    // Element kinds.
    private static let kNormal: UInt32 = 0
    private static let kScript: UInt32 = 1
    private static let kStyle: UInt32 = 2
    private static let kJSON: UInt32 = 3
    private static let kOpaque: UInt32 = 4
    private static let kTypeScript: UInt32 = 5

    private static func embedded(_ kind: UInt32) -> SyntaxLanguage? {
        switch kind {
        case kScript: return .javascript
        case kStyle: return .css
        case kJSON: return .json
        case kTypeScript: return .typescript
        default: return nil
        }
    }

    static func lex(_ dialect: Dialect, _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        while pos < to {
            guard let top = state.top else {
                pos = text(dialect, &ctx, pos, to, &state)
                continue
            }
            switch frameKind(top) {
            case fComment:
                pos = closeDelimited(&ctx, pos, to, &state, "-->", .comment)
            case fCDATA:
                pos = closeDelimited(&ctx, pos, to, &state, "]]>", .literal)
            case fInstruction:
                pos = instruction(&ctx, pos, to, &state)
            case fDeclaration:
                pos = closeDelimited(&ctx, pos, to, &state, ">", .tagDoctype)
            case fTag:
                pos = tag(dialect, &ctx, pos, to, &state)
            case fRaw:
                pos = raw(&ctx, pos, to, &state)
            default:
                state.pop()
            }
        }
    }

    static func finishLine(_ dialect: Dialect, _ state: inout LexState) {
        guard let top = state.top, frameKind(top) == fRaw, let language = embedded(framePayload(top)) else { return }
        var inner = state.innerState
        language.finishLine(&inner)
        state.innerState = inner
    }

    private static func closeDelimited(
        _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState,
        _ delimiter: StaticString, _ scope: SyntaxScope
    ) -> Int {
        guard let end = ctx.find(delimiter, from: from, to: to) else {
            ctx.emit(from, to, scope)
            return to
        }
        let close = end + delimiter.utf8CodeUnitCount
        ctx.emit(from, close, scope)
        state.pop()
        return close
    }

    /// Character data between tags.
    private static func text(_ dialect: Dialect, _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        var index = from
        while index < to {
            let c = ctx[index]
            if c == Ch.amp {
                var end = index + 1
                if end < to, ctx[end] == Ch.hash { end += 1 }
                let nameEnd = ctx.scanIdentifier(end, to)
                if nameEnd > end, nameEnd < to, ctx[nameEnd] == Ch.semicolon {
                    ctx.emit(index, nameEnd + 1, .stringEscape)
                    index = nameEnd + 1
                    continue
                }
            }
            if c == Ch.lt, index + 1 < to {
                let n = ctx[index + 1]
                if n == Ch.bang {
                    if ctx.matches("<!--", at: index) {
                        state.push(frame(fComment))
                        ctx.emit(index, index + 4, .comment)
                        return index + 4
                    }
                    if ctx.matches("<![CDATA[", at: index) {
                        ctx.emit(index, index + 9, .punctuationSpecial)
                        state.push(frame(fCDATA))
                        return index + 9
                    }
                    state.push(frame(fDeclaration))
                    ctx.emit(index, index + 2, .tagDoctype)
                    return index + 2
                }
                if n == Ch.question {
                    let nameEnd = ctx.scanIdentifier(index + 2, to, extra: Ch.minus)
                    ctx.emit(index, nameEnd, .keywordDirective)
                    state.push(frame(fInstruction))
                    return nameEnd
                }
                if n == Ch.slash {
                    let nameStart = index + 2
                    let nameEnd = tagName(&ctx, nameStart, to)
                    if nameEnd > nameStart {
                        ctx.emit(nameStart, nameEnd, .tag)
                        var end = nameEnd
                        while end < to, ctx[end] != Ch.gt { end += 1 }
                        index = min(to, end + 1)
                        continue
                    }
                }
                if isIdentifierStart(n) {
                    let nameEnd = tagName(&ctx, index + 1, to)
                    ctx.emit(index + 1, nameEnd, .tag)
                    var kind = kNormal
                    if dialect == .html {
                        let length = nameEnd - index - 1
                        if length == 6, ctx.matches("script", at: index + 1, caseInsensitive: true) { kind = kScript }
                        if length == 5, ctx.matches("style", at: index + 1, caseInsensitive: true) { kind = kStyle }
                    }
                    state.push(frame(fTag, kind))
                    return nameEnd
                }
            }
            index += 1
        }
        return to
    }

    private static func tagName(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int {
        var end = from
        while end < to {
            let c = ctx[end]
            if isIdentifierPart(c) || c == Ch.minus || c == Ch.colon || c == Ch.dot { end += 1 } else { break }
        }
        return end
    }

    /// Inside `<name …` until `>`: attributes and their values.
    private static func tag(_ dialect: Dialect, _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        var payload = framePayload(state.top ?? 0)
        var index = from

        // A quoted value that started on an earlier line.
        let openQuote = UInt16((payload >> 8) & 0xFF)
        if openQuote != 0 {
            var end = index
            while end < to, ctx[end] != openQuote { end += 1 }
            if end >= to {
                ctx.emit(index, to, .string)
                return to
            }
            ctx.emit(index, end + 1, .string)
            payload &= ~(0xFF << 8)
            state.replaceTop(frame(fTag, payload))
            index = end + 1
        }

        while index < to {
            let c = ctx[index]
            if isSpace(c) { index += 1; continue }
            if c == Ch.slash, index + 1 < to, ctx[index + 1] == Ch.gt {
                state.pop()
                return index + 2
            }
            if c == Ch.gt {
                state.pop()
                let kind = payload & 0xFF
                if kind != kNormal, state.stack.count < 64 {
                    state.push(frame(fRaw, kind))
                    state.innerState = LexState()
                }
                return index + 1
            }
            if c == Ch.eq {
                payload |= 1 << 16
                index += 1
                continue
            }
            if payload & (1 << 16) != 0 {
                // An attribute value.
                payload &= ~(1 << 16)
                var valueStart = index
                var valueEnd: Int
                if c == Ch.dquote || c == Ch.squote {
                    var end = index + 1
                    while end < to, ctx[end] != c { end += 1 }
                    if end >= to {
                        ctx.emit(index, to, .string)
                        payload |= UInt32(c) << 8
                        state.replaceTop(frame(fTag, payload))
                        return to
                    }
                    ctx.emit(index, end + 1, .string)
                    valueStart = index + 1
                    valueEnd = end
                    index = end + 1
                } else {
                    var end = index
                    while end < to, !isSpace(ctx[end]), ctx[end] != Ch.gt { end += 1 }
                    ctx.emit(index, end, .string)
                    valueEnd = end
                    index = end
                }
                if payload & (1 << 17) != 0 {
                    payload &= ~(1 << 17)
                    let kind = payload & 0xFF
                    if kind == kScript || kind == kJSON || kind == kOpaque || kind == kTypeScript {
                        payload = (payload & ~0xFF) | scriptKind(&ctx, valueStart, valueEnd)
                    }
                }
                state.replaceTop(frame(fTag, payload))
                continue
            }
            if isIdentifierStart(c) || c == Ch.colon || c == Ch.at || c == Ch.minus {
                let end = attributeName(&ctx, index, to)
                ctx.emit(index, end, .tagAttribute)
                let length = end - index
                let isType = (length == 4 && ctx.matches("type", at: index, caseInsensitive: true))
                    || (length == 4 && ctx.matches("lang", at: index, caseInsensitive: true))
                if isType { payload |= 1 << 17 } else { payload &= ~(1 << 17) }
                state.replaceTop(frame(fTag, payload))
                index = end
                continue
            }
            index += 1
        }
        state.replaceTop(frame(fTag, payload))
        return to
    }

    private static func attributeName(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int {
        var end = from
        while end < to {
            let c = ctx[end]
            if isSpace(c) || c == Ch.eq || c == Ch.gt || c == Ch.dquote || c == Ch.squote { break }
            if c == Ch.slash, end + 1 < to, ctx[end + 1] == Ch.gt { break }
            end += 1
        }
        return max(end, from + 1)
    }

    private static func scriptKind(_ ctx: inout LexContext, _ start: Int, _ end: Int) -> UInt32 {
        guard end > start else { return kScript }
        func has(_ word: StaticString) -> Bool { ctx.find(word, from: start, to: end, caseInsensitive: true) != nil }
        if has("json") { return kJSON }
        if (end - start == 2 && ctx.matches("ts", at: start, caseInsensitive: true)) || has("typescript") { return kTypeScript }
        if has("javascript") || has("ecmascript") || has("module") || has("babel") || has("jsx") { return kScript }
        return kOpaque
    }

    /// A `<script>` or `<style>` body, up to its closing tag.
    private static func raw(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        let kind = framePayload(state.top ?? 0)
        let closer: StaticString = kind == kStyle ? "</style" : "</script"
        let end = ctx.find(closer, from: from, to: to, caseInsensitive: true) ?? to
        if let language = embedded(kind), end > from {
            var inner = state.innerState
            language.lex(&ctx, from, end, &inner)
            state.innerState = inner
        }
        if end < to {
            state.pop()
            state.inner.removeAll()
        }
        return end
    }

    private static func instruction(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        var index = from
        while index < to {
            let c = ctx[index]
            if c == Ch.question, index + 1 < to, ctx[index + 1] == Ch.gt {
                ctx.emit(index, index + 2, .keywordDirective)
                state.pop()
                return index + 2
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
                let end = ctx.scanIdentifier(index, to, extra: Ch.minus, extra2: Ch.colon)
                ctx.emit(index, end, .tagAttribute)
                index = end
                continue
            }
            index += 1
        }
        return to
    }
}

// MARK: - CSS

/// CSS (and enough of SCSS/Less to be useful). Whether a statement is a
/// selector or a declaration is decided when it starts: a `{` before the next
/// `;` makes it a rule, `name:` makes it a declaration.
enum CSSLexer {
    private static let fComment: UInt8 = 1
    private static let fBlock: UInt8 = 2   // payload: depth | inValue << 16 | inPrelude << 17

    private enum Mode { case selector, declarationName, value, prelude }

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        if let top = state.top, frameKind(top) == fComment {
            guard let end = ctx.find("*/", from: pos, to: to) else {
                ctx.emit(pos, to, .comment)
                return
            }
            ctx.emit(pos, end + 2, .comment)
            state.pop()
            pos = end + 2
        }
        let blockPayload = state.top.map { frameKind($0) == fBlock ? framePayload($0) : 0 } ?? 0
        var depth = Int(blockPayload & 0xFFFF)
        var mode: Mode
        if blockPayload & (1 << 16) != 0 { mode = .value }
        else if blockPayload & (1 << 17) != 0 { mode = .prelude }
        else { mode = statementMode(&ctx, pos, to, depth: depth) }

        func store(_ state: inout LexState) {
            var payload = UInt32(min(depth, 0xFFFF))
            if mode == .value { payload |= 1 << 16 }
            if mode == .prelude { payload |= 1 << 17 }
            if payload == 0 { state.stack.removeAll() } else { state.stack = [frame(fBlock, payload)] }
        }

        while pos < to {
            let c = ctx[pos]
            let next = pos + 1 < to ? ctx[pos + 1] : 0
            if isSpace(c) { pos += 1; continue }

            if c == Ch.slash, next == Ch.star {
                guard let end = ctx.find("*/", from: pos + 2, to: to) else {
                    ctx.emit(pos, to, .comment)
                    store(&state)
                    state.push(frame(fComment))
                    return
                }
                ctx.emit(pos, end + 2, .comment)
                pos = end + 2
                continue
            }
            if c == Ch.slash, next == Ch.slash, mode != .value || pos == ctx.skipSpaces(ctx.lineStart, to) {
                ctx.emit(pos, to, .comment)   // SCSS / Less
                break
            }
            if c == Ch.lbrace {
                depth += 1
                pos += 1
                mode = statementMode(&ctx, pos, to, depth: depth)
                continue
            }
            if c == Ch.rbrace {
                depth = max(0, depth - 1)
                pos += 1
                mode = statementMode(&ctx, pos, to, depth: depth)
                continue
            }
            if c == Ch.semicolon {
                pos += 1
                mode = statementMode(&ctx, pos, to, depth: depth)
                continue
            }
            if c == Ch.dquote || c == Ch.squote {
                var end = pos + 1
                while end < to, ctx[end] != c {
                    if ctx[end] == Ch.backslash { end += 1 }
                    end += 1
                }
                end = min(to, end + 1)
                CFamilyLexer.emitEscapes(&ctx, pos, end, .string)
                pos = end
                continue
            }
            if c == Ch.at, isIdentifierStart(next) || next == Ch.minus {
                let end = ctx.scanIdentifier(pos + 1, to, extra: Ch.minus)
                ctx.emit(pos, end, .keyword)
                pos = end
                mode = .prelude
                continue
            }

            switch mode {
            case .selector:
                pos = selector(&ctx, pos, to)
            case .declarationName:
                if isIdentifierStart(c) || c == Ch.minus || c == Ch.dollar || c == Ch.star {
                    var end = ctx.scanIdentifier(pos + 1, to, extra: Ch.minus)
                    end = max(end, pos + 1)
                    ctx.emit(pos, end, c == Ch.minus && next == Ch.minus || c == Ch.dollar ? .variableSpecial : .property)
                    pos = end
                } else if c == Ch.colon {
                    pos += 1
                    mode = .value
                } else {
                    pos += 1
                }
            case .value, .prelude:
                pos = value(&ctx, pos, to, prelude: mode == .prelude)
            }
        }
        store(&state)
    }

    /// Decide what the statement starting at `from` is, from this line alone.
    private static func statementMode(_ ctx: inout LexContext, _ from: Int, _ to: Int, depth: Int) -> Mode {
        var index = ctx.skipSpaces(from, to)
        guard index < to else { return depth == 0 ? .selector : .declarationName }
        if depth == 0 { return .selector }
        // `name:` with no `{` before the statement ends is a declaration.
        var sawColon = false
        while index < to {
            let c = ctx[index]
            if c == Ch.lbrace { return .selector }
            if c == Ch.semicolon || c == Ch.rbrace { return sawColon ? .declarationName : .selector }
            if c == Ch.colon { sawColon = true }
            if c == Ch.dquote || c == Ch.squote {
                let q = c
                index += 1
                while index < to, ctx[index] != q { index += 1 }
            }
            index += 1
        }
        return sawColon ? .declarationName : .selector
    }

    private static func selector(_ ctx: inout LexContext, _ pos: Int, _ to: Int) -> Int {
        let c = ctx[pos]
        let next = pos + 1 < to ? ctx[pos + 1] : 0
        if c == Ch.dot, isIdentifierStart(next) || next == Ch.minus {
            let end = ctx.scanIdentifier(pos + 1, to, extra: Ch.minus)
            ctx.emit(pos, end, .type)
            return end
        }
        if c == Ch.hash, isIdentifierPart(next) || next == Ch.minus {
            let end = ctx.scanIdentifier(pos + 1, to, extra: Ch.minus)
            ctx.emit(pos, end, .constant)
            return end
        }
        if c == Ch.colon {
            var start = pos + 1
            if start < to, ctx[start] == Ch.colon { start += 1 }
            let end = ctx.scanIdentifier(start, to, extra: Ch.minus)
            ctx.emit(pos, end, .attribute)
            return max(end, pos + 1)
        }
        if c == Ch.lbracket {
            var index = pos + 1
            let nameEnd = ctx.scanIdentifier(ctx.skipSpaces(index, to), to, extra: Ch.minus)
            let nameStart = ctx.skipSpaces(index, to)
            ctx.emit(nameStart, nameEnd, .tagAttribute)
            index = nameEnd
            while index < to, ctx[index] != Ch.rbracket {
                let d = ctx[index]
                if d == Ch.dquote || d == Ch.squote {
                    var end = index + 1
                    while end < to, ctx[end] != d { end += 1 }
                    end = min(to, end + 1)
                    ctx.emit(index, end, .string)
                    index = end
                    continue
                }
                index += 1
            }
            return min(to, index + 1)
        }
        if isDigit(c) {
            var end = pos
            while end < to, isDigit(ctx[end]) || ctx[end] == Ch.dot { end += 1 }
            if end < to, ctx[end] == Ch.percent { end += 1 }
            ctx.emit(pos, end, .number)
            return end
        }
        if isIdentifierStart(c) {
            let end = ctx.scanIdentifier(pos, to, extra: Ch.minus)
            ctx.emit(pos, end, .tag)
            return end
        }
        if c == Ch.amp {
            ctx.emit(pos, pos + 1, .keyword)
            return pos + 1
        }
        return pos + 1
    }

    private static let preludeKeywords = WordTable([(.keyword, ["and", "not", "only", "or", "from", "to", "through", "as", "with", "layer", "supports"])])

    private static func value(_ ctx: inout LexContext, _ pos: Int, _ to: Int, prelude: Bool) -> Int {
        let c = ctx[pos]
        let next = pos + 1 < to ? ctx[pos + 1] : 0
        if c == Ch.hash, isHexDigit(next) {
            var end = pos + 1
            while end < to, isAlnum(ctx[end]) { end += 1 }
            ctx.emit(pos, end, .constant)
            return end
        }
        if isDigit(c) || (c == Ch.dot && isDigit(next)) || ((c == Ch.minus || c == Ch.plus) && (isDigit(next) || next == Ch.dot)) {
            var end = pos + 1
            while end < to, isDigit(ctx[end]) || ctx[end] == Ch.dot { end += 1 }
            if end < to, ctx[end] == u("e") || ctx[end] == u("E"), end + 1 < to, isDigit(ctx[end + 1]) {
                end += 1
                while end < to, isDigit(ctx[end]) { end += 1 }
            }
            while end < to, isAsciiLetter(ctx[end]) || ctx[end] == Ch.percent { end += 1 }
            ctx.emit(pos, end, .number)
            return end
        }
        if c == Ch.bang {
            let end = ctx.scanIdentifier(ctx.skipSpaces(pos + 1, to), to)
            ctx.emit(pos, end, .keyword)
            return max(end, pos + 1)
        }
        if c == Ch.minus && next == Ch.minus || c == Ch.dollar {
            let end = ctx.scanIdentifier(pos + 1, to, extra: Ch.minus)
            ctx.emit(pos, end, .variableSpecial)
            return max(end, pos + 1)
        }
        if isIdentifierStart(c) || (c == Ch.minus && isIdentifierStart(next)) {
            let end = ctx.scanIdentifier(pos + 1, to, extra: Ch.minus)
            if end < to, ctx[end] == Ch.lparen {
                ctx.emit(pos, end, .function)
                let length = end - pos
                if length == 3, ctx.matches("url", at: pos, caseInsensitive: true) {
                    var close = end + 1
                    while close < to, ctx[close] != Ch.rparen { close += 1 }
                    let body = ctx.skipSpaces(end + 1, close)
                    if body < close, ctx[body] != Ch.dquote, ctx[body] != Ch.squote {
                        ctx.emit(body, close, .string)
                        return close
                    }
                }
                return end
            }
            if prelude {
                if preludeKeywords.lookup(ctx.text, pos, end) != nil { ctx.emit(pos, end, .keyword) }
                else if ctx.nextNonSpace(end, to) == Ch.colon { ctx.emit(pos, end, .property) }
            } else {
                ctx.emit(pos, end, .constantBuiltin)
            }
            return end
        }
        return pos + 1
    }
}

// MARK: - PHP

/// PHP files are HTML with `<?php … ?>` islands. The HTML state and the PHP
/// state are both carried (in `inner[0]` and `inner[1]`) so an island inside
/// an attribute value returns to that attribute value.
enum PHPLexer {
    private static let fPHP: UInt8 = 1

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var inPHP = state.top.map { frameKind($0) == fPHP } ?? false
        var html = state.inner.count > 0 ? state.inner[0] : LexState()
        var php = state.inner.count > 1 ? state.inner[1] : LexState()
        var pos = from
        while pos < to {
            if !inPHP {
                let open = findOpenTag(&ctx, pos, to)
                let end = open?.start ?? to
                if end > pos { MarkupLexer.lex(.html, &ctx, pos, end, &html) }
                guard let open else { pos = to; break }
                ctx.emit(open.start, open.end, .tag)
                inPHP = true
                pos = open.end
            } else {
                let close = ctx.find("?>", from: pos, to: to)
                let end = close ?? to
                if end > pos { CFamilyLexer.lex(CFamilySpec.php, &ctx, pos, end, &php) }
                guard let close else { pos = to; break }
                if php.stack.isEmpty {
                    ctx.emit(close, close + 2, .tag)
                    inPHP = false
                } else {
                    CFamilyLexer.lex(CFamilySpec.php, &ctx, close, close + 2, &php)
                }
                pos = close + 2
            }
        }
        state.stack = inPHP ? [frame(fPHP)] : []
        state.inner = html == LexState() && php == LexState() ? [] : [html, php]
    }

    static func finishLine(_ state: inout LexState) {
        guard state.inner.count == 2 else { return }
        if state.top.map({ frameKind($0) == fPHP }) ?? false {
            CFamilyLexer.finishLine(CFamilySpec.php, &state.inner[1])
        } else {
            MarkupLexer.finishLine(.html, &state.inner[0])
        }
        if state.inner[0] == LexState() && state.inner[1] == LexState() { state.inner = [] }
    }

    private static func findOpenTag(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> (start: Int, end: Int)? {
        var index = from
        while let found = ctx.find("<?", from: index, to: to) {
            if ctx.matches("<?php", at: found, caseInsensitive: true) { return (found, found + 5) }
            if ctx.matches("<?=", at: found) { return (found, found + 3) }
            let after = found + 2
            if after >= to || isSpace(ctx[after]) { return (found, after) }
            index = found + 2
        }
        return nil
    }
}
