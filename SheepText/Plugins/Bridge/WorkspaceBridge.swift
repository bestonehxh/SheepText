//
//  WorkspaceBridge.swift
//  Exposed to plugin JS as `workspace`.
//

import Foundation
import JavaScriptCore

@objc protocol WorkspaceBridgeExports: JSExport {
    func getRootPath() -> String
    func findFiles(_ glob: String) -> [String]
}

@objc final class WorkspaceBridge: NSObject, WorkspaceBridgeExports {

    private weak var workspace: WorkspaceStore?

    init(workspace: WorkspaceStore?) {
        self.workspace = workspace
    }

    func getRootPath() -> String {
        // See PluginMainThread.swift: this must not be an unconditional
        // main.sync, plugin JS runs on the main thread today.
        pluginMainSync { self.workspace?.rootURL?.path ?? "" }
    }

    func findFiles(_ glob: String) -> [String] {
        pluginMainSync { self.workspace?.findFiles(matching: glob) ?? [] }
            .map(\.path)
    }
}
