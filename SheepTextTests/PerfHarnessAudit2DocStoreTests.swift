//
//  PerfHarnessAudit2DocStoreTests.swift
//  Workloads for the persistence perf findings of the second audit (DP3, DP5).
//
//  Both call only API that exists before the fix, so the orchestrator can run
//  this file against the old commit for a before/after pair.
//
//  DP1 (Find in Files downloading cloud placeholders) has no workload here on
//  purpose: the cost is a network download of a File Provider placeholder, and
//  a test cannot create one — `SF_DATALESS` is a system flag that needs root.
//  `ReplaceInFilesRecoveryTests` pins the behaviour instead.
//

import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessAudit2DocStoreTests: XCTestCase {

    private var draftsDirectory: URL {
        AppStorageLocation.applicationSupport.appendingPathComponent("Drafts", isDirectory: true)
    }

    /// Stale drafts accumulate: nothing sweeps the directory on a schedule, and
    /// every draft write used to enumerate and prefix-match all of it.
    private func seedStaleDrafts(_ count: Int) throws {
        try FileManager.default.createDirectory(at: draftsDirectory, withIntermediateDirectories: true)
        for index in 0..<count {
            let base = "\(UUID().uuidString)-\(UUID().uuidString)"
            try Data("{}".utf8).write(to: draftsDirectory.appendingPathComponent("\(base).json"))
            try Data("stale \(index)".utf8).write(to: draftsDirectory.appendingPathComponent("\(base).txt"))
        }
    }

    private func makeStore(dirtyTabs: Int, bytesPerTab: Int) -> (DocumentStore, [Document]) {
        let store = DocumentStore()
        store.autoSaveIsEnabled = { false }
        var documents: [Document] = []
        for index in 0..<dirtyTabs {
            let doc = store.newUntitled()
            doc.text = String(repeating: "line \(index) of a document being edited\n",
                              count: max(1, bytesPerTab / 40))
            doc.isDirty = true
            documents.append(doc)
        }
        return (store, documents)
    }

    private func withBackupsOn(_ body: () throws -> Void) rethrows {
        let preferences = AppPreferences.current
        let previousBackup = preferences?.backupDocumentsWhileEditing
        let previousAsk = preferences?.askBeforeClosingUnsavedDocuments
        preferences?.backupDocumentsWhileEditing = true
        preferences?.askBeforeClosingUnsavedDocuments = false
        defer {
            if let previousBackup { preferences?.backupDocumentsWhileEditing = previousBackup }
            if let previousAsk { preferences?.askBeforeClosingUnsavedDocuments = previousAsk }
        }
        try body()
    }

    /// DP3: ⌘Q rewrote every dirty draft inline on the main actor — a full-text
    /// write plus a JSON write plus a directory scan per tab — including the
    /// tabs whose draft on disk already held exactly that text.
    ///
    /// The body is idempotent: after the first flush every draft is current, so
    /// the fixed code does nothing and the old code redoes all of it.
    func testPerfQuitFlushOfDraftsThatAreAlreadyCurrent() throws {
        try seedStaleDrafts(300)
        let (store, documents) = makeStore(dirtyTabs: 10, bytesPerTab: 200_000)
        try withBackupsOn {
            store.flushDirtyDraftsImmediately()   // bring every draft up to date

            PerfHarness.measure("docstore_quit_flush_current_drafts_10tabs", samples: 5, iterations: 1) {
                store.flushDirtyDraftsImmediately()
                return documents.count
            }

            for doc in documents { doc.isDirty = false }
            for doc in documents { _ = store.close(doc.id) }
        }
    }

    /// DP5: every draft write enumerated the whole Drafts directory and
    /// prefix-matched every entry, to delete the two files it already knew the
    /// names of. One edit-then-flush cycle per document per sample.
    func testPerfDraftRewriteCycleWithAFullDraftsDirectory() throws {
        try seedStaleDrafts(600)
        let (store, documents) = makeStore(dirtyTabs: 5, bytesPerTab: 20_000)
        try withBackupsOn {
            store.flushDirtyDraftsImmediately()

            var round = 0
            PerfHarness.measure("docstore_draft_rewrite_cycle_5tabs", samples: 5, iterations: 1) {
                round += 1
                for doc in documents {
                    doc.text += "edit \(round)\n"
                    doc.isDirty = true
                }
                store.flushDirtyDraftsImmediately()
                return documents.count
            }

            for doc in documents { doc.isDirty = false }
            for doc in documents { _ = store.close(doc.id) }
        }
    }
}
