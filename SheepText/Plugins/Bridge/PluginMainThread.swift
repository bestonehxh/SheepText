//
//  PluginMainThread.swift
//  Main-thread hop used by every plugin bridge.
//
//  The bridges used to call `DispatchQueue.main.sync` unconditionally, on the
//  assumption — stated in EditorBridge's header — that plugin JS always runs on
//  PluginHost's private queue. That stopped being true when PluginHost became
//  `@MainActor`: its `queue` went unused and `JSContext.evaluateScript` plus
//  every command callback now run on the main thread. `main.sync` from the main
//  thread is an immediate deadlock, so the bundled hello-world plugin hung the
//  app the first time it called `editor.getCurrentLine()`.
//
//  This helper runs the body inline when it is already on the main thread and
//  hops only when it genuinely has to, so both the current main-actor host and a
//  future off-main host work without the bridges changing again.
//

import Foundation

/// Hand-off box for values that are only ever touched on the main actor.
/// Bridge results include `[String: Any]`, which is not Sendable.
nonisolated private struct PluginTransfer<Value>: @unchecked Sendable {
    let value: Value
}

/// Run `body` on the main actor and return its result, blocking only when the
/// caller is not already there.
nonisolated func pluginMainSync<T>(_ body: @MainActor () -> T) -> T {
    // `assumeIsolated` requires a Sendable result, so the value travels boxed.
    if Thread.isMainThread {
        return MainActor.assumeIsolated { PluginTransfer(value: body()) }.value
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated { PluginTransfer(value: body()) }
    }.value
}

/// Fire-and-forget counterpart. Runs inline when already on the main actor so a
/// plugin's side effect is visible by the time the call returns, which is what
/// the JS API reads like.
nonisolated func pluginMainAsync(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
        return
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { body() }
    }
}
