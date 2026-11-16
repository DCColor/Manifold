// rc-soak-ax: the Markers slot's gear, by accessibility only (no keystrokes, no pointer, no screenshots). For rc-soak.py.
//   rc-soak-ax <pid> gear     exit 0 when the Markers slot's gear is on screen (the slot is open), 3 when not
//   rc-soak-ax <pid> regen    gear ▸ Regenerate Thumbnails, then the gear again to close its popover
// The gear is found by its tooltip (AXHelp), "Thumbnails, colors shown, start timecode" (App/Markers/MarkersScopeView.swift:37),
// which only the Markers slot's gear carries. "colours shown" is accepted too: builds before fbb735a (American English) spell it so.
// Build: swiftc -O -o build/decklink-loopback/rc-soak-ax scripts/decklink-loopback/rc-soak-ax.swift
import AppKit
import ApplicationServices

let a = CommandLine.arguments
guard a.count == 3, let pid = pid_t(a[1]) else { print("rc-soak-ax <pid> gear|regen"); exit(2) }
let gearHelps: Set<String> = ["Thumbnails, colors shown, start timecode", "Thumbnails, colours shown, start timecode"], regenTitle = "Regenerate Thumbnails"

func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func find(_ e: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if depth > 40 { return nil }
    let role = attr(e, kAXRoleAttribute) as? String
    if role == "AXMenu" || role == "AXMenuBar" { return nil }   // never walk into menus (reading one opens it)
    if role == "AXButton", match(e) { return e }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(c, depth: depth + 1, match) { return f } }
    return nil
}
let app = AXUIElementCreateApplication(pid)
func windows() -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
func first(_ match: (AXUIElement) -> Bool) -> AXUIElement? { for w in windows() { if let f = find(w, match) { return f } }; return nil }
let isGear: (AXUIElement) -> Bool = { gearHelps.contains((attr($0, kAXHelpAttribute) as? String) ?? "") }
let isRegen: (AXUIElement) -> Bool = { (attr($0, kAXTitleAttribute) as? String) == regenTitle || (attr($0, kAXDescriptionAttribute) as? String) == regenTitle }

guard let gear = first(isGear) else { print("no-gear"); exit(3) }
if a[2] == "gear" { print("gear"); exit(0) }
guard a[2] == "regen" else { print("unknown verb"); exit(2) }
if first(isRegen) == nil { _ = AXUIElementPerformAction(gear, kAXPressAction as CFString) }   // open the popover unless already open
var regen: AXUIElement?
for _ in 0..<30 { if let r = first(isRegen) { regen = r; break }; usleep(100_000) }
guard let regen else { print("no-regen-button"); exit(4) }
let enabled = (attr(regen, kAXEnabledAttribute) as? Bool) ?? false
let pressed = enabled ? AXUIElementPerformAction(regen, kAXPressAction as CFString).rawValue : -1
usleep(300_000)
_ = AXUIElementPerformAction(gear, kAXPressAction as CFString)   // close the popover (the gear toggles it)
var closed = false
for _ in 0..<20 { if first(isRegen) == nil { closed = true; break }; usleep(100_000) }
print("regen enabled=\(enabled) press=\(pressed) popover-closed=\(closed)")
exit(enabled && pressed == 0 ? 0 : 5)
