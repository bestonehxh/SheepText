//
//  WorkspaceStore.swift
//  Tracks the currently opened folder, the file tree, and the "active" file.
//  Observable via the @Observable macro so SwiftUI views refresh automatically.
//

import Foundation
import AppKit
import Observation

@Observable
final class WorkspaceStore {

    private let recentWorkspacesKey = "sheeptext.recentWorkspaces"
    private let sessionWorkspaceKey = "sheeptext.session.workspace"
    private let maxRecentWorkspaces = 12

    var rootURL: URL?
    var tree: FileNode?
    var activeFileURL: URL?
    private(set) var recentWorkspaces: [URL] = []

    init() {
        recentWorkspaces = UserDefaults.standard.stringArray(forKey: recentWorkspacesKey)?
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) } ?? []
    }

    /// Open a native folder picker. On success, loads the file tree.
    @MainActor
    func promptOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories   = true
        panel.canChooseFiles         = false
        panel.allowsMultipleSelection = false
        panel.prompt                 = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Open a native file picker for one or many files. Unlike
    /// `promptOpenFolder`, this does not change the workspace root —
    /// it just returns the chosen URLs so the caller can open them as tabs.
    /// Returns an empty array if the user cancels.
    @MainActor
    func promptOpenFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.allowsMultipleSelection = true
        panel.prompt                  = "Open"
        guard panel.runModal() == .OK else { return [] }
        for url in panel.urls {
            SecurityScopedResourceAccess.remember(
                url,
                bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey
            )
        }
        return panel.urls
    }

    func open(_ url: URL, rememberRecent: Bool = true) {
        let accessibleURL = SecurityScopedResourceAccess.prepare(
            url,
            bookmarkKey: SecurityScopedResourceAccess.workspaceBookmarksKey,
            shouldRemember: rememberRecent
        )
        rootURL = accessibleURL
        persistSessionWorkspace(accessibleURL)
        if rememberRecent {
            rememberWorkspace(accessibleURL)
        }
        Task { @MainActor [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                FileNode.scan(at: accessibleURL)
            }.value
            self?.tree = scanned
        }
    }

    @MainActor
    func refreshTree() {
        guard let rootURL else { return }
        let url = rootURL
        Task { @MainActor [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                FileNode.scan(at: url)
            }.value
            self?.tree = scanned
        }
    }

    @MainActor
    func createFile(in directory: URL) -> URL? {
        let url = uniqueURL(in: directory, preferredName: "Untitled.txt")
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { return nil }
        refreshTree()
        return url
    }

    @MainActor
    func createFolder(in directory: URL) -> URL? {
        let url = uniqueURL(in: directory, preferredName: "New Folder")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            refreshTree()
            return url
        } catch {
            return nil
        }
    }

    @MainActor
    func rename(_ url: URL, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != url.lastPathComponent,
              !trimmed.contains("/")
        else { return nil }

        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return nil }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
            refreshTree()
            return destination
        } catch {
            return nil
        }
    }

    @MainActor
    func trash(_ url: URL) -> Bool {
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            refreshTree()
            return true
        } catch {
            return false
        }
    }

    func restoreLastSessionWorkspace() {
        guard rootURL == nil,
              let path = UserDefaults.standard.string(forKey: sessionWorkspaceKey)
        else { return }

        let url = SecurityScopedResourceAccess.restore(
            path: path,
            bookmarkKey: SecurityScopedResourceAccess.workspaceBookmarksKey
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            UserDefaults.standard.removeObject(forKey: sessionWorkspaceKey)
            return
        }

        open(url, rememberRecent: false)
    }

    func openRecentWorkspace(at index: Int) {
        guard recentWorkspaces.indices.contains(index) else { return }
        open(recentWorkspaces[index])
    }

    func clearRecentWorkspaces() {
        recentWorkspaces = []
        persistRecentWorkspaces()
    }

    /// Search files in the workspace by glob. Used by the palette and plugins.
    func findFiles(matching glob: String) -> [URL] {
        guard let root = rootURL else { return [] }
        return FileNode.flatten(tree).filter { node in
            !node.isDirectory && FNMatch.match(glob, node.url.path(relativeTo: root))
        }.map(\.url)
    }

    private func rememberWorkspace(_ url: URL) {
        recentWorkspaces.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentWorkspaces.insert(url, at: 0)
        if recentWorkspaces.count > maxRecentWorkspaces {
            recentWorkspaces = Array(recentWorkspaces.prefix(maxRecentWorkspaces))
        }
        persistRecentWorkspaces()
    }

    private func persistRecentWorkspaces() {
        UserDefaults.standard.set(recentWorkspaces.map(\.path), forKey: recentWorkspacesKey)
    }

    private func persistSessionWorkspace(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: sessionWorkspaceKey)
    }

    private func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let preferredURL = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: preferredURL.path) else { return preferredURL }

        let ns = preferredName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }
}

/// Node in the sidebar tree.
struct FileNode: Identifiable, Hashable, Sendable {
    /// The URL **is** the identity. It used to be a fresh `UUID()` per node, so
    /// every `refreshTree()` produced a tree that SwiftUI considered entirely
    /// new: the whole outline was rebuilt and every expanded folder collapsed —
    /// after creating a file, renaming one, or trashing one.
    var id: URL { url }
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?

    var name: String { url.lastPathComponent }

    /// Recursively scan a directory. Skips hidden files and common junk.
    nonisolated static func scan(at url: URL, depth: Int = 0) -> FileNode {
        scan(at: url, isDirectory: isDirectory(at: url), depth: depth)
    }

    private nonisolated static func isDirectory(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// `isDirectory` is passed in because the caller already asked for it while
    /// sorting the parent's contents — the recursion used to re-`stat` every
    /// single node on the way in, i.e. twice per file per scan.
    private nonisolated static func scan(at url: URL, isDirectory: Bool, depth: Int) -> FileNode {
        if !isDirectory {
            return FileNode(url: url, isDirectory: false, children: nil)
        }
        guard depth < 12 else { // pathological safety
            return FileNode(url: url, isDirectory: true, children: [])
        }

        let skip: Set<String> = [".git", "node_modules", ".build", ".DS_Store", "DerivedData"]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let children = contents
            .filter { !skip.contains($0.lastPathComponent) }
            .map { (url: $0, isDirectory: Self.isDirectory(at: $0)) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory } // directories first
                return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
            .map { scan(at: $0.url, isDirectory: $0.isDirectory, depth: depth + 1) }

        return FileNode(url: url, isDirectory: true, children: children)
    }

    nonisolated static func flatten(_ node: FileNode?) -> [FileNode] {
        guard let node else { return [] }
        var out = [node]
        for child in node.children ?? [] {
            out.append(contentsOf: flatten(child))
        }
        return out
    }
}

// Tiny helpers

private extension URL {
    nonisolated func path(relativeTo base: URL) -> String {
        guard self.path.hasPrefix(base.path) else { return self.path }
        let trimmed = String(self.path.dropFirst(base.path.count))
        return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
    }
}

/// Minimal fnmatch — sufficient for simple globs like `*.swift`, `src/**/*.ts`.
/// For more complex patterns we can swap in a proper glob library later.
nonisolated enum FNMatch {
    static func match(_ pattern: String, _ name: String) -> Bool {
        // Convert glob to regex: * → [^/]*, ** → .*, ? → [^/]
        var rx = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            switch c {
            case "*":
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    rx += ".*"
                    i = pattern.index(after: next)
                    continue
                }
                rx += "[^/]*"
            case "?": rx += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                rx += "\\\(c)"
            default:
                rx.append(c)
            }
            i = pattern.index(after: i)
        }
        rx += "$"
        return name.range(of: rx, options: .regularExpression) != nil
    }
}
