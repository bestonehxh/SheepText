//
//  CursorState.swift
//  Shared observable state for the current cursor position, selection,
//  and document size. The editor updates this on every selection change;
//  the status bar reads from it for live display.
//
//  Keeping this as a tiny dedicated object (not inside DocumentStore)
//  lets us update it at 60 Hz on keystrokes without triggering re-renders
//  of the tab list or other document-store observers.
//

import Foundation
import Observation

@Observable
@MainActor
final class CursorState {
    /// 1-based line number of the primary cursor.
    var line: Int = 1
    /// 1-based column number of the primary cursor.
    var column: Int = 1
    /// Number of characters currently selected (across all selections,
    /// for multi-cursor). 0 when nothing is selected.
    var selectedCount: Int = 0
    /// Total character count of the active document. Useful for
    /// Sublime-style status bar "X characters" readout.
    var totalCount: Int = 0
}
