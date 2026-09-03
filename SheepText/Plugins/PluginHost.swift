//
//  PluginHost.swift
//  Owns the JSContext for a single plugin. Injects the bridge objects,
//  evaluates the plugin's entry file, and calls activate() / deactivate().
//
//  Everything here runs on the main actor. There used to be a private
//  DispatchQueue field for running plugin JS off-main, but nothing ever
//  dispatched to it — meanwhile the bridges still blocked on
//  `DispatchQueue.main.sync`, which deadlocks from the main thread. The dead
//  queue is gone and the bridges hop conditionally; see PluginMainThread.swift.
//
//  Why JavaScriptCore instead of embedding QuickJS or V8?
//   - Ships with macOS (zero MB cost, signed by Apple)
//   - Hardware-accelerated on Apple Silicon
//   - `JSContext.exceptionHandler` gives us structured error reporting
//   - Host objects are straightforward via `@objc` protocols
//

import Foundation
import JavaScriptCore

@MainActor
final class PluginHost {

    let manifest: PluginManifest
    let folder: URL
    private let context: JSContext
    /// Held directly rather than fished back out of the context on every call:
    /// `deactivate()` has to reach it after the JS side may already be torn
    /// down, and `invokeCommand` should not pay a JS round trip per command.
    private var commandsBridge: CommandsBridge?
    private weak var commands: CommandRegistry?
    private weak var workspace: WorkspaceStore?

    init(folder: URL, manifest: PluginManifest, commands: CommandRegistry, workspace: WorkspaceStore) {
        self.folder = folder
        self.manifest = manifest
        self.context = JSContext(virtualMachine: JSVirtualMachine())
        self.commands = commands
        self.workspace = workspace
        installBridges()
        installExceptionHandler()
    }

    // MARK: - Lifecycle

    func activate() {
        let mainURL = folder.appendingPathComponent(manifest.main)
        guard let source = try? String(contentsOf: mainURL, encoding: .utf8) else {
            PluginLog.shared.log("[\(manifest.id)] main file not found at \(mainURL.path)")
            return
        }

        // Wrap the plugin source in a CommonJS-like shim so `module.exports`
        // and `export function activate` both work via our preamble.
        let wrapper = Self.moduleShim + source + "\n;__sl_getExports(module);"

        _ = context.evaluateScript(wrapper, withSourceURL: mainURL)

        guard let exports = context.objectForKeyedSubscript("__sl_exports"),
              let activate = exports.objectForKeyedSubscript("activate"),
              !activate.isUndefined else {
            PluginLog.shared.log("[\(manifest.id)] no activate() export")
            return
        }

        _ = activate.call(withArguments: [pluginContextObject()])
        PluginLog.shared.log("[\(manifest.id)] activated")

        // Register any commands declared in the manifest so they appear in the
        // palette even before the plugin's code runs them.
        for cmd in manifest.contributes?.commands ?? [] {
            commands?.register(
                id: cmd.id,
                title: cmd.title,
                source: .plugin(manifest.id)
            ) { [weak self] args in
                self?.invokeCommand(id: cmd.id, args: args)
            }
        }
    }

    /// Register a command the plugin created at runtime with the Swift registry,
    /// so it shows up in the palette like a manifest-declared one.
    ///
    /// Registered under this plugin's source, so `deactivate` sweeps it up with
    /// the rest. `CommandRegistry.entries` is keyed by id, so the manifest pass
    /// in `activate` simply overwrites this with the nicer title when the plugin
    /// declared the same command in both places.
    func registerDynamicCommand(id: String) {
        let declaredTitle = manifest.contributes?.commands?.first { $0.id == id }?.title
        commands?.register(
            id: id,
            title: declaredTitle ?? id,
            source: .plugin(manifest.id)
        ) { [weak self] args in
            self?.invokeCommand(id: id, args: args)
        }
    }

    func deactivate() {
        if let exports = context.objectForKeyedSubscript("__sl_exports"),
           let deactivate = exports.objectForKeyedSubscript("deactivate"),
           !deactivate.isUndefined {
            _ = deactivate.call(withArguments: [])
        }
        commands?.unregisterAll(from: .plugin(manifest.id))
        // Drops the plugin's JS handlers and their managed references. Without
        // this the JSContext ⇄ bridge cycle survived every reload, leaking a
        // whole JS heap per press of Reload.
        commandsBridge?.deactivate()
        commandsBridge = nil
        context.exceptionHandler = nil
        PluginLog.shared.log("[\(manifest.id)] deactivated")
    }

    // MARK: - Bridges

    private func installBridges() {
        let commandsBridge  = CommandsBridge(host: self)
        self.commandsBridge = commandsBridge
        let editorBridge    = EditorBridge()
        let workspaceBridge = WorkspaceBridge(workspace: workspace)
        let uiBridge        = UIBridge()
        let fsBridge        = FSBridge(pluginFolder: folder, workspaceRoot: workspace?.rootURL)

        context.setObject(commandsBridge,  forKeyedSubscript: "commands"  as NSString)
        context.setObject(editorBridge,    forKeyedSubscript: "editor"    as NSString)
        context.setObject(workspaceBridge, forKeyedSubscript: "workspace" as NSString)
        context.setObject(uiBridge,        forKeyedSubscript: "ui"        as NSString)
        context.setObject(fsBridge,        forKeyedSubscript: "fs"        as NSString)

        // console.log / warn / error → plugin log
        guard let console = JSValue(object: [:], in: context) else { return }
        let logger: @convention(block) (String) -> Void = { [id = manifest.id] msg in
            PluginLog.shared.log("[\(id)] \(msg)")
        }
        console.setObject(logger, forKeyedSubscript: "log"   as NSString)
        console.setObject(logger, forKeyedSubscript: "warn"  as NSString)
        console.setObject(logger, forKeyedSubscript: "error" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    private func installExceptionHandler() {
        context.exceptionHandler = { [id = manifest.id] _, exception in
            PluginLog.shared.log("[\(id)] JS exception: \(exception?.toString() ?? "unknown")")
        }
    }

    /// Object passed to `activate(context)` — plugin-scoped API surface.
    private func pluginContextObject() -> [String: Any] {
        [
            "storagePath": folder.path,
            "pluginId": manifest.id
        ]
    }

    /// Internal: call a command declared in the manifest. Resolves to the
    /// JS-side handler the plugin registered with `commands.register`.
    private func invokeCommand(id: String, args: [Any]) {
        // Plugin JS already registered the handler on the commands bridge;
        // we route through the bridge, not back through the Swift registry,
        // to avoid recursion.
        commandsBridge?.trigger(id: id)
    }

    // MARK: - Module shim

    /// A tiny shim so plugins can use either CommonJS-style
    /// (`module.exports = { activate }`) or ESM-ish
    /// (`export function activate`). For v1 we accept CommonJS; a real ESM
    /// loader can slot in later.
    private static let moduleShim = """
    var module = { exports: {} };
    var exports = module.exports;
    function __sl_getExports(m) { globalThis.__sl_exports = m.exports; }
    """
}
