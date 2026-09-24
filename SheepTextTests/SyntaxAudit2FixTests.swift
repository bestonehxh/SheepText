//
//  SyntaxAudit2FixTests.swift
//  Regression tests for the syntax-engine findings of the 2026-09-17 audit.
//
//  S3  the Cisco `vlan` validator painted real IOS global commands red
//  S8  a VLAN list written with spaces after its commas validated one item
//  S4  the vendor fingerprint locked prose `.txt` on a single English word
//  S5  NBSP and the Unicode line separators counted as word bytes
//  S1  the markdown widening loop could return ranges wider than its injections
//  S2  non-markdown injections got no changed-range widening at all
//  S6  `network_config:arubaCX` degraded to `.auto` once the id was lowercased
//  S7  the markdown highlights-only temp copy was never refreshed
//
//  The through-line for the network-config half is the promise the language
//  makes to the person it was written for: **red means wrong**. A missed red is
//  a gap; a false red on `vlan internal allocation policy ascending` — which
//  most Catalyst switches emit by default — is worse, because it trains the
//  reader to ignore the colour.
//

import AppKit
import XCTest
import NetworkHighlightKit
@testable import SheepText

@MainActor
final class SyntaxAudit2FixTests: XCTestCase {

    // MARK: - Helpers

    private func runs(_ text: String, language: String, documentID: UUID? = nil) -> [HighlightRun] {
        SyntaxEngine.shared.runsImmediately(
            text: text, language: language, documentID: documentID
        )?.runs ?? []
    }

    private func style(
        _ list: [HighlightRun], of token: String, in text: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> HighlightStyleID {
        let range = (text as NSString).range(of: token)
        guard range.location != NSNotFound else {
            XCTFail("token \(token) not in the fixture", file: file, line: line)
            return HighlightStyleTable.none
        }
        return HighlightRunList.style(at: range.location, in: list)
    }

    private var error: HighlightStyleID { HighlightStyleTable.styleID(forCapture: "error") }
    private var number: HighlightStyleID { HighlightStyleTable.styleID(forCapture: "number") }
    private var keyword: HighlightStyleID { HighlightStyleTable.styleID(forCapture: "keyword") }

    // MARK: - S3: the `vlan` globals are not errors

    /// Every one of these is a real line out of `show running-config` on a
    /// Catalyst or a Nexus. The second token is not a VLAN list, and painting it
    /// red said the config was broken when it was not.
    func testCiscoVlanGlobalCommandsAreNotErrors() {
        let lines = [
            "vlan internal allocation policy ascending",
            "vlan dot1q tag native",
            "vlan configuration 10-20",
            "vlan database",
            // The map's name is deliberately not a state word: the package's
            // scanner claims `blocked` / `down` wherever they appear, which is
            // its job and not what this test is about.
            "vlan access-map MAPA 10",
            "vlan filter MAP1 vlan-list 10-20",
            "vlan group ENG vlan-list 1-5",
            "vlan accounting input",
            "vlan name SALES"
        ]
        for line in lines {
            let source = line + "\n"
            let list = runs(source, language: "network_config:cisco")
            let second = (source as NSString).range(of: " ").location + 1
            XCTAssertNotEqual(
                HighlightRunList.style(at: second, in: list), error,
                "false red on `\(line)`"
            )
            // Nothing anywhere on the line may be red: these lines are correct.
            for run in list {
                XCTAssertNotEqual(
                    run.style, error,
                    "`\(line)` painted red at \(run.location)"
                )
            }
        }
    }

    /// …and the fix is not "delete the validator". A typo in a real list is
    /// still the reason this language exists.
    func testCiscoVlanListStillValidates() {
        let source = "vlan 1,3,23,101-102,306s\nvlan 4095\nvlan configuration 10,5000\n"
        let list = runs(source, language: "network_config:cisco")
        XCTAssertEqual(style(list, of: "306s", in: source), error)
        XCTAssertEqual(style(list, of: "4095", in: source), error)
        XCTAssertEqual(style(list, of: "5000", in: source), error)
        XCTAssertEqual(style(list, of: "101-102", in: source), number)
        // `vlan configuration` is a sub-command, so it is a keyword and its own
        // argument is the list.
        XCTAssertEqual(style(list, of: "configuration", in: source), keyword)
    }

    /// A leading `+` used to be accepted, because the validator leaned on
    /// `Int.init` and `Int("+5") == 5`. IOS does not take `vlan +5`.
    func testASignedVlanItemIsNotValid() {
        XCTAssertFalse(NetworkConfigHighlighter.isValidVlanItem("+5"))
        XCTAssertFalse(NetworkConfigHighlighter.isValidVlanItem("-5"))
        XCTAssertFalse(NetworkConfigHighlighter.isValidVlanItem("1-+5"))
        XCTAssertTrue(NetworkConfigHighlighter.isValidVlanItem("5"))
        XCTAssertTrue(NetworkConfigHighlighter.isValidVlanItem("1-4094"))
        XCTAssertFalse(NetworkConfigHighlighter.isValidVlanItem("4095"))
    }

    /// The validator is reached from the places a VLAN list actually appears,
    /// not only from a line that begins with `vlan`. `switchport trunk allowed
    /// vlan …` is the commonest of them and used to get no validation at all.
    func testTheVlanValidatorIsReachedThroughItsIntroducingKeyword() {
        let cases: [(line: String, bad: String)] = [
            (" switchport trunk allowed vlan 10,20,306s", "306s"),
            (" switchport trunk allowed vlan add 10,4095", "4095"),
            (" switchport access vlan 5000", "5000"),
            ("no vlan 9999", "9999"),
            (" spanning-tree vlan 0 priority 4096", "0"),
            ("vlan filter MAP1 vlan-list 10-5000", "10-5000")
        ]
        for (line, bad) in cases {
            let source = line + "\n"
            let list = runs(source, language: "network_config:cisco")
            XCTAssertEqual(
                style(list, of: bad, in: source), error,
                "`\(line)`: \(bad) should be red"
            )
        }

        // And the valid forms of the same lines are not.
        let good = """
         switchport trunk allowed vlan 10,20,30-40
         switchport trunk allowed vlan none
         switchport access vlan 100
         spanning-tree vlan 1-4094 priority 24576
        interface Vlan10
         switchport voice vlan dot1p

        """
        let list = runs(good, language: "network_config:cisco")
        for run in list {
            XCTAssertNotEqual(run.style, error, "false red at \(run.location) in the good fixture")
        }
        // `interface Vlan10` is an interface name, never a list.
        XCTAssertEqual(
            style(list, of: "Vlan10", in: good),
            HighlightStyleTable.styleID(forCapture: "type")
        )
    }

    /// `add` / `remove` / `except` are ordinary English AND ordinary CLI words.
    /// They continue a list that a `vlan` token already opened
    /// (`switchport trunk allowed vlan add 10,20`) and they mean nothing on
    /// their own — reading them as introducers anywhere on a line reddened
    /// numbers that are not VLAN ids at all.
    func testAListContinuationOnlyCountsAfterAVlanKeyword() {
        let innocent = """
        description add 5000 ports to po1
         remark remove 9999 later
        ip sla schedule 5 life forever except 70000
        snmp-server enable traps add 65535

        """
        let list = runs(innocent, language: "network_config:cisco")
        for run in list {
            XCTAssertNotEqual(
                run.style, error,
                "false red at \(run.location) in `\((innocent as NSString).substring(with: (innocent as NSString).lineRange(for: NSRange(location: run.location, length: 0))).trimmingCharacters(in: .newlines))`"
            )
        }

        // …and they still continue a list that `vlan` opened.
        for (line, bad) in [(" switchport trunk allowed vlan add 10,5000", "5000"),
                            (" switchport trunk allowed vlan remove 4095", "4095")] {
            let source = line + "\n"
            XCTAssertEqual(
                style(runs(source, language: "network_config:cisco"), of: bad, in: source), error,
                "`\(line)`: \(bad) should be red"
            )
        }
        for line in [" switchport trunk allowed vlan except 5-10",
                     " switchport trunk allowed vlan add 10,20,30-40"] {
            let source = line + "\n"
            let painted = runs(source, language: "network_config:cisco")
            XCTAssertFalse(painted.isEmpty, line)
            for run in painted {
                XCTAssertNotEqual(run.style, error, "false red in `\(line)`")
            }
            XCTAssertEqual(
                style(painted, of: line.contains("except") ? "5-10" : "30-40", in: source), number,
                "`\(line)`: the list should be validated, not ignored"
            )
        }
        // The plain form is untouched by any of this.
        let plain = "no vlan 4095\n"
        XCTAssertEqual(style(runs(plain, language: "network_config:cisco"), of: "4095", in: plain), error)
    }

    /// After `description`, `remark`, `banner`, `name`, `alias` and
    /// `snmp-server location|contact` the rest of the line is PROSE. The editor
    /// layer has no business validating a list, painting a sub-keyword or
    /// claiming a bare integer in it — whatever the package's scanner finds
    /// there (an address, an interface name, a state word) is its own affair.
    func testFreeTextCommandsLeaveTheRestOfTheLineAlone() {
        let source = """
         description uplink to vlan 5000x core
         description add 4095 trunk mode access
        interface GigabitEthernet1/0/1
         description spare port 24
         remark permit vlan 9999 for the audit
        banner motd ^ vlan 70000 maintenance window ^
        snmp-server location rack 12 vlan 65535
        snmp-server contact noc except 99999
        alias exec shrun show running-config vlan 88888
        vlan 10
         name SALES vlan 4095

        """
        let list = runs(source, language: "network_config:cisco")
        let ns = source as NSString
        for run in list {
            XCTAssertNotEqual(run.style, error, "false red at \(run.location)")
        }
        // Nothing in the prose is painted by the EDITOR layer. `24` after
        // `description spare port` used to come out number-orange.
        for token in ["5000x", "4095 trunk", "24", "9999", "70000", "65535", "99999", "88888"] {
            let range = ns.range(of: token)
            guard range.location != NSNotFound else { continue }
            XCTAssertEqual(
                HighlightRunList.style(at: range.location, in: list), HighlightStyleTable.none,
                "`\(token)` is inside free text and must stay plain"
            )
        }
        // The command word itself is still the command.
        XCTAssertEqual(style(list, of: "description", in: source), keyword)
        XCTAssertEqual(style(list, of: "banner", in: source), keyword)
        // And a real config line beside them still works.
        XCTAssertEqual(
            style(list, of: "GigabitEthernet1/0/1", in: source),
            HighlightStyleTable.styleID(forCapture: "type")
        )
        XCTAssertEqual(style(list, of: "vlan 10\n", in: source), keyword)
    }

    // MARK: - S8: a spaced list

    /// `vlan 10, 20, 5000` tokenises into three whitespace-delimited tokens. Only
    /// the first was judged; `5000` came out the same orange a validated item
    /// gets, which is the one thing this language must never do.
    func testASpacedVlanListValidatesEveryItem() {
        let source = "vlan 10, 20, 5000\n"
        let list = runs(source, language: "network_config:cisco")
        XCTAssertEqual(style(list, of: "10", in: source), number)
        XCTAssertEqual(style(list, of: "20", in: source), number)
        XCTAssertEqual(style(list, of: "5000", in: source), error)

        // The space itself is not part of any item's run.
        let ns = source as NSString
        let spaceBefore20 = ns.range(of: ", 20").location + 1
        XCTAssertEqual(
            HighlightRunList.style(at: spaceBefore20, in: list), HighlightStyleTable.none,
            "the blank between items must stay unpainted"
        )
    }

    // MARK: - S4: prose must not lock a vendor

    /// The signature table is written to one rule — *a wrong lock is worse than
    /// no lock* — and file mode broke it by inheriting the stream table's
    /// one-word banner signatures. A note that merely mentions Ubuntu was locked
    /// to `.linux`, whose editor rules paint every line's first word purple.
    func testProseThatMerelyMentionsAVendorStaysOnAuto() {
        let prose = [
            "Meeting notes 2026-09-17\nWe agreed to move the build box to Ubuntu 24.04 next month.\nAlso: ask Somchai about the invoice.\n",
            "Recipe notes\nThe centos of the plate should hold the sauce.\nServe warm.\n",
            "Runbook draft\nTo check the link, execute ping against the gateway first.\nThen escalate.\n",
            "The junos team shipped the release yesterday.\nNothing else to report.\n",
            "We run Debian GNU/Linux on the jump host and Red Hat Enterprise on the build farm.\n",
            "Fortigate and Palo Alto Networks were both quoted; pan-os won on price.\n",
            "Juniper Networks called about the nx-os migration and the Cisco IOS Software refresh.\n",
            "Grocery list\nbuy milk bread and eggs\ncall the plumber tomorrow\n"
        ]
        for text in prose {
            XCTAssertNil(
                NetworkConfigLanguage.detectVendor(in: text),
                "prose locked a vendor: \(text.prefix(40))"
            )
        }

        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/sheeptext-audit2-notes.txt"),
            initialText: prose[0], encoding: .utf8, hasBOM: false
        )
        XCTAssertEqual(doc.language, NetworkConfigLanguage.id)
        XCTAssertEqual(doc.networkVendor, .auto)
    }

    /// A real captured session still locks — the stream table is what SheepTerm
    /// feeds and it is unchanged.
    func testAStreamBannerStillLocksItsVendor() {
        var fingerprint = VendorFingerprint()
        XCTAssertEqual(
            fingerprint.consider(Array("Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0)\n".utf8)),
            .linux
        )
    }

    // MARK: - S5: Unicode separators are separators

    /// A config pasted out of a browser or a Confluence page carries NBSP where
    /// the spaces were. Both spans died: the address failed `boundaryAfter`
    /// (the NBSP's lead byte answered "word") and the mask failed
    /// `boundaryBefore`.
    func testANonBreakingSpaceIsABoundaryLikeAPlainSpace() {
        let nbsp = "\u{00A0}"
        let source = " ip address 10.0.0.1\(nbsp)255.255.255.0\n"
        let list = runs(source, language: "network_config:cisco")
        XCTAssertEqual(style(list, of: "10.0.0.1", in: source), number)
        XCTAssertEqual(style(list, of: "255.255.255.0", in: source), number)
    }

    /// U+2028/U+2029 split a line for `NSString.lineRange`, which is what the
    /// engine's incremental ranges are built from. The package split on `0x0A`
    /// alone, so the two disagreed about what a line is and incremental stopped
    /// equalling clean.
    func testUnicodeLineSeparatorsAgreeBetweenIncrementalAndClean() {
        for separator in ["\u{2028}", "\u{2029}", "\u{0085}"] {
            var lines: [String] = []
            for i in 0..<60 {
                lines.append("interface GigabitEthernet1/0/\(i % 24 + 1)")
                lines.append(" ip address 10.\(i % 250).0.1 255.255.255.0")
                lines.append("!")
            }
            let base = lines.joined(separator: separator) + separator
            let id = UUID()
            defer { SyntaxEngine.shared.discardSession(for: id) }
            _ = runs(base, language: "network_config:cisco", documentID: id)

            let ns = NSMutableString(string: base)
            for step in 0..<4 {
                let offset = ns.length / 2 + step * 29
                ns.replaceCharacters(in: NSRange(location: offset, length: 1), with: "x")
                let edited = ns as String
                XCTAssertEqual(
                    runs(edited, language: "network_config:cisco", documentID: id),
                    runs(edited, language: "network_config:cisco"),
                    "separator U+\(String(separator.unicodeScalars.first!.value, radix: 16)): "
                        + "incremental diverged at step \(step)"
                )
            }
        }
    }

    // MARK: - S6: the vendor resolves case-insensitively

    /// Every language id the app takes from outside goes through a lowercasing
    /// normaliser, and exactly two `Vendor` raw values are camelCase. A plugin's
    /// `editor.setLanguage("network_config:arubaCX", "cx")` therefore stored
    /// `network_config:arubacx`, which resolved to `.auto` — literal values
    /// only, silently.
    func testTheVendorResolvesCaseInsensitively() {
        XCTAssertEqual(
            NetworkConfigLanguage.vendor(forEngineLanguage: "network_config:arubacx"), .arubaCX
        )
        XCTAssertEqual(
            NetworkConfigLanguage.vendor(forEngineLanguage: "network_config:arubaos"), .arubaOS
        )
        XCTAssertEqual(
            NetworkConfigLanguage.vendor(forEngineLanguage: "NETWORK_CONFIG"), .auto
        )
        XCTAssertEqual(
            NetworkConfigLanguage.vendor(forEngineLanguage: "Network_Config:Cisco"), .cisco
        )
        XCTAssertNil(NetworkConfigLanguage.vendor(forEngineLanguage: "swift"))

        // Through the public door a plugin uses: `editor.setLanguage` lands in
        // `HighlightOverrides`, which lowercases everything it is handed.
        HighlightOverrides.shared.setLanguage("network_config:arubaCX", forFileExtension: "cxtest")
        defer { HighlightOverrides.shared.clearLanguage(forFileExtension: "cxtest") }
        let overridden = HighlightOverrides.shared.resolvedLanguage(
            for: URL(fileURLWithPath: "/tmp/sheeptext-audit2.cxtest"), defaultLanguage: "plaintext"
        )
        XCTAssertEqual(
            NetworkConfigLanguage.vendor(forEngineLanguage: overridden), .arubaCX,
            "a normalised (lowercased) id must still name its vendor"
        )
    }

    // MARK: - S1: markdown widening runs to a fixed point

    /// The widening loop gave up after four rounds and returned the ranges it
    /// had grown to together with the injections it had found BEFORE that last
    /// growth. Everything absorbed on the fourth round was inside the repainted
    /// bounds and not repainted, so `HighlightRunList.replacing` cleared its runs
    /// and nothing put them back.
    ///
    /// Only an ABUTTING chain cascades: `paragraphRanges` widens a range by one
    /// line, so it reaches the next region only when that region begins on the
    /// line after. Back-to-back fences do that, and four of them exhaust the
    /// cap — the fifth round never runs. What lands in the ranges on that last
    /// round is the line after the fourth fence, so a paragraph there is
    /// inside the repainted bounds with its `inline` injection missing from the
    /// list, and its `**bold**` loses its colour until a full pass.
    func testAParagraphAfterFourAbuttingFencesKeepsItsInlineMarkup() {
        var blocks: [String] = []
        for i in 0..<4 {
            blocks.append("```swift\nlet value\(i) = \(i)\nfunc make\(i)() -> Int { \(i) }\n```")
        }
        let base = "# Title\n\n" + blocks.joined(separator: "\n") + "\n"
            + "**bold** and `code` in the paragraph right after the last fence\n"
            + "\nordinary prose below it\n"
        assertIncrementalEqualsClean(
            base, edits: ["let value0 = 0", "let value0 = 9"], language: "markdown"
        )
    }

    /// The same cap with one more fence behind it, so the region that falls off
    /// the end is a fence body rather than a paragraph.
    func testSixAbuttingFencesKeepTheirHighlightsOnAnIncrementalPass() {
        var blocks: [String] = []
        for i in 0..<6 {
            blocks.append("```swift\nlet v\(i)=\(i)\n```")
        }
        let base = "# Title\n\n" + blocks.joined(separator: "\n") + "\n"
            + "**bold** trailing paragraph\n"
        assertIncrementalEqualsClean(
            base, edits: ["let v0=0", "let v0=9"], language: "markdown"
        )
    }

    // MARK: - S2: every injected language widens, not just markdown

    /// HTML's tree sees a `<script>` body as one `raw_text` token, so replacing
    /// `//` with `/*` is a one-character edit whose extent does not change and
    /// whose changed range is the edited line. Every line below it is now inside
    /// a JavaScript block comment, and those lines kept their old colours.
    func testOpeningABlockCommentInsideAScriptRepaintsTheRestOfIt() {
        var script: [String] = []
        for i in 0..<60 {
            script.append("  const value\(i) = compute(\(i), \"label-\(i)\");")
        }
        // A CLOSED comment at the foot, so opening one at the head really does
        // turn every line between into comment. JavaScript's `comment` token
        // needs its `*/`; an unterminated `/*` is an error node and recolours
        // nothing, which is why the obvious fixture proves nothing.
        script.append("  /* trailing note */")
        let head = "<!doctype html>\n<html>\n<head></head>\n<body>\n<script>\n"
        let tail = "\n</script>\n</body>\n</html>\n"
        let base = head + script.joined(separator: "\n") + tail
        assertIncrementalEqualsClean(
            base,
            edits: ["  const value0 = compute(0, \"label-0\");",
                    "  /*onst value0 = compute(0, \"label-0\");",
                    "  const value0 = compute(0, \"label-0\");"],
            language: "html"
        )
    }

    /// The same shape in CSS: opening a comment on the first line of a `<style>`
    /// block comments out the rest of it.
    func testOpeningABlockCommentInsideAStyleRepaintsTheRestOfIt() {
        var css: [String] = []
        for i in 0..<40 {
            css.append("  .rule\(i) { padding: \(i)px; color: blue; }")
        }
        css.append("  /* trailing note */")
        let base = "<html>\n<head><style>\n" + css.joined(separator: "\n")
            + "\n</style></head>\n<body>x</body>\n</html>\n"
        assertIncrementalEqualsClean(
            base,
            edits: ["  .rule0 { padding: 0px; color: blue; }",
                    "  /*ule0 { padding: 0px; color: blue; }"],
            language: "html"
        )
    }

    // MARK: - SP3: the synchronous precompute does not join someone else's queue

    /// `queue` is one serial queue every document shares, so a `queue.sync`
    /// from the main actor waits for what is ahead of it as well as for its own
    /// work — and nothing bounds what is ahead. The precompute caps its own
    /// input at 40 000 units; a document stays inside the engine up to a
    /// million characters.
    func testTheSynchronousPassGivesUpWhileTheQueueIsBusy() {
        let big = (0..<3_000).map { i in
            "## Section \(i)\nProse with **bold** and `code`.\n\n```swift\nlet v\(i) = \(i)\n```\n"
        }.joined()
        let busy = UUID()
        let finished = expectation(description: "the queued pass finishes")
        SyntaxEngine.shared.highlightRuns(
            text: big, language: "markdown", documentID: busy
        ) { _ in finished.fulfill() }

        // The pass above is counted at ENQUEUE, so it is already in the way.
        let started = DispatchTime.now().uptimeNanoseconds
        XCTAssertNil(
            SyntaxEngine.shared.runsImmediately(text: "let x = 1\n", language: "swift"),
            "the synchronous path queued itself behind an unbounded pass"
        )
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        XCTAssertLessThan(elapsedMS, 100, "giving up took \(elapsedMS) ms")

        wait(for: [finished], timeout: 120)
        SyntaxEngine.shared.discardSession(for: busy)

        // …and once the queue is genuinely free again it answers as it always
        // did. Other syntax/perf classes run concurrently in the full suite, so
        // completion of OUR pass does not prove nobody else queued one behind
        // it; treating that legitimate busy answer as a failure made this test
        // depend on the test runner's scheduling order.
        let freeDeadline = Date().addingTimeInterval(30)
        var immediate: SyntaxHighlightRuns?
        repeat {
            immediate = SyntaxEngine.shared.runsImmediately(text: "let x = 1\n", language: "swift")
            if immediate == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        } while immediate == nil && Date() < freeDeadline
        XCTAssertNotNil(immediate, "the syntax queue never became free after the concurrent workloads")
    }

    // MARK: - S7: a query override reaches both markdown grammars

    /// `highlightsOnlyDirectory` copies `highlights.scm` into the sandbox's
    /// temporary directory, which survives relaunches and app updates — and it
    /// used to skip the copy whenever a file was already there. So a shipped
    /// fix to the bundled query was never read, and a user's own override was
    /// copied to a path the bundled one already occupied and ignored.
    func testTheMarkdownHighlightsCopyTracksItsSource() throws {
        let fm = FileManager.default
        let source = fm.temporaryDirectory
            .appendingPathComponent("sheeptext-audit2-queries-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: source) }
        let src = source.appendingPathComponent("highlights.scm")

        for sentinel in ["(comment) @comment\n", "(comment) @comment\n(atx_heading) @text.title\n"] {
            try Data(sentinel.utf8).write(to: src)
            guard let dir = SyntaxEngine.highlightsOnlyDirectory(
                from: source, language: "markdown-audit2-probe"
            ) else {
                return XCTFail("no directory for \(sentinel.count) bytes")
            }
            let copied = try String(
                contentsOf: dir.appendingPathComponent("highlights.scm"), encoding: .utf8
            )
            XCTAssertEqual(copied, sentinel, "the copy did not follow its source")
        }
    }

    /// Walk a document through a series of one-token substitutions, comparing an
    /// incremental pass against a clean one at every step. Equality is the whole
    /// contract: the changed ranges are an optimisation, never a licence to
    /// produce a different answer.
    private func assertIncrementalEqualsClean(
        _ base: String, edits: [String], language: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let documentID = UUID()
        defer { SyntaxEngine.shared.discardSession(for: documentID) }

        var current = base
        _ = SyntaxEngine.shared.highlightImmediately(
            text: current, language: language, isDark: true, documentID: documentID
        )
        for step in 1..<edits.count {
            let replaced = current.replacingOccurrences(of: edits[step - 1], with: edits[step])
            XCTAssertNotEqual(replaced, current, "step \(step) changed nothing", file: file, line: line)
            current = replaced
            let incremental = SyntaxEngine.shared.highlightImmediately(
                text: current, language: language, isDark: true, documentID: documentID
            )
            let clean = SyntaxEngine.shared.highlightImmediately(
                text: current, language: language, isDark: true
            )
            XCTAssertNotNil(incremental, "step \(step)", file: file, line: line)
            XCTAssertNotNil(clean, "step \(step)", file: file, line: line)
            if let incremental, let clean {
                XCTAssertTrue(
                    incremental.isEqual(to: clean),
                    "\(language): incremental diverged from clean at step \(step)",
                    file: file, line: line
                )
            }
        }
    }
}
