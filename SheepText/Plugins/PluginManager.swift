//
//  PluginManager.swift
//  Discovers plugins on disk, spins up a PluginHost per plugin,
//  and handles reload / unload lifecycle.
//
//  Plugin discovery path:
//    ~/Library/Application Support/SheepText/Plugins/<plugin-id>/
//
//  Each plugin folder must contain `plugin.json` (manifest) and whatever
//  source file the manifest's `main` field points at.
//

import Foundation
import JavaScriptCore
import Observation

// MARK: - Manifest

struct PluginManifest: Codable {
    let id: String
    let name: String
    let version: String
    let main: String
    let activationEvents: [String]?
    let permissions: [String]?
    let contributes: Contributes?

    struct Contributes: Codable {
        let commands: [Command]?
        let keybindings: [Keybinding]?

        struct Command: Codable {
            let id: String
            let title: String
        }
        struct Keybinding: Codable {
            let command: String
            let key: String
            let when: String?
        }
    }
}

// MARK: - Paths

nonisolated enum PluginPaths {
    static var appSupport: URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/SheepText", isDirectory: true)
        }
        return base.appendingPathComponent("SheepText", isDirectory: true)
    }
    static var pluginsDir: URL { appSupport.appendingPathComponent("Plugins", isDirectory: true) }
    static var logsDir:    URL { appSupport.appendingPathComponent("Logs",    isDirectory: true) }
    static var logFile:    URL { logsDir.appendingPathComponent("plugin-host.log") }

    static func ensureExists() {
        let fm = FileManager.default
        for dir in [appSupport, pluginsDir, logsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Manager

@Observable
@MainActor
final class PluginManager {

    private(set) var hosts: [PluginHost] = []
    private weak var commandRegistry: CommandRegistry?
    private weak var workspaceStore: WorkspaceStore?

    init() {
        NotificationCenter.default.addMainActorObserver(
            forName: .reloadPlugins,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.reloadAll() }
        }
    }

    func loadAll(commands: CommandRegistry, workspace: WorkspaceStore) async {
        commandRegistry = commands
        workspaceStore = workspace

        PluginPaths.ensureExists()
        installBundledSamplePluginsIfNeeded()
        let fm = FileManager.default

        let pluginRoots = pluginSearchRoots()
        var loadedIDs = Set<String>()

        for root in pluginRoots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for url in entries where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard let manifest = readManifest(at: url) else { continue }
                guard loadedIDs.insert(manifest.id).inserted else { continue }
                await load(from: url, manifest: manifest, commands: commands, workspace: workspace)
            }
        }
    }

    func reloadAll() async {
        // For simplicity, tear down all hosts. A nicer version would diff.
        for host in hosts { host.deactivate() }
        hosts.removeAll()

        guard let commands = commandRegistry, let workspace = workspaceStore else {
            PluginLog.shared.log("Plugins unloaded, but reload context missing.")
            return
        }

        await loadAll(commands: commands, workspace: workspace)
        PluginLog.shared.log("Plugins reloaded.")
    }

    func installPlugin(from sourceFolder: URL) async throws {
        PluginPaths.ensureExists()
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PluginInstallError.notAFolder
        }

        guard let manifest = readManifest(at: sourceFolder) else {
            throw PluginInstallError.invalidManifest
        }

        let destination = PluginPaths.pluginsDir.appendingPathComponent(manifest.id, isDirectory: true)

        if sourceFolder.standardizedFileURL == destination.standardizedFileURL {
            await reloadAll()
            return
        }

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        try fm.copyItem(at: sourceFolder, to: destination)
        PluginLog.shared.log("Installed plugin \(manifest.id) from \(sourceFolder.path)")
        await reloadAll()
    }

    private func load(from url: URL, manifest: PluginManifest, commands: CommandRegistry, workspace: WorkspaceStore) async {
        let host = PluginHost(folder: url, manifest: manifest, commands: commands, workspace: workspace)
        host.activate()
        hosts.append(host)
    }

    private func pluginSearchRoots() -> [URL] {
        var roots: [URL] = [PluginPaths.pluginsDir]
        if let development = developmentPluginsDir() {
            roots.append(development)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true) {
            roots.append(bundled)
        }
        return roots
    }

    private func developmentPluginsDir() -> URL? {
        let fm = FileManager.default
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repoPlugins = sourceFileURL
            .deletingLastPathComponent() // Plugins
            .deletingLastPathComponent() // SheepText
            .deletingLastPathComponent() // repo-ish root
            .appendingPathComponent("Plugins", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: repoPlugins.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return repoPlugins
    }

    private func readManifest(at pluginFolder: URL) -> PluginManifest? {
        let manifestURL = pluginFolder.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            PluginLog.shared.log("Skipping \(pluginFolder.lastPathComponent): invalid or missing plugin.json")
            return nil
        }
        return manifest
    }

    /// If resources include the built-in hello-world plugin files, copy them
    /// into the writable plugins directory so sandboxed app runs can load it.
    private func installBundledSamplePluginsIfNeeded() {
        let fm = FileManager.default
        let pluginDir = PluginPaths.pluginsDir.appendingPathComponent("hello-world", isDirectory: true)
        let manifestDest = pluginDir.appendingPathComponent("plugin.json")
        let mainDest = pluginDir.appendingPathComponent("src", isDirectory: true).appendingPathComponent("index.js")

        if fm.fileExists(atPath: manifestDest.path), fm.fileExists(atPath: mainDest.path) {
            return
        }

        guard let manifestSource = Bundle.main.url(forResource: "plugin", withExtension: "json"),
              let mainSource = Bundle.main.url(forResource: "index", withExtension: "js") else {
            return
        }

        do {
            try fm.createDirectory(at: mainDest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: manifestDest.path) {
                try fm.copyItem(at: manifestSource, to: manifestDest)
            }
            if !fm.fileExists(atPath: mainDest.path) {
                try fm.copyItem(at: mainSource, to: mainDest)
            }
            PluginLog.shared.log("Installed bundled sample plugin into \(pluginDir.path)")
        } catch {
            PluginLog.shared.log("Failed to install bundled sample plugin: \(error.localizedDescription)")
        }
    }
}

enum PluginInstallError: LocalizedError {
    case notAFolder
    case invalidManifest

    var errorDescription: String? {
        switch self {
        case .notAFolder:
            return "Selected path is not a plugin folder."
        case .invalidManifest:
            return "plugin.json is missing or invalid."
        }
    }
}

// MARK: - Logging

/// Append-only log file for plugins. Keeps the app's stderr clean.
/// Mutable file-handle work is confined to the private serial queue.
nonisolated final class PluginLog: @unchecked Sendable {
    static let shared = PluginLog()
    private let queue = DispatchQueue(label: "sheeptext.pluginlog")

    func log(_ message: String) {
        queue.async {
            PluginPaths.ensureExists()
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: PluginPaths.logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: PluginPaths.logFile)
            }
        }
    }
}
