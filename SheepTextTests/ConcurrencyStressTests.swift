import AppKit
import XCTest
@testable import SheepText

/// The app's heaviest concurrency runs through GCD behind `@unchecked Sendable`,
/// which is exactly where the Swift 6 compiler stops checking. These drive those
/// surfaces hard enough for Thread Sanitizer to have something to catch; they
/// are near-worthless without it.
///
///     xcodebuild test -enableThreadSanitizer YES
///
final class ConcurrencyStressTests: XCTestCase {

    /// `SyntaxEngine` confines `sessions`, `parsers` and `configurations` to one
    /// serial queue and declares itself `@unchecked Sendable` on that basis.
    /// `highlight` hops onto the queue from the main actor while
    /// `discardSession` is nonisolated and can be called from anywhere, so the
    /// two can be in flight at once over the same dictionary.
    @MainActor
    func testConcurrentHighlightAndSessionDiscard() async {
        let source = """
        struct Value {
            let number: Int
            func doubled() -> Int { number * 2 }
        }

        """
        let documentIDs = (0..<8).map { _ in UUID() }
        let finished = expectation(description: "all highlights returned")
        finished.expectedFulfillmentCount = documentIDs.count * 3

        // Nonisolated, so these really do run off the main actor.
        for id in documentIDs {
            Task.detached(priority: .utility) {
                for _ in 0..<20 { SyntaxEngine.shared.discardSession(for: id) }
            }
        }

        for (index, id) in documentIDs.enumerated() {
            for pass in 0..<3 {
                let text = String(repeating: source, count: 4 + index) + "// pass \(pass)\n"
                SyntaxEngine.shared.highlightRuns(
                    text: text,
                    language: "swift",
                    documentID: id
                ) { _ in finished.fulfill() }
            }
        }

        // queue.sync from the main actor while all of the above is queued behind it.
        _ = SyntaxEngine.shared.highlightImmediately(
            text: source, language: "swift", isDark: true, documentID: documentIDs[0]
        )

        await fulfillment(of: [finished], timeout: 120)
        for id in documentIDs { SyntaxEngine.shared.discardSession(for: id) }
    }

    /// Two panes highlighting different documents at once is the everyday case
    /// this has to survive — one engine, one queue, two callers.
    @MainActor
    func testTwoDocumentsHighlightSimultaneously() async {
        let left = UUID(), right = UUID()
        let done = expectation(description: "both panes")
        done.expectedFulfillmentCount = 2
        SyntaxEngine.shared.highlightRuns(text: "let a = 1\n", language: "swift", documentID: left) { _ in done.fulfill() }
        SyntaxEngine.shared.highlightRuns(text: "let b = 2\n", language: "swift", documentID: right) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 60)
        SyntaxEngine.shared.discardSession(for: left)
        SyntaxEngine.shared.discardSession(for: right)
    }

    /// `activePaths` is a `nonisolated(unsafe)` static Set behind an NSLock.
    func testSecurityScopedAccessIsHammeredFromManyThreads() {
        let urls = (0..<16).map {
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sheeptext-tsan-\($0)")
        }
        DispatchQueue.concurrentPerform(iterations: 64) { iteration in
            _ = SecurityScopedResourceAccess.startAccessing(urls[iteration % urls.count])
        }
    }

    /// `PluginLog` is `@unchecked Sendable` and appends to one file from its own
    /// queue; every bridge and the host log through it.
    func testPluginLogFromManyThreads() {
        DispatchQueue.concurrentPerform(iterations: 64) { iteration in
            PluginLog.shared.log("tsan probe \(iteration)")
        }
    }

    /// The compare engine's pure core, which `EditorView` calls from
    /// `DispatchQueue.global` on both panes at once.
    func testCompareCoreFromManyThreads() {
        let left = (0..<400).map { "vlan \($0 % 4094 + 1) description user-\($0)" }.joined(separator: "\r\n")
        var rightLines = (0..<400).map { "vlan \($0 % 4094 + 1) description user-\($0)" }
        for index in stride(from: 5, to: rightLines.count, by: 40) { rightLines[index] += " changed" }
        let right = rightLines.joined(separator: "\n")

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let result = TextComparator.compare(left, right, options: CompareOptions())
            switch result {
            case .match, .cancelled:
                XCTFail("expected the two sides to differ")
            case .mismatch(let summary):
                XCTAssertGreaterThan(summary.added + summary.removed + summary.changed, 0)
            }
        }
    }

    /// Find in Files runs on `Task.detached` while the UI keeps mutating.
    func testFindInFilesFromManyThreads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheeptext-tsan-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<12 {
            try Data("alpha needle omega \(index)\nsecond line\n".utf8)
                .write(to: root.appendingPathComponent("file\(index).txt"))
        }
        let tree = FileNode.scan(at: root)
        let options = FindInFilesOptions(query: "needle", caseSensitive: true, wholeWord: false, useRegex: false)

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let summary = try? FindInFilesEngine.search(root: root, tree: tree, options: options)
            XCTAssertEqual(summary?.matches.count, 12)
        }
    }
}
