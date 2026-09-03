import Foundation

/// Single-pass byte scanner for the eleven built-in network-device highlight
/// rules. Ported from SheepTerm 3.0(3) (`SheepTerm/HighlightScanner.swift`).
///
/// It replaces eleven `NSRegularExpression` passes (ICU, backtracking) with one
/// walk over the bytes that can never backtrack: a 256-entry start table says
/// which rules may begin at each byte, and each matcher is a direct hand
/// translation of its default regex. Measured against the regex path on a 4 MB
/// dump in SheepTerm: ~17x faster match phase, identical output byte-for-byte.
///
/// ## Vendors
///
/// The eleven rule NAMES are fixed. What varies between device families is the
/// DATA inside them — which interface spellings exist, which words are states
/// rather than policy, whether ports are written `10GE1/1/1` or `ge-0/0/0` or
/// `1/1/1` — and that data lives in `Profile`. Adding a device family is one
/// `Profile` literal plus one `Vendor` case: never a new rule bit, a new
/// ordinal, or a change to a matcher.
///
/// The keyword arrays a profile is built from are also what
/// `NetworkHighlightReference.defaultConfigs(for:)` generates its regex
/// alternations from, in the same sorted order. That is deliberate: the two
/// matching paths can only agree if, for every pair where one keyword is a
/// prefix of another, the longer one is tried first. Generating both from one
/// sorted array makes that true by construction instead of by review.
///
/// ## Differences from SheepTerm (both deliberate, both documented here)
///
/// 1. **Non-ASCII bytes are WORD bytes.** SheepTerm refuses to scan a run that
///    contains any byte >= 0x80 and falls back to ICU regex, because `\b` there
///    is Unicode-aware and because its painter maps a byte offset onto a
///    terminal column. An editor sees Thai and CJK in `description` lines all
///    day, so this port has no fallback: every byte >= 0x80 answers `true` to
///    `isWord`, exactly as if it were a letter. Consequences, and they are the
///    intended ones: `ห้อง10` is not a VLAN id (the digits have a word byte
///    behind them), `10.0.0.1ห` is not an address (a word byte follows), and
///    `ห้อง 10.0.0.1` IS an address because the space between them is a real
///    boundary. Combining marks and ZWJ sequences are word bytes too, so a
///    token is never split in the middle of a grapheme.
/// 2. **The optional blank between an interface name and its number is
///    `[ \t]`, not `\s`.** SheepTerm's `\s?` also matches a newline, so
///    `GigabitEthernet\n1/0/1` matched across a line break. Every rule here has
///    to be line-local or `scanLine` cannot equal a whole-document scan, which
///    is what an incremental editor needs. `NetworkHighlightReference` emits
///    `[ \t]?` for the same reason, so the two paths still agree exactly.
public enum HighlightScanner {
    /// A contiguous UTF-8 buffer. The matchers index it directly.
    public typealias Bytes = UnsafeBufferPointer<UInt8>

    /// The eleven rule names, in PRIORITY order — an earlier rule claims its
    /// range first and a later one skips anything already claimed.
    ///
    /// `vlan` must precede `interface` or "interface" claims the `vlan 1` in
    /// `vlan 10,20,30-40` and the comma list loses its tail; `mac` must precede
    /// `ipv6` or a colon MAC is read as an address.
    public enum BuiltIn: String, CaseIterable, Sendable {
        case vlan, interface, cxPort = "cx-port", mask, cidr, ipv4, mac, ipv6
        case stateGood = "state-good", stateWarn = "state-warn", stateBad = "state-bad"
    }

    /// `\w`, plus every non-ASCII byte. See difference (1) in the type comment:
    /// treating a UTF-8 lead or continuation byte as a word byte is what keeps
    /// `ห้อง10` from being a VLAN id and keeps a match from ever ending inside
    /// a multi-byte character.
    @inline(__always) public static func isWord(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39)
            || b == 0x5F || b >= 0x80
    }
    @inline(__always) public static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    @inline(__always) public static func isHex(_ b: UInt8) -> Bool {
        isDigit(b) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46)
    }
    @inline(__always) public static func lower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
    }
    /// \b before a word char: start of buffer or a non-word byte behind.
    @inline(__always) static func boundaryBefore(_ b: Bytes, _ i: Int) -> Bool {
        i == 0 || !isWord(b[i - 1])
    }
    /// \b after a word char: end of buffer or a non-word byte ahead.
    @inline(__always) static func boundaryAfter(_ b: Bytes, _ e: Int) -> Bool {
        e == b.count || !isWord(b[e])
    }

    public static func bit(of rule: BuiltIn) -> UInt16 {
        switch rule {
        case .vlan: return 1
        case .interface: return 2
        case .cxPort: return 4
        case .mask: return 8
        case .cidr: return 16
        case .ipv4: return 32
        case .mac: return 64
        case .ipv6: return 128
        case .stateGood: return 256
        case .stateWarn: return 512
        case .stateBad: return 1024
        }
    }

    public static func ordinal(of rule: BuiltIn) -> Int {
        bit(of: rule).trailingZeroBitCount
    }

    public static func rule(ordinal index: Int) -> BuiltIn? {
        BuiltIn.allCases.first { ordinal(of: $0) == index }
    }

    /// Width of every per-rule table here — one slot per `BuiltIn`, indexed by
    /// `ordinal(of:)`.
    static let ruleCount = 11

    /// Bit mask for a set of rules — cached by the caller alongside its
    /// profile, so the hot path never rebuilds it.
    public static func mask(of rules: some Sequence<BuiltIn>) -> UInt16 {
        rules.reduce(into: UInt16(0)) { $0 |= bit(of: $1) }
    }

    // MARK: - Profile

    /// Everything that differs between device families, plus the lookup tables
    /// derived from it. One immutable instance per `Vendor`.
    ///
    /// A class, not a struct, and that is a performance decision inherited from
    /// SheepTerm: the matching path lifts a profile out of shared storage once
    /// per text run — thousands of times per escape-heavy chunk — and a struct
    /// here would retain/release all seven tables on every one of those copies.
    /// Every stored property is a `let`, so sharing the reference is safe.
    public final class Profile: Sendable {
        /// Interface name prefixes, longest-first (see the type comment for why
        /// the order is load-bearing). A prefix may end in `-` or `.` (`ge-`,
        /// `irb.`) — the shared tail then supplies the digits, which is how
        /// Junos and PAN-OS names are expressed without a new matcher.
        public let interfaceKeywords: [String]
        /// Interface names that stand alone with no number after them — Check
        /// Point's `Mgmt`/`Sync`, FortiGate's `internal`/`dmz`, the plain `lo`
        /// in `ip addr`. They are the SECOND top-level alternative of the
        /// interface pattern, so the numbered form always wins first.
        public let bareInterfaces: [String]
        public let stateGoodKeywords: [String]
        public let stateWarnKeywords: [String]
        public let stateBadKeywords: [String]
        /// Words that mean "not" in front of `shutdown` — Cisco says `no`,
        /// Huawei and Comware say `undo`, a firewall says neither.
        public let negations: [String]
        /// `\d{1,3}GE` — Huawei/Comware ports whose speed leads the name
        /// (`10GE1/1/1`, `100GE1/2/3`). No other family writes them this way.
        public let digitSpeedPorts: Bool
        /// `vlan batch 2110 to 2113 2120` — the `batch` keyword and `to`
        /// ranges. Huawei and Comware only; elsewhere a vlan list is commas.
        public let vlanRanges: Bool
        /// `00e0-fc12-3456` — three dash-separated 4-hex groups. Enabling it
        /// everywhere would colour any `1234-5678-9012`-shaped token, so it
        /// stays with the families that actually print MACs that way.
        public let macDashGroups: Bool
        /// `3810f0-7ade00` — two dash-separated 6-hex groups, which is how
        /// AOS-CX prints the chassis base MAC (`show system`). Same reasoning
        /// as `macDashGroups`.
        public let macSixHexGroups: Bool
        /// Which of the eleven rules this family uses at all. `cx-port` is the
        /// one that matters: it claims `0/0/0`, so leaving it on for Junos
        /// would tear `ge-0/0/0` in half.
        public let rules: UInt16

        let startTable: [UInt16]
        let interfaceByFirst: [[[UInt8]]]
        let bareByFirst: [[[UInt8]]]
        let stateGoodByFirst: [[[UInt8]]]
        let stateWarnByFirst: [[[UInt8]]]
        let stateBadByFirst: [[[UInt8]]]
        let negationBytes: [[UInt8]]

        public init(
            interface: [String],
            bare: [String] = [],
            stateGood: [String],
            stateBad: [String],
            stateWarn: [String] = ["warning", "warn"],
            negations: [String] = [],
            digitSpeedPorts: Bool = false,
            vlanRanges: Bool = false,
            macDashGroups: Bool = false,
            macSixHexGroups: Bool = false,
            omitting: Set<BuiltIn> = []
        ) {
            let ifKws = Profile.sortLongestFirst(interface)
            let bareKws = Profile.sortLongestFirst(bare)
            let good = Profile.sortLongestFirst(stateGood)
            let warn = Profile.sortLongestFirst(stateWarn)
            let bad = Profile.sortLongestFirst(stateBad)
            interfaceKeywords = ifKws
            bareInterfaces = bareKws
            stateGoodKeywords = good
            stateWarnKeywords = warn
            stateBadKeywords = bad
            self.negations = negations
            self.digitSpeedPorts = digitSpeedPorts
            self.vlanRanges = vlanRanges
            self.macDashGroups = macDashGroups
            self.macSixHexGroups = macSixHexGroups
            rules = BuiltIn.allCases.reduce(into: UInt16(0)) {
                if !omitting.contains($1) { $0 |= HighlightScanner.bit(of: $1) }
            }
            interfaceByFirst = Profile.bucketByFirst(ifKws)
            bareByFirst = Profile.bucketByFirst(bareKws)
            stateGoodByFirst = Profile.bucketByFirst(good)
            stateWarnByFirst = Profile.bucketByFirst(warn)
            stateBadByFirst = Profile.bucketByFirst(bad)
            negationBytes = negations.map { Array($0.lowercased().utf8) }
            startTable = Profile.makeStartTable(
                interface: ifKws + bareKws, good: good, warn: warn, bad: bad,
                negations: negations, digitSpeedPorts: digitSpeedPorts,
                rules: rules
            )
        }

        /// Longest first, ties in the order written. A proper prefix is always
        /// strictly shorter, so this alone guarantees the invariant the two
        /// matching paths depend on.
        static func sortLongestFirst(_ keywords: [String]) -> [String] {
            var seen = Set<String>()
            let unique = keywords.map { $0.lowercased() }.filter { seen.insert($0).inserted }
            return unique.enumerated()
                .sorted {
                    $0.element.count > $1.element.count
                        || ($0.element.count == $1.element.count && $0.offset < $1.offset)
                }
                .map(\.element)
        }

        /// Keywords pre-lowered to byte arrays, bucketed by first byte — at any
        /// position only the handful that can actually start there are tried,
        /// and compares run on raw bytes.
        static func bucketByFirst(_ keywords: [String]) -> [[[UInt8]]] {
            var table = [[[UInt8]]](repeating: [], count: 256)
            for kw in keywords {
                let bytes = Array(kw.utf8)
                table[Int(bytes[0])].append(bytes) // sorted order kept inside each bucket
            }
            return table
        }

        /// byte -> bitmask of rules that may START at that byte.
        static func makeStartTable(
            interface: [String], good: [String], warn: [String], bad: [String],
            negations: [String], digitSpeedPorts: Bool, rules: UInt16
        ) -> [UInt16] {
            var table = [UInt16](repeating: 0, count: 256)
            let maskBit = bit(of: .mask), cxBit = bit(of: .cxPort), v4Bit = bit(of: .ipv4)
            let macBit = bit(of: .mac), v6Bit = bit(of: .ipv6), cidrBit = bit(of: .cidr)
            let ifBit = bit(of: .interface)
            for d: UInt8 in 0x30...0x39 {
                table[Int(d)] = cxBit | v4Bit | macBit | v6Bit
                // Huawei's digit-led \d{1,3}GE ports are the only rule that can
                // begin on a digit but is not a number.
                if digitSpeedPorts { table[Int(d)] |= ifBit }
            }
            table[Int(0x32)] |= maskBit // '2' may start 255.x.x.x
            table[Int(0x2F)] = cidrBit  // '/'
            table[Int(0x3A)] = v6Bit    // ':' (::1)
            for h: UInt8 in 0x61...0x66 {
                table[Int(h)] |= macBit | v6Bit
                table[Int(h - 0x20)] |= macBit | v6Bit
            }
            var letterRules = [UInt8: UInt16]()
            func addKeyword(_ kw: String, _ ruleBit: UInt16) {
                guard let first = kw.utf8.first else { return }
                letterRules[lower(first), default: 0] |= ruleBit
            }
            addKeyword("vlan", bit(of: .vlan))
            for kw in interface { addKeyword(kw, ifBit) }
            for kw in good { addKeyword(kw, bit(of: .stateGood)) }
            // The negation branch of state-good is spelled out rather than left
            // to whatever else happens to claim 'n'/'u': the branch must not
            // silently stop matching if a keyword list is refactored.
            for kw in negations { addKeyword(kw, bit(of: .stateGood)) }
            for kw in warn { addKeyword(kw, bit(of: .stateWarn)) }
            for kw in bad { addKeyword(kw, bit(of: .stateBad)) }
            for (letter, ruleBits) in letterRules {
                table[Int(letter)] |= ruleBits
                if letter >= 0x61, letter <= 0x7A { table[Int(letter - 0x20)] |= ruleBits }
            }
            // A rule the family does not use must never start anywhere.
            for i in 0..<256 { table[i] &= rules }
            return table
        }
    }

    // MARK: - Scratch

    /// The workspace one `scan` needs: a match bucket and a cursor per rule,
    /// plus the two buffers the claim pass merges through.
    ///
    /// It exists because the buckets are per-CALL but the caller is per-LINE.
    /// `NetworkHighlighter.spansUTF16` scans each line separately (every rule is
    /// line-local, which is the whole basis of the incremental editor path), so
    /// building `[[Range<Int>]](repeating: [], count: 11)` and a cursor array
    /// inside `scan` meant ~22 array allocations PER LINE — about 440 000 of
    /// them on a 20 000-line config, and most of the 12 ms the scanner added to
    /// a full editor pass. A whole-text pass now creates one `Scratch` and
    /// `reset()`s it between lines: `removeAll(keepingCapacity: true)` keeps the
    /// buffers, so the buckets grow to the widest line once and then never
    /// allocate again.
    ///
    /// Deliberately NOT `Sendable`: it is mutable scratch space owned by one
    /// scan at a time. Every entry point that hands one out creates it locally,
    /// so a `NetworkHighlighter` stays a `Sendable` value that is safe to call
    /// from any queue.
    final class Scratch {
        /// Matches per rule, indexed by `ordinal(of:)`.
        var perRule: [[Range<Int>]]
        /// Per-rule "the next match may not start before here" cursor — what
        /// makes matches leftmost non-overlapping within a rule.
        var cursor: [Int]
        /// Output of the claim pass, in byte offsets.
        var claimed: [NetworkSpan] = []
        /// The buffer the claim pass merges into; swapped with `claimed` once
        /// per rule so neither one is ever reallocated.
        var merged: [NetworkSpan] = []

        init() {
            perRule = [[Range<Int>]](repeating: [], count: HighlightScanner.ruleCount)
            cursor = [Int](repeating: 0, count: HighlightScanner.ruleCount)
        }

        /// Between lines. Allocates nothing — that is the point of the type.
        @inline(__always) func reset() {
            for index in 0..<HighlightScanner.ruleCount {
                perRule[index].removeAll(keepingCapacity: true)
                cursor[index] = 0
            }
        }
    }

    // MARK: - Scan

    /// One pass over the bytes; per-rule matches, leftmost non-overlapping
    /// within each rule (per-rule cursor) — exactly `enumerateMatches`
    /// semantics.
    ///
    /// Returns the matches ordinal-indexed (index == `ordinal(of:)`), always 11
    /// entries. Re-keying into a `[BuiltIn: [Range<Int>]]` used to cost more
    /// than the scan itself on short text runs, and every caller indexes by
    /// ordinal anyway.
    ///
    /// This form allocates a `Scratch` per call. A caller that scans line after
    /// line should use the `scratch:` overload and reuse one.
    public static func scan(_ bytes: Bytes, enabledMask: UInt16, profile: Profile) -> [[Range<Int>]] {
        let scratch = Scratch()
        scan(bytes, enabledMask: enabledMask, profile: profile, scratch: scratch)
        return scratch.perRule
    }

    public static func scan(_ bytes: [UInt8], enabledMask: UInt16, profile: Profile) -> [[Range<Int>]] {
        bytes.withUnsafeBufferPointer { scan($0, enabledMask: enabledMask, profile: profile) }
    }

    /// `scan`, filling a caller-owned `Scratch`. It only APPENDS: the caller
    /// resets between lines (a freshly built `Scratch` is already empty).
    static func scan(
        _ bytes: Bytes, enabledMask: UInt16, profile: Profile, scratch: Scratch
    ) {
        let active = enabledMask & profile.rules
        guard active != 0 else { return }
        // Move the buckets out of the object for the duration of the loop. Read
        // through `scratch.` they would be reloaded — and exclusivity-checked —
        // on every append; as uniquely-referenced locals they are plain arrays
        // again. The empty literals left behind are the shared empty singleton,
        // so this costs nothing.
        var perRule = scratch.perRule
        var cursor = scratch.cursor
        scratch.perRule = []
        scratch.cursor = []
        defer {
            scratch.perRule = perRule
            scratch.cursor = cursor
        }
        let n = bytes.count
        var i = 0
        while i < n {
            var mask = profile.startTable[Int(bytes[i])] & active
            // Bit index == rule ordinal (bits were assigned 1 << ordinal).
            while mask != 0 {
                let ord = mask.trailingZeroBitCount
                mask &= mask &- 1
                if i >= cursor[ord], let end = matchOrdinal(ord, bytes, i, profile) {
                    perRule[ord].append(i..<end)
                    cursor[ord] = end
                }
            }
            i += 1
        }
    }

    static func matchOrdinal(_ ord: Int, _ b: Bytes, _ s: Int, _ p: Profile) -> Int? {
        switch ord {
        case 0: return matchVLAN(b, s, p)
        case 1: return matchInterface(b, s, p)
        case 2: return matchCXPort(b, s)
        case 3: return matchMask(b, s)
        case 4: return matchCIDR(b, s)
        case 5: return matchIPv4(b, s)
        case 6: return matchMAC(b, s, p)
        case 7: return matchIPv6(b, s)
        case 8: return matchState(b, s, p.stateGoodByFirst, negations: p.negationBytes)
        case 9: return matchState(b, s, p.stateWarnByFirst, negations: [])
        case 10: return matchState(b, s, p.stateBadByFirst, negations: [])
        default: return nil
        }
    }

    // MARK: - Matchers

    /// `\b255(?:\.\d{1,3}){3}\b` — groups 1-2 need a dot after 1-3 digits,
    /// group 3 needs a word boundary; an over-long digit run can never match.
    static func matchMask(_ b: Bytes, _ s: Int) -> Int? {
        guard boundaryBefore(b, s), s + 3 <= b.count,
              b[s] == 0x32, b[s + 1] == 0x35, b[s + 2] == 0x35 else { return nil }
        var p = s + 3
        for group in 0..<3 {
            guard p < b.count, b[p] == 0x2E else { return nil }
            p += 1
            var d = 0
            while p < b.count, isDigit(b[p]), d < 4 { p += 1; d += 1 }
            guard d >= 1, d <= 3 else { return nil }
            if group == 2 {
                guard boundaryAfter(b, p) else { return nil }
            }
        }
        return p
    }

    /// `(?<=[.:]\d{1,3})/\d{1,2}\b` — match starts AT the slash.
    ///
    /// The lookbehind used to be a bare `(?<=\d)`, which made every port number
    /// a CIDR prefix: `Gi1/0/1` came out with `/0` and `/1` in the mask colour
    /// whenever no interface rule claimed the token first. A prefix length
    /// follows an ADDRESS, so require the digits before the slash to be
    /// preceded by a `.` or `:` — true of `10.0.0.1/24` and `fe80::1/64`, false
    /// of `Gi1/0/1`, `Fa0/1`, `100GE1/2/3` and `1/1/1`.
    static func matchCIDR(_ b: Bytes, _ s: Int) -> Int? {
        guard b[s] == 0x2F, s > 0, isDigit(b[s - 1]) else { return nil }
        // [.:]\d{1,3} ending at s — existential in the digit count, so the
        // order the regex tries them in cannot matter.
        var anchored = false
        for k in 1...3 {
            let sep = s - k - 1
            guard sep >= 0, s - k >= 0 else { break }
            guard (s - k ..< s).allSatisfy({ isDigit(b[$0]) }) else { break }
            if b[sep] == 0x2E || b[sep] == 0x3A { anchored = true; break }
        }
        guard anchored else { return nil }
        var p = s + 1
        var d = 0
        while p < b.count, isDigit(b[p]), d < 3 { p += 1; d += 1 }
        guard d >= 1, d <= 2, boundaryAfter(b, p) else { return nil }
        return p
    }

    /// `\b\d{1,2}/\d{1,2}/\d{1,2}(?::\d)?\b`
    static func matchCXPort(_ b: Bytes, _ s: Int) -> Int? {
        guard boundaryBefore(b, s) else { return nil }
        var p = s
        for group in 0..<3 {
            var d = 0
            while p < b.count, isDigit(b[p]), d < 3 { p += 1; d += 1 }
            guard d >= 1, d <= 2 else { return nil }
            if group < 2 {
                guard p < b.count, b[p] == 0x2F else { return nil }
                p += 1
            }
        }
        // optional :d — greedy first, then backtrack to without
        if p < b.count, b[p] == 0x3A, p + 1 < b.count, isDigit(b[p + 1]) {
            let e = p + 2
            if boundaryAfter(b, e) { return e }
        }
        guard boundaryAfter(b, p) else { return nil }
        return p
    }

    /// Octet per the pattern's alternation order: `25[0-5] | 2[0-4]d | 1dd | [1-9]?d`
    static func matchOctet(_ b: Bytes, _ p: Int) -> Int? {
        guard p < b.count, isDigit(b[p]) else { return nil }
        let has1 = p + 1 < b.count && isDigit(b[p + 1])
        let has2 = p + 2 < b.count && isDigit(b[p + 2])
        if b[p] == 0x32, has1, b[p + 1] == 0x35, has2, b[p + 2] <= 0x35 { return p + 3 }
        if b[p] == 0x32, has1, b[p + 1] <= 0x34, has2 { return p + 3 }
        if b[p] == 0x31, has1, has2 { return p + 3 }
        if b[p] != 0x30, has1 { return p + 2 }
        return p + 1
    }

    /// `\b(?:octet\.){3}octet\b` — backtracking never helps a digit run, so a
    /// straight 4-octet parse + end boundary is equivalent.
    static func matchIPv4(_ b: Bytes, _ s: Int) -> Int? {
        guard boundaryBefore(b, s) else { return nil }
        var p = s
        for i in 0..<4 {
            guard let e = matchOctet(b, p) else { return nil }
            p = e
            if i < 3 {
                guard p < b.count, b[p] == 0x2E else { return nil }
                p += 1
            }
        }
        guard boundaryAfter(b, p) else { return nil }
        return p
    }

    /// `\b(?:h{4}[.\-]){2}h{4}\b | \b(?:h{2}[:\-]){5}h{2}\b | \bh{6}-h{6}\b` —
    /// alternatives tried in pattern order. The dash form of the first one is
    /// Huawei's `00e0-fc12-3456` and the third is AOS-CX's `3810f0-7ade00`;
    /// both are in the pattern only for families that print MACs that way.
    static func matchMAC(_ b: Bytes, _ s: Int, _ profile: Profile) -> Int? {
        guard boundaryBefore(b, s) else { return nil }
        func hexRun(_ p: Int, _ n: Int) -> Int? {
            var q = p
            for _ in 0..<n {
                guard q < b.count, isHex(b[q]) else { return nil }
                q += 1
            }
            return q
        }
        // cisco dotted xxxx.xxxx.xxxx / huawei dashed xxxx-xxxx-xxxx (the class
        // is per separator, so a mixed pair matches too — exactly what the
        // regex does)
        let dash = profile.macDashGroups
        @inline(__always) func isGroupSep(_ p: Int) -> Bool {
            b[p] == 0x2E || (dash && b[p] == 0x2D)
        }
        if let e1 = hexRun(s, 4), e1 < b.count, isGroupSep(e1),
           let e2 = hexRun(e1 + 1, 4), e2 < b.count, isGroupSep(e2),
           let e3 = hexRun(e2 + 1, 4), boundaryAfter(b, e3) {
            return e3
        }
        // colon/dash xx-xx-xx-xx-xx-xx
        var p = s
        var ok = true
        for _ in 0..<5 {
            guard let e = hexRun(p, 2), e < b.count, b[e] == 0x3A || b[e] == 0x2D else {
                ok = false
                break
            }
            p = e + 1
        }
        if ok, let e = hexRun(p, 2), boundaryAfter(b, e) { return e }
        // aos-cx base MAC 3810f0-7ade00
        if profile.macSixHexGroups,
           let e1 = hexRun(s, 6), e1 < b.count, b[e1] == 0x2D,
           let e2 = hexRun(e1 + 1, 6), boundaryAfter(b, e2) {
            return e2
        }
        return nil
    }

    /// `\bvlan(?:[ \t]+batch)?[ \t-]+\d{1,4}(?:[ \t]*[,\-][ \t]*\d{1,4}|[ \t]+(?:to[ \t]+)?\d{1,4})*`
    /// — no trailing `\b`, so a 5th digit is simply left out; the repeat group
    /// backtracks cleanly. The `batch` keyword and the second alternative exist
    /// only when `profile.vlanRanges` is set (Huawei "vlan batch 2110 to 2113
    /// 2120"); the two alternatives are disjoint at the decision byte, so
    /// trying them in pattern order is what the regex does.
    static func matchVLAN(_ b: Bytes, _ s: Int, _ profile: Profile) -> Int? {
        guard boundaryBefore(b, s), s + 4 <= b.count,
              lower(b[s]) == 0x76, lower(b[s + 1]) == 0x6C,
              lower(b[s + 2]) == 0x61, lower(b[s + 3]) == 0x6E else { return nil }
        @inline(__always) func isBlank(_ p: Int) -> Bool { b[p] == 0x20 || b[p] == 0x09 }
        var p = s + 4
        if profile.vlanRanges {
            // (?:[ \t]+batch)? — greedy, and dropping it can never rescue a
            // failed match (the separator run below then lands on the `b`,
            // which is never a digit).
            var q = p
            while q < b.count, isBlank(q) { q += 1 }
            if q > p, q + 5 <= b.count, lower(b[q]) == 0x62, lower(b[q + 1]) == 0x61,
               lower(b[q + 2]) == 0x74, lower(b[q + 3]) == 0x63, lower(b[q + 4]) == 0x68 {
                p = q + 5
            }
        }
        let sepStart = p
        while p < b.count, isBlank(p) || b[p] == 0x2D { p += 1 }
        guard p > sepStart else { return nil }
        var d = 0
        while p < b.count, isDigit(b[p]), d < 4 { p += 1; d += 1 }
        guard d >= 1 else { return nil }
        while true {
            // [ \t]*[,\-][ \t]*\d{1,4}
            var q = p
            while q < b.count, isBlank(q) { q += 1 }
            if q < b.count, b[q] == 0x2C || b[q] == 0x2D {
                var r = q + 1
                while r < b.count, isBlank(r) { r += 1 }
                var dd = 0
                while r < b.count, isDigit(b[r]), dd < 4 { r += 1; dd += 1 }
                if dd >= 1 { p = r; continue }
            }
            guard profile.vlanRanges else { break }
            // [ \t]+(?:to[ \t]+)?\d{1,4}
            var r = p
            while r < b.count, isBlank(r) { r += 1 }
            guard r > p else { break }
            if r + 2 <= b.count, lower(b[r]) == 0x74, lower(b[r + 1]) == 0x6F {
                var t = r + 2
                let tSpace = t
                while t < b.count, isBlank(t) { t += 1 }
                if t > tSpace {
                    var dd = 0
                    var u = t
                    while u < b.count, isDigit(b[u]), dd < 4 { u += 1; dd += 1 }
                    if dd >= 1 { p = u; continue }
                }
            }
            var dd = 0
            var u = r
            while u < b.count, isDigit(b[u]), dd < 4 { u += 1; dd += 1 }
            guard dd >= 1 else { break }
            p = u
        }
        return p
    }

    /// `[ \t]?\d+(?:[\/.:_-]\d+)*\b` — the part every interface spelling
    /// shares, starting right after the name prefix. nil = this prefix cannot
    /// match, so the caller falls back to a shorter keyword (or fewer speed
    /// digits).
    ///
    /// SheepTerm spells the optional blank `\s?`, which also matches a newline;
    /// see difference (2) in the type comment for why this port does not.
    @inline(__always)
    static func matchInterfaceTail(_ b: Bytes, _ start: Int) -> Int? {
        var p = start
        if p < b.count, b[p] == 0x20 || b[p] == 0x09 { p += 1 }
        let dStart = p
        while p < b.count, isDigit(b[p]) { p += 1 }
        guard p > dStart else { return nil }
        // The `\b` picks the LONGEST candidate prefix that lands on a boundary,
        // and the candidates are produced in ascending order — so the last one
        // that satisfies `boundaryAfter` is the answer, and tracking it as we go
        // is exactly what collecting them and walking `.reversed()` did. The
        // array it replaces was allocated on every call.
        var best: Int? = boundaryAfter(b, p) ? p : nil
        while p < b.count, b[p] == 0x2F || b[p] == 0x2E || b[p] == 0x3A || b[p] == 0x5F || b[p] == 0x2D {
            let sep = p
            p += 1
            let ds = p
            while p < b.count, isDigit(b[p]) { p += 1 }
            guard p > ds else { p = sep; break }
            if boundaryAfter(b, p) { best = p }
        }
        return best
    }

    /// `(?:\d{1,3}GE|keyword)[ \t]?\d+(?:[\/.:_-]\d+)*\b` — longest keyword
    /// first; the `\b` at the end picks the longest candidate prefix that lands
    /// on a boundary. The digit-led alternative is Huawei's `10GE1/1/1` form:
    /// it is first in the pattern and can never share a start byte with a
    /// keyword, so trying it before the buckets matches the regex exactly.
    static func matchInterface(_ b: Bytes, _ s: Int, _ profile: Profile) -> Int? {
        if profile.digitSpeedPorts, isDigit(b[s]) {
            guard boundaryBefore(b, s) else { return nil }
            // \d{1,3} is greedy, then backtracks: 3 digits, 2, then 1.
            var digits = 0
            while digits < 3, s + digits < b.count, isDigit(b[s + digits]) { digits += 1 }
            while digits >= 1 {
                let g = s + digits
                if g + 1 < b.count, lower(b[g]) == 0x67, lower(b[g + 1]) == 0x65,
                   let end = matchInterfaceTail(b, g + 2) {
                    return end
                }
                digits -= 1
            }
            return nil
        }
        // A keyword may open with `-`/`.`-adjacent text (ge-, irb.) but its
        // FIRST byte is always a word char, so \b still applies here.
        guard boundaryBefore(b, s) else { return nil }
        for kw in profile.interfaceByFirst[Int(lower(b[s]))] {
            let klen = kw.count
            guard s + klen <= b.count else { continue }
            var hit = true
            for i in 1..<klen where lower(b[s + i]) != kw[i] { hit = false; break }
            guard hit else { continue }
            guard let end = matchInterfaceTail(b, s + klen) else { continue }
            return end
        }
        // Second top-level alternative: \b(?:bare)\b. Reached only after every
        // numbered spelling has failed at this position, which is what the
        // regex does with its alternation.
        for kw in profile.bareByFirst[Int(lower(b[s]))] {
            let klen = kw.count
            guard s + klen <= b.count else { continue }
            var hit = true
            for i in 1..<klen where lower(b[s + i]) != kw[i] { hit = false; break }
            if hit, boundaryAfter(b, s + klen) { return s + klen }
        }
        return nil
    }

    /// `(?<![0-9A-Fa-f:])(?=[0-9A-Fa-f:]*::|(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(?![0-9A-Fa-f:]))(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])`
    ///
    /// The shape alone (2-7 colons, 0-4 hex per group) also fits a clock, so
    /// every `14:37:24` in `show events` / `show logging` came out address
    /// blue; a run is only an address if it is compressed (`::` anywhere) or
    /// spelled in full (7 colons, all 8 groups non-empty).
    ///
    /// This is the one rule whose boundaries are a character class rather than
    /// `\b`, so the non-ASCII policy has to be spelled out in it: a byte >= 0x80
    /// on either side blocks the match, exactly as a word byte would elsewhere.
    /// Without that, `::e` would be claimed out of `::é` — `e` is a hex digit
    /// and U+0301 is neither hex nor a colon — and the span would end in the
    /// middle of a character. ASCII input is unaffected, so the regex oracle
    /// still agrees.
    static func matchIPv6(_ b: Bytes, _ s: Int) -> Int? {
        if s > 0, isHex(b[s - 1]) || b[s - 1] == 0x3A || b[s - 1] >= 0x80 { return nil } // lookbehind
        // Parse colon-terminated groups greedily: 0-4 hex then ':'.
        var groupEnds: [Int] = []
        var p = s
        while true {
            var q = p
            while q < b.count, isHex(b[q]) { q += 1 }
            guard q - p <= 4, q < b.count, b[q] == 0x3A else { break }
            groupEnds.append(q + 1)
            p = q + 1
        }
        // k groups (7 down to 2), then 0-4 hex, then the lookahead class.
        var k = min(groupEnds.count, 7)
        while k >= 2 {
            let afterGroups = groupEnds[k - 1]
            var hexEnd = afterGroups
            while hexEnd < b.count, isHex(b[hexEnd]) { hexEnd += 1 }
            var take = min(hexEnd - afterGroups, 4)
            while take >= 0 {
                let end = afterGroups + take
                if end == b.count || !(isHex(b[end]) || b[end] == 0x3A || b[end] >= 0x80) {
                    return isAddressShaped(b, s, end, groupEnds, k, take) ? end : nil
                }
                take -= 1
            }
            k -= 1
        }
        return nil
    }

    /// The extra condition the regex spells as a lookahead: `::` somewhere in
    /// the run, or exactly 8 non-empty groups. The body can only end where a
    /// non-hex/non-colon byte follows, so the match always covers the whole
    /// maximal hex/colon run — a `::` anywhere in `s..<end` is inside it.
    private static func isAddressShaped(
        _ b: Bytes, _ s: Int, _ end: Int, _ groupEnds: [Int], _ k: Int, _ take: Int
    ) -> Bool {
        if end - s >= 2 {
            for i in s..<(end - 1) where b[i] == 0x3A && b[i + 1] == 0x3A { return true }
        }
        guard k == 7, take >= 1 else { return false }
        var groupStart = s
        for i in 0..<k {
            guard groupEnds[i] - 1 > groupStart else { return false } // empty group
            groupStart = groupEnds[i]
        }
        return true
    }

    static let shutdownBytes = Array("shutdown".utf8)

    /// Keyword sets with `\b` on both sides; `(?:no|undo)[ \t]+shutdown` is the
    /// leading alternative of state-good and is handled apart.
    static func matchState(
        _ b: Bytes, _ s: Int, _ byFirst: [[[UInt8]]], negations: [[UInt8]]
    ) -> Int? {
        guard boundaryBefore(b, s) else { return nil }
        for word in negations {
            guard s + word.count <= b.count else { continue }
            var hit = true
            for i in 0..<word.count where lower(b[s + i]) != word[i] { hit = false; break }
            guard hit else { continue }
            var p = s + word.count
            let spStart = p
            while p < b.count, b[p] == 0x20 || b[p] == 0x09 { p += 1 }
            if p > spStart, p + 8 <= b.count {
                var ok = true
                for i in 0..<8 where lower(b[p + i]) != shutdownBytes[i] { ok = false; break }
                if ok, boundaryAfter(b, p + 8) { return p + 8 }
            }
        }
        for kw in byFirst[Int(lower(b[s]))] {
            let klen = kw.count
            guard s + klen <= b.count else { continue }
            var hit = true
            for i in 1..<klen where lower(b[s + i]) != kw[i] { hit = false; break }
            if hit, boundaryAfter(b, s + klen) { return s + klen }
        }
        return nil
    }
}

// MARK: - Vendor catalogue
//
// Data only. A new device family is one `Vocab` entry plus one line in
// `profiles` — no matcher, rule bit, or start-table change.

extension HighlightScanner {
    /// Word lists shared between families, so a family only spells out what is
    /// actually its own.
    public enum Vocab {
        /// States that mean the same thing on every box.
        public static let goodCore = ["up", "connected", "active", "established", "running",
                                      "enabled", "enable", "successful", "success", "forwarding",
                                      "reachable", "authorized", "full"]
        public static let badCore = ["down", "shutdown", "fail", "failed", "failure", "unreachable",
                                     "invalid", "error", "err", "critical", "crit", "emergency",
                                     "alert", "suspended", "half", "disabled", "disable"]
        /// Filter/ACL verdicts. On a switch these ARE the health signal; on a
        /// firewall they are the configured policy and colouring them red or
        /// green says nothing, so the firewall packs leave them out.
        public static let policyGood = ["permit", "permitted", "permits", "allow", "allowed"]
        public static let policyBad = ["deny", "denied", "blocked", "blocking", "discarding"]
        /// Port-level faults only switches report.
        public static let switchBad = ["err-disabled", "errdisable", "notconnect", "violation"]
        /// Huawei/Comware board, AP and optical-module states.
        public static let vrpGood = ["normal", "online"]
        public static let vrpBad = ["abnormal", "offline", "fault", "faulty"]
        /// AOS-CX columns and event severities. `ok` is the Reason column of
        /// `show vlan` and the Status of `show environment fan|power-supply`;
        /// `normal` is the temperature Status and a transceiver's `Status:
        /// Normal`. `admin_down` has to be its own word because `_` is a word
        /// char — `\bdown\b` can never reach the tail of it. The VSX/NTP pairs
        /// carry their `-` the same way `err-disabled` does.
        public static let cxGood = ["ok", "normal", "in-sync", "synchronized"]
        public static let cxBad = ["fault", "faulty", "admin_down", "out-of-sync", "unsynchronized"]
        /// `show events` severities. LOG_INFO and LOG_DEBUG stay plain: a
        /// normal events dump is nearly all of them, and colouring the routine
        /// line is how a severity column stops meaning anything.
        public static let cxWarn = ["warning", "warn", "log_warn"]
        public static let cxSevereBad = ["log_err", "log_crit", "log_alert", "log_emer"]

        public static let cisco = ["GigabitEthernet", "TenGigabitEthernet", "TwoGigabitEthernet",
                                   "TwentyFiveGigE", "FortyGigabitEthernet", "HundredGigE",
                                   "AppGigabitEthernet", "FastEthernet", "Port-channel",
                                   "Bundle-Ether", "Ethernet", "Vethernet", "Loopback", "Tunnel",
                                   "Management", "Serial", "Nve", "Vlan", "Gi", "Twe", "Tw", "Te",
                                   "Fo", "Hu", "Fa", "Eth", "Po", "Lo", "Se", "mgmt"]
        public static let arubaCX = ["Vlan", "Loopback", "Tunnel", "lag", "mgmt"]
        public static let arubaOS = ["GigabitEthernet", "FastEthernet", "Port-channel", "Loopback",
                                     "Tunnel", "Vlan", "Trk", "Gi", "Fa", "Po", "Lo", "mgmt"]
        /// `MultiGE` is the multi-rate (100M/1G/2.5G/5G/10G) port on CloudEngine
        /// and S-series campus switches, `MTIGE` its short form in `display`
        /// output; `Wlan-Ess` / `Wlan-Radio` are the AC / AP service and radio
        /// interfaces. All four were missing (September 2026), so a
        /// `MultiGE0/0/1` block took no interface colour at all.
        public static let huawei = ["GigabitEthernet", "XGigabitEthernet", "M-GigabitEthernet",
                                    "Virtual-Template", "Eth-Trunk", "Stack-Port", "LoopBack",
                                    "Wlan-Radio", "Wlan-Ess", "MultiGE", "MTIGE",
                                    "Vlanif", "Ethernet", "Tunnel", "Serial", "MEth", "NULL",
                                    "Vlan", "Aux", "Pos", "GE", "XGE", "FGE", "HGE"]
        public static let comware = ["Ten-GigabitEthernet", "Twenty-FiveGigE", "Hundred-GigE",
                                     "Forty-GigE", "M-GigabitEthernet", "XGigabitEthernet",
                                     "Bridge-Aggregation", "Route-Aggregation", "Vlan-interface",
                                     "InLoopBack", "M-Ethernet", "Ethernet", "Loopback", "Tunnel",
                                     "NULL", "BAGG", "RAGG", "Vlan", "XGE", "FGE", "HGE", "WGE", "GE"]
        /// Junos names carry their separator in the prefix (`ge-`, `irb.`),
        /// which the shared tail then completes — no new matcher needed.
        public static let juniper = ["ge-", "xe-", "et-", "xle-", "fte-", "vcp-", "gr-", "ip-",
                                     "vt-", "sp-", "vme.", "irb.", "vlan.", "demux", "reth",
                                     "fxp", "vme", "irb", "ae", "em", "me", "lo", "st"]
        public static let panos = ["loopback.", "ethernet", "tunnel.", "vlan.", "ae"]
        /// `port` is exactly why a document needs to know its vendor: it is
        /// mandatory here (`port1`, `edit "port1"`) and poison everywhere else,
        /// where `port 443` is a service number.
        public static let fortios = ["redundant", "aggregate", "internal", "modem", "ssl.",
                                     "port", "wan", "lan", "dmz", "agg", "npu", "mgmt", "vlan",
                                     "ha", "ppp"]
        public static let gaia = ["bond", "eth", "wrp", "lo", "bp"]
        public static let linux = ["docker", "virbr", "dummy", "vmbr", "wlan", "veth", "bond",
                                   "wlp", "enp", "ens", "eno", "esp", "eth", "tun", "tap",
                                   "sit", "br", "lo"]
    }

    /// The pack a `Vendor` resolves to. Built once, then shared — every derived
    /// table inside is immutable.
    public static let profiles: [String: Profile] = [
        // `auto` is the vendor-NEUTRAL core, not a union: addresses, masks,
        // CIDR, MACs, VLAN ids, and the state words that mean the same thing on
        // every box. `interface` and `cx-port` are left out on purpose — an
        // interface name is the most vendor-specific token there is, and
        // guessing it is what tore `ge-0/0/0` in half and what would put a
        // FortiGate's `port1` and a service `port 443` in the same colour.
        "auto": Profile(
            interface: [],
            stateGood: Vocab.goodCore,
            stateBad: Vocab.badCore,
            omitting: [.interface, .cxPort]
        ),
        "cisco": Profile(
            interface: Vocab.cisco,
            stateGood: Vocab.goodCore + Vocab.policyGood,
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad,
            negations: ["no"],
            omitting: [.cxPort]
        ),
        "arubaCX": Profile(
            interface: Vocab.arubaCX,
            stateGood: Vocab.goodCore + Vocab.policyGood + Vocab.cxGood,
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad
                + Vocab.cxBad + Vocab.cxSevereBad,
            stateWarn: Vocab.cxWarn,
            negations: ["no"],
            macSixHexGroups: true
        ),
        "arubaOS": Profile(
            interface: Vocab.arubaOS,
            stateGood: Vocab.goodCore + Vocab.policyGood + ["registered"],
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad
                + ["rebooting", "unprovisioned"],
            negations: ["no"]
        ),
        "huawei": Profile(
            interface: Vocab.huawei,
            stateGood: Vocab.goodCore + Vocab.policyGood + Vocab.vrpGood,
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad + Vocab.vrpBad,
            negations: ["no", "undo"],
            digitSpeedPorts: true, vlanRanges: true, macDashGroups: true,
            omitting: [.cxPort]
        ),
        "comware": Profile(
            interface: Vocab.comware,
            stateGood: Vocab.goodCore + Vocab.policyGood + Vocab.vrpGood,
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad + Vocab.vrpBad,
            negations: ["undo", "no"],
            digitSpeedPorts: true, vlanRanges: true, macDashGroups: true,
            omitting: [.cxPort]
        ),
        // cx-port off is the whole point here: `\d{1,2}/\d{1,2}/\d{1,2}` was
        // claiming the `0/0/0` out of `ge-0/0/0` and leaving `ge-` grey.
        "juniper": Profile(
            interface: Vocab.juniper,
            stateGood: Vocab.goodCore,
            stateBad: Vocab.badCore + ["inactive", "flapping"],
            omitting: [.cxPort]
        ),
        "panos": Profile(
            interface: Vocab.panos, bare: ["mgt"],
            stateGood: ["up", "active", "enabled", "established", "connected", "running", "valid"],
            stateBad: ["down", "disabled", "error", "fail", "failed", "failure", "critical",
                       "unreachable", "invalid", "dead", "expired"],
            omitting: [.cxPort]
        ),
        // No enable/disable: FortiOS ends nearly every config line in one of
        // them, so colouring them turns a config dump into a wall of green.
        "fortios": Profile(
            interface: Vocab.fortios, bare: ["internal", "modem", "dmz", "mgmt"],
            stateGood: ["up", "connected", "established", "active", "alive", "ok", "reachable"],
            stateBad: ["down", "dead", "fail", "failed", "failure", "error", "critical",
                       "unreachable", "invalid", "expired"],
            omitting: [.cxPort]
        ),
        "gaia": Profile(
            interface: Vocab.gaia, bare: ["Mgmt", "Sync", "lo"],
            stateGood: ["up", "active", "ready", "connected", "established", "running",
                        "enabled", "enable", "ok"],
            stateBad: Vocab.badCore + ["problem"],
            omitting: [.cxPort]
        ),
        catalogueKey: Profile(
            interface: Vocab.cisco + Vocab.arubaCX + Vocab.arubaOS + Vocab.huawei
                + Vocab.comware + Vocab.juniper + Vocab.panos + Vocab.fortios
                + Vocab.gaia + Vocab.linux,
            bare: ["internal", "modem", "Mgmt", "Sync", "dmz", "mgt", "lo"],
            stateGood: Vocab.goodCore + Vocab.policyGood + Vocab.vrpGood + Vocab.cxGood,
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad + Vocab.vrpBad
                + Vocab.cxBad + Vocab.cxSevereBad,
            stateWarn: Vocab.cxWarn,
            negations: ["no", "undo"],
            digitSpeedPorts: true, vlanRanges: true, macDashGroups: true,
            macSixHexGroups: true
        ),
        "linux": Profile(
            interface: Vocab.linux, bare: ["lo"],
            stateGood: Vocab.goodCore + ["listening", "loaded", "ok"],
            stateBad: Vocab.badCore + ["dead", "inactive", "masked", "refused", "denied"],
            omitting: [.cxPort]
        ),
    ]

    /// Key of the catalogue profile — every rule, the union vocabulary. It is
    /// NOT a vendor and is never used to match anything: it exists so a host
    /// app can enumerate all eleven rule names whatever pack a document is on.
    public static let catalogueKey = "\u{0}catalogue"

    /// Never nil in practice — `Vendor` and `profiles` are kept in step by
    /// `NetworkHighlightReference.vendorCoverageIsComplete()`, which the test
    /// suite asserts.
    public static func profile(_ key: String) -> Profile {
        profiles[key] ?? profiles["auto"]!
    }

    public static func profile(for vendor: Vendor) -> Profile {
        profile(vendor.rawValue)
    }
}
