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
//  ── ⚠️ THE KEY IS TEMPORARY ──────────────────────────────────────────────────────────────────
//
//  Backslash (key code 42, so Shift-backslash is the same key whatever the layout prints for it), until
//  the shortcut registry decides the real one (§6.11 decision 3). Nothing else in the app binds it.
//
//  ── WHY A LOCAL EVENT MONITOR, AND WHY HERE ──────────────────────────────────────────────────
//
//  A hold needs key-UP, which a SwiftUI `.keyboardShortcut` never delivers. And `ContentView` cannot
//  take another modifier (§6.7), so this is app-level, installed once from `ManifoldApp.init`, and it
//  acts on the key deck. It steps aside while a text field is being typed into.
//
//  A hold always ends: on key-up, and also if the window stops being key or the app stops being
//  active (the key-up would then go to someone else and the window would be left comparing).
//

import AppKit
import QuartzCore

@MainActor
final class HoldToCompare {
    static let shared = HoldToCompare()

    /// ⚠️ TEMPORARY — backslash. See the header.
    static let keyCode: UInt16 = 42

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// The deck a hold is in progress on, and the mode it showed.
    private weak var holdingDeck: WindowDeck?
    private var holding = false

    private init() {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            MainActor.assumeIsolated { HoldToCompare.shared.handle(event) }
        }
        print("[COMPARE] hold-to-compare key monitor " + (monitor == nil ? "⚠️ NOT installed" : "installed")
            + " — temporary key: backslash (Shift: Bypass)")
        let nc = NotificationCenter.default
        // A menu opening also ends a hold: while a menu tracks, key-up goes to the menu, not to this
        // monitor, and the window would be left comparing.
        let enders: [(Notification.Name, String)] = [(NSWindow.didResignKeyNotification, "window not key"),
                                                     (NSApplication.didResignActiveNotification, "app not active"),
                                                     (NSMenu.didBeginTrackingNotification, "a menu opened")]
        for (name, reason) in enders {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HoldToCompare.shared.release(reason: reason) }
            })
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == Self.keyCode else { return event }
        // Typing a backslash into a field (the calibration fields, a URL) is not a hold.
        if let responder = event.window?.firstResponder, responder is NSText { return event }
        switch event.type {
        case .keyDown:
            if event.isARepeat { return holding ? nil : event }
            // A fresh key-down while a hold is recorded means its key-up was never delivered (or a
            // menu pick already ended it). End it, then start this one — never ignore the key and
            // leave the window stuck.
            if holding { release(reason: "missed key up") }
            return begin(shift: event.modifierFlags.contains(.shift)) ? nil : event
        case .keyUp:
            if holding { release(reason: "key up"); return nil }
            return event
        default:
            return event
        }
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

    private func release(reason: String) {
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
