/// POSIX shell / bash / zsh. The shape that matters is the command: the first
/// word of each simple command is the program being run, and that is what gets
/// the function colour. Quotes, `$(…)`, backticks and heredocs may all span
/// lines, so each is a frame.
enum BashLexer {
    private static let fDouble: UInt8 = 1
    private static let fSingle: UInt8 = 2       // payload 1: $'…' (escapes)
    private static let fSubst: UInt8 = 3        // $( … ) — payload: paren depth
    private static let fBacktick: UInt8 = 4
    private static let fHeredoc: UInt8 = 5      // payload: 1 = <<-, 2 = quoted (no expansion)
    private static let fHeredocPending: UInt8 = 6
    /// The line ended in `\` mid-command: the next line continues its
    /// arguments, it does not start a new command.
    private static let fArguments: UInt8 = 7

    private static let keywords = WordTable([(.keyword, [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do", "done",
        "in", "function", "time", "coproc", "!", "[[", "]]",
    ])])
    /// After these, the next word is a command again.
    private static let commandIntroducers = WordTable([(.keyword, [
        "if", "then", "else", "elif", "while", "until", "do", "time", "!", "coproc", "exec", "sudo",
        "command", "builtin", "nohup", "env", "xargs",
    ])])
    private static let builtins = WordTable([(.functionBuiltin, [
        "alias", "bg", "bind", "break", "builtin", "caller", "cd", "command", "compgen", "complete",
        "continue", "declare", "dirs", "disown", "echo", "enable", "eval", "exec", "exit", "export", "false",
        "fc", "fg", "getopts", "hash", "help", "history", "jobs", "kill", "let", "local", "logout", "popd",
        "printf", "pushd", "pwd", "read", "readonly", "return", "set", "shift", "shopt", "source", "suspend",
        "test", "times", "trap", "true", "type", "typeset", "ulimit", "umask", "unalias", "unset", "wait",
    ])])

    struct Context {
        var commandPosition = true
        var afterAssignment = false
        var defFunction = false
        var forLoop = false
    }

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        var context = Context()
        if let top = state.top, frameKind(top) == fArguments {
            state.pop()
            context.commandPosition = false
        }
        while pos < to {
            guard let top = state.top else {
                pos = code(&ctx, pos, to, &state, &context)
                continue
            }
            switch frameKind(top) {
            case fDouble: pos = double(&ctx, pos, to, &state)
            case fSingle: pos = single(&ctx, pos, to, &state)
            case fHeredoc: pos = heredoc(&ctx, pos, to, &state)
            default: pos = code(&ctx, pos, to, &state, &context)
            }
        }
        // `cmd arg \` — the next line is more arguments.
        if to == ctx.lineEnd, !context.commandPosition, state.stack.count < 64,
           state.top.map({ frameKind($0) == fSubst || frameKind($0) == fBacktick }) ?? true {
            var end = to
            while end > from, isSpace(ctx[end - 1]) { end -= 1 }
            if end > from, ctx[end - 1] == Ch.backslash, !(end - 2 >= from && ctx[end - 2] == Ch.backslash) {
                state.push(frame(fArguments))
            }
        }
    }

    static func finishLine(_ state: inout LexState) {
        if let pending = state.stack.lastIndex(where: { frameKind($0) == fHeredocPending }) {
            state.stack[pending] = frame(fHeredoc, framePayload(state.stack[pending]))
            state.stack.removeSubrange((pending + 1)...)
        }
    }

    /// Is the shell somewhere a line break does not end the command — inside
    /// quotes, a substitution or a heredoc? Dockerfile uses it to decide that
    /// the next line still belongs to `RUN`.
    static func isOpen(_ state: LexState) -> Bool { !state.stack.isEmpty }

    @inline(__always) private static func isWordBreak(_ c: UInt16) -> Bool {
        isSpace(c) || c == Ch.semicolon || c == Ch.amp || c == Ch.pipe || c == Ch.lparen || c == Ch.rparen
            || c == Ch.lt || c == Ch.gt || c == Ch.dquote || c == Ch.squote || c == Ch.dollar
            || c == Ch.backtick || c == Ch.backslash
    }

    private static func code(
        _ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState, _ context: inout Context
    ) -> Int {
        var pos = from
        var wordStart = true
        while pos < to {
            let c = ctx[pos]
            let next = pos + 1 < to ? ctx[pos + 1] : 0

            if isSpace(c) {
                if context.afterAssignment {
                    context.afterAssignment = false
                    context.commandPosition = true
                }
                wordStart = true
                pos += 1
                continue
            }

            if c == Ch.hash && wordStart {
                ctx.emit(pos, to, .comment)
                return to
            }

            if c == Ch.backslash {
                pos += 2
                wordStart = false
                continue
            }

            if c == Ch.dquote {
                ctx.emit(pos, pos + 1, .string)
                if push(&state, frame(fDouble)) { return pos + 1 }
                pos += 1
                continue
            }
            if c == Ch.squote {
                ctx.emit(pos, pos + 1, .string)
                if push(&state, frame(fSingle)) { return pos + 1 }
                pos += 1
                continue
            }
            if c == Ch.dollar && next == Ch.squote {
                ctx.emit(pos, pos + 2, .string)
                if push(&state, frame(fSingle, 1)) { return pos + 2 }
                pos += 2
                continue
            }
            if c == Ch.dollar {
                if let end = expansion(&ctx, pos, to, &state) {
                    if end < 0 { return -end }
                    pos = end
                    wordStart = false
                    context.commandPosition = false
                    continue
                }
                pos += 1
                continue
            }
            if c == Ch.backtick {
                if let top = state.top, frameKind(top) == fBacktick {
                    state.pop()
                    ctx.emit(pos, pos + 1, .punctuationSpecial)
                    return pos + 1
                }
                ctx.emit(pos, pos + 1, .punctuationSpecial)
                if push(&state, frame(fBacktick)) { return pos + 1 }
                pos += 1
                continue
            }

            // Heredocs (not here-strings).
            if c == Ch.lt, next == Ch.lt, !(pos + 2 < to && ctx[pos + 2] == Ch.lt),
               let end = heredocOpen(&ctx, pos, to, &state) {
                pos = end
                wordStart = true
                continue
            }

            // Command separators put us back in command position.
            // `>&2`, `2>&1`, `&>file` are redirections, not `&`.
            if c == Ch.amp, next == Ch.gt || (pos > ctx.lineStart && (ctx[pos - 1] == Ch.gt || ctx[pos - 1] == Ch.lt)) {
                pos += 1
                var end = pos
                while end < to, isDigit(ctx[end]) || ctx[end] == Ch.minus { end += 1 }
                if end > pos { ctx.emit(pos, end, .number) }
                pos = end
                wordStart = true
                continue
            }
            if c == Ch.semicolon || c == Ch.amp || c == Ch.pipe || c == Ch.lparen || c == Ch.lbrace
                || (c == Ch.bang && wordStart) {
                if c == Ch.lparen, let top = state.top, frameKind(top) == fSubst {
                    state.replaceTop(frame(fSubst, framePayload(top) + 1))
                }
                context.commandPosition = true
                context.afterAssignment = false
                pos += 1
                wordStart = true
                continue
            }
            if c == Ch.rparen {
                if let top = state.top, frameKind(top) == fSubst {
                    let depth = framePayload(top)
                    if depth == 0 {
                        state.pop()
                        var end = pos + 1
                        if end < to, ctx[end] == Ch.rparen { end += 1 }
                        ctx.emit(pos, end, .punctuationSpecial)
                        return end
                    }
                    state.replaceTop(frame(fSubst, depth - 1))
                }
                pos += 1
                wordStart = true
                continue
            }
            if c == Ch.lt || c == Ch.gt || c == Ch.rbrace {
                pos += 1
                wordStart = true
                continue
            }

            // A bare word chunk.
            var end = pos
            while end < to {
                let d = ctx[end]
                if isWordBreak(d) { break }
                if d == Ch.eq, end > pos, context.commandPosition, isAssignmentName(&ctx, pos, end) { break }
                end += 1
            }
            if end == pos { pos += 1; continue }

            // `NAME=value` in command position.
            if end < to, ctx[end] == Ch.eq, context.commandPosition, wordStart {
                ctx.emit(pos, end, .variableSpecial)
                pos = end + 1
                context.commandPosition = false
                context.afterAssignment = true
                wordStart = false
                continue
            }

            if wordStart, let keyword = keywords.lookup(ctx.text, pos, end), context.commandPosition || isLoopWord(&ctx, pos, end, context) {
                ctx.emit(pos, end, keyword)
                let length = end - pos
                if length == 8, ctx.matches("function", at: pos) {
                    context.defFunction = true
                    context.commandPosition = false
                } else if (length == 3 && ctx.matches("for", at: pos)) || (length == 6 && ctx.matches("select", at: pos))
                            || (length == 4 && ctx.matches("case", at: pos)) {
                    context.forLoop = true
                    context.commandPosition = false
                } else if length == 2, ctx.matches("in", at: pos) {
                    context.forLoop = false
                    context.commandPosition = false
                } else {
                    context.commandPosition = commandIntroducers.lookup(ctx.text, pos, end) != nil
                }
            } else if context.defFunction {
                ctx.emit(pos, end, .function)
                context.defFunction = false
            } else if context.commandPosition && wordStart && end < to && ctx[end] == Ch.rparen
                        && !(state.top.map(frameKind) == fSubst) {
                // A `case` pattern: `start)`, `*.txt|*.md)`.
                context.commandPosition = true
            } else if context.commandPosition && wordStart {
                let isDefinition = ctx.nextNonSpace(end, to) == Ch.lparen
                    && ctx.skipSpaces(end, to) + 1 < to && ctx[ctx.skipSpaces(end, to) + 1] == Ch.rparen
                let scope: SyntaxScope = isDefinition ? .function
                    : builtins.lookup(ctx.text, pos, end) != nil ? .functionBuiltin : .function
                ctx.emit(pos, end, scope)
                context.commandPosition = commandIntroducers.lookup(ctx.text, pos, end) != nil
            } else if allDigits(&ctx, pos, end) {
                ctx.emit(pos, end, .number)
            } else if ctx[pos] == Ch.minus, !context.forLoop {
                ctx.emit(pos, end, .constant)
            }
            wordStart = false
            pos = end
        }
        return pos
    }

    private static func isLoopWord(_ ctx: inout LexContext, _ start: Int, _ end: Int, _ context: Context) -> Bool {
        context.forLoop && end - start == 2 && ctx.matches("in", at: start)
    }

    private static func isAssignmentName(_ ctx: inout LexContext, _ start: Int, _ end: Int) -> Bool {
        guard isIdentifierStart(ctx[start]) else { return false }
        for index in start..<end where !isIdentifierPart(ctx[index]) {
            // `arr[3]=x`
            if ctx[index] == Ch.lbracket || ctx[index] == Ch.rbracket || ctx[index] == Ch.plus { continue }
            return false
        }
        return true
    }

    private static func allDigits(_ ctx: inout LexContext, _ start: Int, _ end: Int) -> Bool {
        for index in start..<end where !isDigit(ctx[index]) { return false }
        return true
    }

    private static func push(_ state: inout LexState, _ value: UInt32) -> Bool {
        guard state.stack.count < 64 else { return false }
        state.push(value)
        return true
    }

    /// `$name`, `${…}`, `$1`, `$@`, `$(…)`, `$((…))`. Returns the end, a
    /// negated position when a frame was pushed, or nil when `$` is literal.
    private static func expansion(_ ctx: inout LexContext, _ pos: Int, _ to: Int, _ state: inout LexState) -> Int? {
        guard pos + 1 < to else { return nil }
        let next = ctx[pos + 1]
        if next == Ch.lparen {
            let arithmetic = pos + 2 < to && ctx[pos + 2] == Ch.lparen
            let open = pos + (arithmetic ? 3 : 2)
            ctx.emit(pos, open, .punctuationSpecial)
            guard push(&state, frame(fSubst, arithmetic ? 0 : 0)) else { return open }
            return -open
        }
        if next == Ch.lbrace {
            var depth = 0
            var end = pos + 1
            while end < to {
                if ctx[end] == Ch.lbrace { depth += 1 }
                if ctx[end] == Ch.rbrace { depth -= 1; if depth == 0 { end += 1; break } }
                end += 1
            }
            ctx.emit(pos, end, .variableSpecial)
            return end
        }
        if isIdentifierStart(next) {
            let end = ctx.scanIdentifier(pos + 1, to)
            ctx.emit(pos, end, .variableSpecial)
            return end
        }
        if isDigit(next) || next == Ch.at || next == Ch.star || next == Ch.hash || next == Ch.question
            || next == Ch.dollar || next == Ch.bang || next == Ch.minus {
            ctx.emit(pos, pos + 2, .variableSpecial)
            return pos + 2
        }
        return nil
    }

    private static func double(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        var index = from
        var segment = from
        while index < to {
            let c = ctx[index]
            if c == Ch.dquote {
                ctx.emit(segment, index + 1, .string)
                state.pop()
                return index + 1
            }
            if c == Ch.backslash, index + 1 < to {
                let n = ctx[index + 1]
                if n == Ch.dquote || n == Ch.backslash || n == Ch.dollar || n == Ch.backtick {
                    ctx.emit(segment, index, .string)
                    ctx.emit(index, index + 2, .stringEscape)
                    segment = index + 2
                }
                index += 2
                continue
            }
            if c == Ch.dollar {
                ctx.emit(segment, index, .string)
                if let end = expansion(&ctx, index, to, &state) {
                    if end < 0 { return -end }
                    index = end
                    segment = end
                    continue
                }
                segment = index
            }
            if c == Ch.backtick {
                ctx.emit(segment, index, .string)
                ctx.emit(index, index + 1, .punctuationSpecial)
                if push(&state, frame(fBacktick)) { return index + 1 }
                segment = index + 1
            }
            index += 1
        }
        ctx.emit(segment, to, .string)
        return to
    }

    private static func single(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        let escapes = framePayload(state.top ?? 0) == 1
        var index = from
        var segment = from
        while index < to {
            let c = ctx[index]
            if escapes, c == Ch.backslash, index + 1 < to {
                ctx.emit(segment, index, .string)
                let end = CFamilyLexer.escapeEnd(&ctx, index + 1, to)
                ctx.emit(index, end, .stringEscape)
                index = end
                segment = end
                continue
            }
            if c == Ch.squote {
                ctx.emit(segment, index + 1, .string)
                state.pop()
                return index + 1
            }
            index += 1
        }
        ctx.emit(segment, to, .string)
        return to
    }

    private static func heredocOpen(_ ctx: inout LexContext, _ pos: Int, _ to: Int, _ state: inout LexState) -> Int? {
        var index = pos + 2
        var mode: UInt32 = 0
        if index < to, ctx[index] == Ch.minus { mode |= 1; index += 1 }
        index = ctx.skipSpaces(index, to)
        var quote: UInt16 = 0
        if index < to, ctx[index] == Ch.squote || ctx[index] == Ch.dquote {
            quote = ctx[index]
            index += 1
            mode |= 2
        } else if index < to, ctx[index] == Ch.backslash {
            index += 1
            mode |= 2
        }
        var nameEnd = index
        while nameEnd < to, !isWordBreak(ctx[nameEnd]) || (quote != 0 && ctx[nameEnd] != quote && ctx[nameEnd] != Ch.space) {
            nameEnd += 1
        }
        guard nameEnd > index else { return nil }
        var end = nameEnd
        if quote != 0 {
            guard end < to, ctx[end] == quote else { return nil }
            end += 1
        }
        guard push(&state, frame(fHeredocPending, mode)) else { return nil }
        ctx.emit(pos, end, .string)
        state.text = ctx.slice(index, nameEnd)
        return end
    }

    private static func heredoc(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) -> Int {
        let mode = framePayload(state.top ?? 0)
        if from == ctx.lineStart {
            var start = from
            if mode & 1 != 0 { while start < to, ctx[start] == Ch.tab { start += 1 } }
            if ctx.matches(state.text, at: start), start + state.text.count == to {
                ctx.emit(start, to, .string)
                state.pop()
                state.text.removeAll()
                return to
            }
        }
        if mode & 2 != 0 {
            ctx.emit(from, to, .string)
            return to
        }
        var index = from
        var segment = from
        while index < to {
            let c = ctx[index]
            if c == Ch.backslash {
                index += 2
                continue
            }
            if c == Ch.dollar {
                ctx.emit(segment, index, .string)
                var scratch = LexState()
                if let end = expansion(&ctx, index, to, &scratch) {
                    let resume = end < 0 ? substitutionEnd(&ctx, -end, to) : end
                    index = resume
                    segment = resume
                    continue
                }
                segment = index
            }
            index += 1
        }
        ctx.emit(segment, to, .string)
        return to
    }

    /// `$(` inside a heredoc: lex the command up to its `)` on this line.
    private static func substitutionEnd(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int {
        var depth = 0
        var end = from
        while end < to {
            if ctx[end] == Ch.lparen { depth += 1 }
            if ctx[end] == Ch.rparen { if depth == 0 { break }; depth -= 1 }
            end += 1
        }
        var scratch = LexState()
        var context = Context()
        _ = code(&ctx, from, end, &scratch, &context)
        if end < to { ctx.emit(end, end + 1, .punctuationSpecial) }
        return min(to, end + 1)
    }
}
