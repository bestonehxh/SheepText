//
//  EditorBridge.swift
//  Exposed to plugin JS as `editor`. Provides read/write access to the
//  currently focused editor.
//
//  AppKit access goes through `pluginMainSync` / `pluginMainAsync`, which run
//  inline when the caller is already on the main actor. Plugin JS currently runs
//  on the main thread (PluginHost is @MainActor), so the old unconditional
//  `DispatchQueue.main.sync` deadlocked on the first bridge call.
//

import Foundation
import AppKit
import JavaScriptCore

@objc protocol EditorBridgeExports: JSExport {
    func getText() -> String
    func replaceSelection(_ text: String)
    func getCurrentLine() -> [String: Any]
    func replaceCurrentLine(_ text: String)
    func getLanguage() -> String
    func setHighlightLanguageForExtension(_ fileExtension: String, _ language: String)
    func clearHighlightLanguageForExtension(_ fileExtension: String)
}

@objc final class EditorBridge: NSObject, EditorBridgeExports {

    /// Finds the first-responder NSTextView in the key window, if any.
    @MainActor
    private func currentTextView() -> EditorTextView? {
        NSApp.keyWindow?.firstResponder as? EditorTextView
    }

    func getText() -> String {
        pluginMainSync {
            guard let tv = self.currentTextView() else { return "" }
            return tv.string
        }
    }

    func replaceSelection(_ text: String) {
        pluginMainSync {
            guard let tv = self.currentTextView() else { return }
            tv.insertText(text, replacementRange: tv.selectedRange())
        }
    }

    func getCurrentLine() -> [String: Any] {
        pluginMainSync {
            guard let tv = self.currentTextView() else {
                return ["text": "", "number": 0]
            }
            let str = tv.string as NSString
            let sel = tv.selectedRange()
            let lineRange = str.lineRange(for: sel)
            let line = str.substring(with: lineRange)
                .trimmingCharacters(in: .newlines)
            // Line number: count newlines before sel.location. Counted over the
            // UTF-16 view because `sel.location` is a UTF-16 offset and Swift
            // treats CRLF as one Character, which undercounted on CRLF files.
            var number = 1
            for index in 0..<min(sel.location, str.length) where str.character(at: index) == 0x0A {
                number += 1
            }
            return ["text": line, "number": number]
        }
    }

    func replaceCurrentLine(_ text: String) {
        pluginMainSync {
            guard let tv = self.currentTextView() else { return }
            let str = tv.string as NSString
            let lineRange = str.lineRange(for: tv.selectedRange())
            tv.insertText(text + "\n", replacementRange: lineRange)
        }
    }

    func getLanguage() -> String {
        pluginMainSync {
            self.currentTextView()?.document?.language ?? "plaintext"
        }
    }

    func setHighlightLanguageForExtension(_ fileExtension: String, _ language: String) {
        pluginMainAsync {
            HighlightOverrides.shared.setLanguage(language, forFileExtension: fileExtension)
        }
    }

    func clearHighlightLanguageForExtension(_ fileExtension: String) {
        pluginMainAsync {
            HighlightOverrides.shared.clearLanguage(forFileExtension: fileExtension)
        }
    }
}
