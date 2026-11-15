import AppKit
import SwiftUI

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

    /// One share in flight: its folder, and the view keyboard focus returns to when its sheet closes.
    private struct Pending {
        let folder: URL
        weak var focus: NSView?
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

    /// Write the frame with `write` (which returns the file, or nil when there is no frame) and open the share sheet on
    /// `anchor`. Beeps when there is nothing to share. `focus` (the player view) is made first responder when the sheet
    /// closes, sent or cancelled.
    func share(anchor: NSView, focus: NSView?, write: (URL) -> URL?) {
        sweep(keepingInFlight: true)
        guard let root = Self.root else { NSSound.beep(); return }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSSound.beep(); return
        }
        guard let file = write(folder) else {
            try? FileManager.default.removeItem(at: folder)
            NSSound.beep(); return
        }
        let picker = NSSharingServicePicker(items: [file])
        picker.delegate = self
        byPicker[ObjectIdentifier(picker)] = Pending(folder: folder, focus: focus)
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

    /// Also a cancel from the service's own sheet (Messages' Cancel reports a user-cancelled error).
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
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
