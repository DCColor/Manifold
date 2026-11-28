//
//  FrameSaveNotice.swift
//  Manifold — what the window's banner says after Export Frame, Export Frame for Support or Share Frame
//  (docs/BUGS.md, 0.9.6 UI polish item 3).
//
//  Until 0.9.6 Export Frame saved with no word on screen: a saved frame said nothing about where it went, and a failed PNG
//  write went only to the log. Share Frame only beeped. A save now ends in a short banner: the file's name and Show in
//  Finder, or what went wrong and what to do. The banner names the file and its folder, which the user chose; never a path.
//

import Foundation

/// The banner a frame save leaves in its window.
public enum FrameSaveNotice: Equatable, Sendable {
    /// Saved at `url`. `note` is a second sentence, when the frame did not go where the settings said (the per-clip
    /// folder's fallback, `FrameFileName.fallbackNotice`).
    case saved(url: URL, note: String?)
    /// Not saved, or not shared: the whole message.
    case failed(String)

    public var text: String {
        switch self {
        case .saved(let url, let note):
            let line = "Saved “\(url.lastPathComponent)”."
            return note.map { "\(line) \($0)" } ?? line
        case .failed(let message):
            return message
        }
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

    /// How long the banner stays up. A saved frame needs only a glance; a failure stays as long as a connection error does
    /// (9 s, `ContentView.connectErrorBanner`). Either can be closed sooner.
    public var autoHideSeconds: Double { isFailure ? 9 : 6 }

    /// The same notice with `note` added to a saved frame's line. A failure is unchanged: its message is the news.
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

    /// The banner. Names the file and its folder (both chosen by the user and on screen in Settings), never a path, and says
    /// what to do.
    public func message(fileName: String, folderName: String) -> String {
        let settings = "Settings ▸ Files ▸ Frame Export"
        switch self {
        case .folderMissing:
            return "Couldn’t save “\(fileName)”: the folder “\(folderName)” isn’t there anymore. Choose a folder in \(settings)."
        case .folderNotWritable:
            return "Couldn’t save “\(fileName)”: Manifold can’t write to the folder “\(folderName)”. Choose another folder in \(settings)."
        case .diskFull:
            return "Couldn’t save “\(fileName)”: the disk is full. Free some space, then export again."
        case .unknown:
            return "Couldn’t save “\(fileName)” in “\(folderName)”. Try again, or choose another folder in \(settings)."
        }
    }
}

/// What Share Frame's banner says when the share could not happen. A cancel says nothing.
public enum ShareFailure {
    /// The JPEG could not be written to the app's own share folder, or the folder could not be made.
    public static let couldNotPrepare = "Couldn’t prepare the frame to share. Try again, or use Export Frame… to save it instead."

    /// The chosen service (Mail, Messages, AirDrop…) reported a failure. `detail` is the system's own description.
    public static func couldNotShare(detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Couldn’t share the frame. Try again, or use Export Frame… to save it instead." }
        return "Couldn’t share the frame: \(trimmed)"
    }

    /// A service's "failure" that is the user's own Cancel (Messages reports one this way), which shows no banner.
    public static func isCancel(domain: String, code: Int) -> Bool {
        domain == NSCocoaErrorDomain && code == NSUserCancelledError
    }
}
