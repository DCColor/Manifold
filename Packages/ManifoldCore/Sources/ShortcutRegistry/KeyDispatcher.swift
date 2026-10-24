//
//  KeyDispatcher.swift — every key the menus do not take, matched against the registry in one place
//  (docs/SHORTCUTS_AUDIT.md §4.4). The app feeds it from ONE `NSEvent` local monitor; tests feed it synthesized
//  `NSEvent`s through the same adapter.
//
//  The order, and why:
//    1. Recording in the Keyboard Shortcuts window: take nothing.
//    2. A text field is being typed into: take nothing. Menus still get their ⌘ keys from AppKit, except the ones a
//       field uses itself, which the app hands to the field (`textFieldTakes`).
//    3. Timecode entry is open: every bare or ⇧ key belongs to it (nothing moves behind the overlay); ⌘ / ⌃ / ⌥
//       keys go on to the matcher, as they did before (the nudge, the debug hooks).
//    4. The registry's bindings, exact modifiers. Several actions may share a key in scopes that never meet (a file
//       window and a live window): the first the window can perform wins. One that cannot is passed over, and if
//       none can, the key goes on to AppKit, as a disabled hidden button's key used to.
//    5. A bare digit, + or − opens timecode entry.
//
//  ── HOLDS AND THE K+J/L GESTURE NEED KEY-UP ─────────────────────────────────────────────────
//
//  A SwiftUI `.keyboardShortcut` never sees a key-up, which is why hold-to-compare had its own monitor and why
//  K+J/L could not be built before (audit C11). Here:
//    • Hold (C, ⇧C, ⌥C): key-down begins, its key-up ends; auto-repeats are swallowed while holding. ⌘C, ⌃C and
//      any other modified C match nothing and pass through: modifiers are exact.
//    • K held, then J or L (DaVinci Resolve R20 p729: "Hold K and tap J or L = 1 frame", "Hold K+J or K+L =
//      slow-motion play"; Final Cut Pro, Play media: hold K and hold J or L = ½×): each press steps one frame;
//      a press still held after `slowPlayDelay` plays at ½× in its direction until J/L or K is released.
//

import Foundation

@MainActor
public protocol KeyDispatchHost: AnyObject {
    /// The key window's first responder is a text view being edited.
    var isEditingText: Bool { get }
    var isTimecodeEntryOpen: Bool { get }
    /// Entry is open: the key is entry's. True when consumed (entry swallows every bare key).
    func timecodeEntryKey(_ event: KeyEvent) -> Bool
    /// Entry is closed: a digit, + or − may open it. True when it did.
    func timecodeEntryOpen(_ event: KeyEvent) -> Bool
    func canPerform(_ id: ShortcutID) -> Bool
    func perform(_ id: ShortcutID)
    /// False when there is nothing to compare (no source): the key then passes on.
    func beginHold(_ id: ShortcutID) -> Bool
    func endHold(reason: String)
    func stepFrames(_ frames: Int)
    func shuttle(rate: Float)
}

@MainActor
public final class KeyDispatcher {
    public typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> (() -> Void)

    public let registry: ShortcutRegistry
    public static let slowPlayDelay: TimeInterval = 0.3
    public static let slowPlayRate: Float = 0.5

    private let schedule: Scheduler
    /// The key code of the hold in progress.
    public private(set) var holdKeyCode: UInt16?
    /// K (whatever key `shuttlePause` has) is down.
    public private(set) var pauseKeyCode: UInt16?
    private struct Gesture { let keyCode: UInt16; let direction: Int; var slow: Bool; let cancel: () -> Void }
    private var gesture: Gesture?
    public var isSlowPlaying: Bool { gesture?.slow == true }

    public init(registry: ShortcutRegistry, schedule: Scheduler? = nil) {
        self.registry = registry
        self.schedule = schedule ?? KeyDispatcher.mainQueueScheduler
    }

    public static let mainQueueScheduler: Scheduler = { delay, work in
        var cancelled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { if !cancelled { work() } }
        }
        return { cancelled = true }
    }

    /// A key a menu item carries that the text field being typed into should have instead (N, ⌘↑): the app hands
    /// it to the field directly, ahead of the menu's key matching. Asked before `handle`.
    public func textFieldTakes(_ event: KeyEvent, host: KeyDispatchHost) -> Bool {
        event.phase == .down && !registry.isRecording && host.isEditingText && registry.menuKeyATextFieldUses(event)
    }

    /// True when the event was consumed and must go no further.
    public func handle(_ event: KeyEvent, host: KeyDispatchHost) -> Bool {
        if registry.isRecording { return false }
        switch event.phase {
        case .up: return handleUp(event, host: host)
        case .down: return handleDown(event, host: host)
        }
    }

    /// A window stopped being key, the app went inactive, or a menu opened: the key-ups will go elsewhere.
    public func reset(host: KeyDispatchHost?, reason: String) {
        if holdKeyCode != nil {
            holdKeyCode = nil
            host?.endHold(reason: reason)
        }
        pauseKeyCode = nil
        endGesture(host: host)
    }

    private func handleUp(_ event: KeyEvent, host: KeyDispatchHost) -> Bool {
        var consumed = false
        if let code = holdKeyCode, code == event.keyCode {
            holdKeyCode = nil
            host.endHold(reason: "key up")
            consumed = true
        }
        if let g = gesture, g.keyCode == event.keyCode { endGesture(host: host) }
        if let k = pauseKeyCode, k == event.keyCode {
            pauseKeyCode = nil
            endGesture(host: host)
        }
        return consumed
    }

    private func handleDown(_ event: KeyEvent, host: KeyDispatchHost) -> Bool {
        if host.isEditingText { return false }
        let commandLike = !event.modifiers.isDisjoint(with: .commandLike)
        if host.isTimecodeEntryOpen && !commandLike { return host.timecodeEntryKey(event) }

        for (def, chord) in registry.dispatcherBindings() where event.matches(chord) {
            switch def.dispatch {
            case .hold:
                if event.isRepeat {
                    if holdKeyCode == event.keyCode { return true }
                    continue
                }
                // A fresh key-down while a hold is recorded means its key-up was never delivered. End it, then start
                // this one: never leave the window stuck.
                if holdKeyCode != nil {
                    holdKeyCode = nil
                    host.endHold(reason: "missed key up")
                }
                guard host.beginHold(def.id) else { continue }
                holdKeyCode = event.keyCode
                return true
            default:
                guard host.canPerform(def.id) else { continue }
                if (def.id == .shuttleReverse || def.id == .shuttleForward), pauseKeyCode != nil {
                    return gestureDown(event, forward: def.id == .shuttleForward, host: host)
                }
                if event.isRepeat && !def.repeats { return true }
                host.perform(def.id)
                if def.id == .shuttlePause, !event.isRepeat { pauseKeyCode = event.keyCode }
                return true
            }
        }
        if !commandLike { return host.timecodeEntryOpen(event) }
        return false
    }

    private func gestureDown(_ event: KeyEvent, forward: Bool, host: KeyDispatchHost) -> Bool {
        if event.isRepeat { return true }   // held: the timer decides
        endGesture(host: host)
        let direction = forward ? 1 : -1
        host.stepFrames(direction)
        let code = event.keyCode
        let cancel = schedule(Self.slowPlayDelay) { [weak self, weak host] in
            guard let self, let host, self.gesture?.keyCode == code, self.pauseKeyCode != nil else { return }
            self.gesture?.slow = true
            host.shuttle(rate: Self.slowPlayRate * Float(direction))
        }
        gesture = Gesture(keyCode: code, direction: direction, slow: false, cancel: cancel)
        return true
    }

    private func endGesture(host: KeyDispatchHost?) {
        guard let g = gesture else { return }
        g.cancel()
        gesture = nil
        if g.slow { host?.shuttle(rate: 0) }
    }
}
