//
//  FrameSaveNotice.swift
//  Manifold — what the window's banner says after Export Frame, Export Frame for Support or Share Frame
//  (docs/BUGS.md, 0.9.6 UI polish item 3).
//
//  Until 0.9.6 Export Frame saved with no word on screen: a saved frame said nothing about where it went, and a failed PNG
//  write went only to the log. Share Frame only beeped. A save now ends in a short banner: the file's name and Show in
//  Finder, or what went wrong and what to do.
//
//  THE FILE NAME IS NEVER INSIDE A SENTENCE (Robbie, 2026-11-27). A long name wrapped mid-word and was hyphenated, which
//  reads as a different name. So the banner is three parts: a headline ("Saved", "Couldn’t save"), the file name on the same
//  line, shown on one line and truncated in the middle when it doesn't fit, and a detail sentence that names no file or
//  folder. Never a path.
//

import Foundation

/// The banner a frame save leaves in its window.
public enum FrameSaveNotice: Equatable, Sendable {
    /// Saved at `url`. `note` is a detail sentence, when the frame did not go where the settings said (the per-clip folder's
    /// fallback, `FrameFileName.fallbackNotice`).
    case saved(url: URL, note: String?)
    /// Not saved, or not shared. `fileName` is the file that could not be written, when there is one.
    case failed(headline: String, fileName: String?, detail: String?)

    public var headline: String {
        switch self {
        case .saved: return "Saved"
        case .failed(let headline, _, _): return headline
        }
    }

    /// Shown on the headline's line, never wrapped: one line, truncated in the middle.
    public var fileName: String? {
        switch self {
        case .saved(let url, _): return url.lastPathComponent
        case .failed(_, let name, _): return name
        }
    }

    /// The sentence under the headline. Names no file and no folder.
    public var detail: String? {
        switch self {
        case .saved(_, let note): return note
        case .failed(_, _, let detail): return detail
        }
    }

    /// All three parts as one line, for the accessibility label and the tests.
    public var text: String {
        var line = headline
        if let fileName { line += " “\(fileName)”" }
        line += "."
        if let detail { line += " \(detail)" }
        return line
    }

    /// The saved file, for Show in Finder. nil for a failure.
    public var fileURL: URL? {
        if case .saved(let url, _) = self { return url }
        return nil
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// How long the banner stays up, or nil: it stays until closed or replaced. A saved frame needs only a glance; a failure
    /// is an error, and errors stand (naming decision D7, Robbie, 2026-11-27).
    public var autoHideSeconds: Double? { isFailure ? nil : 6 }

    /// THE RENDERER'S SPELLING, KEPT. `MetalVideoRenderer.writeFrameExport` (batch 2, 0.9.6) writes
    /// `.failed(failure.message(fileName:folderName:))`, and batch 3 may not change that file. `message` now returns the
    /// structured notice, and this passes it through, so the name still lands on its own line.
    public static func failed(_ notice: FrameSaveNotice) -> FrameSaveNotice { notice }

    /// The same notice with `note` added to a saved frame's detail. A failure is unchanged: its detail is the news.
    public func adding(note: String?) -> FrameSaveNotice {
        guard let note, case .saved(let url, let existing) = self else { return self }
        return .saved(url: url, note: existing.map { "\($0) \(note)" } ?? note)
    }
}

/// Why a frame could not be written. `CGImageDestinationFinalize` returns only false, so the reason is read from the folder
/// afterwards; `.unknown` when nothing there explains it.
public enum FrameSaveFailure: Equatable, Sendable {
    case folderMissing
    case folderNotWritable
    case diskFull
    case unknown

    /// For the `[EXPORT]` log line, which carries no path.
    public var logLabel: String {
        switch self {
        case .folderMissing: return "folder missing"
        case .folderNotWritable: return "folder not writable"
        case .diskFull: return "disk full"
        case .unknown: return "reason unknown"
        }
    }

    /// The reason, from what is known about the folder. `freeBytes` nil: the volume did not say, so the disk is not
    /// blamed. `neededBytes` is an upper bound for the file (an uncompressed 16-bit RGBA frame).
    public static func diagnose(folderExists: Bool, folderWritable: Bool, freeBytes: Int64?, neededBytes: Int64) -> FrameSaveFailure {
        if !folderExists { return .folderMissing }
        if !folderWritable { return .folderNotWritable }
        if let freeBytes, freeBytes < neededBytes { return .diskFull }
        return .unknown
    }

    /// `diagnose` read from the folder itself, after the write failed.
    public static func diagnose(folder: URL, neededBytes: Int64, fileManager: FileManager = .default) -> FrameSaveFailure {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let writable = exists && fileManager.isWritableFile(atPath: folder.path)
        let free = exists
            ? (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            : nil
        return diagnose(folderExists: exists, folderWritable: writable, freeBytes: free, neededBytes: neededBytes)
    }

    /// What to do, without a file or folder name (the name is the banner's own line).
    public var detail: String {
        let settings = "Settings ▸ Files ▸ Frame Export"
        switch self {
        case .folderMissing: return "Its folder isn’t there anymore. Choose a folder in \(settings)."
        case .folderNotWritable: return "Manifold can’t write to its folder. Choose another folder in \(settings)."
        case .diskFull: return "The disk is full. Free some space, then export again."
        case .unknown: return "Try again, or choose another folder in \(settings)."
        }
    }

    /// The banner for a frame that could not be written as `fileName`.
    public func notice(fileName: String) -> FrameSaveNotice {
        .failed(headline: "Couldn’t save", fileName: fileName, detail: detail)
    }

    /// `notice(fileName:)` under the name the renderer calls (see `FrameSaveNotice.failed(_:)`). The folder is not named:
    /// the detail sentence says "its folder".
    public func message(fileName: String, folderName _: String) -> FrameSaveNotice { notice(fileName: fileName) }
}

/// What Share Frame's banner says when the share could not happen. A cancel says nothing.
public enum ShareFailure {
    public static let headline = "Couldn’t share the frame"

    /// The JPEG could not be written to the app's own share folder, or the folder could not be made.
    public static let couldNotPrepare = FrameSaveNotice.failed(headline: headline, fileName: nil,
                                                               detail: "Try again, or use Export Frame… to save it instead.")

    /// The chosen service (Mail, Messages, AirDrop…) reported a failure. `detail` is the system's own description.
    public static func couldNotShare(detail: String) -> FrameSaveNotice {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(headline: headline, fileName: nil,
                       detail: trimmed.isEmpty ? "Try again, or use Export Frame… to save it instead." : trimmed)
    }

    /// A service's "failure" that is the user's own Cancel (Messages reports one this way), which shows no banner.
    public static func isCancel(domain: String, code: Int) -> Bool {
        domain == NSCocoaErrorDomain && code == NSUserCancelledError
    }
}
