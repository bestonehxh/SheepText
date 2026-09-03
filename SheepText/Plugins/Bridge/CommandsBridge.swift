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
    ///
    /// These are `JSManagedValue`s, not raw `JSValue`s, and that is the whole
    /// point. A `JSValue` holds its `JSContext` strongly. The context holds the
    /// bridge (it was handed to `setObject(_:forKeyedSubscript:)`), and the
    /// bridge held the handlers — a cycle straight through the JS heap that
    /// neither ARC nor the JS garbage collector could break. So every
    /// `reloadAll()` leaked an entire JSContext, its virtual machine, and every
    /// object the plugin had allocated; a user editing a plugin and hitting
    /// Reload leaked one full JS heap per press.
    ///
    /// `JSManagedValue` + `addManagedReference(_:withOwner:)` is JavaScriptCore's
    /// answer: the value stays alive as long as the *owner* is reachable from
    /// the JS heap, and the reference is weak from ARC's point of view, so the
    /// cycle is gone while the handler is still safe to call.
    private var handlers: [String: JSManagedValue] = [:]

    /// The virtual machine the managed references are registered with. Held
    /// weakly so the bridge never keeps the VM (and therefore the context)
    /// alive on its own — see the cycle described above.
    private weak var virtualMachine: JSVirtualMachine?

    /// Optional so the bridge can be exercised on its own (there is a
    /// retain-cycle regression test that does exactly that).
    init(host: PluginHost?) {
        self.host = host
    }

    func register(_ id: String, _ handler: JSValue) {
        guard let vm = handler.context?.virtualMachine else { return }
        virtualMachine = vm

        if let previous = handlers[id] {
            vm.removeManagedReference(previous, withOwner: self)
        }

        let managed = JSManagedValue(value: handler, andOwner: self)
        vm.addManagedReference(managed, withOwner: self)
        handlers[id] = managed

        // Also surface it in the command palette. This used to stop at the line
        // above, so a command a plugin registered at runtime could only ever be
        // reached by another plugin — it was invisible to the user unless the
        // same id was *also* declared in plugin.json, which is easy to forget
        // and gives no feedback when you do.
        host?.registerDynamicCommand(id: id)
    }

    func execute(_ id: String) {
        _ = handlers[id]?.value?.call(withArguments: [])
    }

    func getAll() -> [[String: String]] {
        handlers.keys.sorted().map { ["id": $0, "title": $0] }
    }

    /// Called by PluginHost when a manifest-declared command fires.
    @nonobjc func trigger(id: String) {
        handlers[id]?.value?.call(withArguments: [])
    }

    /// Drop every handler and its managed reference.
    ///
    /// Called from `PluginHost.deactivate()`. Without it the managed references
    /// stayed registered with a virtual machine that is about to be discarded,
    /// and the bridge kept boxes pointing into a dead heap.
    @nonobjc func deactivate() {
        if let vm = virtualMachine {
            for managed in handlers.values {
                vm.removeManagedReference(managed, withOwner: self)
            }
        }
        handlers.removeAll()
        host = nil
    }
}
