//
//  DisplayCalibrationStore.swift — colour S1, docs/COLOR_MANAGEMENT_FINDINGS.md §6.11 (decisions 1, 2).
//
//  "Is this display calibrated to Rec.709 / BT.1886 in its own hardware, and what are its white and
//  black?" — a statement about the user's ROOM, not about a clip (§6.6), so it is stored per DISPLAY
//  and not per window, and it is never inferred: no API reports either fact.
//
//  ── KEYED BY THE DISPLAY'S IDENTITY, NOT ITS NAME ────────────────────────────────────────────
//
//  `NSScreen.localizedName` is not unique (two identical monitors share it) and can change with the
//  OS language. The key is CoreGraphics' vendor, model and serial numbers. The name is stored beside
//  the record only so a person reading the defaults can tell which display is which.
//
//  ── ONE DEFAULTS KEY, READ AND MERGED BEFORE EVERY WRITE ─────────────────────────────────────
//
//  The whole table lives under `displayCalibrations` as JSON. A write reads the current table,
//  replaces one entry, and writes the table back — never a fresh table with one entry in it, which
//  would erase every other display's setting (CLAUDE.md's defaults rule, and the `streamBookmarks`
//  loss it records). An entry equal to the default is removed rather than stored, so a display the
//  user never touched leaves no trace.
//
//  Thread safety: reads may come from any thread (the renderer computes its plan on main, but nothing
//  here assumes it); writes happen on main, from the readout's controls. A lock covers the cache.
//

import AppKit
import ColorimetryModel

final class DisplayCalibrationStore: ObservableObject, @unchecked Sendable {
    static let shared = DisplayCalibrationStore()

    /// Posted on main after any change, `object` = the display key that changed.
    static let didChange = Notification.Name("DisplayCalibrationStore.didChange")

    static let defaultsKey = "displayCalibrations"

    struct Entry: Codable, Equatable {
        var name: String
        var calibration: DisplayCalibration
    }

    private let lock = NSLock()
    private var cache: [String: Entry]?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: Identity

    /// `vendor-model-serial`, from CoreGraphics. nil when the screen has no display number.
    static func key(for screen: NSScreen) -> String? {
        guard let id = displayID(for: screen) else { return nil }
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    // MARK: Read

    /// The calibration stated for this display, or the default (not calibrated, Lw 100, Lb 0).
    func calibration(for screen: NSScreen?) -> DisplayCalibration {
        guard let screen, let key = Self.key(for: screen) else { return .standard }
        return calibration(forKey: key)
    }

    func calibration(forKey key: String) -> DisplayCalibration {
        (table()[key]?.calibration ?? .standard).sanitized
    }

    private func table() -> [String: Entry] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let loaded = Self.decode(defaults.data(forKey: Self.defaultsKey))
        cache = loaded
        return loaded
    }

    /// Tolerant: an unreadable table reads as empty rather than failing, and is NOT overwritten
    /// until the user changes a setting — at which point the read-merge below starts from what
    /// could be read.
    private static func decode(_ data: Data?) -> [String: Entry] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    // MARK: Write (main)

    func set(_ calibration: DisplayCalibration, for screen: NSScreen) {
        guard let key = Self.key(for: screen) else { return }
        let value = calibration.sanitized
        lock.lock()
        // READ, MERGE, WRITE — re-read from defaults, not from the cache, so a table changed under
        // us is merged into rather than replaced.
        var current = Self.decode(defaults.data(forKey: Self.defaultsKey))
        if value == .standard {
            current.removeValue(forKey: key)
        } else {
            current[key] = Entry(name: screen.localizedName, calibration: value)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if current.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? encoder.encode(current) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        cache = current
        lock.unlock()
        print("[REFERENCE] display \"\(screen.localizedName)\" (\(key)): "
            + (value.calibrated ? "calibrated to Rec.709 / BT.1886" : "described by its profile")
            + String(format: ", Lw %g, Lb %g", value.whiteNits, value.blackNits))
        objectWillChange.send()
        NotificationCenter.default.post(name: Self.didChange, object: key)
    }
}
