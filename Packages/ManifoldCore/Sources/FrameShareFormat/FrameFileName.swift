//
//  FrameFileName.swift
//  FrameShareFormat — the base name Export Frame and Share Frame give a frame (Robbie, 2026-11-15).
//
//  A file:   "<clip name> <timecode>", the timecode as HH-MM-SS-FF: the file's source timecode when it has a timecode track,
//            otherwise the elapsed time from the start of the file, e.g. "MyClip 01-02-14-05".
//  A stream: "<stream name> <date time>", e.g. "Studio Feed 2026-11-15 14-03-22".
//  Export keeps its extension (.png); Share adds .jpg. The base is the same for both.
//
//  The base is built here, as plain strings, so the rules are pinned by `swift test`; the app supplies the clip name,
//  the timecode string the transport readout shows, and the stream name the window title shows (never a URL).
//

import Foundation

public enum FrameFileName {

    /// A transport timecode ("01:02:14:05", or "01:02:14;05" for drop frame) as a file-name field: every ":" and ";"
    /// becomes "-", so the name carries no character Finder shows as "/" (":") and none a shell reads as a separator.
    /// Drop frame is not marked in the name.
    public static func timecodeField(_ smpte: String) -> String {
        String(smpte.map { $0 == ":" || $0 == ";" ? "-" : $0 })
    }

    /// The elapsed time from the start of the file as HH-MM-SS-FF, for a file with no timecode track. The frame index is
    /// `round(seconds × rate)` at the EXACT rate and the fields split at the INTEGER rate (24 at 23.976), the rule the
    /// transport readout and timecode entry use (TimecodeEntry.swift header). Non-drop. A rate of 0 or less, or a
    /// non-finite time, counts at 24 fps from 0, as the readout's frame mode does.
    public static func elapsedTimecode(seconds: Double, rate: Double) -> String {
        let r = rate.isFinite && rate > 0 ? rate : 24
        let nfr = max(Int(r.rounded()), 1)
        let t = seconds.isFinite && seconds > 0 ? seconds : 0
        let frames = Int((t * r).rounded())
        let ff = frames % nfr
        let totalSeconds = frames / nfr
        return String(format: "%02d-%02d-%02d-%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, ff)
    }

    /// "<clip name> <timecode field>". `clipName` is the file's name without its extension.
    public static func clipBase(clipName: String, timecodeField: String) -> String {
        sanitized(clipName, fallback: "Frame") + " " + timecodeField
    }

    /// "<stream name> <yyyy-MM-dd HH-mm-ss>", local time unless `timeZone` says otherwise.
    public static func streamBase(streamName: String, date: Date, timeZone: TimeZone = .current) -> String {
        sanitized(streamName, fallback: "Stream") + " " + dateTimeField(date, timeZone: timeZone)
    }

    /// "Manifold frame <date time>": no source name to give (nothing loaded, or a path that had none).
    public static func fallbackBase(date: Date, timeZone: TimeZone = .current) -> String {
        "Manifold frame " + dateTimeField(date, timeZone: timeZone)
    }

    /// `yyyy-MM-dd HH-mm-ss`, POSIX locale, so the digits and the calendar do not follow the user's region.
    public static func dateTimeField(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }

    /// The longest a base may be, in UTF-8 bytes. APFS allows 255 per name; this leaves room for a " 99" uniquing
    /// suffix, the pixel-aspect tag ("_par40-33") and the extension.
    public static let maxBaseBytes = 200

    /// A name part safe in a file name: "/" and ":" become "-" (one is the path separator, Finder shows the other as "/"),
    /// control characters and newlines become spaces, runs of spaces collapse, leading dots and spaces go (no hidden
    /// files), and the result is cut to `maxBaseBytes` on a character boundary. Empty after all that: `fallback`.
    public static func sanitized(_ name: String, fallback: String) -> String {
        var out = ""
        var lastWasSpace = false
        for ch in name {
            var c = ch
            if c == "/" || c == ":" { c = "-" }
            if c.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
                c = " "
            }
            if c == " " {
                if lastWasSpace || out.isEmpty { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            out.append(c)
        }
        while out.hasPrefix(".") || out.hasPrefix(" ") { out.removeFirst() }
        while out.hasSuffix(" ") { out.removeLast() }
        while out.utf8.count > maxBaseBytes { out.removeLast() }
        while out.hasSuffix(" ") { out.removeLast() }
        return out.isEmpty ? fallback : out
    }

    /// `<base><suffix>.<ext>` in `folder`, or, when that exists, `<base> 2<suffix>.<ext>`, ` 3`, … as Finder does, so an
    /// export never replaces an earlier one of the same frame. `suffix` is the pixel-aspect tag ("_par2-1") or "".
    public static func uniqueURL(in folder: URL, base: String, suffix: String = "", ext: String,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = folder.appendingPathComponent(base + suffix).appendingPathExtension(ext)
        guard exists(first) else { return first }
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(n)" + suffix).appendingPathExtension(ext)
            if !exists(candidate) || n >= 10_000 { return candidate }
            n += 1
        }
    }
}

// MARK: - Folder per clip (Robbie, 2026-11-15, item 7)
//
// Settings ▸ Frame Export ▸ "Put exported frames in a folder per clip", default OFF. On: Export Frame saves into
// <export location>/<folder>/<file name>. The folder is the clip's name (the file's name without its extension), or the
// stream's name, made safe the same way the file names are, so the folder and the files in it begin with the same text.
// Share Frame is unaffected: it writes into its own temporary folder.

/// What a frame is called: the file's base name and, for the per-clip folder, the folder's name (nil: no source name to
/// give, so the frame goes in the export location itself).
public struct FrameName: Equatable, Sendable {
    public let base: String
    public let folder: String?
    public init(base: String, folder: String?) {
        self.base = base
        self.folder = folder
    }

    /// A file: "<clip> <HH-MM-SS-FF>", in the folder "<clip>".
    public static func clip(name: String, timecodeField: String) -> FrameName {
        FrameName(base: FrameFileName.clipBase(clipName: name, timecodeField: timecodeField),
                  folder: FrameFileName.folderName(name, fallback: "Frame"))
    }

    /// A stream: "<stream> <date time>", in the folder "<stream>".
    public static func stream(name: String, date: Date, timeZone: TimeZone = .current) -> FrameName {
        FrameName(base: FrameFileName.streamBase(streamName: name, date: date, timeZone: timeZone),
                  folder: FrameFileName.folderName(name, fallback: "Stream"))
    }
}

extension FrameFileName {

    /// The longest a per-clip folder name may be, in UTF-8 bytes (APFS allows 255).
    public static let maxFolderBytes = 100

    /// A clip or stream name as a folder name: `sanitized` ("/" and ":" become "-", control characters go, spaces
    /// collapse, no leading dots or spaces, trimmed), then cut to `maxFolderBytes` on a character boundary and trimmed
    /// again, with trailing dots removed as well. Empty: `fallback`.
    public static func folderName(_ name: String, fallback: String) -> String {
        var out = sanitized(name, fallback: fallback)
        while out.utf8.count > maxFolderBytes { out.removeLast() }
        while out.hasSuffix(" ") || out.hasSuffix(".") { out.removeLast() }
        return out.isEmpty ? fallback : out
    }

    /// Where a per-clip export goes.
    public enum ClipFolder: Equatable {
        /// `<root>/<name>`, existing or just created.
        case folder(URL)
        /// The root itself, because `<root>/<name>` is a file, or could not be created.
        case root(URL, reason: FallbackReason)
    }

    public enum FallbackReason: Equatable {
        case fileInTheWay
        case couldNotCreate
    }

    /// `<root>/<name>`, creating it when it does not exist. Falls back to `root` when a file (not a folder) already has
    /// that name, or the folder cannot be created.
    public static func clipFolder(in root: URL, name: String, fileManager: FileManager = .default) -> ClipFolder {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? .folder(folder) : .root(root, reason: .fileInTheWay)
        }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            return .folder(folder)
        } catch {
            return .root(root, reason: .couldNotCreate)
        }
    }

    /// The banner when a per-clip export fell back to the export location. Names the folder, which is the clip's own name
    /// and on screen already; never a path.
    public static func fallbackNotice(folder: String, reason: FallbackReason) -> String {
        switch reason {
        case .fileInTheWay:
            return "Frame exported to the export folder, not to “\(folder)”: a file with that name is in the way."
        case .couldNotCreate:
            return "Frame exported to the export folder: the folder “\(folder)” couldn’t be created."
        }
    }
}
