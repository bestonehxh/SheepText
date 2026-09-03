//
//  FSBridge.swift
//  Exposed to plugin JS as `fs`. Reads and writes are restricted to:
//    - The plugin's own folder
//    - The currently open workspace root (if any)
//
//  Any path escaping these roots throws a PermissionError on the JS side.
//  There is no way to widen that: the manifest used to carry a `permissions`
//  array, but nothing ever read it, so a plugin could declare anything it liked
//  and it changed nothing. It has been removed rather than left standing as a
//  security control that does not exist. If a broader scope is ever wanted, it
//  needs a real user prompt behind it, not a field in a file the plugin writes.
//

import Foundation
import JavaScriptCore

@objc protocol FSBridgeExports: JSExport {
    func readFile(_ path: String) -> String
    func writeFile(_ path: String, _ content: String) -> Bool
    func exists(_ path: String) -> Bool
}

@objc final class FSBridge: NSObject, FSBridgeExports {

    private let pluginFolder: URL
    private let workspaceRoot: URL?

    init(pluginFolder: URL, workspaceRoot: URL?) {
        self.pluginFolder = pluginFolder
        self.workspaceRoot = workspaceRoot
    }

    func readFile(_ path: String) -> String {
        guard let url = resolve(path), isAllowed(url) else {
            JSContext.current()?.exception = JSValue(newErrorFromMessage:
                "PermissionError: read outside allowed scope", in: JSContext.current())
            return ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func writeFile(_ path: String, _ content: String) -> Bool {
        guard let url = resolve(path), isAllowed(url) else {
            JSContext.current()?.exception = JSValue(newErrorFromMessage:
                "PermissionError: write outside allowed scope", in: JSContext.current())
            return false
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    func exists(_ path: String) -> Bool {
        guard let url = resolve(path), isAllowed(url) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Helpers

    private func resolve(_ path: String) -> URL? {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if path.hasPrefix("~") {
            url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        } else {
            // Relative paths resolve against the workspace root, falling back
            // to the plugin folder if there's no workspace open.
            let base = workspaceRoot ?? pluginFolder
            url = base.appendingPathComponent(path)
        }
        return Self.canonical(url)
    }

    /// Fully resolved form used for every scope comparison: symlinks followed,
    /// then `..` / `.` removed.
    ///
    /// Order matters. `standardizedFileURL` alone collapses `..` textually,
    /// which is exactly wrong across a symlink, and `resolvingSymlinksInPath`
    /// alone leaves `..` in place on a path whose parents do not exist.
    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isAllowed(_ url: URL) -> Bool {
        if Self.isInside(url, root: Self.canonical(pluginFolder)) { return true }
        if let root = workspaceRoot.map(Self.canonical), Self.isInside(url, root: root) { return true }
        return false
    }

    /// Containment by path COMPONENTS, not by string prefix.
    ///
    /// The old check was `url.path.hasPrefix(root.path)`, which is a string
    /// test: for a workspace root of `/proj`, the paths `/proj-secrets/keys`
    /// and `/project/anything` both start with "/proj" and were both allowed.
    /// It also compared unresolved paths, so a symlink planted inside the
    /// workspace pointing at `~/.ssh` read straight through the check.
    ///
    /// Both arguments must already be `canonical`.
    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let urlComponents = url.pathComponents
        guard urlComponents.count >= rootComponents.count else { return false }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }
}
