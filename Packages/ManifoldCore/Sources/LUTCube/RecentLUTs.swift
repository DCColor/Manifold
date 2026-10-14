//
//  RecentLUTs.swift — the Recent LUTs list as stored in the defaults (colour S6, L3; §6.11 D4).
//
//  One defaults key, an array of dictionaries, newest first: the file's path, its bookmark data (plain, not
//  security-scoped: the app is not sandboxed, §6.11 audit finding 5) and the output space stated for it
//  (`ColorimetryOverride.storageID`; absent = Same as Source). The app's store reads and writes it; this file
//  only says what the value is, so the rules can be tested without a defaults domain.
//
//  ⚠️ A VALUE THIS CODE CANNOT READ IS NEVER WRITTEN OVER. `decode` returns nil for anything that is not a list of
//  entries it understands, including an entry with a key it does not know, and the store then writes nothing:
//  `defaults write` semantics replace a list wholesale, so writing "the list as we understood it" would erase
//  what we did not (CLAUDE.md's defaults rule, and the `streamBookmarks` loss in docs/BUGS.md).
//

import Foundation

public struct RecentLUTEntry: Equatable, Sendable {
    public var path: String
    public var bookmark: Data?
    /// `ColorimetryOverride.storageID` of the stated output space; nil = Same as Source.
    public var outputSpace: String?

    public init(path: String, bookmark: Data? = nil, outputSpace: String? = nil) {
        (self.path, self.bookmark, self.outputSpace) = (path, bookmark, outputSpace)
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

public enum RecentLUTList {
    public static let defaultsKey = "recentLUTs"
    public static let capacity = 10

    static let pathKey = "path", bookmarkKey = "bookmark", outputKey = "outputSpace"
    static let knownKeys: Set<String> = [pathKey, bookmarkKey, outputKey]

    /// The stored value as entries. Absent → an empty list. **nil → not a list this version reads: write nothing.**
    public static func decode(_ stored: Any?) -> [RecentLUTEntry]? {
        guard let stored else { return [] }
        guard let array = stored as? [Any] else { return nil }
        var entries: [RecentLUTEntry] = []
        for item in array {
            guard let d = item as? [String: Any], Set(d.keys).isSubset(of: knownKeys),
                  let path = d[pathKey] as? String, !path.isEmpty else { return nil }
            let bookmark = d[bookmarkKey]
            let output = d[outputKey]
            guard bookmark == nil || bookmark is Data, output == nil || output is String else { return nil }
            entries.append(RecentLUTEntry(path: path, bookmark: bookmark as? Data, outputSpace: output as? String))
        }
        return entries
    }

    /// The value to store. An absent bookmark or output space is an absent key, never an empty value.
    public static func encode(_ entries: [RecentLUTEntry]) -> [[String: Any]] {
        entries.map { e in
            var d: [String: Any] = [pathKey: e.path]
            if let b = e.bookmark { d[bookmarkKey] = b }
            if let o = e.outputSpace { d[outputKey] = o }
            return d
        }
    }

    /// `entry` at the front; any older entry for the same file removed; at most `capacity` kept.
    public static func inserting(_ entry: RecentLUTEntry, into entries: [RecentLUTEntry]) -> [RecentLUTEntry] {
        let key = standardized(entry.path)
        return Array(([entry] + entries.filter { standardized($0.path) != key }).prefix(capacity))
    }

    /// The same list with the output space of the entry for `path` replaced; unchanged when it is not listed.
    public static func settingOutputSpace(_ outputSpace: String?, forPath path: String,
                                          in entries: [RecentLUTEntry]) -> [RecentLUTEntry] {
        let key = standardized(path)
        return entries.map { e in
            guard standardized(e.path) == key else { return e }
            var copy = e
            copy.outputSpace = outputSpace
            return copy
        }
    }

    /// The entry for `path`, if listed.
    public static func entry(forPath path: String, in entries: [RecentLUTEntry]) -> RecentLUTEntry? {
        let key = standardized(path)
        return entries.first { standardized($0.path) == key }
    }

    static func standardized(_ path: String) -> String { (path as NSString).standardizingPath }
}
