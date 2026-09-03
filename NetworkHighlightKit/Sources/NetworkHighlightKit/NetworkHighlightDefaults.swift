import Foundation

/// SheepTerm's per-rule presentation, kept here as REFERENCE DATA.
///
/// The package deliberately paints nothing: it has no AppKit dependency and a
/// host app maps a `NetworkRule` onto its own token palette (SheepText onto its
/// syntax theme, SheepTerm onto terminal attributes). But SheepTerm's colours
/// are a real decision with real reasons — masks and prefix lengths share a
/// colour because they are the same idea written two ways; the interface and
/// cx-port colours match because a bare `1/1/1` IS a port name; the three state
/// colours are traffic lights and are the only bold rules — and losing them in
/// the move would mean rediscovering them later.
///
/// So this is what SheepTerm 3.0(3) shipped, unchanged, ready for the day
/// SheepTerm adopts this package.
public enum NetworkHighlightDefaults {
    public struct Presentation: Equatable, Sendable {
        /// "RRGGBB", as `Highlighter.makeConfigs` wrote it.
        public let colorHex: String
        public let bold: Bool
        /// Whether the rule's regex was compiled case-insensitively — a
        /// property of the RULE, not of its colour, and the scanner lowercases
        /// its keyword compares to match.
        public let caseInsensitive: Bool

        public var rgb: (r: UInt8, g: UInt8, b: UInt8) {
            let hex = UInt32(colorHex, radix: 16) ?? 0xFF_FF_FF
            return (UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
        }
    }

    public static let presentation: [NetworkRule: Presentation] = [
        .vlan: Presentation(colorHex: "E8D06B", bold: false, caseInsensitive: true),
        .interface: Presentation(colorHex: "F0A860", bold: false, caseInsensitive: true),
        .cxPort: Presentation(colorHex: "F0A860", bold: false, caseInsensitive: false),
        .mask: Presentation(colorHex: "C678DD", bold: false, caseInsensitive: false),
        .cidr: Presentation(colorHex: "C678DD", bold: false, caseInsensitive: false),
        .ipv4: Presentation(colorHex: "6CD1E0", bold: false, caseInsensitive: false),
        .mac: Presentation(colorHex: "E08BC7", bold: false, caseInsensitive: false),
        .ipv6: Presentation(colorHex: "6CD1E0", bold: false, caseInsensitive: false),
        .stateGood: Presentation(colorHex: "7DD98C", bold: true, caseInsensitive: true),
        .stateWarn: Presentation(colorHex: "E0B568", bold: true, caseInsensitive: true),
        .stateBad: Presentation(colorHex: "ED7A7A", bold: true, caseInsensitive: true),
    ]

    /// A suggested mapping onto the capture names a Tree-sitter theme already
    /// has, for a host that would rather reuse its syntax palette than paint
    /// SheepTerm's literal colours. Advisory only — nothing in the package
    /// reads it.
    ///
    /// The choices: an address, a mask and a prefix length are literal values
    /// (`number`); a VLAN id is a value too but wants to stand apart from the
    /// addresses around it (`constant`); an interface name is the thing a line
    /// is ABOUT, so it takes the same ink as a type; and the state words are the
    /// only place a config carries a verdict, which is what `string` /
    /// `warning` / `error` already mean in every theme.
    ///
    /// A MAC gets `property`, NOT `number`, and it is the one entry here that
    /// does not simply follow "a literal value is a number". `presentation`
    /// above never painted the two alike — a MAC is pink `E08BC7` and an IPv4
    /// address cyan `6CD1E0` — and a config where `aabb.ccdd.eeff` and
    /// `10.20.30.40` carry the same ink is harder to read, not easier: the two
    /// are the same shape at a glance and only the colour tells them apart.
    /// `property` is the closest a Tree-sitter palette comes to that pink. This
    /// mapping used to say `number`, and SheepText overrode it in its own table
    /// for exactly this reason; the default is now the right one.
    public static let suggestedTokenNames: [NetworkRule: String] = [
        .vlan: "constant",
        .interface: "type",
        .cxPort: "type",
        .mask: "number",
        .cidr: "number",
        .ipv4: "number",
        .mac: "property",
        .ipv6: "number",
        .stateGood: "string",
        .stateWarn: "warning",
        .stateBad: "error",
    ]
}
