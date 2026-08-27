//
//  CommandsBridge.swift
//  Exposed to plugin JS as `commands`. Wraps the Swift CommandRegistry.
//
//  JavaScriptCore bridges Objective-C protocols to JS. So each bridge is a
//  class conforming to an @objc JSExport protocol; only the protocol's
//  members are visible to JS.
//

import Foundation
import JavaScriptCore

@objc protocol CommandsBridgeExports: JSExport {
    func register(_ id: String, _ handler: JSValue)
    func execute(_ id: String)
    func getAll() -> [[String: String]]
}

@objc final class CommandsBridge: NSObject, CommandsBridgeExports {

    private weak var host: PluginHost?
    /// Handlers the plugin has registered, keyed by command id.
    private var handlers: [String: JSValue] = [:]

    init(host: PluginHost) {
        self.host = host
    }

    func register(_ id: String, _ handler: JSValue) {
        // Keep a strong reference to the JS handler so it doesn't get GC'd.
        handlers[id] = handler
        // Also surface it in the command palette. This used to stop at the line
        // above, so a command a plugin registered at runtime could only ever be
        // reached by another plugin — it was invisible to the user unless the
        // same id was *also* declared in plugin.json, which is easy to forget
        // and gives no feedback when you do.
        host?.registerDynamicCommand(id: id)
    }

    func execute(_ id: String) {
        guard let handler = handlers[id] else { return }
        _ = handler.call(withArguments: [])
    }

    func getAll() -> [[String: String]] {
        handlers.keys.sorted().map { ["id": $0, "title": $0] }
    }

    /// Called by PluginHost when a manifest-declared command fires.
    @nonobjc func trigger(id: String) {
        handlers[id]?.call(withArguments: [])
    }
}
