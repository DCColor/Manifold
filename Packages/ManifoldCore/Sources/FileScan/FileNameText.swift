//
//  FileNameText.swift
//  FileScan — a file name as on-screen text that wraps without a hyphen (docs/BUGS.md, 0.9.6 UI polish, batch 4 item 1).
//
//  SwiftUI's `Text` hyphenates a word it has to break, and a file name is one long "word" to it: the Inspector showed
//  "Stereo_Textless" as "Stere-o_Textless", a name the file does not have. SwiftUI has no switch for hyphenation (the
//  macOS 27 SDK has none), so the name is given a line-break opportunity between every character instead: a zero-width
//  space (U+200B), which draws nothing. No run is then long enough to hyphenate, and a long name wraps at the character
//  where the line ends, as Terminal wraps it.
//
//  Use it only where a name is meant to wrap (the Inspector's File Name row, a name inside a sentence). Where a name is on
//  one line, truncate it in the middle instead (`lineLimit(1)` + `truncationMode(.middle)`), which never breaks it.
//
//  ⚠️ FOR DISPLAY ONLY. The result is not the file's name: never compare it, log it, write it to disk or put it on a
//  pasteboard. Give the view an accessibility label with the plain name, so VoiceOver reads the name and not the joins.
//

public enum FileNameText {

    /// U+200B ZERO WIDTH SPACE: a line-break opportunity that draws nothing.
    public static let breakOpportunity: Character = "\u{200B}"

    /// `name` with a break opportunity between every two characters (grapheme clusters, so an accented letter or an emoji
    /// is never split). Empty and one-character names come back unchanged.
    public static func wrappable(_ name: String) -> String {
        guard name.count > 1 else { return name }
        var out = ""
        out.reserveCapacity(name.utf8.count * 2)
        for (i, c) in name.enumerated() {
            if i > 0 { out.append(breakOpportunity) }
            out.append(c)
        }
        return out
    }

    /// The plain name back from `wrappable`'s output.
    public static func plain(_ shown: String) -> String {
        shown.filter { $0 != breakOpportunity }
    }
}
