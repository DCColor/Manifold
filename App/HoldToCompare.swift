//
//  HoldToCompare.swift — colour S2, docs/COLOR_MANAGEMENT_FINDINGS.md §6.11 (decision 3); §6.3's
//  "momentary compare, not only a sticky mode".
//
//  Hold the key: the key window shows the OTHER of macOS and Reference until the key is released.
//  Shift-hold: it shows Bypass instead. From Bypass, a plain hold shows macOS. Release, and the window
//  is back in the mode that was chosen — which never moved: the change goes through
//  `DeckRegistry.setDisplayTransform(_:on:temporary: true)`, so the checkmark, the pulldown and the
//  label stay where they were, and only `chrome.heldDisplayTransform` carries the comparison.
//
//  ⌥-hold: the window's LUT is bypassed until release (nothing happens with no LUT applied). Unlike the other two
//  this is not desktop-only: a bypassed LUT is off the renderer, so scopes and SDI follow it for the hold, exactly as
//  the menu's Bypass LUT does.
//
//  ── THE KEY: C, ⇧C FOR BYPASS, ⌥C FOR LUT OFF ─────────────────────────────────────────────────
//
//  C for Compare (Robbie, 2026-10-24, docs/SHORTCUTS_AUDIT.md §8), replacing D (2026-10-23), which replaced the
//  temporary backslash. The keys are the registry's (`ShortcutID.holdCompare`, `.holdCompareBypass`,
//  `.holdCompareLUTOff`) and can be rebound in the Keyboard Shortcuts window.
//
//  ── WHO READS THE KEY ────────────────────────────────────────────────────────────────────────
//
//  A hold needs key-UP, which a SwiftUI `.keyboardShortcut` never delivers, so this used to run its own `NSEvent`
//  monitor. That monitor matched key code 42 under ANY modifiers, and so swallowed ⇧⌘\ (Show All Tabs, measured in
//  the menu bar) and every other modified backslash (audit C3). It is gone: `ShortcutCenter`'s one monitor feeds
//  the registry's `KeyDispatcher`, which matches exact modifiers (⌘C, ⌃C and any other unbound modified C pass through),
//  steps aside while a text field is being typed into, swallows the hold's auto-repeats, and calls `begin` / `release`
//  here. A hold always ends: on key-up, and also when the window stops being key, the app stops being active, or a
//  menu opens (the key-up would then go to someone else and the window would be left comparing); `ShortcutCenter`
//  watches those.
//

import AppKit
import QuartzCore
import ShortcutRegistry

@MainActor
final class HoldToCompare {
    static let shared = HoldToCompare()

    /// The deck a hold is in progress on, and the mode it showed.
    private weak var holdingDeck: WindowDeck?
    private var holding = false
    /// The deck whose LUT this hold bypassed (⌥C), so release puts back only what the hold took off.
    private weak var lutHoldDeck: WindowDeck?

    private init() {}

    /// The dispatcher's begin: `.holdCompare`, `.holdCompareBypass` or `.holdCompareLUTOff`.
    func begin(_ id: ShortcutID) -> Bool {
        id == .holdCompareLUTOff ? beginLUTOff() : begin(shift: id == .holdCompareBypass)
    }

    /// ⌥C: the LUT off while held. With a key deck but no LUT applied it takes the key and does nothing.
    private func beginLUTOff() -> Bool {
        guard let deck = DeckRegistry.shared.keyDeck else { return false }
        guard deck.lut.isApplied else {
            print("[COMPARE] LUT hold — no LUT applied in this window, nothing to compare"); return true
        }
        print(String(format: "[COMPARE] t=%.3f ", CACurrentMediaTime()) + "hold ↓ LUT → off")
        deck.renderer?.markCompareEvent("hold → LUT off", at: CACurrentMediaTime())
        deck.lut.setBypassed(true)
        lutHoldDeck = deck
        return true
    }

    /// Returns false when there is nothing to compare (no key deck, no source), so the key passes on.
    private func begin(shift: Bool) -> Bool {
        let registry = DeckRegistry.shared
        guard let deck = registry.keyDeck, let chrome = deck.chrome else {
            print("[COMPARE] key ignored — no key window with a deck"); return false
        }
        guard deck.engine?.displaySize != nil else {
            print("[COMPARE] key ignored — this window has no source"); return false
        }
        let chosen = chrome.displayTransform
        let target: DisplayTransformMode
        if shift {
            target = .bypass
        } else {
            switch chosen {
            case .os:        target = .reference
            case .reference: target = .os
            case .bypass:    target = .os
            }
        }
        guard target != chosen else { return true }   // Shift-hold from Bypass: nothing to compare
        let now = CACurrentMediaTime()
        let refresh = deck.window?.screen?.maximumFramesPerSecond ?? 0
        print(String(format: "[COMPARE] t=%.3f ", now) + "hold ↓ \(chosen.logLabel) → \(target.logLabel)"
            + (refresh > 0 ? String(format: "  (display refresh %d Hz = %.1f ms)", refresh, 1000.0 / Double(refresh)) : ""))
        deck.renderer?.markCompareEvent("hold → \(target.logLabel)", at: now)
        registry.setDisplayTransform(target, on: deck, temporary: true)
        holdingDeck = deck
        holding = true
        return true
    }

    func release(reason: String) {
        if let deck = lutHoldDeck {
            lutHoldDeck = nil
            // A LUT removed or replaced during the hold has nothing to restore; one still bypassed is put back. (Bypass
            // LUT chosen from the menu mid-hold cannot be told apart from the hold's own bypass, and is undone too.)
            if deck.lut.bypassed {
                print(String(format: "[COMPARE] t=%.3f ", CACurrentMediaTime()) + "release ↑ (\(reason)) → LUT on")
                deck.renderer?.markCompareEvent("release → LUT on", at: CACurrentMediaTime())
                deck.lut.setBypassed(false)
            }
        }
        guard holding else { return }
        holding = false
        guard let deck = holdingDeck, let chrome = deck.chrome else { holdingDeck = nil; return }
        holdingDeck = nil
        // A real choice made during the hold has already ended it (`setDisplayTransform` clears the
        // held mode); there is then nothing to restore.
        guard chrome.heldDisplayTransform != nil else {
            print("[COMPARE] release ↑ (\(reason)) — the hold had already ended")
            return
        }
        let chosen = chrome.displayTransform
        print(String(format: "[COMPARE] t=%.3f ", CACurrentMediaTime()) + "release ↑ (\(reason)) → back to \(chosen.logLabel)")
        deck.renderer?.markCompareEvent("release → \(chosen.logLabel)", at: CACurrentMediaTime())
        DeckRegistry.shared.setDisplayTransform(chosen, on: deck, temporary: true)
    }
}
