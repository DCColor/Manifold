//
//  SessionPaths.swift
//  Manifold — the file paths this process has opened, for the diagnostics redactor.
//
//  Privacy stage P1 (docs/PRIVACY_AUDIT.md). A pattern cannot tell where a path with spaces in it
//  ends — `/Volumes/DCCOLOR/TEST FLIP/MXF NCLc Matrix/cs709-g24.mxf` reads as several words — so
//  the redactor removes the paths it KNOWS literally, before its generic rule runs. This is where it
//  learns them: media, LUTs and caption files are noted as they are opened.
//
//  In memory only, for the life of the process. Never written anywhere.
//

import Foundation

enum SessionPaths {
    private static let lock = NSLock()
    private static var paths = Set<String>()

    /// Remember a file URL's path (and its resolved form, when a symlink or `/private` alias makes
    /// them differ). Non-file URLs are ignored: streams carry no local path.
    static func note(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.path
        let resolved = url.resolvingSymlinksInPath().path
        lock.lock()
        paths.insert(path)
        paths.insert(resolved)
        lock.unlock()
    }

    static func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(paths)
    }
}
