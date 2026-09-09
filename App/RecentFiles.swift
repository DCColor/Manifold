//
//  RecentFiles.swift
//  Manifold
//
//  File ▸ Open Recent. AppKit owns the LIST; SwiftUI owns the MENU. Both halves of that split
//  were measured, and the second half was measured the hard way — see below.
//

import SwiftUI
import AppKit

/// ── WHY NSDOCUMENTCONTROLLER OWNS THE LIST ───────────────────────────────────────────────────
///
/// The hard part of a recents list is not remembering paths, it is FILE IDENTITY — and in post that
/// is the common case rather than the edge: files are renamed on delivery and moved off shuttle
/// drives onto a NAS as a matter of routine. AppKit tracks the file through both. MEASURED
/// 2026-09-09, as four separate processes so nothing could be cached in memory:
///
///   * noted `/…/delivery-A.mov`            → `recentDocumentURLs` = ["…/delivery-A.mov"]
///   * renamed it to `delivery-RENAMED.mov` → ["…/delivery-RENAMED.mov"]      ← followed the rename
///   * moved it into `moved/`               → ["…/moved/delivery-RENAMED.mov"] ← followed the move
///   * read from a FRESH process            → unchanged, so it persists across launches
///
/// It also prunes, caps the list at the user's Recent Items setting, feeds the Dock icon's Recent
/// Documents section, and gives the user one place to clear it.
///
/// ⚠️ AN UNREACHABLE FILE IS SIMPLY NOT LISTED, AND THAT IS APPKIT'S DOING — which is why there is
/// no staleness model anywhere in this file. MEASURED with a real disk image: a file noted on
/// /Volumes/SHUTTLE listed normally; after `hdiutil detach` the same read returned an EMPTY list in
/// 4.7 ms — no mount prompt, no stall — and after re-attaching, the entry was back. A deleted file
/// drops out the same way. The unplugged-shuttle-drive row is absent while the drive is, and
/// returns with it.
///
/// ── ⚠️ WHY THERE IS A PUBLISHED MIRROR AND NOT A DIRECT READ ─────────────────────────────────
///
/// `recentDocumentURLs` is not observable, so it cannot drive a `ForEach`. This is the smallest
/// thing that can: a published copy, refreshed at the two moments it can go stale — when WE add an
/// entry (`note`), and when a menu is about to be shown (`NSMenu.didBeginTrackingNotification`,
/// which covers AppKit pruning an entry behind our back, a volume ejecting, or another window
/// having loaded something). Reading the list was measured at 0.7–18.5 ms, ejected volume included,
/// so doing it on menu-open costs nothing worth managing. Nothing is STORED here.
@MainActor
final class RecentFiles: ObservableObject {

    static let shared = RecentFiles()

    /// AppKit's list, mirrored. Never written to except by `refresh`.
    @Published private(set) var urls: [URL] = []

    private init() {
        refresh()
        // Any menu beginning to track re-reads the list. Cheap (see above), and it is the only
        // hook there is: SwiftUI's `Menu` has no will-open callback, and the facts behind the list
        // change without us — AppKit prunes, volumes come and go, another window loads a file.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { RecentFiles.shared.refresh() }
        }
    }

    /// ── THE RECORD POINT: THE COMMIT EDGE, NOT THE OPEN PANEL ───────────────────────────────
    ///
    /// Called from `ContentView`'s `currentURL` observer, which fires on the one assignment in
    /// `loadAsset`'s PHASE 2 — past the point of no return, where the file has already been vetted.
    /// Phase 1 refuses stills, R3D and anything AVFoundation exposes no video track for, and it
    /// refuses them WITHOUT touching `currentURL`, precisely so a refused file cannot overwrite the
    /// one on screen. Recording here inherits that: a file the app declined to play never reaches
    /// this call. Noting at the open panel would have listed every refusal.
    ///
    /// ⚠️ STREAMS CANNOT ARRIVE HERE AND NEED NO GUARD. NDI, WHEP, SRT and HLS reach the deck
    /// through `LiveSource` / `StreamBookmarkStore`, never through `FrameEngine.load(url:)`, so
    /// `currentURL` is never set for them and this is never called. A `guard url.isFileURL` would
    /// be checking a condition that cannot occur, and would read as though it could.
    static func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        shared.refresh()
    }

    /// AppKit's own clear, so the Dock's Recent Documents section goes with it.
    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refresh()
    }

    /// Re-read AppKit's list. Assigns only on a real change, so a menu opening does not publish an
    /// identical array and rebuild the commands for nothing.
    func refresh() {
        let latest = NSDocumentController.shared.recentDocumentURLs
        guard latest != urls else { return }
        urls = latest
    }
}

/// ── ⚠️ WHY THIS IS A SwiftUI COMMAND AND NOT AN `NSApp.mainMenu` INSERTION ───────────────────
///
/// The first version of this feature inserted an "Open Recent" item into the File menu by hand,
/// because `CommandGroup` has no recent-documents slot and a non-document app is given no such
/// submenu. **That approach cannot be made to work, and the failure is invisible from inside the
/// process.** MEASURED on macOS 26 (Darwin 25.5), in Manifold itself:
///
///   * The insertion succeeded. `NSApp.mainMenu`'s File submenu read
///     `[New Window | Open… | Open Recent | <sep> | <sep> | Close | Close All]`.
///   * Left alone, it stayed that way — re-checked every 5 s, PRESENT through +86 s, same NSMenu
///     object throughout (the menu is never replaced).
///   * **The first time the menu bar was actually displayed, SwiftUI removed our item.** One
///     Accessibility read of the File menu — what a click does — returned the menu already WITHOUT
///     it, and the in-process check 5 s later agreed: `ourItem=MISSING`, same object. Reproduced on
///     three launches.
///
/// So it "worked" in every check that did not involve looking at it. That is the same family as the
/// `CommandGroup(replacing: .singleWindowList)` receipt in `ManifoldApp`, and worse: it fails later
/// and more quietly. SwiftUI reconciles the menus it owns and discards what it did not put there.
///
/// Expressed as a command instead, it is SwiftUI's to keep. MEASURED in a probe of this app's exact
/// shape, read via the Accessibility API — i.e. what is on screen, not what the data structure
/// says: the submenu renders, a runtime insertion into the published list appeared without any
/// interaction, a clear emptied it, and four menu-bar accesses across 28 s removed nothing.
struct OpenRecentMenu: View {

    @ObservedObject var recents: RecentFiles

    var body: some View {
        Menu("Open Recent") {
            if recents.urls.isEmpty {
                // A disabled row rather than an empty submenu, which reads as broken.
                Button("No Recent Files") {}.disabled(true)
            } else {
                ForEach(recents.urls, id: \.self) { url in
                    // ⚠️ THE SAME ROUTING ⌘O USES, AND DELIBERATELY NOT A SECOND POLICY.
                    // `openFromUserAction` is the one place that decides which window a
                    // user-initiated open lands in — an empty window is always re-used, otherwise
                    // the Settings preference chooses this window or a new one — and
                    // `preferring: nil` means "the key window", which is what a menu command acts
                    // on. That is exactly what `File ▸ Open…` passes.
                    //
                    // A file that vanished between the menu being drawn and the row being picked
                    // needs nothing here: `loadAsset`'s phase-1 vet opens the URL, gets no video
                    // track, and calls `rejectLoad`, which raises the banner "This file couldn't be
                    // opened — its video track is unreadable." and logs `[PLAYBACK] no video
                    // track`. Nothing is torn down, so the deck keeps what it had. (That sentence
                    // names a video track, so a file whose drive was just unplugged is described as
                    // unreadable rather than as missing — the correct refusal with an imprecise
                    // reason, and re-wording it belongs at the refusal, not here.)
                    Button(url.lastPathComponent) {
                        DeckRegistry.shared.openFromUserAction(url, preferring: nil)
                    }
                }
            }
            Divider()
            Button("Clear Menu") { recents.clear() }
                .disabled(recents.urls.isEmpty)
        }
    }
}
