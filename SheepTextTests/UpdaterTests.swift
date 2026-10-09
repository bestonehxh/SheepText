import CryptoKit
import Foundation
import XCTest
@testable import SheepText

// The in-app updater's pure half (SheepText/Update/UpdateCore.swift) and its install
// helper script, run for real in a scratch directory. Ported from SheepTerm's
// Tests/tests/UpdaterTests.swift (9 Oct 2026) with its check/eq harness mapped onto XCTest.

final class UpdaterTests: XCTestCase {
    func testUpdater() { runUpdaterChecks() }
}

/// The repository root: this file is <root>/SheepTextTests/UpdaterTests.swift.
private let updPackageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

private func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(cond, "\(name) \(detail())", file: file, line: line)
}

private func eq<T: Equatable>(_ a: T, _ b: T, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a, b, name, file: file, line: line)
}

private let updTestConfig = UpdateConfig(appName: "SheepText", repository: "bestonehxh/SheepText",
                                         tagScheme: .build, publicKeyBase64: "",
                                         signingKeychainService: "test")

private func updV(_ m: String, _ b: Int?) -> UpdateVersion { UpdateVersion(marketing: m, build: b) }

/// Runs a tool and waits; exit status.
@discardableResult
private func updRun(_ tool: String, _ args: [String], env: [String: String]? = nil) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if let env { p.environment = env }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// A minimal app bundle: Info.plist + an executable + a marker file.
private func updMakeBundle(at app: URL, id: String = "Bestchaan.SheepText", short: String, build: String,
                           marker: String, executable: Bool = true) {
    let fm = FileManager.default
    try? fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": short,
                                "CFBundleVersion": build, "CFBundleExecutable": "SheepText"]
    let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try! data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    if executable {
        let exe = app.appendingPathComponent("Contents/MacOS/SheepText")
        try! Data("#!/bin/sh\n".utf8).write(to: exe)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }
    try! Data(marker.utf8).write(to: app.appendingPathComponent("Contents/marker"))
}

private func updMarker(_ app: String) -> String? {
    (try? String(contentsOfFile: app + "/Contents/marker", encoding: .utf8))
}

private func updReleaseJSON(tag: String = "v5.0-1", assets: [(String, String, Int)], html: String? = nil,
                            body: String = "Notes line\n\n---\nUnsigned build footer") -> Data {
    let list = assets.map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)","size":\#($0.2)}"# }
        .joined(separator: ",")
    let htmlField = html.map { #","html_url":"\#($0)""# } ?? ""
    let escaped = body.replacingOccurrences(of: "\n", with: "\\n")
    return Data(#"{"tag_name":"\#(tag)","draft":false,"prerelease":false,"body":"\#(escaped)","assets":[\#(list)]\#(htmlField)}"#.utf8)
}

private func runUpdaterChecks() {
    let scheme = UpdateConfig.TagScheme.build

    // ---- offer alert pages (5.0 (4): notes only behind Details…) ----
    eq(UpdateOfferAction.offerPage(hasNotes: true), [.install, .details, .later, .skip], "upd: offer page has Details when there are notes")
    eq(UpdateOfferAction.offerPage(hasNotes: false), [.install, .later, .skip], "upd: no notes → no Details button")
    eq(UpdateOfferAction.offerPage(hasNotes: true).map(\.title), ["Install & Relaunch", "Details…", "Later", "Skip This Version"], "upd: offer titles")
    eq(UpdateOfferAction.detailsPage, [.install, .back], "upd: details page = Install & Relaunch / Back")
    let withNotes = UpdateOfferAction.offerPage(hasNotes: true)
    eq(UpdateOfferAction.answer(1, on: withNotes), .details, "upd: second button opens Details")
    eq(UpdateOfferAction.answer(3, on: withNotes), .skip, "upd: fourth button skips")
    eq(UpdateOfferAction.answer(2, on: UpdateOfferAction.offerPage(hasNotes: false)), .skip, "upd: without notes the third button skips")
    for odd in [-1, 4, 99] {
        eq(UpdateOfferAction.answer(odd, on: withNotes), .later, "upd: answer \(odd) is Later, never an install")
    }
    eq(UpdateOfferAction.answer(1, on: UpdateOfferAction.detailsPage), .back, "upd: Back returns to the first page")
    let items = UpdateCore.noteItems("- First **bold** `code` item\n  wrapped tail\n\n* Second\nPlain line\n• Third")
    eq(items.map(\.text), ["First bold code item wrapped tail", "Second", "Plain line", "Third"], "upd: note items joined and cleaned")
    eq(items.map(\.bullet), [true, true, false, true], "upd: bullets vs plain lines")
    eq(UpdateCore.noteItems("").count, 0, "upd: no notes → no items")

    // ---- tags ----
    eq(UpdateCore.parseTag("v4.2-9", scheme: scheme), updV("4.2", 9), "upd: v4.2-9 parses")
    eq(UpdateCore.parseTag("v5.0-1", scheme: scheme), updV("5.0", 1), "upd: v5.0-1 parses")
    eq(UpdateCore.parseTag("v5.10-12", scheme: scheme), updV("5.10", 12), "upd: v5.10-12 parses")
    for bad in ["4.2-9", "v4.2", "v4.2-0", "v4.2-x", "v4.2-9-1", "v.2-1", "v4..2-1", "v4.2-9 ", "V4.2-9",
                "v4.2--9", "v-1", "v4.2-+9", "v4.2-٣", "v1.2.3.4.5-1", ""] {
        check(UpdateCore.parseTag(bad, scheme: scheme) == nil, "upd: tag '\(bad)' refused")
    }
    eq(UpdateCore.parseTag("v3.7", scheme: .semver), updV("3.7", nil), "upd: semver v3.7 parses")
    check(UpdateCore.parseTag("v3.7-1", scheme: .semver) == nil, "upd: semver refuses a build suffix")
    eq(UpdateCore.tag(for: updV("5.0", 1), scheme: scheme), "v5.0-1", "upd: tag round-trip")
    eq(UpdateCore.zipName(for: updV("5.0", 1), config: updTestConfig), "SheepText-5.0-1.zip", "upd: zip name (build scheme)")
    eq(UpdateCore.currentVersion(shortVersion: "4.2", bundleVersion: "9", scheme: scheme), updV("4.2", 9), "upd: current version from Info.plist")
    check(UpdateCore.currentVersion(shortVersion: "4.2", bundleVersion: nil, scheme: scheme) == nil, "upd: no CFBundleVersion → unknown")

    // ---- ordering: marketing first, then build (the build resets at 5.0) ----
    let newer: [(String, Int, String, Int, Bool)] = [
        ("5.0", 1, "4.2", 9, true),     // 4.2 (9) → 5.0 (1) is an upgrade
        ("4.2", 9, "5.0", 1, false),    // …and not the other way round
        ("5.0", 2, "5.0", 1, true),
        ("5.1", 1, "5.0", 30, true),
        ("5.10", 1, "5.9", 1, true),
        ("5.9", 1, "5.10", 1, false),
        ("5.0", 1, "5.0", 1, false),
        ("5.0", 30, "5.1", 1, false),
        ("4.2", 10, "4.2", 9, true),
        ("5.0.0", 2, "5.0", 1, true),   // 5.0.0 == 5.0, so the build decides
        ("5.0.0", 1, "5.0", 1, false),
        ("5.0.1", 1, "5.0", 9, true),
    ]
    for (cm, cb, om, ob, want) in newer {
        eq(UpdateCore.isNewer(updV(cm, cb), than: updV(om, ob), scheme: scheme), want,
           "upd: \(cm) (\(cb)) newer than \(om) (\(ob)) == \(want)")
    }
    check(UpdateCore.isNewer(updV("3.10", nil), than: updV("3.9", nil), scheme: .semver), "upd: semver 3.10 > 3.9")
    check(!UpdateCore.isNewer(updV("3.9", nil), than: updV("3.9", nil), scheme: .semver), "upd: semver equal is not newer")

    // ---- when to check: every launch after 5 s, then every 24 h this run ----
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    check(UpdateCore.nextAutoCheckDelay(enabled: false, inFlight: false, lastCheckThisRun: nil, now: now) == nil, "upd: toggle off → no automatic check")
    check(UpdateCore.nextAutoCheckDelay(enabled: true, inFlight: true, lastCheckThisRun: nil, now: now) == nil, "upd: never two at once")
    eq(UpdateCore.nextAutoCheckDelay(enabled: true, inFlight: false, lastCheckThisRun: nil, now: now), 5, "upd: every launch checks after 5 s")
    eq(UpdateCore.nextAutoCheckDelay(enabled: true, inFlight: false, lastCheckThisRun: now.addingTimeInterval(-3600), now: now),
       23 * 3600, "upd: an hour after a check, the next is 23 h away")
    eq(UpdateCore.nextAutoCheckDelay(enabled: true, inFlight: false, lastCheckThisRun: now.addingTimeInterval(-25 * 3600), now: now),
       0, "upd: past 24 h → due now")
    eq(UpdateCore.nextAutoCheckDelay(enabled: true, inFlight: false, lastCheckThisRun: now.addingTimeInterval(24 * 3600), now: now),
       0, "upd: a clock that went backwards → due now")

    // ---- what to do with the latest release ----
    let cur = updV("4.2", 9)
    eq(UpdateCore.decide(latest: updV("5.0", 1), current: cur, skippedTag: nil, manual: false, scheme: scheme), .offer, "upd: newer → offer")
    eq(UpdateCore.decide(latest: updV("4.2", 9), current: cur, skippedTag: nil, manual: true, scheme: scheme), .upToDate, "upd: same → up to date")
    eq(UpdateCore.decide(latest: updV("4.2", 8), current: cur, skippedTag: nil, manual: false, scheme: scheme), .upToDate, "upd: older → up to date")
    eq(UpdateCore.decide(latest: updV("5.0", 1), current: cur, skippedTag: "v5.0-1", manual: false, scheme: scheme), .skipped, "upd: skipped version stays quiet (automatic)")
    eq(UpdateCore.decide(latest: updV("5.0", 1), current: cur, skippedTag: "v5.0-1", manual: true, scheme: scheme), .offer, "upd: a manual check ignores the skip")
    eq(UpdateCore.decide(latest: updV("5.0", 2), current: cur, skippedTag: "v5.0-1", manual: false, scheme: scheme), .offer, "upd: a release after the skipped one is offered")
    eq(UpdateCore.decide(latest: updV("5.0", 1), current: cur, skippedTag: "garbage", manual: false, scheme: scheme), .offer, "upd: an unreadable skip is ignored")

    // ---- HTTP status ----
    check(UpdateCore.statusError(200) == nil, "upd: 200 ok")
    eq(UpdateCore.statusError(403), .rateLimited, "upd: 403 = rate limited")
    eq(UpdateCore.statusError(429), .rateLimited, "upd: 429 = rate limited")
    eq(UpdateCore.statusError(404), .noRelease, "upd: 404 = no release")
    eq(UpdateCore.statusError(500), .badStatus(500), "upd: 500 = bad status")

    // ---- asset + signature selection ----
    let base = "https://github.com/bestonehxh/SheepText/releases/download/v5.0-1/"
    let good: [(String, String, Int)] = [
        ("SheepText-5.0-1.zip.zip", base + "SheepText-5.0-1.zip.zip", 10),   // decoy, never chosen
        ("SheepText-5.0-1.zip", base + "SheepText-5.0-1.zip", 12_000_000),
        ("SheepText-5.0-1.zip.sig", base + "SheepText-5.0-1.zip.sig", 89),
    ]
    do {
        let release = try UpdateCore.decodeRelease(updReleaseJSON(assets: good, html: "https://github.com/bestonehxh/SheepText/releases/tag/v5.0-1"))
        let offer = try UpdateCore.offer(from: release, config: updTestConfig)
        eq(offer.version, updV("5.0", 1), "upd: offer version")
        eq(offer.zipName, "SheepText-5.0-1.zip", "upd: offer picks the exact zip name")
        eq(offer.zipURL.absoluteString, base + "SheepText-5.0-1.zip", "upd: zip URL")
        eq(offer.signatureURL.absoluteString, base + "SheepText-5.0-1.zip.sig", "upd: sig URL")
        eq(offer.zipSize, 12_000_000, "upd: zip size carried")
        eq(offer.notes, "Notes line", "upd: notes cut at the --- footer")
        eq(offer.page.absoluteString, "https://github.com/bestonehxh/SheepText/releases/tag/v5.0-1", "upd: release page kept")
    } catch {
        check(false, "upd: good release reads", "\(error)")
    }
    func offerError(_ assets: [(String, String, Int)], tag: String = "v5.0-1") -> UpdateError? {
        do {
            _ = try UpdateCore.offer(from: try UpdateCore.decodeRelease(updReleaseJSON(tag: tag, assets: assets)), config: updTestConfig)
            return nil
        } catch { return error }
    }
    eq(offerError(Array(good.prefix(2))), .missingSignature("SheepText-5.0-1.zip.sig"), "upd: no .sig → refused")
    eq(offerError([good[0], good[2]]), .missingAsset("SheepText-5.0-1.zip"), "upd: no zip → refused")
    eq(offerError(good, tag: "latest"), .unrecognisedTag("latest"), "upd: unrecognised tag")
    let evil = "https://github.com/bestonehxh/SheepTextEvil/releases/download/v5.0-1/SheepText-5.0-1.zip"
    eq(offerError([("SheepText-5.0-1.zip", evil, 5), good[2]]), .untrustedURL(evil), "upd: another repo's URL refused")
    let plain = "http://github.com/bestonehxh/SheepText/releases/download/v5.0-1/SheepText-5.0-1.zip"
    eq(offerError([("SheepText-5.0-1.zip", plain, 5), good[2]]), .untrustedURL(plain), "upd: http refused")
    let other = "https://example.com/bestonehxh/SheepText/releases/download/v5.0-1/SheepText-5.0-1.zip"
    eq(offerError([("SheepText-5.0-1.zip", other, 5), good[2]]), .untrustedURL(other), "upd: another host refused")
    let sigEvil = "https://github.com/someone/SheepText/releases/download/v5.0-1/x.sig"
    eq(offerError([good[1], ("SheepText-5.0-1.zip.sig", sigEvil, 89)]), .untrustedURL(sigEvil), "upd: sig from elsewhere refused")
    eq(offerError([("SheepText-5.0-1.zip", base + "SheepText-5.0-1.zip", 0), good[2]]), .tooLarge("SheepText-5.0-1.zip"), "upd: empty zip refused")
    eq(offerError([("SheepText-5.0-1.zip", base + "SheepText-5.0-1.zip", UpdateCore.maxZipBytes + 1), good[2]]), .tooLarge("SheepText-5.0-1.zip"), "upd: huge zip refused")
    eq(offerError([good[1], ("SheepText-5.0-1.zip.sig", base + "SheepText-5.0-1.zip.sig", 5000)]), .tooLarge("SheepText-5.0-1.zip.sig"), "upd: huge sig refused")
    do {
        _ = try UpdateCore.decodeRelease(Data("<html>rate limited</html>".utf8))
        check(false, "upd: garbage JSON refused")
    } catch { eq(error, .unreadableRelease, "upd: garbage JSON → unreadable") }
    eq(UpdateCore.releasePage("file:///etc/passwd", config: updTestConfig), updTestConfig.releasesPage, "upd: file:// page → releases page")
    eq(UpdateCore.releasePage("https://github.com/bestonehxh/SheepTextX/releases", config: updTestConfig), updTestConfig.releasesPage, "upd: other repo page → releases page")
    eq(UpdateCore.releasePage(nil, config: updTestConfig), updTestConfig.releasesPage, "upd: no page → releases page")

    // ---- release notes ----
    eq(UpdateCore.capNotes("\n\nA\nB\n---\nfooter"), "A\nB", "upd: notes trimmed, footer dropped")
    eq(UpdateCore.capNotes("a\u{1b}[31mb\u{7}\tc"), "a[31mb\tc", "upd: control characters removed, tab kept")
    let many = (1...100).map { "line \($0)" }.joined(separator: "\n")
    let cappedLines = UpdateCore.capNotes(many, maxLines: 10)
    check(cappedLines.hasPrefix("line 1\n") && cappedLines.contains("line 10") && !cappedLines.contains("line 11"), "upd: notes capped by lines")
    check(cappedLines.hasSuffix("(the full notes are on the release page)"), "upd: a capped note says so")
    let long = UpdateCore.capNotes(String(repeating: "x", count: 10_000), maxCharacters: 100)
    check(long.hasPrefix(String(repeating: "x", count: 100)) && !long.hasPrefix(String(repeating: "x", count: 101)), "upd: notes capped by characters")
    eq(UpdateCore.capNotes("short"), "short", "upd: short notes untouched")
    eq(UpdateCore.capNotes(""), "", "upd: empty notes")

    // ---- signatures: a throwaway key ----
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let payload = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let sig = try! key.signature(for: payload)
    let sigText = Data((sig.base64EncodedString() + "\n").utf8)
    check(UpdateCore.verifySignature(of: payload, signatureText: sigText, publicKeyBase64: pub), "upd: signature round trip verifies")
    var flipped = payload; flipped[1234] ^= 0x01
    check(!UpdateCore.verifySignature(of: flipped, signatureText: sigText, publicKeyBase64: pub), "upd: a flipped byte is refused")
    check(!UpdateCore.verifySignature(of: payload + Data([0]), signatureText: sigText, publicKeyBase64: pub), "upd: an appended byte is refused")
    let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    check(!UpdateCore.verifySignature(of: payload, signatureText: sigText, publicKeyBase64: otherKey), "upd: the wrong key is refused")
    let truncated = Data(sig.prefix(63).base64EncodedString().utf8)
    check(!UpdateCore.verifySignature(of: payload, signatureText: truncated, publicKeyBase64: pub), "upd: a truncated signature is refused")
    check(!UpdateCore.verifySignature(of: payload, signatureText: Data("not*base64!".utf8), publicKeyBase64: pub), "upd: non-base64 signature is refused")
    check(!UpdateCore.verifySignature(of: payload, signatureText: Data(), publicKeyBase64: pub), "upd: an empty signature is refused")
    check(!UpdateCore.verifySignature(of: payload, signatureText: sigText, publicKeyBase64: ""), "upd: no public key → refused")
    check(!UpdateCore.verifySignature(of: payload, signatureText: sigText + Data(repeating: 0x20, count: 2000), publicKeyBase64: pub), "upd: an oversized .sig is refused")
    var badSig = Data(sig); badSig[0] ^= 0x80
    check(!UpdateCore.verifySignature(of: payload, signatureText: Data(badSig.base64EncodedString().utf8), publicKeyBase64: pub), "upd: a corrupted signature is refused")

    // ---- the embedded key == `.ship.conf`'s, and it is a real Ed25519 key ----
    let appFile = (try? String(contentsOf: updPackageRoot.appendingPathComponent("SheepText/App/SheepTextUpdate.swift"), encoding: .utf8)) ?? ""
    let conf = (try? String(contentsOf: updPackageRoot.appendingPathComponent(".ship.conf"), encoding: .utf8)) ?? ""
    func firstMatch(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
    let embedded = firstMatch(#"publicKeyBase64: "([A-Za-z0-9+/=]+)""#, appFile)
    let shipped = firstMatch(#"UPDATE_SIGN_PUBLIC_KEY="([A-Za-z0-9+/=]+)""#, conf)
    check(embedded != nil, "upd: the app embeds a public key")
    // .ship.conf stays in the private repo; the public tree (which ships these tests) has none.
    if !conf.isEmpty {
        eq(embedded, shipped, "upd: .ship.conf signs with the key the app embeds")
    }

    // ---- SheepText's own config: semver tags and zips (.ship.conf VERSION_SCHEME) ----
    let app = UpdateConfig.sheepText
    eq(app.appName, "SheepText", "upd: app name")
    eq(app.repository, "bestonehxh/SheepText", "upd: public repository")
    eq(app.signingKeychainService, "Bestchaan.SheepText.update-signing", "upd: Keychain service")
    if !conf.isEmpty {
        eq(firstMatch(#"UPDATE_SIGN_KEYCHAIN_SERVICE="([^"]+)""#, conf), app.signingKeychainService, "upd: .ship.conf names the same Keychain service")
    }
    eq(UpdateCore.parseTag("v3.8", scheme: app.tagScheme), updV("3.8", nil), "upd: SheepText's v3.8 parses")
    eq(UpdateCore.tag(for: updV("3.8", nil), scheme: app.tagScheme), "v3.8", "upd: SheepText tag")
    eq(UpdateCore.zipName(for: updV("3.8", nil), config: app), "SheepText-3.8.zip", "upd: SheepText zip name")
    check(embedded.flatMap { Data(base64Encoded: $0) }.flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } != nil,
          "upd: the embedded key is a valid Ed25519 public key")

    testUpdaterBundles()
    testUpdaterHelperScript()
}

/// `inspectExtracted` and `installTarget` against fake bundles on disk.
private func testUpdaterBundles() {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sheeptext-upd-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    var n = 0
    func fresh() -> URL {
        n += 1
        let dir = root.appendingPathComponent("x\(n)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    let current = updV("4.2", 9)
    func inspect(_ dir: URL, current: UpdateVersion = current, advertised: UpdateVersion = updV("5.0", 1)) -> UpdateError? {
        do {
            _ = try UpdateCore.inspectExtracted(at: dir, config: updTestConfig, bundleIdentifier: "Bestchaan.SheepText",
                                                current: current, advertised: advertised)
            return nil
        } catch { return error }
    }

    var d = fresh()
    updMakeBundle(at: d.appendingPathComponent("SheepText.app"), short: "5.0", build: "1", marker: "new")
    check(inspect(d) == nil, "upd: 5.0 (1) over 4.2 (9) passes inspection", "\(String(describing: inspect(d)))")
    check(inspect(d, current: updV("5.0", 1)) != nil, "upd: the same version is refused")
    check(inspect(d, current: updV("5.0", 2)) != nil, "upd: 5.0 (1) over 5.0 (2) is refused")
    check(inspect(d, advertised: updV("5.0", 2)) != nil, "upd: bundle ≠ advertised build is refused")
    check(inspect(d, advertised: updV("5.1", 1)) != nil, "upd: bundle ≠ advertised marketing is refused")

    d = fresh()
    updMakeBundle(at: d.appendingPathComponent("SheepText.app"), short: "4.2", build: "10", marker: "new")
    check(inspect(d, current: updV("5.0", 1), advertised: updV("4.2", 10)) != nil, "upd: 5.0 (1) over 5.0 (1) is refused (downgrade)")

    d = fresh()
    updMakeBundle(at: d.appendingPathComponent("SheepText.app"), short: "5.0", build: "1", marker: "a")
    updMakeBundle(at: d.appendingPathComponent("Other.app"), short: "5.0", build: "1", marker: "b")
    check(inspect(d) != nil, "upd: two apps in the zip are refused")

    d = fresh()
    updMakeBundle(at: d.appendingPathComponent("SheepText.app"), short: "5.0", build: "1", marker: "a")
    try? Data("x".utf8).write(to: d.appendingPathComponent("README"))
    check(inspect(d) != nil, "upd: an extra file beside the app is refused")

    d = fresh()
    updMakeBundle(at: d.appendingPathComponent("SheepText.app"), id: "com.evil.SheepText", short: "5.0", build: "1", marker: "a")
    check(inspect(d) != nil, "upd: another bundle identifier is refused")

    d = fresh()
    updMakeBundle(at: d.appendingPathComponent("Sheep.app"), short: "5.0", build: "1", marker: "a")
    check(inspect(d) != nil, "upd: a differently named app is refused")

    d = fresh()
    updMakeBundle(at: d.appendingPathComponent("SheepText.app"), short: "5.0", build: "1", marker: "a", executable: false)
    check(inspect(d) != nil, "upd: an app without its executable is refused")

    d = fresh()
    let real = fresh()
    updMakeBundle(at: real.appendingPathComponent("SheepText.app"), short: "5.0", build: "1", marker: "a")
    try? fm.createSymbolicLink(at: d.appendingPathComponent("SheepText.app"), withDestinationURL: real.appendingPathComponent("SheepText.app"))
    check(inspect(d) != nil, "upd: a symlinked .app is refused")

    d = fresh()
    check(inspect(d) != nil, "upd: an empty archive is refused")

    // Install target: only a writable bundle in /Applications.
    check(UpdateCore.installTarget(bundleURL: root.appendingPathComponent("x1/SheepText.app")) == nil, "upd: outside /Applications → reveal instead")
    check(UpdateCore.installTarget(bundleURL: URL(fileURLWithPath: "/Applications/../tmp/SheepText.app")) == nil, "upd: /Applications/.. does not count")
    check(UpdateCore.installTarget(bundleURL: URL(fileURLWithPath: "/Applications/NoSuchSheepTextForTests.app")) == nil, "upd: a missing bundle is not writable")
    check(UpdateCore.installTarget(bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/SheepText.app")) == nil, "upd: a translocated copy → reveal")
    let backup = UpdateCore.backupPath(for: URL(fileURLWithPath: "/Applications/SheepText.app"), stamp: "42")
    eq(backup, "/Applications/.SheepText-previous-42.app", "upd: the backup sits beside the app (same volume → rename)")
}

/// The real helper script, run by /bin/sh against fake bundles.
private func testUpdaterHelperScript() {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sheeptext-updsh-\(UUID().uuidString)")
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        _ = updRun("/bin/chmod", ["-R", "u+w", root.path])
        try? fm.removeItem(at: root)
    }
    let script = root.appendingPathComponent("install.sh")
    try! Data(UpdateCore.helperScript.utf8).write(to: script)
    let opener = root.appendingPathComponent("opener.sh")
    let opened = root.appendingPathComponent("opened.txt")
    try! Data("#!/bin/sh\necho \"$1\" >> '\(opened.path)'\n".utf8).write(to: opener)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)

    struct Scene { var apps: URL; var target: String; var work: URL; var new: String; var backup: String; var log: String }
    var n = 0
    func scene() -> Scene {
        n += 1
        let apps = root.appendingPathComponent("Applications\(n)")
        let work = root.appendingPathComponent("work\(n)")
        try! fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try! fm.createDirectory(at: work.appendingPathComponent("extracted"), withIntermediateDirectories: true)
        let target = apps.appendingPathComponent("SheepText.app")
        let new = work.appendingPathComponent("extracted/SheepText.app")
        updMakeBundle(at: target, short: "4.2", build: "9", marker: "old")
        updMakeBundle(at: new, short: "5.0", build: "1", marker: "new")
        try? fm.removeItem(at: opened)
        return Scene(apps: apps, target: target.path, work: work, new: new.path,
                     backup: UpdateCore.backupPath(for: target, stamp: "t\(n)"),
                     log: root.appendingPathComponent("log\(n).txt").path)
    }
    func helper(_ s: Scene, pid: String, waitTenths: String = "100") -> Int32 {
        updRun("/bin/sh", [script.path, pid, s.target, s.new, s.backup, s.work.path, s.log],
               env: ["PATH": "/usr/bin:/bin", "SHEEP_UPDATE_OPEN": opener.path, "SHEEP_UPDATE_WAIT_TENTHS": waitTenths])
    }
    func openedPaths() -> [String] {
        ((try? String(contentsOf: opened, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    func sleeper(_ seconds: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = [seconds]
        try! p.run()
        return p
    }

    // 1. Happy path: waits for the PID, swaps, strips quarantine, cleans up, relaunches.
    var s = scene()
    _ = updRun("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;00000000;Test;", s.new])
    let app = sleeper("0.6")
    let started = Date()
    var status = helper(s, pid: String(app.processIdentifier))
    let waited = Date().timeIntervalSince(started)
    app.waitUntilExit()
    eq(status, 0, "upd helper: install succeeds")
    check(waited >= 0.4, "upd helper: waited for the app to exit first", "\(waited) s")
    eq(updMarker(s.target), "new", "upd helper: the new bundle is in place")
    check(!fm.fileExists(atPath: s.backup), "upd helper: the backup is deleted on success")
    check(!fm.fileExists(atPath: s.work.path), "upd helper: the work directory is removed")
    eq(openedPaths(), [s.target], "upd helper: relaunches the installed app")
    check(updRun("/usr/bin/xattr", ["-p", "com.apple.quarantine", s.target]) != 0, "upd helper: quarantine stripped")
    check((try? String(contentsOfFile: s.log, encoding: .utf8))?.contains("installed") == true, "upd helper: logs the install")

    // 2. Moving the new bundle in fails → the old one is restored and relaunched.
    s = scene()
    _ = updRun("/bin/chmod", ["555", s.work.appendingPathComponent("extracted").path])
    status = helper(s, pid: "999999")
    _ = updRun("/bin/chmod", ["755", s.work.appendingPathComponent("extracted").path])
    eq(status, 70, "upd helper: a failed move reports the restore")
    eq(updMarker(s.target), "old", "upd helper: the old bundle is restored")
    check(!fm.fileExists(atPath: s.backup), "upd helper: nothing left at the backup path after a restore")
    // (The work directory is not checked here: the read-only folder that
    // made the move fail also stops its removal — drop_work is best effort.)
    eq(openedPaths(), [s.target], "upd helper: relaunches the old app after a restore")

    // 3. The app never exits → nothing changes.
    s = scene()
    let stuck = sleeper("30")
    status = helper(s, pid: String(stuck.processIdentifier), waitTenths: "3")
    stuck.terminate(); stuck.waitUntilExit()
    eq(status, 65, "upd helper: gives up when the app does not exit")
    check(UpdateCore.helperScript.contains("SHEEP_UPDATE_WAIT_TENTHS:-18000"), "upd helper: default wait is 30 min (Quit can sit on a log report)")
    eq(updMarker(s.target), "old", "upd helper: …and changes nothing")
    check(!fm.fileExists(atPath: s.work.path), "upd helper: …the work directory is removed")
    eq(openedPaths(), [], "upd helper: …and launches nothing")

    // 4. Missing new bundle / occupied backup path / bad arguments → nothing changes.
    s = scene()
    try! fm.removeItem(atPath: s.new)
    eq(helper(s, pid: "999999"), 66, "upd helper: a missing new bundle is refused")
    eq(updMarker(s.target), "old", "upd helper: …old app untouched")
    check(!fm.fileExists(atPath: s.work.path), "upd helper: …the work directory is removed")
    s = scene()
    try! fm.createDirectory(atPath: s.backup, withIntermediateDirectories: true)
    eq(helper(s, pid: "999999"), 67, "upd helper: an occupied backup path is refused")
    eq(updMarker(s.target), "old", "upd helper: …old app untouched")
    check(!fm.fileExists(atPath: s.work.path), "upd helper: …the work directory is removed")
    check(fm.fileExists(atPath: s.backup), "upd helper: …and the stranger at the backup path is left alone")
    s = scene()
    eq(helper(s, pid: "12x"), 64, "upd helper: a bad PID is refused")
    check(fm.fileExists(atPath: s.work.path), "upd helper: …and bad arguments delete nothing")
    var relative = s; relative.target = "SheepText.app"
    eq(helper(relative, pid: "999999"), 64, "upd helper: a relative path is refused")
    eq(updMarker(s.target), "old", "upd helper: …old app untouched")
    eq(openedPaths(), [], "upd helper: refusals launch nothing")
}
