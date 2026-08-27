//
//  CommandRegistry.swift
//  id → handler map. Commands are registered by built-ins and by plugins.
//  The palette reads from CommandRegistry.list() to show its entries.
//
//  Thread model: the registry itself is an actor. Handlers are called from
//  their registering thread (main for built-ins, plugin queue for plugins).
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
        /// Source: built-in, or a plugin ID. Used when reloading plugins so we
        /// can remove only that plugin's commands.
        let source: Source
    }

    enum Source: Equatable {
        case builtIn
        case plugin(String)
    }

    private(set) var entries: [String: Entry] = [:]
    private var recentCommandIDs: [String] = []

    init() {
        recentCommandIDs = UserDefaults.standard.stringArray(forKey: recentCommandsKey) ?? []
    }

    func register(id: String, title: String, source: Source = .builtIn, handler: @escaping ([Any]) -> Void) {
        entries[id] = Entry(id: id, title: title, handler: handler, source: source)
    }

    func unregister(id: String) {
        entries.removeValue(forKey: id)
    }

    func unregisterAll(from source: Source) {
        entries = entries.filter { $0.value.source != source }
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
        UserDefaults.standard.set(recentCommandIDs, forKey: recentCommandsKey)
    }
}
