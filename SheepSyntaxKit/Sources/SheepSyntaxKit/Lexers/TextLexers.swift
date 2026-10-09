// Diff, log files and SQL.

// MARK: - Diff

/// Unified diffs, `git diff` / `git show` / `git format-patch` output.
///
/// Inside a hunk the header's line counts say exactly how many old and new
/// lines follow, so a removed line that happens to start `--- ` is still a
/// removal, not a file header. Outside a hunk, `+`/`-` lines are still
/// coloured, for loose patches with no header at all.
enum DiffLexer {
    private static let fHunk: UInt8 = 1   // payload: old lines left | new lines left << 12

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        guard from < to else {
            // A blank line inside a hunk is a context line some tools strip.
            consume(&state, old: true, new: true)
            return
        }
        let c = ctx[from]

        if let top = state.top, frameKind(top) == fHunk {
            switch c {
            case Ch.plus:
                ctx.emit(from, to, .diffPlus)
                consume(&state, old: false, new: true)
                return
            case Ch.minus:
                ctx.emit(from, to, .diffMinus)
                consume(&state, old: true, new: false)
                return
            case Ch.space:
                consume(&state, old: true, new: true)
                return
            case Ch.backslash:
                ctx.emit(from, to, .comment)   // "\ No newline at end of file"
                return
            default:
                state.pop()
            }
        }

        if ctx.matches("@@", at: from) {
            hunkHeader(&ctx, from, to, &state)
            return
        }
        if (ctx.matches("--- ", at: from) || ctx.matches("+++ ", at: from) || ctx.matches("*** ", at: from)) {
            ctx.emit(from, to, .diffHeader)
            return
        }
        if ctx.matches("diff ", at: from) || ctx.matches("index ", at: from) || ctx.matches("similarity index", at: from)
            || ctx.matches("rename ", at: from) || ctx.matches("new file mode", at: from)
            || ctx.matches("deleted file mode", at: from) || ctx.matches("old mode", at: from)
            || ctx.matches("new mode", at: from) || ctx.matches("copy ", at: from) || ctx.matches("Binary files", at: from)
            || ctx.matches("Only in ", at: from) {
            ctx.emit(from, to, .keyword)
            return
        }
        if ctx.matches("commit ", at: from) {
            ctx.emit(from, from + 6, .keyword)
            ctx.emit(from + 7, to, .constant)
            return
        }
        if ctx.matches("Author:", at: from) || ctx.matches("Date:", at: from) || ctx.matches("Merge:", at: from)
            || ctx.matches("From ", at: from) || ctx.matches("Subject:", at: from) {
            let colon = ctx.find(":", from: from, to: to) ?? (from + 4)
            ctx.emit(from, colon + 1, .keyword)
            return
        }
        switch c {
        case Ch.plus: ctx.emit(from, to, .diffPlus)
        case Ch.minus: ctx.emit(from, to, .diffMinus)
        case Ch.gt: ctx.emit(from, to, .diffPlus)     // normal diff format
        case Ch.lt: ctx.emit(from, to, .diffMinus)
        case Ch.bang: ctx.emit(from, to, .diffDelta)  // context diff
        default:
            if isDigit(c) { normalDiffCommand(&ctx, from, to) }
        }
    }

    private static func consume(_ state: inout LexState, old: Bool, new: Bool) {
        guard let top = state.top, frameKind(top) == fHunk else { return }
        var oldLeft = framePayload(top) & 0xFFF
        var newLeft = framePayload(top) >> 12
        if old, oldLeft > 0 { oldLeft -= 1 }
        if new, newLeft > 0 { newLeft -= 1 }
        if oldLeft == 0 && newLeft == 0 {
            state.pop()
        } else {
            state.replaceTop(frame(fHunk, oldLeft | (newLeft << 12)))
        }
    }

    /// `@@ -12,7 +12,9 @@ func context()`.
    private static func hunkHeader(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        let close = ctx.find("@@", from: from + 2, to: to).map { $0 + 2 } ?? to
        ctx.emit(from, close, .diffDelta)
        if close < to { ctx.emit(close, to, .function) }
        let counts = numbers(&ctx, from + 2, close)
        guard counts.count >= 2 else { return }
        // -a,b +c,d; a missing count means 1.
        var oldCount = 1
        var newCount = 1
        var index = 0
        var sign: UInt16 = 0
        var cursor = from + 2
        var seenOld = false
        var seenNew = false
        while cursor < close {
            let unit = ctx[cursor]
            if unit == Ch.minus && !seenOld { sign = Ch.minus; seenOld = true; index = 0 }
            else if unit == Ch.plus && !seenNew { sign = Ch.plus; seenNew = true; index = 0 }
            else if isDigit(unit) {
                var value = 0
                while cursor < close, isDigit(ctx[cursor]) {
                    value = min(value * 10 + Int(ctx[cursor] - 0x30), 0xFFF)
                    cursor += 1
                }
                if index == 1 {
                    if sign == Ch.minus { oldCount = value } else if sign == Ch.plus { newCount = value }
                }
                index += 1
                continue
            } else if unit == Ch.comma {
                index = 1
            }
            cursor += 1
        }
        if oldCount > 0 || newCount > 0 {
            state.push(frame(fHunk, UInt32(oldCount) | (UInt32(newCount) << 12)))
        }
    }

    private static func numbers(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> [Int] {
        var out: [Int] = []
        var index = from
        while index < to {
            if isDigit(ctx[index]) {
                var value = 0
                while index < to, isDigit(ctx[index]) { value = value &* 10 &+ Int(ctx[index] - 0x30); index += 1 }
                out.append(value)
                continue
            }
            index += 1
        }
        return out
    }

    /// `12,14c12,15` in `diff` normal format.
    private static func normalDiffCommand(_ ctx: inout LexContext, _ from: Int, _ to: Int) {
        var index = from
        while index < to, isDigit(ctx[index]) || ctx[index] == Ch.comma { index += 1 }
        guard index < to, ctx[index] == u("a") || ctx[index] == u("c") || ctx[index] == u("d") else { return }
        index += 1
        while index < to, isDigit(ctx[index]) || ctx[index] == Ch.comma { index += 1 }
        if index == to { ctx.emit(from, to, .diffDelta) }
    }
}

// MARK: - Log

/// SheepText's log language. This is the `besttext_log` grammar that used to
/// be a tree-sitter package in this repository, ported rule for rule: the
/// same token classes, the same precedence order, the same scopes. The one
/// deliberate difference: a severity or keyword must be a whole word, so
/// `download` is no longer `down` + `load` and `errors` is still an error.
enum LogLexer {
    private static let severityError = WordTable([(.logError, [
        "emergency", "alert", "critical", "crit", "error", "err", "failed", "fail", "failure", "down",
        "deny", "denied", "block", "blocked", "disable", "disabled", "errors", "fatal", "panic", "exception",
    ])], caseInsensitive: true)
    private static let severityWarning = WordTable([(.logWarning, ["warning", "warn", "warnings"])], caseInsensitive: true)
    private static let severitySuccess = WordTable([(.logSuccess, [
        "ok", "okay", "done", "pass", "passed", "allow", "allowed", "enable", "enabled", "permit", "permits",
        "permitted", "permite", "up", "success", "succeeded", "successful",
    ])], caseInsensitive: true)
    private static let networkKeywords = WordTable([(.keyword, [
        "notice", "info", "debug", "trace", "interface", "hostname", "router", "route", "access-list", "acl",
        "ip", "ipv6", "address", "mac", "arp", "nat", "dhcp", "snmp", "ntp", "dns", "vrf", "ospf", "bgp",
        "vrrp", "hsrp", "lacp", "stp", "ssh", "telnet", "show", "set", "config", "configuration", "shutdown",
        "description",
    ])], caseInsensitive: true)
    private static let interfacePrefixes: [StaticString] = [
        "tengigabitethernet", "gigabitethernet", "fastethernet", "port-channel", "management", "ethernet",
        "loopback", "tunnel", "vlan", "mgmt", "eth", "hu", "fo", "te", "gi", "fa", "po", "lo",
    ]
    private static let months: [StaticString] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        while pos < to {
            let c = ctx[pos]
            if isSpace(c) { pos += 1; continue }

            if isDigit(c) || isHexDigit(c) || isAsciiLetter(c) {
                // Highest precedence first, as the grammar declared them.
                if let end = timestamp(&ctx, pos, to) { ctx.emit(pos, end, .comment); pos = end; continue }
                if let end = ipv4(&ctx, pos, to) { ctx.emit(pos, end, .function); pos = end; continue }
                if let end = mac(&ctx, pos, to) { ctx.emit(pos, end, .string); pos = end; continue }
                if let end = ipv6(&ctx, pos, to) { ctx.emit(pos, end, .type); pos = end; continue }
                if let end = vlan(&ctx, pos, to) { ctx.emit(pos, end, .constant); pos = end; continue }
                if let end = interfaceName(&ctx, pos, to) { ctx.emit(pos, end, .property); pos = end; continue }
            }

            if isAsciiLetter(c) || c == Ch.underscore {
                // `no shutdown` is a success.
                if ctx.matches("no", at: pos, caseInsensitive: true), pos + 2 < to, isSpace(ctx[pos + 2]) {
                    let word = ctx.skipSpaces(pos + 2, to)
                    if ctx.matches("shutdown", at: word, caseInsensitive: true), !isIdentifierPart(ctx.at(word + 8)) {
                        ctx.emit(pos, word + 8, .logSuccess)
                        pos = word + 8
                        continue
                    }
                }
                // prompt: `switch1#`, `router>` — the longer token wins over a
                // keyword of the same precedence, as the grammar's lexer did.
                let promptEnd = scanWord(&ctx, pos, to)
                if promptEnd < to, ctx[promptEnd] == Ch.hash || ctx[promptEnd] == Ch.gt,
                   promptEnd + 1 >= to || isSpace(ctx[promptEnd + 1]) {
                    // Captured as `@operator`, the base foreground: consumed, not painted.
                    pos = promptEnd + 1
                    continue
                }
                // Keyword classes need the whole word.
                var wordEnd = pos
                while wordEnd < to, isAlnum(ctx[wordEnd]) || (ctx[wordEnd] == Ch.minus && wordEnd + 1 < to && isAsciiLetter(ctx[wordEnd + 1])) {
                    wordEnd += 1
                }
                let boundary = wordEnd >= to || !(isAlnum(ctx[wordEnd]) || ctx[wordEnd] == Ch.underscore)
                if boundary {
                    if let s = severityError.lookup(ctx.text, pos, wordEnd) ?? severityWarning.lookup(ctx.text, pos, wordEnd)
                        ?? severitySuccess.lookup(ctx.text, pos, wordEnd) ?? networkKeywords.lookup(ctx.text, pos, wordEnd) {
                        ctx.emit(pos, wordEnd, s)
                        pos = wordEnd
                        continue
                    }
                }
                pos = promptEnd
                continue
            }
            if isDigit(c) {
                var end = pos
                while end < to, isDigit(ctx[end]) { end += 1 }
                if end + 1 < to, ctx[end] == Ch.dot, isDigit(ctx[end + 1]) {
                    end += 1
                    while end < to, isDigit(ctx[end]) { end += 1 }
                }
                ctx.emit(pos, end, .number)
                pos = end
                continue
            }
            pos += 1
        }
    }

    private static func scanWord(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int {
        var end = from
        while end < to {
            let c = ctx[end]
            if isAlnum(c) || c == Ch.underscore || c == Ch.dot || c == Ch.at || c == Ch.slash || c == Ch.minus { end += 1 } else { break }
        }
        return end
    }

    private static func digits(_ ctx: inout LexContext, _ from: Int, _ to: Int, min: Int, max: Int) -> Int? {
        var end = from
        while end < to, end - from < max, isDigit(ctx[end]) { end += 1 }
        return end - from >= min ? end : nil
    }

    private static func expect(_ ctx: inout LexContext, _ at: Int, _ to: Int, _ unit: UInt16) -> Int? {
        at < to && ctx[at] == unit ? at + 1 : nil
    }

    /// `2026-09-27 10:11:12.123Z`, `10:11:12`, `Sep 27 10:11:12`.
    private static func timestamp(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int? {
        func clock(_ at: Int) -> Int? {
            guard var i = digits(&ctx, at, to, min: 2, max: 2), let a = expect(&ctx, i, to, Ch.colon),
                  let b = digits(&ctx, a, to, min: 2, max: 2), let c = expect(&ctx, b, to, Ch.colon),
                  let d = digits(&ctx, c, to, min: 2, max: 2) else { return nil }
            i = d
            if i < to, ctx[i] == Ch.dot, let f = digits(&ctx, i + 1, to, min: 1, max: 9) { i = f }
            return i
        }
        if isDigit(ctx[from]) {
            if let y = digits(&ctx, from, to, min: 4, max: 4), let a = expect(&ctx, y, to, Ch.minus),
               let m = digits(&ctx, a, to, min: 2, max: 2), let b = expect(&ctx, m, to, Ch.minus),
               let d = digits(&ctx, b, to, min: 2, max: 2), d < to, ctx[d] == Ch.space || ctx[d] == u("T"),
               var end = clock(d + 1) {
                if end < to, ctx[end] == u("Z") { end += 1 }
                else if end < to, ctx[end] == Ch.plus || ctx[end] == Ch.minus,
                        let h = digits(&ctx, end + 1, to, min: 2, max: 2) {
                    var z = h
                    if z < to, ctx[z] == Ch.colon { z += 1 }
                    if let mm = digits(&ctx, z, to, min: 2, max: 2) { end = mm }
                }
                return end
            }
            return clock(from)
        }
        for month in months where ctx.matches(month, at: from) {
            var i = from + 3
            guard i < to, isSpace(ctx[i]) else { return nil }
            i = ctx.skipSpaces(i, to)
            guard let day = digits(&ctx, i, to, min: 1, max: 2), day < to, isSpace(ctx[day]) else { return nil }
            return clock(ctx.skipSpaces(day, to))
        }
        return nil
    }

    private static func ipv4(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int? {
        guard isDigit(ctx[from]) else { return nil }
        var i = from
        for part in 0..<4 {
            if part > 0 {
                guard let dot = expect(&ctx, i, to, Ch.dot) else { return nil }
                i = dot
            }
            guard let end = digits(&ctx, i, to, min: 1, max: 3) else { return nil }
            i = end
        }
        if i < to, ctx[i] == Ch.slash, let prefix = digits(&ctx, i + 1, to, min: 1, max: 2) { i = prefix }
        return i
    }

    private static func mac(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int? {
        func hex(_ at: Int, _ count: Int) -> Int? {
            guard at + count <= to else { return nil }
            for i in at..<(at + count) where !isHexDigit(ctx[i]) { return nil }
            return at + count
        }
        for separator in [Ch.colon, Ch.minus] {
            if var i = hex(from, 2) {
                var ok = true
                for _ in 0..<5 {
                    guard let s = expect(&ctx, i, to, separator), let h = hex(s, 2) else { ok = false; break }
                    i = h
                }
                if ok { return i }
            }
        }
        if let a = hex(from, 4), let d1 = expect(&ctx, a, to, Ch.dot), let b = hex(d1, 4),
           let d2 = expect(&ctx, b, to, Ch.dot), let c = hex(d2, 4) {
            return c
        }
        return nil
    }

    private static func ipv6(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int? {
        var i = from
        var groups = 0
        var colons = 0
        var hexDigits = 0
        while i < to {
            var run = 0
            while i < to, run < 4, isHexDigit(ctx[i]) { i += 1; run += 1 }
            hexDigits += run
            groups += 1
            guard i < to, ctx[i] == Ch.colon, colons < 7 else { break }
            colons += 1
            i += 1
        }
        guard colons >= 2, hexDigits > 0, groups >= 3 else { return nil }
        // Do not swallow the tail of `word::`.
        if i < to, isIdentifierPart(ctx[i]) { return nil }
        if i < to, ctx[i] == Ch.slash, let prefix = digits(&ctx, i + 1, to, min: 1, max: 3) { i = prefix }
        return i
    }

    private static func vlan(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int? {
        guard ctx.matches("vlan", at: from, caseInsensitive: true) else { return nil }
        var i = from + 4
        while i < to, isSpace(ctx[i]) || ctx[i] == Ch.minus { i += 1 }
        return digits(&ctx, i, to, min: 1, max: 4)
    }

    private static func interfaceName(_ ctx: inout LexContext, _ from: Int, _ to: Int) -> Int? {
        for prefix in interfacePrefixes where ctx.matches(prefix, at: from, caseInsensitive: true) {
            var i = from + prefix.utf8CodeUnitCount
            let mgmt = prefix.utf8CodeUnitCount == 4 && ctx.matches("mgmt", at: from, caseInsensitive: true)
            guard let first = digits(&ctx, i, to, min: mgmt ? 0 : 1, max: 8) else { continue }
            i = first
            while i + 1 < to, ctx[i] == Ch.slash || ctx[i] == Ch.dot || ctx[i] == Ch.colon
                    || ctx[i] == Ch.underscore || ctx[i] == Ch.minus,
                  let more = digits(&ctx, i + 1, to, min: 1, max: 8) {
                i = more
            }
            return i
        }
        return nil
    }
}

// MARK: - SQL

/// SQL across the common dialects. Keywords are case-insensitive; `$$`
/// bodies, block comments and quoted strings may span lines.
enum SQLLexer {
    private static let fComment: UInt8 = 1
    private static let fString: UInt8 = 2    // payload: quote
    private static let fDollar: UInt8 = 3    // tag in state.text

    private static let words = WordTable([
        (.keyword, [
            "abort", "action", "add", "after", "all", "alter", "always", "analyze", "and", "any", "as", "asc",
            "attach", "authorization", "autoincrement", "before", "begin", "between", "by", "cascade", "case",
            "cast", "check", "collate", "column", "comment", "commit", "concurrently", "conflict", "constraint",
            "create", "cross", "current", "current_date", "current_time", "current_timestamp", "cursor",
            "database", "declare", "default", "deferrable", "deferred", "delete", "desc", "detach", "distinct",
            "do", "drop", "each", "else", "elsif", "end", "escape", "except", "exclusive", "execute", "exists",
            "explain", "extension", "fetch", "filter", "first", "following", "for", "foreign", "from", "full",
            "function", "generated", "grant", "group", "groups", "having", "if", "ignore", "ilike", "immediate",
            "in", "index", "inner", "insert", "instead", "intersect", "into", "is", "isnull", "join", "key",
            "language", "last", "lateral", "left", "like", "limit", "lock", "loop", "match", "materialized",
            "merge", "natural", "no", "not", "nothing", "notnull", "nulls", "of", "offset", "on", "only", "or",
            "order", "others", "outer", "over", "partition", "plan", "pragma", "preceding", "primary",
            "procedure", "raise", "range", "recursive", "references", "regexp", "reindex", "release", "rename",
            "replace", "restrict", "return", "returning", "returns", "revoke", "right", "rollback", "row",
            "rows", "savepoint", "schema", "select", "sequence", "set", "show", "similar", "table", "temp",
            "temporary", "then", "ties", "to", "transaction", "trigger", "truncate", "unbounded", "union",
            "unique", "unlogged", "update", "use", "using", "vacuum", "values", "view", "virtual", "when",
            "where", "while", "window", "with", "within", "without", "declare", "exec", "go", "top", "output",
            "inserted", "deleted", "engine", "charset", "auto_increment", "unsigned", "zerofill", "owner",
            "security", "definer", "invoker", "immutable", "stable", "volatile", "strict", "setof", "perform",
            "elseif", "leave", "iterate", "handler", "continue", "exit", "signal", "call",
        ]),
        (.typeBuiltin, [
            "array", "bigint", "bigserial", "binary", "bit", "blob", "bool", "boolean", "box", "bytea", "char",
            "character", "cidr", "clob", "date", "datetime", "datetime2", "datetimeoffset", "dec", "decimal",
            "double", "enum", "float", "float4", "float8", "geography", "geometry", "image", "inet", "int",
            "int2", "int4", "int8", "integer", "interval", "json", "jsonb", "line", "longblob", "longtext",
            "macaddr", "mediumblob", "mediumint", "mediumtext", "money", "nchar", "ntext", "number", "numeric",
            "nvarchar", "oid", "point", "polygon", "precision", "real", "regclass", "serial", "smalldatetime",
            "smallint", "smallmoney", "smallserial", "text", "time", "timestamp", "timestamptz", "timetz",
            "tinyblob", "tinyint", "tinytext", "tsquery", "tsvector", "uniqueidentifier", "uuid", "varbinary",
            "varchar", "varchar2", "varying", "xml", "year", "zone",
        ]),
        (.boolean, ["true", "false"]),
        (.constantBuiltin, ["null", "unknown"]),
    ], caseInsensitive: true)

    static func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        var pos = from
        if let top = state.top {
            switch frameKind(top) {
            case fComment:
                guard let end = ctx.find("*/", from: pos, to: to) else { ctx.emit(pos, to, .comment); return }
                ctx.emit(pos, end + 2, .comment)
                state.pop()
                pos = end + 2
            case fString:
                let end = quoted(&ctx, pos, to, UInt16(framePayload(top)), start: pos)
                if end < 0 { return }
                state.pop()
                pos = end
            case fDollar:
                guard let end = findDollarTag(&ctx, pos, to, state.text) else { ctx.emit(pos, to, .string); return }
                ctx.emit(pos, end, .string)
                state.pop()
                state.text.removeAll()
                pos = end
            default:
                state.stack.removeAll()
            }
        }

        var prevDot = false
        var afterRelationKeyword = false
        while pos < to {
            let c = ctx[pos]
            let next = pos + 1 < to ? ctx[pos + 1] : 0
            if isSpace(c) { pos += 1; continue }
            if (c == Ch.minus && next == Ch.minus) || (c == Ch.hash && (next == Ch.space || next == 0)) {
                ctx.emit(pos, to, .comment)
                return
            }
            if c == Ch.slash, next == Ch.star {
                guard let end = ctx.find("*/", from: pos + 2, to: to) else {
                    ctx.emit(pos, to, .comment)
                    state.push(frame(fComment))
                    return
                }
                ctx.emit(pos, end + 2, .comment)
                pos = end + 2
                continue
            }
            if c == Ch.squote || ((c == u("E") || c == u("e") || c == u("N") || c == u("n") || c == u("B") || c == u("X")) && next == Ch.squote) {
                let quote = c == Ch.squote ? pos : pos + 1
                let end = quoted(&ctx, quote + 1, to, Ch.squote, start: pos)
                if end < 0 {
                    state.push(frame(fString, UInt32(Ch.squote)))
                    return
                }
                pos = end
                prevDot = false
                continue
            }
            if c == Ch.dquote || c == Ch.backtick || c == Ch.lbracket {
                // Quoted identifiers.
                let close = c == Ch.lbracket ? Ch.rbracket : c
                var end = pos + 1
                while end < to, ctx[end] != close { end += 1 }
                if c == Ch.lbracket, end >= to { pos += 1; continue }
                end = min(to, end + 1)
                ctx.emit(pos, end, prevDot ? .property : .none)
                pos = end
                prevDot = false
                continue
            }
            if c == Ch.dollar {
                if isDigit(next) {
                    let end = ctx.scanIdentifier(pos + 1, to)
                    ctx.emit(pos, end, .variableParameter)
                    pos = end
                    continue
                }
                // $$ or $tag$
                var end = pos + 1
                while end < to, isIdentifierPart(ctx[end]) { end += 1 }
                if end < to, ctx[end] == Ch.dollar {
                    let tag = ctx.slice(pos, end + 1)
                    if let close = findDollarTag(&ctx, end + 1, to, tag) {
                        ctx.emit(pos, close, .string)
                        pos = close
                        continue
                    }
                    ctx.emit(pos, to, .string)
                    state.text = tag
                    state.push(frame(fDollar))
                    return
                }
            }
            if (c == Ch.at || c == Ch.colon || c == Ch.question) && (isIdentifierStart(next) || c == Ch.question) {
                if c == Ch.colon, pos > ctx.lineStart, ctx[pos - 1] == Ch.colon { pos += 1; continue }
                var start = pos + 1
                if c == Ch.at, next == Ch.at { start += 1 }
                let end = c == Ch.question ? pos + 1 : ctx.scanIdentifier(start, to)
                ctx.emit(pos, end, .variableParameter)
                pos = end
                continue
            }
            if isDigit(c) || (c == Ch.dot && isDigit(next) && !prevDot) {
                let end = CFamilyLexer.scanNumber(&ctx, pos, to)
                ctx.emit(pos, end, .number)
                pos = end
                continue
            }
            if isIdentifierStart(c) {
                let end = ctx.scanIdentifier(pos, to)
                let following = ctx.nextNonSpace(end, to)
                if prevDot {
                    ctx.emit(pos, end, following == Ch.lparen && !afterRelationKeyword ? .function : .property)
                    afterRelationKeyword = false
                } else if let scope = words.lookup(ctx.text, pos, end) {
                    ctx.emit(pos, end, scope)
                    afterRelationKeyword = relationKeywords.lookup(ctx.text, pos, end) != nil
                } else {
                    if following == Ch.lparen, !afterRelationKeyword { ctx.emit(pos, end, .function) }
                    if following != Ch.dot { afterRelationKeyword = false }
                }
                prevDot = false
                pos = end
                continue
            }
            prevDot = c == Ch.dot
            pos += 1
        }
    }

    private static let relationKeywords = WordTable([(.keyword, [
        "table", "into", "references", "exists", "view", "update", "join", "from", "index", "on", "type",
    ])], caseInsensitive: true)

    private static func quoted(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ quote: UInt16, start: Int) -> Int {
        var index = from
        var segment = start
        while index < to {
            let c = ctx[index]
            if c == quote {
                if index + 1 < to, ctx[index + 1] == quote {
                    ctx.emit(segment, index, .string)
                    ctx.emit(index, index + 2, .stringEscape)
                    index += 2
                    segment = index
                    continue
                }
                ctx.emit(segment, index + 1, .string)
                return index + 1
            }
            if c == Ch.backslash, index + 1 < to {
                index += 2
                continue
            }
            index += 1
        }
        ctx.emit(segment, to, .string)
        return -to
    }

    private static func findDollarTag(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ tag: [UInt16]) -> Int? {
        var index = from
        while index + tag.count <= to {
            if ctx[index] == Ch.dollar, ctx.matches(tag, at: index) { return index + tag.count }
            index += 1
        }
        return nil
    }
}
