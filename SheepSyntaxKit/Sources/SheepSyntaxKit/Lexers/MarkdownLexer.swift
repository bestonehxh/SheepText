/// CommonMark + the GFM parts people use, line by line.
///
/// Block structure is a small state: "the last line was paragraph text"
/// (which decides whether four spaces are code and whether `---` underlines a
/// heading), the content column of the current list item, and at most one
/// container — a fenced code block, an HTML block or front matter — whose
/// embedded language's own state rides in `LexState.inner`. A fence tagged
/// `swift` is highlighted by the Swift lexer, with a block comment opened on
/// one line of it closing on another, exactly as in a `.swift` file.
///
/// The one place a line reads past itself: a paragraph line followed by `===`
/// or `---` is a setext heading. `SyntaxLanguage.markdown.lookahead` makes the
/// incremental pass re-lex the line above every edit to keep that exact.
enum MarkdownLexer {
    private static let fFlags: UInt8 = 1        // payload: paragraph | listIndent << 1 | carry << 16
    private static let fFence: UInt8 = 2        // payload: tilde | quoted << 1 | length << 2 | indent << 8 | language << 16
    private static let fHTML: UInt8 = 3         // payload: end condition
    private static let fFrontMatter: UInt8 = 4  // payload: 0 YAML, 1 TOML

    // HTML block end conditions.
    private static let endAtBlank: UInt32 = 0
    private static let endAtComment: UInt32 = 1
    private static let endAtScript: UInt32 = 2
    private static let endAtPre: UInt32 = 3
    private static let endAtStyle: UInt32 = 4
    private static let endAtTextarea: UInt32 = 5
    private static let endAtInstruction: UInt32 = 6
    private static let endAtDeclaration: UInt32 = 7
    private static let endAtCDATA: UInt32 = 8

    /// Emphasis or strong opened on an earlier line of the paragraph whose
    /// closer is on a later one.
    struct Carry: Equatable {
        var underscore = false
        var strong = false
        var scope: SyntaxScope { strong ? .strong : .emphasis }
        var delimiter: UInt16 { underscore ? Ch.underscore : Ch.star }
        var width: Int { strong ? 2 : 1 }
    }

    private struct Flags {
        var paragraph = false
        var listIndent = 0
        var carry: Carry? = nil
    }

    private static func languageIndex(_ language: SyntaxLanguage) -> UInt32 {
        UInt32(SyntaxLanguage.allCases.firstIndex(of: language)! + 1)
    }

    private static func language(at index: UInt32) -> SyntaxLanguage? {
        guard index > 0, Int(index) <= SyntaxLanguage.allCases.count else { return nil }
        return SyntaxLanguage.allCases[Int(index) - 1]
    }

    // MARK: - Entry points

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var flags = Flags()
        var container: UInt32? = nil
        for value in state.stack {
            switch frameKind(value) {
            case fFlags:
                let payload = framePayload(value)
                flags.paragraph = payload & 1 != 0
                flags.listIndent = Int((payload >> 1) & 0x7FFF)
                if payload & (1 << 16) != 0 {
                    flags.carry = Carry(underscore: payload & (1 << 17) != 0, strong: payload & (1 << 18) != 0)
                }
            default:
                container = value
            }
        }

        if let current = container {
            switch frameKind(current) {
            case fFrontMatter:
                if frontMatterClose(&ctx, from, to, toml: framePayload(current) == 1) {
                    ctx.emit(from, to, .punctuationSpecial)
                    container = nil
                    state.inner.removeAll()
                } else {
                    var inner = state.innerState
                    (framePayload(current) == 1 ? SyntaxLanguage.toml : .yaml).lex(&ctx, from, to, &inner)
                    state.innerState = inner
                }
            case fFence:
                if fenceLine(&ctx, from, to, current, &state) {
                    container = nil
                    flags.paragraph = false
                }
            default:
                if htmlLine(&ctx, from, to, framePayload(current), &state) {
                    container = nil
                    flags.paragraph = false
                }
            }
            store(&state, flags, container)
            return
        }

        if ctx.isFirstLine, from == ctx.lineStart {
            if frontMatterClose(&ctx, from, to, toml: false) && ctx.matches("---", at: from) {
                ctx.emit(from, to, .punctuationSpecial)
                store(&state, flags, frame(fFrontMatter, 0))
                return
            }
            if frontMatterClose(&ctx, from, to, toml: true) {
                ctx.emit(from, to, .punctuationSpecial)
                store(&state, flags, frame(fFrontMatter, 1))
                return
            }
        }

        if ctx.isBlank(from, to) {
            flags.paragraph = false
            store(&state, flags, nil)
            return
        }

        // Leaving a list: a line indented less than the item's content that
        // is neither a new item nor a lazy continuation of its paragraph.
        let indentEnd = ctx.skipSpaces(from, to)
        let indent = column(&ctx, from, indentEnd)
        if flags.listIndent > 0, indent < flags.listIndent, listMarker(&ctx, indentEnd, to) == nil {
            let first = ctx[indentEnd]
            let startsBlock = first == Ch.hash || first == Ch.backtick || first == Ch.tilde || first == Ch.gt
                || first == Ch.lt || isThematicBreak(&ctx, indentEnd, to, first)
            if !flags.paragraph || startsBlock { flags.listIndent = 0 }
        }

        var newContainer: UInt32? = nil
        block(&ctx, from, to, &flags, &newContainer, &state, quoted: false, listItemStart: false)
        store(&state, flags, newContainer)
    }

    static func finishLine(_ state: inout LexState) {
        guard let top = state.stack.last, !state.inner.isEmpty else { return }
        var inner = state.innerState
        switch frameKind(top) {
        case fFence:
            language(at: framePayload(top) >> 16)?.finishLine(&inner)
        case fHTML:
            MarkupLexer.finishLine(.html, &inner)
        default:
            break
        }
        state.innerState = inner
    }

    private static func store(_ state: inout LexState, _ flags: Flags, _ container: UInt32?) {
        var stack: [UInt32] = []
        var payload = (flags.paragraph ? 1 : 0) | (UInt32(min(flags.listIndent, 0x7FFF)) << 1)
        if let carry = flags.carry, flags.paragraph {
            payload |= 1 << 16
            if carry.underscore { payload |= 1 << 17 }
            if carry.strong { payload |= 1 << 18 }
        }
        if payload != 0 { stack.append(frame(fFlags, payload)) }
        if let container { stack.append(container) }
        state.stack = stack
        if container == nil { state.inner.removeAll() }
    }

    /// Visual column of `index`, with tabs to the next multiple of four.
    private static func column(_ ctx: inout LexContext, _ from: Int, _ index: Int) -> Int {
        var col = 0
        var i = ctx.lineStart
        while i < index {
            col = ctx[i] == Ch.tab ? (col / 4 + 1) * 4 : col + 1
            i += 1
        }
        return col
    }

    // MARK: - Containers

    private static func frontMatterClose(_ ctx: inout LexContext, _ from: Int, _ to: Int, toml: Bool) -> Bool {
        var end = to
        while end > from, isSpace(ctx[end - 1]) { end -= 1 }
        guard end - from == 3 else { return false }
        return toml ? ctx.matches("+++", at: from) : (ctx.matches("---", at: from) || ctx.matches("...", at: from))
    }

    /// Returns true when this line closes the fence.
    private static func fenceLine(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ fence: UInt32, _ state: inout LexState) -> Bool {
        let payload = framePayload(fence)
        let fenceChar = payload & 1 != 0 ? Ch.tilde : Ch.backtick
        let quoted = payload & 2 != 0
        let length = Int((payload >> 2) & 0x3F)
        let indent = Int((payload >> 8) & 0xFF)
        var pos = from
        if quoted {
            var index = ctx.skipSpaces(pos, to)
            while index < to, ctx[index] == Ch.gt {
                ctx.emit(index, index + 1, .punctuationSpecial)
                index += 1
                if index < to, ctx[index] == Ch.space { index += 1 }
            }
            pos = index
        }

        // Closing fence: up to three spaces past the opener's indent, a run at
        // least as long as the opener, nothing after it.
        let runStart = ctx.skipSpaces(pos, to)
        if column(&ctx, pos, runStart) - column(&ctx, pos, pos) <= indent + 3 {
            var runEnd = runStart
            while runEnd < to, ctx[runEnd] == fenceChar { runEnd += 1 }
            if runEnd - runStart >= length, ctx.isBlank(runEnd, to) {
                ctx.emit(runStart, runEnd, .punctuationSpecial)
                state.inner.removeAll()
                return true
            }
        }

        // Content: strip up to `indent` columns, then hand it over.
        var contentStart = pos
        var stripped = 0
        while contentStart < to, stripped < indent, ctx[contentStart] == Ch.space {
            contentStart += 1
            stripped += 1
        }
        if let language = language(at: payload >> 16) {
            let savedStart = ctx.lineStart
            let savedFirst = ctx.isFirstLine
            ctx.lineStart = contentStart
            ctx.isFirstLine = false
            var inner = state.innerState
            language.lex(&ctx, contentStart, to, &inner)
            state.innerState = inner
            ctx.lineStart = savedStart
            ctx.isFirstLine = savedFirst
        } else {
            ctx.emit(contentStart, to, .literal)
        }
        return false
    }

    /// Returns true when this line ends the HTML block.
    private static func htmlLine(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ condition: UInt32, _ state: inout LexState) -> Bool {
        if condition == endAtBlank, ctx.isBlank(from, to) {
            state.inner.removeAll()
            return true
        }
        var inner = state.innerState
        MarkupLexer.lex(.html, &ctx, from, to, &inner)
        state.innerState = inner
        if htmlEnds(&ctx, from, to, condition) {
            state.inner.removeAll()
            return true
        }
        return false
    }

    private static func htmlEnds(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ condition: UInt32) -> Bool {
        switch condition {
        case endAtComment: return ctx.find("-->", from: from, to: to) != nil
        case endAtScript: return ctx.find("</script>", from: from, to: to, caseInsensitive: true) != nil
        case endAtPre: return ctx.find("</pre>", from: from, to: to, caseInsensitive: true) != nil
        case endAtStyle: return ctx.find("</style>", from: from, to: to, caseInsensitive: true) != nil
        case endAtTextarea: return ctx.find("</textarea>", from: from, to: to, caseInsensitive: true) != nil
        case endAtInstruction: return ctx.find("?>", from: from, to: to) != nil
        case endAtDeclaration: return ctx.find(">", from: from, to: to) != nil
        case endAtCDATA: return ctx.find("]]>", from: from, to: to) != nil
        default: return false
        }
    }

    // MARK: - Blocks

    private static func block(
        _ ctx: inout LexContext, _ from: Int, _ to: Int, _ flags: inout Flags, _ container: inout UInt32?,
        _ state: inout LexState, quoted: Bool, listItemStart: Bool
    ) {
        let start = ctx.skipSpaces(from, to)
        let carry = flags.carry
        flags.carry = nil
        guard start < to else {
            flags.paragraph = false
            return
        }
        let indent = column(&ctx, from, start)
        let base = flags.listIndent > 0 && indent >= flags.listIndent ? flags.listIndent : (listItemStart ? column(&ctx, from, from) : 0)
        let relative = listItemStart ? 0 : indent - base
        let c = ctx[start]

        // Indented code.
        if relative >= 4 && !flags.paragraph {
            ctx.emit(start, to, .literal)
            return
        }

        // Block quote.
        if c == Ch.gt && relative <= 3 {
            var index = start
            while index < to, ctx[index] == Ch.gt {
                ctx.emit(index, index + 1, .punctuationSpecial)
                index += 1
                if index < to, ctx[index] == Ch.space { index += 1 }
                let next = ctx.skipSpaces(index, to)
                if next < to, ctx[next] == Ch.gt { index = next }
            }
            block(&ctx, index, to, &flags, &container, &state, quoted: true, listItemStart: false)
            return
        }

        // Fenced code.
        if relative <= 3, c == Ch.backtick || c == Ch.tilde {
            var runEnd = start
            while runEnd < to, ctx[runEnd] == c { runEnd += 1 }
            let length = runEnd - start
            if length >= 3, c == Ch.tilde || ctx.find("`", from: runEnd, to: to) == nil {
                ctx.emit(start, runEnd, .punctuationSpecial)
                let infoStart = ctx.skipSpaces(runEnd, to)
                var infoEnd = infoStart
                while infoEnd < to, !isSpace(ctx[infoEnd]), ctx[infoEnd] != Ch.lbrace, ctx[infoEnd] != Ch.comma { infoEnd += 1 }
                var languageStart = infoStart
                if languageStart < to, ctx[languageStart] == Ch.lbrace || ctx[languageStart] == Ch.dot {
                    languageStart += 1
                    while languageStart < to, ctx[languageStart] == Ch.dot { languageStart += 1 }
                    infoEnd = languageStart
                    while infoEnd < to, isIdentifierPart(ctx[infoEnd]) || ctx[infoEnd] == Ch.plus || ctx[infoEnd] == Ch.minus || ctx[infoEnd] == Ch.hash { infoEnd += 1 }
                }
                if infoEnd > languageStart { ctx.emit(languageStart, infoEnd, .label) }
                let word = String(decoding: ctx.text[languageStart..<infoEnd], as: UTF16.self)
                let languageID = SyntaxLanguage(identifier: word).map(languageIndex) ?? 0
                let payload = (c == Ch.tilde ? 1 : 0) | (quoted ? 2 : 0) | (UInt32(min(length, 63)) << 2)
                    | (UInt32(min(indent, 255)) << 8) | (languageID << 16)
                container = frame(fFence, payload)
                state.inner.removeAll()
                flags.paragraph = false
                return
            }
        }

        // ATX heading.
        if relative <= 3, c == Ch.hash {
            var markerEnd = start
            while markerEnd < to, ctx[markerEnd] == Ch.hash { markerEnd += 1 }
            if markerEnd - start <= 6, markerEnd == to || isSpace(ctx[markerEnd]) {
                ctx.emit(start, markerEnd, .punctuationSpecial)
                var contentEnd = to
                while contentEnd > markerEnd, isSpace(ctx[contentEnd - 1]) { contentEnd -= 1 }
                var closeStart = contentEnd
                while closeStart > markerEnd, ctx[closeStart - 1] == Ch.hash { closeStart -= 1 }
                let hasClose = closeStart < contentEnd && (closeStart == markerEnd || isSpace(ctx[closeStart - 1]))
                let textEnd = hasClose ? closeStart : contentEnd
                inline(&ctx, ctx.skipSpaces(markerEnd, textEnd), textEnd, base: .title)
                if hasClose { ctx.emit(closeStart, contentEnd, .punctuationSpecial) }
                flags.paragraph = false
                return
            }
        }

        // Setext underline (the line above was coloured by lookahead).
        if flags.paragraph, relative <= 3, !listItemStart, c == Ch.eq || c == Ch.minus, isUnderline(&ctx, start, to) {
            ctx.emit(start, to, .punctuationSpecial)
            flags.paragraph = false
            return
        }

        // Thematic break.
        if relative <= 3, c == Ch.star || c == Ch.minus || c == Ch.underscore, isThematicBreak(&ctx, start, to, c) {
            ctx.emit(start, to, .punctuationSpecial)
            flags.paragraph = false
            return
        }

        // List item.
        if relative <= 3, let markerEnd = listMarker(&ctx, start, to) {
            ctx.emit(start, markerEnd, .punctuationListMarker)
            var contentStart = ctx.skipSpaces(markerEnd, to)
            if contentStart == to || column(&ctx, from, contentStart) - column(&ctx, from, markerEnd) > 4 {
                contentStart = min(to, markerEnd + 1)
            }
            flags.listIndent = column(&ctx, from, contentStart)
            // Task list: `- [ ]`, `- [x]`.
            if contentStart + 2 < to, ctx[contentStart] == Ch.lbracket, ctx[contentStart + 2] == Ch.rbracket,
               ctx[contentStart + 1] == Ch.space || ctx[contentStart + 1] == u("x") || ctx[contentStart + 1] == u("X"),
               contentStart + 3 >= to || isSpace(ctx[contentStart + 3]) {
                ctx.emit(contentStart, contentStart + 3, .punctuationSpecial)
                contentStart = ctx.skipSpaces(contentStart + 3, to)
            }
            flags.paragraph = false
            if contentStart < to {
                block(&ctx, contentStart, to, &flags, &container, &state, quoted: quoted, listItemStart: true)
            }
            return
        }

        // HTML block.
        if relative <= 3, c == Ch.lt, let condition = htmlBlockStart(&ctx, start, to, interrupting: flags.paragraph) {
            var inner = LexState()
            MarkupLexer.lex(.html, &ctx, start, to, &inner)
            let endsHere = condition != endAtBlank && htmlEnds(&ctx, start + 1, to, condition)
            if !endsHere {
                container = frame(fHTML, condition)
                state.innerState = inner
            }
            flags.paragraph = false
            return
        }

        // Link reference definition.
        if !flags.paragraph, relative <= 3, c == Ch.lbracket, linkDefinition(&ctx, start, to) {
            return
        }

        // GFM table delimiter row.
        if flags.paragraph, isTableDelimiter(&ctx, start, to) {
            ctx.emit(start, to, .punctuationSpecial)
            return
        }

        // Paragraph text; a setext heading if the next line underlines it.
        var heading = false
        if !listItemStart, !quoted, carry == nil {
            ctx.forEachFollowingLine { next in
                let underline = ctx.skipSpaces(next.lowerBound, next.upperBound)
                if underline < next.upperBound, underline - next.lowerBound <= 3,
                   ctx[underline] == Ch.eq || ctx[underline] == Ch.minus,
                   isUnderline(ctx.text, underline, next.upperBound) {
                    heading = true
                }
                return false
            }
        }
        if heading {
            inline(&ctx, start, to, base: .title)
        } else {
            flags.carry = paragraphLine(&ctx, start, to, carry: flags.paragraph ? carry : nil)
        }
        flags.paragraph = true
    }

    private static func isUnderline(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Bool {
        isUnderline(ctx.text, from, to)
    }

    private static func isUnderline(_ text: UnsafeBufferPointer<UInt16>, _ from: Int, _ to: Int) -> Bool {
        let c = text[from]
        var index = from
        while index < to, text[index] == c { index += 1 }
        while index < to, isSpace(text[index]) { index += 1 }
        return index == to
    }

    private static func isThematicBreak(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ c: UInt16) -> Bool {
        var count = 0
        for index in from..<to {
            let d = ctx[index]
            if d == c { count += 1 } else if !isSpace(d) { return false }
        }
        return count >= 3
    }

    /// End of a list marker (`-`, `+`, `*`, `1.`, `1)`), or nil.
    private static func listMarker(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int? {
        guard from < to else { return nil }
        let c = ctx[from]
        var end = from
        if c == Ch.minus || c == Ch.plus || c == Ch.star {
            end = from + 1
        } else if isDigit(c) {
            while end < to, isDigit(ctx[end]), end - from < 9 { end += 1 }
            guard end < to, ctx[end] == Ch.dot || ctx[end] == Ch.rparen else { return nil }
            end += 1
        } else {
            return nil
        }
        guard end == to || isSpace(ctx[end]) else { return nil }
        return end
    }

    private static let blockTags: WordTable = WordTable([(.keyword, [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
        "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
        "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
        "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
        "th", "thead", "title", "tr", "track", "ul", "picture", "source", "img", "br", "video", "audio",
    ])], caseInsensitive: true)

    private static func htmlBlockStart(_ ctx: inout LexContext, _ from: Int, _ to: Int, interrupting: Bool) -> UInt32? {
        if ctx.matches("<!--", at: from) { return endAtComment }
        if ctx.matches("<?", at: from) { return endAtInstruction }
        if ctx.matches("<![CDATA[", at: from) { return endAtCDATA }
        if from + 2 < to, ctx[from + 1] == Ch.bang, isAsciiLetter(ctx[from + 2]) { return endAtDeclaration }
        var nameStart = from + 1
        let closing = nameStart < to && ctx[nameStart] == Ch.slash
        if closing { nameStart += 1 }
        guard nameStart < to, isAsciiLetter(ctx[nameStart]) else { return nil }
        var nameEnd = nameStart
        while nameEnd < to, isAlnum(ctx[nameEnd]) || ctx[nameEnd] == Ch.minus { nameEnd += 1 }
        let after = nameEnd < to ? ctx[nameEnd] : 0
        guard after == 0 || isSpace(after) || after == Ch.gt || (after == Ch.slash) else { return nil }
        if !closing {
            let length = nameEnd - nameStart
            if length == 6, ctx.matches("script", at: nameStart, caseInsensitive: true) { return endAtScript }
            if length == 3, ctx.matches("pre", at: nameStart, caseInsensitive: true) { return endAtPre }
            if length == 5, ctx.matches("style", at: nameStart, caseInsensitive: true) { return endAtStyle }
            if length == 8, ctx.matches("textarea", at: nameStart, caseInsensitive: true) { return endAtTextarea }
        }
        if blockTags.lookup(ctx.text, nameStart, nameEnd) != nil { return endAtBlank }
        // Any other complete tag alone on its line, when not interrupting a paragraph.
        guard !interrupting else { return nil }
        var end = to
        while end > from, isSpace(ctx[end - 1]) { end -= 1 }
        guard end > from, ctx[end - 1] == Ch.gt, ctx.find(">", from: nameEnd, to: end) == end - 1 else { return nil }
        return endAtBlank
    }

    /// `[label]: destination "title"`.
    private static func linkDefinition(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Bool {
        var close = from + 1
        while close < to, ctx[close] != Ch.rbracket {
            if ctx[close] == Ch.backslash { close += 1 }
            close += 1
        }
        guard close + 1 < to, ctx[close + 1] == Ch.colon, close > from + 1 else { return false }
        let destination = ctx.skipSpaces(close + 2, to)
        guard destination < to else { return false }
        ctx.emit(from + 1, close, .reference)
        var destinationEnd = destination
        if ctx[destination] == Ch.lt {
            while destinationEnd < to, ctx[destinationEnd] != Ch.gt { destinationEnd += 1 }
            destinationEnd = min(to, destinationEnd + 1)
        } else {
            while destinationEnd < to, !isSpace(ctx[destinationEnd]) { destinationEnd += 1 }
        }
        ctx.emit(destination, destinationEnd, .uri)
        let title = ctx.skipSpaces(destinationEnd, to)
        if title < to, ctx[title] == Ch.dquote || ctx[title] == Ch.squote || ctx[title] == Ch.lparen {
            ctx.emit(title, to, .string)
        }
        return true
    }

    private static func isTableDelimiter(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Bool {
        var dashes = 0
        var pipes = 0
        for index in from..<to {
            let c = ctx[index]
            if c == Ch.minus { dashes += 1 }
            else if c == Ch.pipe { pipes += 1 }
            else if c != Ch.colon && !isSpace(c) { return false }
        }
        return dashes >= 1 && pipes >= 1
    }

    // MARK: - Inlines

    @inline(__always) private static func isPunctuation(_ c: UInt16) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }

    /// One line of a paragraph: first finish an emphasis carried in from the
    /// line above, then the line's own inlines — which may open one that
    /// closes further down.
    private static func paragraphLine(_ ctx: inout LexContext, _ from: Int, _ to: Int, carry: Carry?) -> Carry? {
        var pos = from
        if let carry {
            guard let (closeStart, _) = closer(&ctx, carry.delimiter, from, to, minimum: carry.width) else {
                inline(&ctx, from, to, base: carry.scope)
                return carry
            }
            inline(&ctx, from, closeStart, base: carry.scope)
            ctx.emit(closeStart, closeStart + carry.width, carry.scope)
            pos = closeStart + carry.width
        }
        return inline(&ctx, pos, to, base: .none, allowCarry: true)
    }

    /// Does a later line of this paragraph close a `c` run of `width`?
    private static func closesOnALaterLine(_ ctx: inout LexContext, _ c: UInt16, width: Int) -> Bool {
        var found = false
        ctx.forEachFollowingLine { range in
            let first = ctx.skipSpaces(range.lowerBound, range.upperBound)
            let d = ctx.text[first]
            // A line that starts another block ends the paragraph.
            if d == Ch.hash || d == Ch.gt || d == Ch.backtick || d == Ch.tilde { return false }
            if (d == Ch.minus || d == Ch.plus || d == Ch.star) && first + 1 < range.upperBound && isSpace(ctx.text[first + 1]) {
                return false
            }
            var index = first
            while index < range.upperBound {
                let e = ctx.text[index]
                if e == Ch.backslash { index += 2; continue }
                if e == c {
                    var run = 0
                    while index + run < range.upperBound, ctx.text[index + run] == c { run += 1 }
                    let before = index > range.lowerBound ? ctx.text[index - 1] : Ch.space
                    let after = index + run < range.upperBound ? ctx.text[index + run] : 0
                    let rightFlanking = !isSpace(before) && !(c == Ch.underscore && isAlnum(after))
                    if run >= width, rightFlanking {
                        found = true
                        return false
                    }
                    index += run
                    continue
                }
                index += 1
            }
            return true
        }
        return found
    }

    /// Code spans, emphasis, strong, links, images, autolinks, bare URLs,
    /// inline HTML and escapes, over `base` (the heading colour in a heading).
    /// With `allowCarry`, an emphasis whose closer is on a later line of the
    /// paragraph runs to the end of this line and is returned.
    @discardableResult
    static func inline(_ ctx: inout LexContext, _ from: Int, _ to: Int, base: SyntaxScope, allowCarry: Bool = false) -> Carry? {
        var index = from
        var segment = from
        @inline(__always) func flush(_ ctx: inout LexContext, _ until: Int) {
            if until > segment { ctx.emit(segment, until, base) }
        }
        while index < to {
            let c = ctx[index]
            switch c {
            case Ch.backslash:
                if index + 1 < to, isPunctuation(ctx[index + 1]) {
                    flush(&ctx, index)
                    ctx.emit(index, index + 2, .stringEscape)
                    index += 2
                    segment = index
                    continue
                }
            case Ch.backtick:
                let run = CFamilyLexer.countRun(&ctx, index, to, Ch.backtick)
                if let close = closingBackticks(&ctx, index + run, to, run) {
                    flush(&ctx, index)
                    ctx.emit(index, close + run, .literal)
                    index = close + run
                    segment = index
                    continue
                }
                index += run
                continue
            case Ch.star, Ch.underscore:
                let run = CFamilyLexer.countRun(&ctx, index, to, c)
                let after = index + run < to ? ctx[index + run] : 0
                let before = index > from ? ctx[index - 1] : 0
                let leftFlanking = after != 0 && !isSpace(after) && !(c == Ch.underscore && isAlnum(before))
                if leftFlanking {
                    if run >= 2, let (closeStart, closeRun) = closer(&ctx, c, index + run, to, minimum: 2) {
                        flush(&ctx, index)
                        let end = closeStart + closeRun
                        ctx.emit(index, index + 2, .strong)
                        inline(&ctx, index + 2, end - 2, base: .strong)
                        ctx.emit(end - 2, end, .strong)
                        index = end
                        segment = index
                        continue
                    }
                    if let (closeStart, _) = closer(&ctx, c, index + run, to, minimum: 1) {
                        flush(&ctx, index)
                        ctx.emit(index, index + run, .emphasis)
                        inline(&ctx, index + run, closeStart, base: .emphasis)
                        ctx.emit(closeStart, closeStart + 1, .emphasis)
                        index = closeStart + 1
                        segment = index
                        continue
                    }
                    if allowCarry {
                        let carry = Carry(underscore: c == Ch.underscore, strong: run >= 2)
                        if closesOnALaterLine(&ctx, c, width: carry.width) {
                            flush(&ctx, index)
                            ctx.emit(index, index + run, carry.scope)
                            inline(&ctx, index + run, to, base: carry.scope)
                            return carry
                        }
                    }
                }
                index += run
                continue
            case Ch.bang, Ch.lbracket:
                let open = c == Ch.bang ? index + 1 : index
                if open < to, ctx[open] == Ch.lbracket, let end = link(&ctx, index, open, to, base: base, flushFrom: segment) {
                    index = end
                    segment = end
                    continue
                }
            case Ch.lt:
                if let end = autolinkOrHTML(&ctx, index, to, segment: segment, base: base) {
                    index = end
                    segment = end
                    continue
                }
            case u("h"), u("w"):
                if index == from || !isAlnum(ctx[index - 1]),
                   ctx.matches("https://", at: index) || ctx.matches("http://", at: index) || ctx.matches("www.", at: index) {
                    var end = index
                    while end < to, !isSpace(ctx[end]), ctx[end] != Ch.lt { end += 1 }
                    while end > index, [Ch.dot, Ch.comma, Ch.colon, Ch.semicolon, Ch.bang, Ch.question, Ch.rparen, Ch.squote, Ch.dquote, Ch.star, Ch.underscore].contains(ctx[end - 1]) {
                        end -= 1
                    }
                    flush(&ctx, index)
                    ctx.emit(index, end, .uri)
                    index = end
                    segment = end
                    continue
                }
            default:
                break
            }
            index += 1
        }
        flush(&ctx, to)
        return nil
    }

    private static func closingBackticks(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ run: Int) -> Int? {
        var index = from
        while index < to {
            if ctx[index] == Ch.backtick {
                let length = CFamilyLexer.countRun(&ctx, index, to, Ch.backtick)
                if length == run { return index }
                index += length
                continue
            }
            index += 1
        }
        return nil
    }

    /// A right-flanking run of `c` at least `minimum` long.
    private static func closer(_ ctx: inout LexContext, _ c: UInt16, _ from: Int, _ to: Int, minimum: Int) -> (Int, Int)? {
        var index = from
        while index < to {
            let d = ctx[index]
            if d == Ch.backslash { index += 2; continue }
            if d == Ch.backtick {
                let run = CFamilyLexer.countRun(&ctx, index, to, Ch.backtick)
                if let close = closingBackticks(&ctx, index + run, to, run) { index = close + run } else { index += run }
                continue
            }
            if d == c {
                let run = CFamilyLexer.countRun(&ctx, index, to, c)
                let before = ctx[index - 1]
                let after = index + run < to ? ctx[index + run] : 0
                let rightFlanking = index > from && !isSpace(before) && !(c == Ch.underscore && isAlnum(after))
                if run >= minimum, rightFlanking { return (index, run) }
                index += run
                continue
            }
            index += 1
        }
        return nil
    }

    private static func matchingBracket(_ ctx: inout LexContext, _ from: Int, _ to: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var index = from
        while index < to {
            let c = ctx[index]
            if c == Ch.backslash { index += 2; continue }
            if c == Ch.backtick {
                let run = CFamilyLexer.countRun(&ctx, index, to, Ch.backtick)
                if let end = closingBackticks(&ctx, index + run, to, run) { index = end + run } else { index += run }
                continue
            }
            if c == open { depth += 1 }
            if c == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// `[text](dest "title")`, `![alt](src)`, `[text][ref]`, `[^note]`.
    private static func link(
        _ ctx: inout LexContext, _ start: Int, _ open: Int, _ to: Int, base: SyntaxScope, flushFrom: Int
    ) -> Int? {
        guard let close = matchingBracket(&ctx, open, to, open: Ch.lbracket, close: Ch.rbracket) else { return nil }
        let isFootnote = open + 1 < close && ctx[open + 1] == Ch.caret
        let after = close + 1 < to ? ctx[close + 1] : 0
        guard after == Ch.lparen || after == Ch.lbracket || isFootnote else { return nil }
        var destinationClose: Int? = nil
        if after == Ch.lparen {
            destinationClose = matchingBracket(&ctx, close + 1, to, open: Ch.lparen, close: Ch.rparen)
            guard destinationClose != nil else { return nil }
        } else if after == Ch.lbracket {
            destinationClose = ctx.find("]", from: close + 2, to: to)
            guard destinationClose != nil else { return nil }
        }
        if start > flushFrom { ctx.emit(flushFrom, start, base) }
        ctx.emit(start, open + 1, base)
        inline(&ctx, open + 1, close, base: .reference)
        guard let destinationEnd = destinationClose else {
            return close + 1
        }
        if after == Ch.lbracket {
            ctx.emit(close + 2, destinationEnd, .reference)
            return destinationEnd + 1
        }
        let destination = ctx.skipSpaces(close + 2, destinationEnd)
        var urlEnd = destination
        if destination < destinationEnd, ctx[destination] == Ch.lt {
            while urlEnd < destinationEnd, ctx[urlEnd] != Ch.gt { urlEnd += 1 }
            urlEnd = min(destinationEnd, urlEnd + 1)
        } else {
            while urlEnd < destinationEnd, !isSpace(ctx[urlEnd]) { urlEnd += 1 }
        }
        ctx.emit(destination, urlEnd, .uri)
        let title = ctx.skipSpaces(urlEnd, destinationEnd)
        if title < destinationEnd { ctx.emit(title, destinationEnd, .string) }
        return destinationEnd + 1
    }

    private static func autolinkOrHTML(_ ctx: inout LexContext, _ index: Int, _ to: Int, segment: Int, base: SyntaxScope) -> Int? {
        guard index + 1 < to else { return nil }
        guard let close = ctx.find(">", from: index + 1, to: to) else { return nil }
        let first = ctx[index + 1]
        // Autolink: <scheme:…> or <user@host>.
        if isAsciiLetter(first) {
            var scheme = index + 1
            while scheme < close, isAlnum(ctx[scheme]) || ctx[scheme] == Ch.plus || ctx[scheme] == Ch.dot || ctx[scheme] == Ch.minus { scheme += 1 }
            let hasSpace = ctx.find(" ", from: index + 1, to: close) != nil
            if !hasSpace, scheme < close, ctx[scheme] == Ch.colon || ctx[scheme] == Ch.at || ctx.find("@", from: index + 1, to: close) != nil {
                if index > segment { ctx.emit(segment, index, base) }
                ctx.emit(index, close + 1, .uri)
                return close + 1
            }
        }
        // Inline HTML.
        if isAsciiLetter(first) || first == Ch.slash || first == Ch.bang || first == Ch.question {
            if index > segment { ctx.emit(segment, index, base) }
            var scratch = LexState()
            MarkupLexer.lex(.html, &ctx, index, close + 1, &scratch)
            return close + 1
        }
        return nil
    }
}
