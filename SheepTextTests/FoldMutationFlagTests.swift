import AppKit
import XCTest
@testable import SheepText

/// The fold-mutation flag is a one-shot handshake: it tells the next
/// `textDidChange` that the edit it is seeing came from folding, so the
/// document is not marked dirty and no safety save is kicked off.
///
/// It shipped armed by `fold` / `unfold` / `unfoldAll` themselves, which was
/// wrong, because a direct `NSTextStorage` mutation posts no
/// `NSText.didChangeNotification` — the notification exists only where an
/// interactive call site calls `didChangeText()` afterwards. Every programmatic
/// caller (building a view, switching tabs, entering compare mode) therefore
/// left the flag armed with nothing coming to consume it, and the user's next
/// genuine edit ate it: no `isDirty`, no autosave, status bar still "Saved".
/// Since one text view serves every tab, that was the FIRST EDIT AFTER EVERY
/// TAB SWITCH.
///
/// These tests pin the invariant that makes that impossible — mutating never
/// arms; only an explicit arm does — rather than pinning the symptom.
@MainActor
final class FoldMutationFlagTests: XCTestCase {

    private func storage(_ text: String) -> NSTextStorage {
        NSTextStorage(string: text)
    }

    private var foldableSource: String {
        """
        func outer() {
            let a = 1
            let b = 2
        }
        let tail = 3
        """
    }

    // MARK: - The invariant

    func testAFreshManagerIsNotArmed() {
        let fm = FoldingManager()
        XCTAssertFalse(fm.consumeFoldMutationFlag())
    }

    func testFoldingDoesNotArmTheFlagByItself() throws {
        let fm = FoldingManager()
        let store = storage(foldableSource)
        let range = try XCTUnwrap(
            fm.foldableRange(onLine: 1, displayText: store.string as NSString),
            "fixture is not foldable — the test would pass vacuously"
        )

        fm.fold(range: range, in: store)

        XCTAssertFalse(
            fm.consumeFoldMutationFlag(),
            "fold() mutated the storage but emitted no change notification, so it must not arm"
        )
    }

    func testUnfoldAllDoesNotArmTheFlagByItself() throws {
        let fm = FoldingManager()
        let store = storage(foldableSource)
        let range = try XCTUnwrap(fm.foldableRange(onLine: 1, displayText: store.string as NSString))
        fm.fold(range: range, in: store)
        _ = fm.consumeFoldMutationFlag()

        // This is the tab-switch path: EditorRepresentable expands the outgoing
        // document's folds before handing the shared text view to the next tab.
        fm.unfoldAll(in: store)

        XCTAssertFalse(
            fm.consumeFoldMutationFlag(),
            "a tab switch left the flag armed; the next real edit would be silently swallowed"
        )
    }

    func testRestoringFoldsDoesNotArmTheFlag() throws {
        let fm = FoldingManager()
        let store = storage(foldableSource)
        let range = try XCTUnwrap(fm.foldableRange(onLine: 1, displayText: store.string as NSString))
        fm.fold(range: range, in: store)
        fm.saveFolds(for: "doc-under-test")
        fm.unfoldAll(in: store)
        _ = fm.consumeFoldMutationFlag()

        fm.restoreFolds(for: "doc-under-test", in: store)

        XCTAssertFalse(
            fm.consumeFoldMutationFlag(),
            "restoring folds emits no notification, so it must leave nothing armed"
        )
    }

    // MARK: - The handshake still works for the paths that DO emit

    func testArmingIsHonouredExactlyOnce() {
        let fm = FoldingManager()

        fm.armFoldMutationFlag()

        XCTAssertTrue(fm.consumeFoldMutationFlag(), "the armed flag must be seen by the next change")
        XCTAssertFalse(fm.consumeFoldMutationFlag(), "and must not survive into any later change")
    }

    /// What the gutter chevron and a fold-placeholder click actually do:
    /// mutate, arm, then emit. The emitted change must read as a fold.
    func testInteractiveFoldSequenceReadsAsAFoldMutation() throws {
        let fm = FoldingManager()
        let store = storage(foldableSource)
        let range = try XCTUnwrap(fm.foldableRange(onLine: 1, displayText: store.string as NSString))

        fm.fold(range: range, in: store)
        fm.armFoldMutationFlag()

        XCTAssertTrue(fm.consumeFoldMutationFlag())
    }

    /// The edit observer added for T1 runs on every user edit while a fold is
    /// collapsed. It re-points the regions — it must not touch this flag, or the
    /// edit it just tracked would be mistaken for a fold and skip `isDirty` and
    /// the safety saves. That is the same class of bug the flag itself caused.
    func testAdjustingRegionsForAUserEditDoesNotArmTheFlag() throws {
        let fm = FoldingManager()
        let store = storage(foldableSource)
        let range = try XCTUnwrap(fm.foldableRange(onLine: 1, displayText: store.string as NSString))
        fm.fold(range: range, in: store)
        _ = fm.consumeFoldMutationFlag()

        store.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")

        XCTAssertFalse(
            fm.consumeFoldMutationFlag(),
            "a real edit above a fold must still mark the document dirty"
        )
    }

    /// The shape of the shipped bug, stated as a scenario: switch tabs, then
    /// make a real edit. That edit must NOT be mistaken for a fold.
    func testFirstEditAfterATabSwitchIsNotMistakenForAFold() throws {
        let fm = FoldingManager()
        let store = storage(foldableSource)
        let range = try XCTUnwrap(fm.foldableRange(onLine: 1, displayText: store.string as NSString))

        // Tab A had a fold; the chevron armed and the notification consumed it.
        fm.fold(range: range, in: store)
        fm.armFoldMutationFlag()
        XCTAssertTrue(fm.consumeFoldMutationFlag())

        // Switch to tab B: folds are saved and expanded, no notification.
        fm.saveFolds(for: "tab-a")
        fm.unfoldAll(in: store)
        fm.restoreFolds(for: "tab-b", in: store)

        // The user now types. textDidChange asks the question this flag answers.
        XCTAssertFalse(
            fm.consumeFoldMutationFlag(),
            "the edit would skip isDirty and the safety saves — an unsaved change reading as \"Saved\""
        )
    }
}
