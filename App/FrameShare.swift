import AppKit
import SwiftUI
import ShortcutRegistry   // ShortcutRegistry — File ▸ Share Frame…'s item
import FrameShareFormat   // ShareLabel — "Share Frame (SDR)…" for an HDR picture (Robbie, 2026-11-15); ShareFailure (0.9.6)

// Share Frame… (Robbie, 2026-11-15): the frame Export Frame would capture, through the macOS share sheet
// (NSSharingServicePicker): Messages, Mail, AirDrop, Notes, Photos and the rest.
//
// THE FILE (follow-ups, Robbie, 2026-11-15). An 8-bit SDR JPEG, quality 0.9, Rec. 709 primaries, tagged sRGB
// (`ShareJPEG`, FrameShareFormat): the same capture as Export Frame (the picture, not the window's display transform),
// converted by one ColorSync draw, which tone-maps HLG and PQ to SDR. Export Frame still writes the 16-bit PNG. Named as
// Export Frame names its PNG, with `.jpg` (`FrameFileName`: "<clip> <HH-MM-SS-FF>" or "<stream> <date time>"). Written by
// `MetalVideoRenderer.writeFrameForShare` into its own folder under the app's caches folder,
// `~/Library/Caches/<bundle id>/Shared Frames/<uuid>/<name>.jpg`, so two shares cannot collide. The folder is deleted when the share completes, fails or is cancelled. Anything a share target
// never reported back on is swept at the next share, at launch and at quit.
//
// FOCUS. When the sheet closes, sent or cancelled, the player view (`MetalHostView`) is made first responder, so AppKit
// does not hand focus to the first control in the window (the Open button, with its focus ring), Robbie, 2026-11-15.
//
// PRIVACY. Nothing leaves the app but the image itself: no path or name is logged, and the only log line is
// "[SHARE] frame shared", with no target and no file name.
//
// FAILURES (0.9.6 UI polish item 3). A share that could not be prepared, or a service that reported a failure, shows the
// window's frame-save banner (`ShareFailure`) instead of only beeping. A Cancel, in the picker or in a service's own sheet,
// shows nothing.

/// The key deck's picture is PQ or HLG, for File ▸ Share Frame…'s title, which cannot observe a deck from inside a
/// `commands` builder (Robbie, 2026-11-15; `ShareLabel`). Set by `WindowDeck` when the key deck changes or its picture does.
@MainActor
final class SharePictureState: ObservableObject {
    static let shared = SharePictureState()
    @Published var keyPictureIsHDR = false
}

/// File ▸ Share Frame…: "Share Frame (SDR)…" while the key window's picture is PQ or HLG.
struct ShareFrameMenuItem: View {
    @ObservedObject var registry: ShortcutRegistry
    @ObservedObject private var state = SharePictureState.shared
    var body: some View {
        ShortcutMenuItem(id: .shareFrame, registry: registry, title: ShareLabel.title(pictureIsHDR: state.keyPictureIsHDR))
    }
}

/// File ▸ Start DeckLink Output / Stop DeckLink Output: the title says what a click does (docs/BUGS.md, 0.9.6 UI polish item
/// 33; it read "Start/Stop DeckLink Output" in every state). The registry title, which the Keyboard Shortcuts window lists,
/// stays "Start/Stop DeckLink Output" (`MenuKeyAudit.titleVariants`). Lives here beside `ShareFrameMenuItem`, the other File
/// item whose title follows state.
struct DeckLinkMenuItem: View {
    @ObservedObject var registry: ShortcutRegistry
    @ObservedObject private var deckLink = DeckLinkService.shared
    var body: some View {
        ShortcutMenuItem(id: .toggleDeckLink, registry: registry,
                         title: deckLink.isOutputting ? "Stop DeckLink Output" : "Start DeckLink Output")
    }
}

/// The NSViews the share sheet may hang from, in this window: More (…) in Compact and Narrow, where Share Frame… sits under
/// Export Frame, and the Share button beside Export in Full, which has no More. Registered by `ShareAnchorView`; held weakly.
final class ShareAnchor {
    weak var more: NSView?
    weak var shareButton: NSView?

    /// The first of More and the Share button that is on screen in this window, else `fallback`.
    func view(fallback: NSView?) -> NSView? {
        for v in [more, shareButton] {
            if let v, v.window != nil, !v.isHiddenOrHasHiddenAncestor, v.bounds.width > 0 { return v }
        }
        return fallback
    }
}

/// A zero-size NSView behind a control, handed to `register` so the share sheet can be anchored to that control.
struct ShareAnchorView: NSViewRepresentable {
    let register: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        register(v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class FrameSharer: NSObject, @preconcurrency NSSharingServicePickerDelegate, @preconcurrency NSSharingServiceDelegate {
    static let shared = FrameSharer()

    /// One share in flight: its folder, the view keyboard focus returns to when its sheet closes, and its window's banner.
    private struct Pending {
        let folder: URL
        weak var focus: NSView?
        let onFailure: (FrameSaveNotice) -> Void
    }

    /// Each share in flight, first by picker, then by the service chosen from it.
    private var byPicker: [ObjectIdentifier: Pending] = [:]
    private var byService: [ObjectIdentifier: Pending] = [:]
    private var quitObserver: NSObjectProtocol?

    private override init() {
        super.init()
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FrameSharer.shared.sweep(keepingInFlight: false) }
        }
    }

    /// `~/Library/Caches/<bundle id>/Shared Frames`. The app's own caches folder; never the Desktop or the export folder.
    static var root: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Manifold", isDirectory: true)
            .appendingPathComponent("Shared Frames", isDirectory: true)
    }

    /// At launch: whatever a previous run left (a crash, a target that never reported back).
    static func sweepAtLaunch() { shared.sweep(keepingInFlight: true) }

    /// Write the frame with `write` (which returns the file, or nil when there is no frame or the write failed) and open the
    /// share sheet on `anchor`. A share that cannot be prepared, or that its service fails, calls `onFailure` with the
    /// banner's text; a Cancel does not. `focus` (the player view) is made first responder when the sheet closes, sent or
    /// cancelled.
    func share(anchor: NSView, focus: NSView?, onFailure: @escaping (FrameSaveNotice) -> Void, write: (URL) -> URL?) {
        sweep(keepingInFlight: true)
        guard let root = Self.root else { onFailure(ShareFailure.couldNotPrepare); return }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            onFailure(ShareFailure.couldNotPrepare); return
        }
        guard let file = write(folder) else {
            try? FileManager.default.removeItem(at: folder)
            onFailure(ShareFailure.couldNotPrepare); return
        }
        let picker = NSSharingServicePicker(items: [file])
        picker.delegate = self
        byPicker[ObjectIdentifier(picker)] = Pending(folder: folder, focus: focus, onFailure: onFailure)
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .minY : .maxY)
    }

    // MARK: NSSharingServicePickerDelegate

    func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard let pending = byPicker.removeValue(forKey: ObjectIdentifier(picker)) else { return }
        if let service {
            byService[ObjectIdentifier(service)] = pending   // deleted when the service says it is done
        } else {
            remove(pending.folder)                            // cancelled
        }
        // The picker has closed either way. A service's own sheet (Messages, Mail) may take focus next; when it reports
        // back, focus is returned again below.
        returnFocus(to: pending.focus)
    }

    // MARK: NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        print("[SHARE] frame shared")
        finish(sharingService)
    }

    /// Also a cancel from the service's own sheet (Messages' Cancel reports a user-cancelled error), which shows nothing.
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let e = error as NSError
        if !ShareFailure.isCancel(domain: e.domain, code: e.code),
           let pending = byService[ObjectIdentifier(sharingService)] {
            pending.onFailure(ShareFailure.couldNotShare(detail: e.localizedDescription))
        }
        finish(sharingService)
    }

    private func finish(_ service: NSSharingService) {
        guard let pending = byService.removeValue(forKey: ObjectIdentifier(service)) else { return }
        remove(pending.folder)
        returnFocus(to: pending.focus)
    }

    // MARK: Focus

    /// Make `view` first responder on the next turn: AppKit restores its own choice (the window's first key view, the Open
    /// button) as the popover or sheet goes, and this has to land after it.
    private func returnFocus(to view: NSView?) {
        guard let view else { return }
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window, window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }

    // MARK: Cleanup

    private func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Delete every share folder, except (with `keepingInFlight`) the ones a share sheet or service still has.
    private func sweep(keepingInFlight: Bool) {
        guard let root = Self.root,
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let keep = keepingInFlight ? Set((Array(byPicker.values) + Array(byService.values)).map(\.folder.standardizedFileURL))
                                   : []
        for e in entries where !keep.contains(e.standardizedFileURL) { remove(e) }
    }
}
