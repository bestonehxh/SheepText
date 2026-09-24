//
//  CommandRegistry.swift
//  id → handler map, filled by the built-in commands.
//  The palette reads from CommandRegistry.list() to show its entries.
//
//  Everything here is main-actor: the registry is written at launch and read
//  by the palette, both on the main thread.
//

import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class CommandRegistry {
    private let recentCommandsKey = "sheeptext.recentCommands"
    private let maxRecentCommands = 50

    struct Entry {
        let id: String
        let title: String
        let handler: ([Any]) -> Void
    }

    private(set) var entries: [String: Entry] = [:]
    private var recentCommandIDs: [String] = []

    init() {
        recentCommandIDs = AppStorageLocation.defaults.stringArray(forKey: recentCommandsKey) ?? []
    }

    func register(id: String, title: String, handler: @escaping ([Any]) -> Void) {
        entries[id] = Entry(id: id, title: title, handler: handler)
    }

    func unregister(id: String) {
        entries.removeValue(forKey: id)
    }

    func execute(_ id: String, args: [Any] = []) {
        guard let entry = entries[id] else {
            Logger.app.warning("CommandRegistry: unknown command \(id)")
            return
        }
        rememberCommand(id)
        entry.handler(args)
    }

    /// All entries sorted by title — for the palette.
    func list() -> [Entry] {
        entries.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func recencyBoost(for id: String) -> Int {
        guard let index = recentCommandIDs.firstIndex(of: id) else { return 0 }
        return max(0, 80 - (index * 4))
    }

    private func rememberCommand(_ id: String) {
        recentCommandIDs.removeAll { $0 == id }
        recentCommandIDs.insert(id, at: 0)
        if recentCommandIDs.count > maxRecentCommands {
            recentCommandIDs = Array(recentCommandIDs.prefix(maxRecentCommands))
        }
        AppStorageLocation.defaults.set(recentCommandIDs, forKey: recentCommandsKey)
    }
}
