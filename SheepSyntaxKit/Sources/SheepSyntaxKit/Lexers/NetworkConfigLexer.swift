// The `network_config` language: one language for every device family, with
// a vendor picked per document (the vendor is chosen and remembered by the
// app; see `SyntaxHighlighter(networkVendor:)`).
//
// Two layers, and the split is the whole design:
//
// 1. **The package** (`NetworkHighlightKit`, shared with SheepTerm) claims the
//    LITERAL VALUES — IPv4 and IPv6 addresses, netmasks, prefix lengths, MACs,
//    VLAN ids, interface names and the state words that carry a verdict. It is
//    a byte scanner with no AppKit dependency and it knows eleven device
//    families. It never guesses: `.auto` carries no interface rule at all.
// 2. **This file** adds what an EDITOR knows and a terminal does not: which
//    character opens a comment and — for Cisco — that `vlan 306s` and
//    `spanning-tree mode rpvsts` are not merely uncoloured but WRONG.
//
// The colours are SheepTerm's, rule for rule (`NetworkHighlightDefaults
// .presentation`): every package rule has a `network.*` scope of its own, so
// the editor and the terminal paint a config identically. Commands and
// sub-keywords are NOT painted — SheepTerm never coloured them, and a config
// where every first word is purple buries the values that matter. The data
// for that layer is still in the table behind `firstTokenIsKeyword`.
//
// Paint order is fill → scanner → override, so a scanner span wins over the
// editor's generic guesses (a first-token keyword, a bare integer) while a
// comment line and a validator's red both win over the scanner. Within a line
// the paint is last-wins, so the order IS the priority.
//
// The vendor rules are a TABLE. Adding a device family's comment character or
// a new validated command is a data change here, not a new branch.
//
// Both layers are LINE-LOCAL. A "line" is what the app has always meant for
// this language: LF, CR, CRLF (the session's lines) and additionally NEL,
// U+2028 and U+2029, which the package splits on too — the lexer treats those
// three as separators inside a session line.
//
// This used to live in the app (`NetworkConfigHighlight.swift`) with its own
// incremental path in `SyntaxEngine`. It moved here so every language goes
// through one engine, one incremental rule and one fuzz.

import NetworkHighlightKit

// MARK: - Commands

/// What one command's arguments mean. Data, not code: a new validated command
/// is one dictionary entry.
public struct NetworkConfigCommand: Sendable {

    public enum Argument: Sendable {
        /// A comma-separated VLAN list — each item is `1…4094` or `a-b` with
        /// both ends in range and `a <= b`. Anything else is an ERROR: `vlan
        /// 306s` is a typo a config review has to catch.
        ///
        /// It is only read as a list when it BEGINS WITH A DIGIT. `vlan
        /// internal allocation policy ascending`, `vlan dot1q tag native` and
        /// `vlan database` share the word and mean something else entirely,
        /// and painting their second token red said a correct config was
        /// broken. A false red is worse than a missed one.
        case vlanList
        /// A closed set: a member stays plain, anything else is an error
        /// (`spanning-tree mode rpvsts`).
        case oneOf(Set<String>)
    }

    /// What the token immediately after the command — or after the last
    /// sub-command matched — means.
    public let argument: Argument?
    /// Sub-commands keyed by the next token (`spanning-tree` → `mode`). The
    /// walker descends this tree as far as it goes.
    public let subCommands: [String: NetworkConfigCommand]

    public init(argument: Argument? = nil, subCommands: [String: NetworkConfigCommand] = [:]) {
        self.argument = argument
        self.subCommands = subCommands
    }
}

// MARK: - Keyword sets

/// A small set of short lowercase-ASCII keywords, matched against UTF-16
/// units without building a `String`.
///
/// The line walker asks this for EVERY token in the document. Keywords are
/// bucketed by length, so a token of the wrong length exits before any
/// comparison; a unit above 0x7F can never equal an ASCII keyword byte, so a
/// Thai or CJK token exits on its first unit.
public struct NetworkKeywordSet: Sendable {

    private let byLength: [[[UInt16]]]
    public let isEmpty: Bool

    public init(_ words: Set<String>) {
        isEmpty = words.isEmpty
        let longest = words.map(\.utf16.count).max() ?? 0
        var buckets = [[[UInt16]]](repeating: [], count: longest + 1)
        for word in words {
            let units = Array(word.lowercased().utf16)
            // A keyword spelled with a non-ASCII character could never match,
            // and silently never matching is how a rule disappears.
            guard !units.contains(where: { $0 >= 0x80 }) else { continue }
            buckets[units.count].append(units)
        }
        byLength = buckets
    }

    func contains(_ text: UnsafeBufferPointer<UInt16>, _ range: Range<Int>) -> Bool {
        let length = range.count
        guard length > 0, length < byLength.count else { return false }
        let candidates = byLength[length]
        guard !candidates.isEmpty else { return false }
        for word in candidates {
            var matched = true
            for offset in 0..<length {
                var unit = text[range.lowerBound + offset]
                if unit >= 0x41, unit <= 0x5A { unit += 0x20 }
                if unit != word[offset] { matched = false; break }
            }
            if matched { return true }
        }
        return false
    }
}

// MARK: - The per-vendor editor table

/// Everything the editor layer knows about one device family.
public struct NetworkConfigVendorRules: Sendable {

    /// UTF-16 units that open a whole-line comment when one is the first
    /// non-blank character on the line. Empty = this family has none here.
    public let commentMarkers: [UInt16]
    /// Paint command words as keywords: the first token of every line, the
    /// sub-commands a `commands` entry walks and `subKeywords`. Off for every
    /// family — SheepTerm colours values, not commands.
    public let firstTokenIsKeyword: Bool
    /// Paint a token made only of digits, `.` and `:` as a number. The package
    /// already claims addresses; this catches the bare `100` in
    /// `spanning-tree vlan 10 priority 100`.
    public let paintsPlainNumbers: Bool
    public let subKeywords: Set<String>
    public let commands: [String: NetworkConfigCommand]
    /// Words after which a digit-leading token is a VLAN list, wherever on the
    /// line they appear: `switchport trunk allowed vlan 10,20`, `switchport
    /// access vlan 100`, `no vlan 10`, `spanning-tree vlan 1-10 priority
    /// 24576`, `vlan filter MAP1 vlan-list 10-20`. `interface Vlan10` is
    /// deliberately NOT reached: the introducer has to be a token of its own.
    public let vlanListIntroducers: Set<String>
    /// Words that CONTINUE a list an introducer already opened on the same
    /// line (`add`, `remove`, `except`), and mean nothing on their own —
    /// `description add 5000 ports to po1` is prose.
    public let vlanListContinuations: Set<String>
    /// Commands after which the rest of the line is PROSE: `description`,
    /// `remark`, `banner …`, a vlan's `name`, `alias`, `snmp-server
    /// location|contact`. The editor layer claims nothing there; the package's
    /// scanner still runs, which keeps `description uplink to 10.0.0.1`
    /// coloured. Free text can only REMOVE editor paint, never add it.
    public let freeTextCommands: Set<String>
    /// Package rules this family's editor layer replaces. Cisco suppresses
    /// `vlan` because the scanner's rule spans the keyword AND its list as one
    /// constant-coloured span, which would bury the per-item validation.
    public let suppressedScannerRules: Set<NetworkRule>

    let subKeywordMatcher: NetworkKeywordSet
    let vlanListIntroducerMatcher: NetworkKeywordSet
    let vlanListContinuationMatcher: NetworkKeywordSet
    let freeTextMatcher: NetworkKeywordSet
    /// Exactly the keys of `commands`, so the first token of a line only pays
    /// for a `String` on the lines that really do open a command.
    let commandMatcher: NetworkKeywordSet

    public init(
        commentMarkers: [UInt16],
        firstTokenIsKeyword: Bool,
        paintsPlainNumbers: Bool,
        subKeywords: Set<String>,
        commands: [String: NetworkConfigCommand],
        vlanListIntroducers: Set<String>,
        vlanListContinuations: Set<String>,
        freeTextCommands: Set<String>,
        suppressedScannerRules: Set<NetworkRule>
    ) {
        self.commentMarkers = commentMarkers
        self.firstTokenIsKeyword = firstTokenIsKeyword
        self.paintsPlainNumbers = paintsPlainNumbers
        self.subKeywords = subKeywords
        self.commands = commands
        self.vlanListIntroducers = vlanListIntroducers
        self.vlanListContinuations = vlanListContinuations
        self.freeTextCommands = freeTextCommands
        self.suppressedScannerRules = suppressedScannerRules
        self.subKeywordMatcher = NetworkKeywordSet(subKeywords)
        self.vlanListIntroducerMatcher = NetworkKeywordSet(vlanListIntroducers)
        self.vlanListContinuationMatcher = NetworkKeywordSet(vlanListContinuations)
        self.freeTextMatcher = NetworkKeywordSet(freeTextCommands)
        self.commandMatcher = NetworkKeywordSet(Set(commands.keys))
    }

    public var isActive: Bool {
        firstTokenIsKeyword || paintsPlainNumbers
            || !commentMarkers.isEmpty || !commands.isEmpty || !subKeywords.isEmpty
            || !vlanListIntroducers.isEmpty
    }

    public static func rules(for vendor: Vendor) -> NetworkConfigVendorRules {
        table[vendor] ?? neutral
    }

    // MARK: Shared pieces

    private static let bang: [UInt16] = [0x21]   // !
    private static let hash: [UInt16] = [0x23]   // #

    /// The second half of a switch command. Shared by the families that speak
    /// switchport-shaped CLI.
    private static let switchSubKeywords: Set<String> = [
        "mode", "access", "trunk", "native", "allowed", "encapsulation",
        "dot1q", "add", "remove", "except", "all", "none"
    ]

    private static let spanningTreeModes: Set<String> = [
        "pvst", "rapid-pvst", "mst", "rstp", "rpvst"
    ]

    /// Cisco also knows two words that introduce a list, so they are keywords.
    private static let ciscoSubKeywords: Set<String> =
        switchSubKeywords.union(["vlan", "vlan-list"])

    /// `banner` covers `banner motd`/`banner login`/…; `location` and `contact`
    /// are the tails of `snmp-server location|contact`.
    private static let ciscoFreeTextCommands: Set<String> = [
        "description", "remark", "banner", "name", "alias", "location", "contact"
    ]

    /// The second word of every `vlan …` global that is NOT a VLAN list. Only
    /// `configuration` carries a list of its own.
    private static let ciscoVlanSubCommands: [String: NetworkConfigCommand] = [
        "internal": NetworkConfigCommand(),
        "dot1q": NetworkConfigCommand(),
        "database": NetworkConfigCommand(),
        "accounting": NetworkConfigCommand(),
        "name": NetworkConfigCommand(),
        "access-map": NetworkConfigCommand(),
        "filter": NetworkConfigCommand(),
        "group": NetworkConfigCommand(),
        "configuration": NetworkConfigCommand(argument: .vlanList)
    ]

    private static let ciscoCommands: [String: NetworkConfigCommand] = [
        // No argument on `vlan` itself: `vlan` is also its own list introducer,
        // so `vlan 10,20` is validated by the same rule as `switchport access
        // vlan 10` — one mechanism, not two.
        "vlan": NetworkConfigCommand(subCommands: ciscoVlanSubCommands),
        "spanning-tree": NetworkConfigCommand(subCommands: [
            "mode": NetworkConfigCommand(argument: .oneOf(spanningTreeModes))
        ])
    ]

    /// `.auto`'s table and the fallback. Deliberately empty: with no vendor
    /// there is no comment character to be sure of, so the package's literal
    /// values are the only honest thing to colour.
    public static let neutral = NetworkConfigVendorRules(
        commentMarkers: [], firstTokenIsKeyword: false, paintsPlainNumbers: false,
        subKeywords: [], commands: [:], vlanListIntroducers: [], vlanListContinuations: [],
        freeTextCommands: [], suppressedScannerRules: []
    )

    /// Every family that speaks a CLI has a `description`.
    private static let commonFreeTextCommands: Set<String> = ["description"]

    private static func standard(
        comment: [UInt16],
        subKeywords: Set<String> = [],
        commands: [String: NetworkConfigCommand] = [:],
        vlanListIntroducers: Set<String> = [],
        vlanListContinuations: Set<String> = [],
        freeTextCommands: Set<String> = commonFreeTextCommands,
        suppressing: Set<NetworkRule> = []
    ) -> NetworkConfigVendorRules {
        NetworkConfigVendorRules(
            commentMarkers: comment,
            firstTokenIsKeyword: false,
            paintsPlainNumbers: false,
            subKeywords: subKeywords,
            commands: commands,
            vlanListIntroducers: vlanListIntroducers,
            vlanListContinuations: vlanListContinuations,
            freeTextCommands: freeTextCommands,
            suppressedScannerRules: suppressing
        )
    }

    public static let table: [Vendor: NetworkConfigVendorRules] = [
        .auto: neutral,
        .cisco: standard(comment: bang, subKeywords: ciscoSubKeywords,
                         commands: ciscoCommands,
                         vlanListIntroducers: ["vlan", "vlan-list"],
                         vlanListContinuations: ["add", "remove", "except"],
                         freeTextCommands: ciscoFreeTextCommands,
                         suppressing: [.vlan]),
        .arubaCX: standard(comment: bang, subKeywords: switchSubKeywords),
        .arubaOS: standard(comment: bang, subKeywords: switchSubKeywords),
        .huawei: standard(comment: hash, subKeywords: switchSubKeywords),
        .comware: standard(comment: hash, subKeywords: switchSubKeywords),
        .juniper: standard(comment: hash),
        .panos: standard(comment: hash),
        .fortios: standard(comment: hash),
        .gaia: standard(comment: hash),
        .linux: standard(comment: hash)
    ]
}

// MARK: - The lexer

public enum NetworkConfigHighlighter {

    /// Rule → scope, grouped exactly as SheepTerm groups its colours: a mask
    /// and a prefix length share one, IPv4 and IPv6 share one, an interface
    /// name and a bare `1/1/1` port share one.
    public static let ruleScope: [NetworkRule: SyntaxScope] = [
        .vlan: .networkVlan,
        .interface: .networkInterface,
        .cxPort: .networkInterface,
        .mask: .networkMask,
        .cidr: .networkMask,
        .ipv4: .networkAddress,
        .ipv6: .networkAddress,
        .mac: .networkMac,
        .stateGood: .networkGood,
        .stateWarn: .networkWarn,
        .stateBad: .networkBad,
    ]

    /// Rule → capture name, for hosts that resolve names.
    public static let ruleTokenNames: [NetworkRule: String] = ruleScope.mapValues(\.captureName)

    /// Scope per rule ordinal, resolved once.
    static let ruleScopes: [SyntaxScope] = (0..<NetworkRule.allCases.count).map { ordinal in
        guard let rule = HighlightScanner.rule(ordinal: ordinal) else { return .none }
        return ruleScope[rule] ?? .none
    }

    /// Everything a line needs about its vendor, resolved once per process and
    /// handed around by reference: the rule table is a struct of sets and
    /// dictionaries, and copying it per line was most of a full pass.
    final class VendorContext: Sendable {
        let rules: NetworkConfigVendorRules
        let isActive: Bool
        let highlighter: NetworkHighlighter
        /// Per rule ordinal: false when the vendor suppresses it or it has no scope.
        let scopes: [SyntaxScope]

        init(_ vendor: Vendor) {
            rules = NetworkConfigVendorRules.rules(for: vendor)
            isActive = rules.isActive
            highlighter = NetworkHighlighter(vendor: vendor)
            let suppressed = rules.suppressedScannerRules
            scopes = (0..<NetworkRule.allCases.count).map { ordinal in
                guard let rule = HighlightScanner.rule(ordinal: ordinal), !suppressed.contains(rule) else {
                    return .none
                }
                return NetworkConfigHighlighter.ruleScopes[ordinal]
            }
        }
    }

    private static let contexts: [Vendor: VendorContext] =
        Dictionary(uniqueKeysWithValues: Vendor.allCases.map { ($0, VendorContext($0)) })

    /// Buffers reused across the pieces of one session line.
    struct Scratch {
        var tokens: [Range<Int>] = []
        var overrides: [(SyntaxScope, Range<Int>)] = []
        var blocked: [Range<Int>] = []
    }

    /// A line of the session, split on the three separators the package also
    /// breaks on (NEL, U+2028, U+2029); each piece is lexed on its own.
    static func lex(_ vendor: Vendor, _ ctx: inout LexContext, _ from: Int, _ to: Int) {
        let context = contexts[vendor] ?? contexts[.auto]!
        var scratch = Scratch()
        var start = from
        var index = from
        while index < to {
            let unit = ctx[index]
            if unit == 0x0085 || unit == 0x2028 || unit == 0x2029 {
                if index > start { lexSegment(context, &ctx, start, index, &scratch) }
                start = index + 1
            }
            index += 1
        }
        if to > start { lexSegment(context, &ctx, start, to, &scratch) }
    }

    /// Paint one line into a scratch array of scopes — fill, scanner,
    /// override, each last-wins — then emit it as runs. Fill is painted
    /// straight into the array (it is first anyway); overrides and the spans
    /// the scanner may not touch are collected, and are rare.
    private static func lexSegment(
        _ context: VendorContext, _ ctx: inout LexContext, _ from: Int, _ to: Int, _ work: inout Scratch
    ) {
        let text = ctx.text
        let count = to - from
        withUnsafeTemporaryAllocation(of: SyntaxScope.self, capacity: count) { scratch in
            scratch.initialize(repeating: .none)
            var paint = LinePaint(scopes: scratch, base: from)
            work.overrides.removeAll(keepingCapacity: true)
            work.blocked.removeAll(keepingCapacity: true)
            swap(&paint.overrides, &work.overrides)
            swap(&paint.blocked, &work.blocked)
            if context.isActive {
                highlightLine(text, from..<to, rules: context.rules, tokens: &work.tokens, into: &paint)
            }

            // Layer 2: the package, over this line's UTF-8, mapped back to UTF-16.
            var blockIndex = 0
            let blocked = paint.blocked
            let scopes = context.scopes
            forEachScannerSpan(context.highlighter, text, from, to) { rule, range in
                let scope = scopes[HighlightScanner.ordinal(of: rule)]
                guard scope != .none else { return }
                while blockIndex < blocked.count, blocked[blockIndex].upperBound <= range.lowerBound {
                    blockIndex += 1
                }
                if blockIndex < blocked.count, blocked[blockIndex].lowerBound < range.upperBound { return }
                for i in range where i >= from && i < to { scratch[i - from] = scope }
            }

            for (scope, range) in paint.overrides { paint.fill(scope, range) }
            swap(&paint.overrides, &work.overrides)
            swap(&paint.blocked, &work.blocked)

            var i = 0
            while i < count {
                let scope = scratch[i]
                var j = i + 1
                while j < count, scratch[j] == scope { j += 1 }
                if scope != .none { ctx.emit(from + i, from + j, scope) }
                i = j
            }
        }
    }

    /// Scanner spans for `[from, to)`, in UTF-16 offsets of the document.
    /// ASCII lines map one to one; otherwise every UTF-8 byte offset is looked
    /// up in a table built while transcoding (a 4-byte sequence is a surrogate
    /// PAIR, two UTF-16 units). The spans arrive in ascending order.
    private static func forEachScannerSpan(
        _ highlighter: NetworkHighlighter, _ text: UnsafeBufferPointer<UInt16>, _ from: Int, _ to: Int,
        _ body: (NetworkRule, Range<Int>) -> Void
    ) {
        var isASCII = true
        for i in from..<to where text[i] >= 0x80 { isASCII = false; break }
        if isASCII {
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: to - from) { bytes in
                for i in from..<to { bytes[i - from] = UInt8(truncatingIfNeeded: text[i]) }
                for span in highlighter.scanLine(UnsafeBufferPointer(bytes)) {
                    body(span.rule, (from + span.range.lowerBound)..<(from + span.range.upperBound))
                }
            }
            return
        }
        // At most three UTF-8 bytes per UTF-16 unit. byteToUnit[b] is the
        // UTF-16 offset (from `from`) of the scalar byte b belongs to.
        let capacity = (to - from) * 3
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: capacity) { bytes in
            withUnsafeTemporaryAllocation(of: Int.self, capacity: capacity + 1) { byteToUnit in
                var written = 0
                var i = from
                while i < to {
                    let unit = text[i]
                    let offset = i - from
                    var scalar = UInt32(unit)
                    var width = 1
                    if (0xD800...0xDBFF).contains(unit), i + 1 < to, (0xDC00...0xDFFF).contains(text[i + 1]) {
                        scalar = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(text[i + 1]) - 0xDC00)
                        width = 2
                    } else if (0xD800...0xDFFF).contains(unit) {
                        scalar = 0xFFFD
                    }
                    UTF8.encode(Unicode.Scalar(scalar) ?? "\u{FFFD}") { byte in
                        bytes[written] = byte
                        byteToUnit[written] = offset
                        written += 1
                    }
                    i += width
                }
                byteToUnit[written] = to - from
                for span in highlighter.scanLine(UnsafeBufferPointer(rebasing: bytes[0..<written])) {
                    let lower = byteToUnit[min(span.range.lowerBound, written)]
                    let upper = byteToUnit[min(span.range.upperBound, written)]
                    if upper > lower { body(span.rule, (from + lower)..<(from + upper)) }
                }
            }
        }
    }

    // MARK: Layer 1: one line

    struct LinePaint {
        /// The line's scopes, one per UTF-16 unit, from `base`.
        let scopes: UnsafeMutableBufferPointer<SyntaxScope>
        let base: Int
        var overrides: [(SyntaxScope, Range<Int>)] = []
        /// Sorted, disjoint spans a scanner match may not touch: comment lines
        /// and the validators' errors.
        var blocked: [Range<Int>] = []

        init(scopes: UnsafeMutableBufferPointer<SyntaxScope>, base: Int) {
            self.scopes = scopes
            self.base = base
        }

        @inline(__always) func fill(_ scope: SyntaxScope, _ range: Range<Int>) {
            for i in range { scopes[i - base] = scope }
        }

        /// A validator's verdict: SheepTerm's `state-bad` red.
        mutating func error(_ range: Range<Int>) {
            overrides.append((.networkBad, range))
            blocked.append(range)
        }
    }

    @inline(__always) private static func isBlank(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }

    /// Longest token ever compared against a keyword table.
    private static let keywordLengthLimit = 16

    /// The token as a lowercase `String`, for the command and argument tables.
    /// Every key in them is ASCII, so a token that is not cannot match and
    /// gets nil without a `String` being built at all.
    private static func lowercased(_ text: UnsafeBufferPointer<UInt16>, _ range: Range<Int>) -> String? {
        guard !range.isEmpty, range.count <= keywordLengthLimit else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(range.count)
        for i in range {
            var unit = text[i]
            guard unit < 0x80 else { return nil }
            if unit >= 0x41, unit <= 0x5A { unit += 0x20 }
            bytes.append(UInt8(unit))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func highlightLine(
        _ text: UnsafeBufferPointer<UInt16>, _ line: Range<Int>,
        rules: NetworkConfigVendorRules, tokens: inout [Range<Int>], into paint: inout LinePaint
    ) {
        let end = line.upperBound
        var scan = line.lowerBound
        while scan < end, isBlank(text[scan]) { scan += 1 }
        guard scan < end else { return }

        if rules.commentMarkers.contains(text[scan]) {
            paint.overrides.append((.comment, line))
            paint.blocked.append(line)
            return
        }

        tokens.removeAll(keepingCapacity: true)
        tokens.reserveCapacity(16)
        var pos = scan
        while pos < end {
            while pos < end, isBlank(text[pos]) { pos += 1 }
            guard pos < end else { break }
            let start = pos
            while pos < end, !isBlank(text[pos]) { pos += 1 }
            tokens.append(start..<pos)
        }
        guard !tokens.isEmpty else { return }

        if rules.firstTokenIsKeyword {
            paint.fill(.keyword, tokens[0])
        }

        var next = 1
        if rules.commandMatcher.contains(text, tokens[0]),
           let command = rules.commands[lowercased(text, tokens[0]) ?? ""] {
            var resolved = command
            while next < tokens.count, !resolved.subCommands.isEmpty,
                  let sub = lowercased(text, tokens[next]),
                  let child = resolved.subCommands[sub] {
                if rules.firstTokenIsKeyword { paint.fill(.keyword, tokens[next]) }
                resolved = child
                next += 1
            }
            if let argument = resolved.argument, next < tokens.count {
                next = apply(argument, at: next, tokens: tokens, text, into: &paint)
            }
        }

        // `listIsOpen`: has a `vlan` / `vlan-list` token appeared yet? Only then
        // do `add` / `remove` / `except` continue a list. A free-text command
        // ends the editor layer's claim on the line.
        var listIsOpen = false
        for consumed in 0..<next {
            if rules.freeTextMatcher.contains(text, tokens[consumed]) { return }
            if rules.vlanListIntroducerMatcher.contains(text, tokens[consumed]) { listIsOpen = true }
        }

        var previous = tokens[next - 1]
        var index = next
        while index < tokens.count {
            let token = tokens[index]
            let previousOpensAList = rules.vlanListIntroducerMatcher.contains(text, previous)
                || (listIsOpen && rules.vlanListContinuationMatcher.contains(text, previous))
            if previousOpensAList {
                let after = paintVlanArgument(at: index, tokens: tokens, text, into: &paint)
                if after > index {
                    // `vlan 10,20` is one yellow span in SheepTerm, keyword included.
                    if rules.vlanListIntroducerMatcher.contains(text, previous) {
                        paint.fill(.networkVlan, previous)
                    }
                    previous = tokens[after - 1]
                    index = after
                    continue
                }
            }
            if rules.freeTextMatcher.contains(text, token) { return }
            if rules.firstTokenIsKeyword, rules.subKeywordMatcher.contains(text, token) {
                paint.fill(.keyword, token)
            } else if rules.paintsPlainNumbers {
                paintPlainNumber(text, token, into: &paint)
            }
            if rules.vlanListIntroducerMatcher.contains(text, token) { listIsOpen = true }
            previous = token
            index += 1
        }
    }

    private static func apply(
        _ argument: NetworkConfigCommand.Argument, at index: Int, tokens: [Range<Int>],
        _ text: UnsafeBufferPointer<UInt16>, into paint: inout LinePaint
    ) -> Int {
        switch argument {
        case .vlanList:
            return paintVlanArgument(at: index, tokens: tokens, text, into: &paint)
        case .oneOf(let allowed):
            let token = tokens[index]
            // A member stays plain, as in SheepTerm; only a wrong value is painted.
            if !(lowercased(text, token).map(allowed.contains) ?? false) {
                paint.error(token)
            }
            return index + 1
        }
    }

    /// The VLAN list that starts at token `index`, or nothing. It has to start
    /// with a digit, and it may run over several tokens (`vlan 10, 20, 5000`).
    /// Returns the index after the list, or `index` when this is not one.
    private static func paintVlanArgument(
        at index: Int, tokens: [Range<Int>], _ text: UnsafeBufferPointer<UInt16>, into paint: inout LinePaint
    ) -> Int {
        let first = tokens[index]
        guard !first.isEmpty else { return index }
        let lead = text[first.lowerBound]
        guard lead >= 0x30, lead <= 0x39 else { return index }

        var last = index
        while last + 1 < tokens.count {
            let endsOnComma = text[tokens[last].upperBound - 1] == 0x2C
            let nextOpensOnComma = text[tokens[last + 1].lowerBound] == 0x2C
            guard endsOnComma || nextOpensOnComma else { break }
            last += 1
        }
        paintVlanList(text, tokens[index].lowerBound..<tokens[last].upperBound, into: &paint)
        return last + 1
    }

    /// `1,3,23,101-102,306s` — every item judged on its own, trimmed of the
    /// blanks a spaced list carries.
    private static func paintVlanList(_ text: UnsafeBufferPointer<UInt16>, _ list: Range<Int>, into paint: inout LinePaint) {
        let end = list.upperBound
        var itemStart = list.lowerBound
        var cursor = list.lowerBound
        while cursor <= end {
            let isComma = cursor < end && text[cursor] == 0x2C
            if cursor == end || isComma {
                var itemBegin = itemStart
                var itemEnd = cursor
                while itemBegin < itemEnd, isBlank(text[itemBegin]) { itemBegin += 1 }
                while itemEnd > itemBegin, isBlank(text[itemEnd - 1]) { itemEnd -= 1 }
                if itemEnd > itemBegin {
                    if isValidVlanItem(text, itemBegin..<itemEnd) {
                        paint.fill(.networkVlan, itemBegin..<itemEnd)
                    } else {
                        paint.error(itemBegin..<itemEnd)
                    }
                }
                if cursor == end { break }
                paint.fill(.networkVlan, cursor..<(cursor + 1))
                itemStart = cursor + 1
            }
            cursor += 1
        }
    }

    /// `N` or `A-B`, ASCII digits only, each in `1…4094`, `A <= B`.
    public static func isValidVlanItem(_ item: String) -> Bool {
        var trimmed = Substring(item)
        while let first = trimmed.first, first == " " || first == "\t" { trimmed.removeFirst() }
        while let last = trimmed.last, last == " " || last == "\t" { trimmed.removeLast() }
        let units = Array(trimmed.utf16)
        return units.withUnsafeBufferPointer { isValidVlanItem($0, 0..<units.count) }
    }

    /// A VLAN id is digits and nothing else: `Int.init` accepts a sign, so
    /// `vlan +5` was once valid, and IOS does not take it. Values clamp past
    /// the maximum rather than overflow.
    static func isValidVlanItem(_ text: UnsafeBufferPointer<UInt16>, _ range: Range<Int>) -> Bool {
        let end = range.upperBound
        var cursor = range.lowerBound
        func number() -> Int? {
            var value = 0
            var digits = 0
            while cursor < end {
                let unit = text[cursor]
                guard unit >= 0x30, unit <= 0x39 else { break }
                if value <= 4094 { value = value * 10 + Int(unit - 0x30) }
                digits += 1
                cursor += 1
            }
            return digits == 0 ? nil : value
        }
        guard let low = number(), low >= 1, low <= 4094 else { return false }
        if cursor == end { return true }
        guard text[cursor] == 0x2D else { return false }
        cursor += 1
        guard let high = number(), cursor == end, high >= 1, high <= 4094, low <= high else { return false }
        return true
    }

    /// A token of digits, `.` and `:` only. `Character.isNumber` is also true
    /// for non-ASCII digits (Thai ๐-๙ among them), so a token with any
    /// non-ASCII unit takes the Character test rather than quietly changing
    /// what counts as a number.
    private static func paintPlainNumber(_ text: UnsafeBufferPointer<UInt16>, _ token: Range<Int>, into paint: inout LinePaint) {
        guard !token.isEmpty else { return }
        var allNumeric = true
        var sawNonASCII = false
        for index in token {
            let unit = text[index]
            if unit > 0x7F { sawNonASCII = true; break }
            let isDigit = unit >= 0x30 && unit <= 0x39
            if !(isDigit || unit == 0x2E || unit == 0x3A) { allNumeric = false; break }
        }
        if sawNonASCII {
            allNumeric = String(decoding: text[token], as: UTF16.self)
                .allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        }
        if allNumeric { paint.fill(.number, token) }
    }
}

extension SyntaxScope {
    /// The scope a capture name names, or nil.
    public init?(captureName: String) {
        guard let scope = SyntaxScope.allCases.first(where: { $0 != .none && $0.captureName == captureName }) else {
            return nil
        }
        self = scope
    }
}
