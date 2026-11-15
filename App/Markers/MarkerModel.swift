//
//  MarkerModel.swift — one window's markers on its file (docs/MARKERS_PLAN.md). Files only in v1.
//
//  OWNED BY THE DECK, per window, like `FileColorOverrideModel`: each window's file has its own markers, its own In and
//  Out, its own undo. Stored per FILE, by content fingerprint, in Application Support (`MarkerStore`, §5), so the same
//  file opened in two windows, or reopened after a rename or a move, finds the same markers.
//
//  ⚠️ PRIVACY (§5.1). Names, notes and keywords are the user's content: this file logs ONLY through `MarkerLog`, whose
//  functions take numbers. Never `NSLog` a marker, a file name or a path here.
//
//  ⚠️ THE FRAME A MARKER GOES ON (D2). Playing: the frame the renderer last put on screen (`presentedPTS`), which can
//  trail the playhead by the render queue's depth (WindowDeck.frameName's note). Paused: the playhead, which is that
//  frame, and which is right at once after a step or a seek, before the renderer has drawn.
//

import AppKit
import Combine
import ManifoldCore
import Markers
import UniformTypeIdentifiers

@MainActor
final class MarkerModel: ObservableObject {

    enum State: Equatable {
        /// No file, or a file markers do not apply to (a still, audio only; D16).
        case none
        /// Fingerprinting and reading the store.
        case loading
        case ready
        /// The stored markers could not be read: shown, and nothing is saved over them.
        case unavailable(String)
    }

    @Published private(set) var state: State = .none
    /// In time order.
    @Published private(set) var markers: [Marker] = []
    /// D6: the start timecode for a file without one.
    @Published private(set) var startOverride: String?
    @Published private(set) var inPoint: Int?
    @Published private(set) var outPoint: Int?
    /// The editor sheet's marker. `editorIsNew`: Save inserts it, Cancel discards it.
    @Published var editorMarker: Marker?
    @Published private(set) var editorIsNew = false
    /// A short line after an export or import, shown in the Markers slot. Counts and words only.
    @Published var notice: String?
    /// Which colours the list shows. Empty = all.
    @Published var colorFilter: Set<MarkerColor> = []

    private weak var deck: WindowDeck?
    private weak var engine: FrameEngine?
    private var doc: MarkerDocument?
    private var fileURL: URL?
    private var loadToken = UUID()
    private var cancellables: Set<AnyCancellable> = []
    private let store = MarkerStore.standard()
    private var noticeTask: Task<Void, Never>?

    init(deck: WindowDeck) { self.deck = deck }

    // MARK: Wiring

    /// From `DeckRegistry.configure`, once per engine. A file change (or unload) reloads.
    func observe(_ engine: FrameEngine) {
        self.engine = engine
        cancellables = []
        engine.$currentURL
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in MainActor.assumeIsolated { self?.fileChanged(url) } }
            .store(in: &cancellables)
        // A stored override, or the "timecode reads differently" check, needs the rate and timecode, which land after
        // the URL; re-publish so the list relabels.
        engine.$metadata
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
            .store(in: &cancellables)
    }

    private func fileChanged(_ url: URL?) {
        if let um = deck?.window?.undoManager { um.removeAllActions(withTarget: self) }
        loadToken = UUID()
        doc = nil
        fileURL = url
        markers = []
        startOverride = nil
        inPoint = nil
        outPoint = nil
        editorMarker = nil
        notice = nil
        guard let url, let engine, engine.mediaKind == .video else { state = .none; return }
        state = .loading
        let token = loadToken
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let fp = FileFingerprint.compute(url: url)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let result: Result<MarkerDocument?, Error>? = fp.map { fp in Result { try store.load(fingerprint: fp) } }
            await MainActor.run { [weak self] in
                self?.finishLoad(token: token, url: url, fingerprint: fp, result: result, ms: ms)
            }
        }
    }

    private func finishLoad(token: UUID, url: URL, fingerprint: String?, result: Result<MarkerDocument?, Error>?, ms: Int) {
        guard token == loadToken else { return }
        guard let fingerprint, let result else {
            state = .unavailable("This file could not be read for markers.")
            NSLog("%@", MarkerLog.unavailable(reason: .unreadable))
            return
        }
        switch result {
        case .failure:
            state = .unavailable("This file’s saved markers could not be read. They are left as they are.")
            NSLog("%@", MarkerLog.unavailable(reason: .storeUnreadable))
        case .success(let stored):
            var d = stored ?? MarkerDocument(fingerprint: fingerprint)
            d.lastPath = url.path
            d.bookmark = try? url.bookmarkData()
            doc = d
            markers = d.sorted
            startOverride = d.startOverride
            state = .ready
            NSLog("%@", MarkerLog.loaded(count: markers.count, fingerprintMs: ms))
            if let seen = d.startTimecodeSeen, let basis, basis.hasTimecode, seen != basis.label(0), !markers.isEmpty {
                show("This file’s start timecode now reads \(basis.label(0)); its markers were made at \(seen). They stay on the same frames.")
            }
        }
    }

    // MARK: What the window is showing

    /// Markers apply: a video file is loaded, its markers are read, and no live source owns the window.
    var isActive: Bool {
        guard state == .ready, let deck, let engine, engine.currentURL != nil, engine.mediaKind == .video else { return false }
        return DeckRegistry.shared.liveSource(for: deck) == nil && basis != nil
    }

    /// The labels this file's frames get: its own timecode, else 00:00:00:00 or the override (§2, D6). The rate rule is
    /// `TimecodeContext`'s (metadata first, the timecode track's own as the fallback), and the timecode's integer rate
    /// is the readout's (`FrameEngine.currentSourceTimecode`).
    var basis: TimecodeBasis? {
        guard let engine, engine.mediaKind == .video else { return nil }
        let declared = engine.metadata?.frameRate ?? 0
        let tc = engine.tcInfo
        let rate = declared > 0 ? declared : (tc?.fps ?? 0)
        guard rate > 0 else { return nil }
        return TimecodeBasis.forFile(rate: rate, timecodeStartFrame: tc?.startFrame, timecodeNFR: tc?.nfr,
                                     dropFrame: tc?.dropFrame ?? false, overrideLabel: startOverride)
    }

    var lastFrame: Int { engine?.totalFrames ?? 0 }

    var fileName: String { fileURL?.lastPathComponent ?? "" }
    var clipName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Markers" }

    /// The frame a marker made now goes on (D2; see the header).
    var markFrame: Int? {
        guard let engine, let rate = basis?.rate else { return nil }
        var frame = engine.currentFrame
        if engine.isPlaying, let pts = deck?.renderer?.presentedPTS, pts.isFinite {
            frame = Int((pts * rate).rounded())
        }
        return min(max(frame, 0), lastFrame)
    }

    /// The marker whose span holds the playhead, latest start first.
    var markerAtPlayhead: Marker? {
        guard let f = engine?.currentFrame else { return nil }
        return markers.last { $0.frame <= f && f <= $0.lastFrame }
    }

    var visibleMarkers: [Marker] {
        colorFilter.isEmpty ? markers : markers.filter { colorFilter.contains($0.color) }
    }

    // MARK: Adding

    /// M. On the frame on screen. With In and Out set, one marker from In to Out, and the marks are cleared (D4). M on
    /// a frame where a marker already starts opens that marker instead of stacking a second one.
    func addMarker(edit: Bool) {
        guard isActive, let frame = markFrame else { NSSound.beep(); return }
        var draft: Marker
        if let i = inPoint, let o = outPoint, o >= i {
            draft = Marker(frame: i, duration: o - i + 1)
            inPoint = nil
            outPoint = nil
        } else {
            if !edit, let existing = markers.first(where: { $0.frame == frame }) {
                openEditor(existing)
                return
            }
            draft = Marker(frame: frame)
        }
        if edit {
            editorIsNew = true
            editorMarker = draft
        } else {
            apply(markers + [draft], action: "Add Marker", log: .add)
        }
    }

    // MARK: Editing

    func openEditor(_ marker: Marker) {
        editorIsNew = false
        editorMarker = marker
    }

    /// The sheet's Save.
    func commitEditor(_ edited: Marker) {
        var m = edited
        m.modified = Date()
        if editorIsNew {
            apply(markers + [m], action: "Add Marker", log: .add)
        } else if markers.contains(where: { $0.id == m.id }) {
            apply(markers.map { $0.id == m.id ? m : $0 }, action: "Edit Marker", log: .edit)
        }
        editorMarker = nil
        editorIsNew = false
    }

    func cancelEditor() {
        editorMarker = nil
        editorIsNew = false
    }

    func setColor(_ color: MarkerColor, for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        apply(markers.map { ids.contains($0.id) ? { var m = $0; m.color = color; m.modified = Date(); return m }($0) : $0 },
              action: "Change Marker Color", log: .edit)
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty, markers.contains(where: { ids.contains($0.id) }) else { return }
        apply(markers.filter { !ids.contains($0.id) }, action: ids.count == 1 ? "Delete Marker" : "Delete Markers", log: .delete)
    }

    /// Mark ▸ Delete Marker: the one at the playhead.
    func deleteAtPlayhead() {
        guard isActive, let m = markerAtPlayhead else { NSSound.beep(); return }
        delete([m.id])
    }

    // MARK: In and Out (D4)

    func markIn() {
        guard isActive, let f = markFrame else { NSSound.beep(); return }
        inPoint = f
        if let o = outPoint, o < f { outPoint = nil }
    }

    func markOut() {
        guard isActive, let f = markFrame else { NSSound.beep(); return }
        outPoint = f
        if let i = inPoint, i > f { inPoint = nil }
    }

    func clearInOut() {
        inPoint = nil
        outPoint = nil
    }

    // MARK: Moving

    /// Double-click in the list, a flag on the timeline, ⇧↑/⇧↓. The quarter-frame landing every typed seek uses
    /// (`TransportKeyMonitor.commit`).
    func go(to marker: Marker) {
        guard let deck, deck.transportKeys?.canMovePlayhead == true else { NSSound.beep(); return }
        deck.transportKeys?.seek(toFrame: marker.frame)
    }

    func goToNeighbour(forward: Bool) {
        guard isActive, let f = engine?.currentFrame else { NSSound.beep(); return }
        let target = forward ? visibleMarkers.first { $0.frame > f } : visibleMarkers.last { $0.frame < f }
        guard let target else { NSSound.beep(); return }
        go(to: target)
    }

    // MARK: Start timecode override (D6)

    /// Only for a file without timecode. Nil or "" returns to 00:00:00:00.
    @discardableResult
    func setStartOverride(_ label: String?) -> Bool {
        guard let b = basis, !b.hasTimecode else { return false }
        let trimmed = label?.trimmingCharacters(in: .whitespaces) ?? ""
        let new: String?
        if trimmed.isEmpty || trimmed == "00:00:00:00" {
            new = nil
        } else {
            guard let count = SMPTEValidation.nonDropCount(trimmed, nfr: b.nfr, rate: b.rate) else { return false }
            new = TimecodeBasis(startFrame: count, nfr: b.nfr, rate: b.rate, dropFrame: false, hasTimecode: false).label(0)
        }
        startOverride = new
        doc?.startOverride = new
        save()
        NSLog("%@", MarkerLog.changed(count: markers.count, action: .startOverride))
        return true
    }

    // MARK: Import (called by MarkerFileIO)

    func importMarkers(_ incoming: [Marker]) -> (added: Int, duplicates: Int) {
        let r = ResolveEDL.merge(incoming, into: markers)
        if !r.added.isEmpty { apply(markers + r.added, action: "Import Markers", log: .add) }
        return (r.added.count, r.duplicates)
    }

    // MARK: Changes, undo and save

    /// Every change goes through here: one undo step, then saved.
    private func apply(_ new: [Marker], action: String, log: MarkerLog.Action) {
        let old = markers
        markers = new.sorted { ($0.frame, $0.created) < ($1.frame, $1.created) }
        if let um = deck?.window?.undoManager {
            um.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.apply(old, action: action, log: .undo) }
            }
            um.setActionName(action)
        }
        save()
        NSLog("%@", MarkerLog.changed(count: markers.count, action: log))
    }

    private func save() {
        guard state == .ready, var d = doc else { return }
        d.markers = markers
        d.startOverride = startOverride
        if let b = basis, b.hasTimecode { d.startTimecodeSeen = b.label(0) }
        doc = d
        do { try store.save(d) } catch {
            NSLog("%@", MarkerLog.unavailable(reason: .saveFailed))
            show("Markers could not be saved.")
        }
    }

    func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

/// Typed start timecodes for the override: non-drop, any punctuation.
enum SMPTEValidation {
    static func nonDropCount(_ label: String, nfr: Int, rate: Double) -> Int? {
        TimecodeBasis(startFrame: 0, nfr: nfr, rate: rate, dropFrame: false, hasTimecode: false).frame(label: label)
    }
}
