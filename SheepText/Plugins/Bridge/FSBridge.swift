//
//  FSBridge.swift
//  Exposed to plugin JS as `fs`. Reads and writes are restricted to:
//    - The plugin's own folder
//    - The currently open workspace root (if any)
//
//  Any path escaping these roots throws a PermissionError on the JS side.
//  To request a broader scope, a plugin must declare it in manifest
//  `permissions` and the user will be prompted on first use.
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
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        } else if path.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
        } else {
            // Relative paths resolve against the workspace root, falling back
            // to the plugin folder if there's no workspace open.
            let base = workspaceRoot ?? pluginFolder
            return base.appendingPathComponent(path).standardizedFileURL
        }
    }

    private func isAllowed(_ url: URL) -> Bool {
        // Allow if inside plugin folder
        if url.path.hasPrefix(pluginFolder.standardizedFileURL.path) { return true }
        // Allow if inside workspace root
        if let root = workspaceRoot?.standardizedFileURL, url.path.hasPrefix(root.path) { return true }
        return false
    }
}
