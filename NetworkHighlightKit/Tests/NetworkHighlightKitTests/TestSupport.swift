import Foundation
import XCTest
@testable import NetworkHighlightKit

// MARK: - Deterministic PRNG

/// xorshift64 — same generator SheepTerm's harness uses, so a seeded fuzz run
/// replays identically on every machine and every run.
struct LCG {
    var s: UInt64 = 0x2545_F491_4F6C_DD1D
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

// MARK: - Span helpers

func describe(_ spans: [NetworkSpan]) -> String {
    spans.map { "\($0.range.lowerBound)+\($0.range.count):\($0.rule.rawValue)" }
        .joined(separator: " ")
}

/// Byte offsets of `token` inside `text`. Both are ASCII wherever this is used,
/// so a byte offset is also a UTF-16 offset.
func byteRange(of token: String, in text: String) -> Range<Int>? {
    let hay = Array(text.utf8), needle = Array(token.utf8)
    guard !needle.isEmpty, hay.count >= needle.count else { return nil }
    for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle {
        return i..<(i + needle.count)
    }
    return nil
}

func overlaps(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
    a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
}

/// `token` must be claimed by exactly one span, that span must be the WHOLE
/// token, and it must belong to `rule`. The "exactly one, whole" part is the
/// interesting half: it is what catches `Out-Of-Sync` being coloured as three
/// pieces, or `admin_down` losing its head to a bare `down`.
func assertClaims(
    _ vendor: Vendor, _ text: String, _ token: String, _ rule: NetworkRule,
    file: StaticString = #filePath, line: UInt = #line
) {
    guard let want = byteRange(of: token, in: text) else {
        XCTFail("sample does not contain \"\(token)\"", file: file, line: line)
        return
    }
    let touching = NetworkHighlighter(vendor: vendor).spans(in: text)
        .filter { overlaps($0.range, want) }
    XCTAssertTrue(
        touching.count == 1 && touching[0].range == want && touching[0].rule == rule,
        "[\(vendor.rawValue)] \"\(token)\" -> \(rule.rawValue), got \(describe(touching))",
        file: file, line: line
    )
}

/// No span of any of `rules` may touch `token` — the negative half, so a keyword
/// added for one family cannot quietly leak into another's pack.
func assertDoesNotClaim(
    _ vendor: Vendor, _ text: String, _ token: String, _ rules: [NetworkRule],
    file: StaticString = #filePath, line: UInt = #line
) {
    guard let want = byteRange(of: token, in: text) else {
        XCTFail("sample does not contain \"\(token)\"", file: file, line: line)
        return
    }
    let touching = NetworkHighlighter(vendor: vendor).spans(in: text)
        .filter { overlaps($0.range, want) }
    for rule in rules {
        XCTAssertFalse(
            touching.contains { $0.rule == rule },
            "[\(vendor.rawValue)] \"\(token)\" must not be \(rule.rawValue), got \(describe(touching))",
            file: file, line: line
        )
    }
}

let stateRules: [NetworkRule] = [.stateGood, .stateWarn, .stateBad]

// MARK: - Corpora

/// The vendor-neutral corpus, ported from SheepTerm's `Tests/tests/main.swift`.
let neutralCorpus: [String] = [
    "GigabitEthernet1/0/1 is up, line protocol is up",
    "Vlan10 192.168.1.1 255.255.255.0 down",
    "vlan 1,10,225-227 allowed on Po1",
    "interface Te1/1/4 err-disabled violation",
    "MAC aabb.ccdd.eeff and 00:11:22:33:44:55 seen",
    "2001:db8::1 and ::1 and fe80::1%en0",
    "10.0.0.1/24 permit tcp any any established",
    "999.999.999.999 not an ip, 255.255.255.255 is a mask",
    "no shutdown\r\nline vty 0 4",
    "WARNING: interface Fa0/1 notconnect, half duplex",
    "Port-channel1 up 100 GigE HundredGigE0/0/0/1",
    "critical alert emergency error err crit",
    "",
    "a",
    "::",
    "1:2:3:4:5:6:7:8 ffff::ffff",
    "2026-09-02T14:37:24.123456+07:00 up  *Sep  2 14:37:24.123: %LINK-3-UPDOWN",
    "1:2:3 a:b:c:d 12:34:56:78 1:2:3:4:5:6:7: :1:2 1:: :: 12345::1 2001:db8:::1",
    "255.0.0.0",
    "/32",
    "bond0 br0 ens192 eno1 mgmt0 lag5 Trk7",
    "show run | inc vlan",
    "100GE1/2/3 down down 0% 0% 0 0",
    "10GE1/1/17                 up       up        0.01%  0.01%",
    "10GE2/1/2                  *down    down",
    "interface Vlanif1039 / Eth-Trunk1000 / MEth0/0/0 / NULL0 / Stack-Port1/1",
    "undo shutdown\r\nundo portswitch",
    "vlan batch 2110 to 2113 2120 to 2126 2170",
    "vlan batch 1010 1034 1038 to 1039",
    "MAC 00e0-fc12-3456 learned on XGE1/0/1",
    "port trunk allow-pass vlan 1034",
    "board state normal, power abnormal, ap offline, timeout, fault faulty alarm",
    "1GE 4000GE9 10G 10GBASE-FIBER 100GE 40GE1/0/1",
    "Ten-GigabitEthernet1/0/1 Bridge-Aggregation10 Route-Aggregation2 M-GigabitEthernet0/0/0",
    "vlan 10 to 20 30 - 40, 50",
    "vlan batchelor 10 and vlan batch1010",
]

/// The per-vendor corpus, ported from SheepTerm's `vendorCorpus`.
let vendorCorpus: [String] = [
    // Juniper — the case cx-port used to tear in half
    "ge-0/0/0.0 up up  xe-0/0/1 et-0/0/2 ae0 irb.100 lo0.0 fxp0 reth1 st0.1 vlan.100",
    "Physical interface: ge-0/0/0, Enabled, Physical link is Up",
    "set interfaces xe-0/0/1 unit 0 family inet address 10.1.1.1/24",
    "me0 vme.0 em0 demux0 gr-1/2/3 vt-0/0/0",
    // Huawei / Comware
    "100GE1/2/3 down down 0% 0%   10GE1/1/17 up up   XGE1/0/1 Bridge-Aggregation10",
    "vlan batch 1010 1034 1038 to 1039 2110 to 2113",
    "interface Vlanif1039 / Eth-Trunk1000 / MEth0/0/0 / NULL0 / Stack-Port1/1",
    "MAC 00e0-fc12-3456 and aabb.ccdd.eeff and 00:11:22:33:44:55",
    "undo shutdown / no shutdown / board normal, ap offline, module fault",
    // Palo Alto
    "ethernet1/1 10.0.0.1/24 up layer3  vlan.1 tunnel.1 loopback.1 ae1",
    "rule Allow-Web from trust to untrust action allow service port 443",
    // FortiGate
    "port1 10.0.0.1 up  wan1 down  internal dmz agg1 ha1 ssl.root",
    "    set status enable\n    set dstport 443",
    // Aruba CX / ArubaOS / Check Point / Linux / Cisco
    "1/1/1 1/1/2 lag5 vlan 10 mgmt0  Trk7 gigabitethernet 0/0/1",
    "eth0 Up eth1 Down bond0 lo0 wrp128  eth1.100",
    "Mgmt Sync lo up   internal dmz modem mgt   lo0 mgmt0 loopback0",
    "ens192 eno1 enp3s0 br0 docker0 veth1a2b tun0 wlp2s0",
    "GigabitEthernet1/0/1 is up, line protocol is up, Te1/1/4 err-disabled",
    // shared traps
    "", "a", "255.255.255.0", "2001:db8::1 ::1", "999.999.999.999", "/32",
    "vlan batchelor 10 and vlan batch1010 and 4000GE9 and 10GBASE-FIBER",
    // cidr must follow an ADDRESS, never a port number
    "10.0.0.1/24 fe80::1/64 2001:db8::/32 10/8 /32 255.255.255.0/24",
    "Gi1/0/1 Fa0/1 100GE1/2/3 1/1/1 Te1/1/4 Se0/0/0:15 ge-0/0/0",
    "10.0.0.100/24 and 1.2.3.4/8 and 10.0.0.1/240",
    // Aruba CX: the columns and tokens the pack was extended for
    "1     DEFAULT_VLAN_1  up  ok  default  1/1/1,1/1/11-1/1/16,",
    "100   VLAN100  down  admin_down  static",
    "Base MAC Address : 3810f0-7ade00",
    "Event|402|LOG_WARN|AMM|1/1|Link status for port 1/1/17 is down",
    "Event|8003|LOG_ERR|AMM|1/1|Fan 1/2 fault",
    "LOG_WARN LOG_ERR LOG_CRIT LOG_ALERT LOG_EMER LOG_INFO LOG_DEBUG",
    "ISL channel : In-Sync  Config Sync Status : Out-Of-Sync",
    "NTP Status : Synchronized / Unsynchronized",
    "Status normal ok fault OK Normal faulty",
    "Fan 1/1 fan-tray-1 normal ok  Power supply PSU1 fault absent",
    "3810f0-7ade00 3810f0-7ade0 3810f07ade00 38-10-f0-7a-de-00 3810.f07a.de00",
    // ipv6 vs the clock: timestamps have the same shape as a short v6 run
    "2026-09-02T14:37:24.123456+07:00 CX6300M hpe-portd[2345]: Event|401|LOG_INFO|AMM|1/1|Link status for port 1/1/21 is up",
    "*Sep  2 14:37:24.123: %LINK-3-UPDOWN: Interface Gi1/0/1, changed state to down",
    "Link state: up for 2 weeks (since Wed Aug 19 07:00:00 +07 2026)",
    "1:2:3 a:b:c:d 12:34:56:78 1:2:3:4:5:6:7: :1:2",
    "2001:db8::1 ::1 fe80::1/64 1:: :: 2001:0db8:85a3:0000:0000:8a2e:0370:7334 2001:db8:1:2:3:4:5:6",
    "::ffff:192.168.0.1 fe80::1%vlan222 [2001:db8::1]:22",
    "1:2:3:4:5:6:7:8:9::1 12345::1 2001:db8:::1",
]

/// Atoms the fuzz assembles lines from — network-shaped, plus every near-miss a
/// rule has ever lost to.
let fuzzAtoms: [String] = [
    "Gi", "1/0/1", " ", "vlan", "10", ".", ":", "255", "up", "down", "-", "/", "eth",
    "aabb.ccdd.eeff", "2001:db8::", "abc", "0", "9", ",", "\t", "err-disabled",
    "no", "shutdown", "255.255.255.0", "192.168.0.1", "warn", "Po", "::1", "%", "]",
    "ge-0/0/0", "xe-", "ae0", "irb.", "100GE", "10GE", "GE", "XGE", "port1",
    "ethernet1/1", "eth0", "ens192", " batch ", " to ", "1010", "enable", "disable",
    "deny", "permit", "normal", "abnormal", "fault", "00e0-fc12-3456", "/24",
    "undo shutdown", "lag5", "1/1/1", "Trk7", "irb.100", "vlan.100", "tunnel.1",
    "Mgmt", "Sync", "lo", "lo0", "mgt", "mgmt", "mgmt0", "internal", "dmz",
    "modem", "docker0", "loopback", "lo0.0",
    "ok", "OK", "admin_down", "_", "LOG_WARN", "LOG_ERR", "LOG_INFO",
    "LOG_CRIT", "LOG_ALERT", "LOG_EMER", "In-Sync", "Out-Of-Sync",
    "Synchronized", "Unsynchronized", "3810f0-7ade00", "3810f0", "7ade00",
    "38-10-f0-7a-de-00", "aabbcc",
    "14:37:24", "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7:", "::", "T",
    // newlines are in the alphabet on purpose: every rule has to be line-local
    "\n", "\r\n",
]
