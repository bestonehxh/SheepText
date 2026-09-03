import Foundation

/// The device family a piece of text was produced by.
///
/// Ported unchanged from SheepTerm (`Models.swift`) — same cases, same raw
/// values, same `slot` numbering — so a `Vendor` written by one app decodes
/// in the other.
///
/// `.auto` is the vendor-NEUTRAL core, not a union of every pack: addresses,
/// masks, CIDR, MACs, VLAN ids and the state words that mean the same thing on
/// every box. It carries no `interface` and no `cx-port` rule, because an
/// interface name is the most vendor-specific token there is — guessing it is
/// what tore `ge-0/0/0` in half and what would put a FortiGate's `port1` and a
/// service `port 443` in the same colour. Port names arrive when a family is
/// picked; the neutral core never misleads.
///
/// Adding a device family is meant to be one `Profile` literal and one case
/// here — never a change to a matcher, a rule bit, or the start table.
public enum Vendor: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case cisco
    case arubaCX
    case arubaOS
    case huawei
    case comware
    case juniper
    case panos
    case fortios
    case gaia
    case linux

    public var id: String { rawValue }

    /// Tolerant of raw values this build does not know. The synthesized
    /// decoder THROWS on an unrecognised string, and `Vendor?` does not save
    /// you — optionality covers a missing key, not a bad value — so one stale
    /// or hand-edited entry would fail a whole document/settings decode.
    /// Unknown reads as `.auto`, which is exactly what "we don't know this
    /// device" means.
    public init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Vendor.init(rawValue:)) ?? .auto
    }

    public var label: String {
        switch self {
        case .auto: return "Auto (all vendors)"
        case .cisco: return "Cisco IOS / IOS-XE / NX-OS"
        case .arubaCX: return "Aruba CX"
        case .arubaOS: return "ArubaOS (Controller / MM)"
        case .huawei: return "Huawei VRP"
        case .comware: return "H3C / HPE Comware"
        case .juniper: return "Juniper Junos"
        case .panos: return "Palo Alto PAN-OS"
        case .fortios: return "Fortinet FortiOS"
        case .gaia: return "Check Point Gaia"
        case .linux: return "Linux / server"
        }
    }

    /// Short form for a status bar or a menu badge.
    public var badge: String {
        switch self {
        case .auto: return "Auto"
        case .cisco: return "Cisco"
        case .arubaCX: return "Aruba CX"
        case .arubaOS: return "ArubaOS"
        case .huawei: return "Huawei"
        case .comware: return "Comware"
        case .juniper: return "Junos"
        case .panos: return "PAN-OS"
        case .fortios: return "FortiOS"
        case .gaia: return "Gaia"
        case .linux: return "Linux"
        }
    }

    /// Dense index into a per-vendor table. Written out rather than derived
    /// from `allCases` because the matching path reads it once per text run.
    public var slot: Int {
        switch self {
        case .auto: return 0
        case .cisco: return 1
        case .arubaCX: return 2
        case .arubaOS: return 3
        case .huawei: return 4
        case .comware: return 5
        case .juniper: return 6
        case .panos: return 7
        case .fortios: return 8
        case .gaia: return 9
        case .linux: return 10
        }
    }
}
