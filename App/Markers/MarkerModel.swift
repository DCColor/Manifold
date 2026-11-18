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
//  EMBEDDED CHAPTERS (docs/CHAPTER_MARKERS_PLAN.md §4.1, Stage 2, Option A / D-C1): a second, READ-ONLY list beside the
//  markers. Read from the FILE through libav (`ChapterReader`, D-C2) off the main thread on every open, beside the
//  fingerprint and under the same `loadToken`; mapped onto the frame index once the rate and length are known; never
//  written to the store, so they show with Remember markers off too. Their titles are the file's content: logged as
//  counts only (`MarkerLog.chapters`). The layer's rules are `ChapterLayer`'s.
//
//  XMP MARKERS (Stage 3, §12): Premiere's `xmpDM:markers`, Chapter and Comment types only, read by `XMPMarkers` in the
//  same detached task as the libav read, under the same token, and mapped with the chapters onto ONE layer, shown as
//  "File markers". Names, comments and GUIDs are never logged: `MarkerLog.xmp` takes counts.
//
//  ⚠️ THE FRAME A MARKER GOES ON (D2). Playing: the frame the renderer last put on screen (`presentedPTS`), which can
//  trail the playhead by the render queue's depth (WindowDeck.frameName's note). Paused: the playhead, which is that
//  frame, and which is right at once after a step or a seek, before the renderer has drawn.
//

import AppKit
import Combine
import ManifoldCore
import Markers
import ChapterRead
import SMPTETimecode
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
    /// Which colours the list shows. Empty (and no Chapters chip) = all.
    @Published var colorFilter: Set<MarkerColor> = []
    /// The filter row's Chapters chip: with any filter chosen, chapters show only when this is on (§4.1).
    @Published var chapterFilter = false
    /// The file's embedded chapters on the frame index, all of them (converted ones included), in frame order. Empty
    /// until the read and the mapping are both done. Never stored.
    @Published private(set) var chapters: [MappedChapter] = []
    /// Chapters (of the chapter kind) the file states that start after its last frame (dropped, never clamped; §3.1).
    /// For the Inspector.
    @Published private(set) var chaptersPastEnd = 0
    /// The "chapters can't be edited" note, on this marker's player window (`MarkerEditorHost`), for this chapter.
    @Published var chapterNote: MappedChapter?
    /// The one chapter selected in a Markers list (slot or window, whichever changed last), so ⇧M on it shows the note.
    /// Nil when the selection is anything else.
    var selectedChapter: Int?

    /// Thumbnails of the markers' frames (§4.4), for the slot and the Markers window.
    let thumbnails = MarkerThumbnailer()

    private weak var deck: WindowDeck?
    private(set) weak var engine: FrameEngine?
    private var doc: MarkerDocument?
    private var fileURL: URL?
    private var loadToken = UUID()
    private var cancellables: Set<AnyCancellable> = []
    private let store = MarkerStore.standard()
    private var noticeTask: Task<Void, Never>?
    /// The frames and rate the thumbnailer was last given (`ThumbnailFeed`: the rate can land after the markers).
    private var feed = ThumbnailFeed()
    /// The start-timecode check (`checkStartTimecode`) has not run for this load: it needs the rate and timecode.
    private var startCheckPending = false
    /// The chapters as the file states them (nil: not read yet, or unreadable by libav), and how long the read took.
    private var fileChapters: ChapterReader.Result?
    private var chapterReadMs = 0
    /// The file's XMP Chapter and Comment markers (Stage 3), and whether the read (libav and XMP) has finished.
    private var xmpItems: [FileChapter] = []
    private var fileMarkersRead = false
    /// What the current `chapters` were mapped with, so a repeat publish of the metadata maps nothing again.
    private var chapterMapKey: ChapterMapKey?
    /// The "chapters start after the end" notice has been shown for this load.
    private var pastEndNoticeShown = false
    private var chapterRetry: Task<Void, Never>?

    /// This file's markers are read from and written to the store: Remember markers between sessions was on when the
    /// file opened (§5.2). Off, they live in memory for as long as the file is open. Saving also asks the preference
    /// again, so turning it off stops writes at once; turning it on applies to files opened afterwards (an open file's
    /// stored markers were never read, and saving its session markers over them would lose them).
    private(set) var persisting = false

    /// Every window's model, for Delete All Stored Markers….
    private static let all = NSHashTable<MarkerModel>.weakObjects()

    init(deck: WindowDeck) {
        self.deck = deck
        Self.all.add(self)
    }

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
        // the URL (tcInfo is set by then: before the metadata task, or in the same main-actor turn on the libav path).
        engine.$metadata
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.metadataChanged() } }
            .store(in: &cancellables)
        // The file's length, for the chapters' last frame (§3.1: past the end is dropped); it can land after both.
        engine.$duration
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.mapChapters() } }
            .store(in: &cancellables)
    }

    private func fileChanged(_ url: URL?) {
        if let um = deck?.window?.undoManager { um.removeAllActions(withTarget: self) }
        loadToken = UUID()
        doc = nil
        fileURL = url
        feed = ThumbnailFeed()
        startCheckPending = false
        markers = []
        startOverride = nil
        inPoint = nil
        outPoint = nil
        editorMarker = nil
        notice = nil
        chapterNote = nil
        selectedChapter = nil
        chapters = []
        chaptersPastEnd = 0
        fileChapters = nil
        xmpItems = []
        fileMarkersRead = false
        chapterMapKey = nil
        pastEndNoticeShown = false
        chapterRetry?.cancel()
        chapterRetry = nil
        thumbnails.reset(engine: engine, fingerprint: nil)
        guard let url, let engine, engine.mediaKind == .video else { state = .none; return }
        state = .loading
        let token = loadToken
        let store = self.store
        let remember = MarkerSettings.remember()
        persisting = remember
        // The file's chapters, beside the fingerprint (§2.4): a private libav open, read and close, never playback's;
        // then its XMP markers (§12, Stage 3): box headers and the packet only, never the media data.
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let read = try? ChapterReader.read(url: url)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let t1 = Date()
            let xmp = XMPMarkers.read(url: url)
            let xmpMs = Int(Date().timeIntervalSince(t1) * 1000)
            await MainActor.run { [weak self] in
                self?.finishChapterRead(token: token, read: read, ms: ms, xmp: xmp, xmpMs: xmpMs)
            }
        }
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let fp = FileFingerprint.compute(url: url)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            // Not remembering: nothing is read either; the session starts with no markers (§5.2).
            let result: Result<MarkerDocument?, Error>? = fp.map { fp in remember ? Result { try store.load(fingerprint: fp) } : .success(nil) }
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
            if persisting {
                d.lastPath = url.path
                d.bookmark = try? url.bookmarkData()
            }
            doc = d
            markers = d.sorted
            startOverride = d.startOverride
            state = .ready
            thumbnails.reset(engine: engine, fingerprint: fingerprint, persist: persisting)
            feed = ThumbnailFeed()
            syncThumbnails()
            NSLog("%@", MarkerLog.loaded(count: markers.count, fingerprintMs: ms))
            startCheckPending = true
            checkStartTimecode()
        }
    }

    /// The engine's metadata changed. The list relabels; and the file's rate may have just landed, after the markers
    /// loaded (`ThumbnailFeed`'s note): the thumbnailer and the start-timecode check get it now. A repeat changes nothing.
    private func metadataChanged() {
        objectWillChange.send()
        mapChapters()
        guard state == .ready else { return }
        syncThumbnails(ifChanged: true)
        checkStartTimecode()
    }

    /// "This file's start timecode now reads …": once per load, as soon as the rate and timecode are known. The first
    /// build ran it only when the markers loaded, so a file whose metadata landed later was never checked.
    private func checkStartTimecode() {
        guard startCheckPending, let basis, let d = doc else { return }
        startCheckPending = false
        if let seen = d.startTimecodeSeen, basis.hasTimecode, seen != basis.label(0), !markers.isEmpty {
            show("This file’s start timecode now reads \(basis.label(0)); its markers were made at \(seen). They stay on the same frames.")
        }
    }

    // MARK: Chapters (docs/CHAPTER_MARKERS_PLAN.md §4.1)

    private struct ChapterMapKey: Equatable {
        let rate: Double
        let lastFrame: Int
        let origin: ChapterTime
    }

    private func finishChapterRead(token: UUID, read: ChapterReader.Result?, ms: Int, xmp: XMPMarkers.Result, xmpMs: Int) {
        guard token == loadToken else { return }
        if read == nil { NSLog("%@", MarkerLog.chaptersUnreadable()) }
        // One counts-only line whenever the file has XMP or its boxes could not be walked; nothing for a file without.
        if xmp.status != .none { NSLog("%@", MarkerLog.xmp(xmp, readMs: xmpMs)) }
        fileChapters = read
        chapterReadMs = ms + xmpMs
        xmpItems = xmp.items
        fileMarkersRead = true
        mapChapters()
    }

    /// Places the file's chapters on the frame index once the rate and the length are known (they can land after the
    /// read), and again whenever either changes. The origin follows the PLAYBACK PATH (D-C10, §11.4): a libav-played
    /// file's frame 0 is its first video frame, so the video stream's `start_time` comes off; an AVFoundation-played
    /// file's frame 0 is the asset's time 0, so nothing does. With `start_time` 0, as on every real file seen, the two
    /// agree and the path is not needed.
    /// XMP items take no origin (they count from the first frame, §12.6); `ChapterMapping.map` knows.
    private func mapChapters() {
        guard fileMarkersRead, let engine, let basis, engine.duration > 0 else { return }
        let videoStart = fileChapters?.videoStart ?? .zero
        let items = (fileChapters?.chapters ?? []) + xmpItems
        let origin: ChapterTime
        if videoStart.value == 0 {
            origin = .zero
        } else if let libav = engine.frameRouteUsesLibav {
            origin = libav ? videoStart : .zero
        } else {
            retryChapterMapping()   // the route is set later in the same load
            return
        }
        let key = ChapterMapKey(rate: basis.rate, lastFrame: lastFrame, origin: origin)
        guard key != chapterMapKey else { return }
        chapterMapKey = key
        let r = ChapterMapping.map(items, origin: origin, rate: basis.rate, lastFrame: lastFrame)
        chapters = r.chapters
        chaptersPastEnd = r.chaptersPastEnd
        if !items.isEmpty { NSLog("%@", MarkerLog.chapters(r, readMs: chapterReadMs)) }
        if r.droppedPastEnd > 0, !pastEndNoticeShown {
            pastEndNoticeShown = true
            let n = r.droppedPastEnd
            show(n == 1 ? "1 file marker starts after the end of the file." : "\(n) file markers start after the end of the file.")
        }
        if state == .ready { syncThumbnails(ifChanged: true) }
    }

    /// The playback route is not known yet (only matters for a file whose video starts after 0): ask again shortly,
    /// for at most five seconds, under this load's token.
    private func retryChapterMapping() {
        guard chapterRetry == nil else { return }
        let token = loadToken
        chapterRetry = Task { [weak self] in
            for _ in 0..<25 {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.loadToken == token else { return }
                if self.engine?.frameRouteUsesLibav != nil {
                    self.chapterRetry = nil
                    self.mapChapters()
                    return
                }
            }
            self?.chapterRetry = nil
        }
    }

    /// The filter as `ChapterLayer` takes it.
    var filter: MarkerFilter { MarkerFilter(colors: colorFilter, chapters: chapterFilter) }

    /// Chapters not shown as a marker of their own yet (§3.3, D-C14).
    var unconvertedChapters: [MappedChapter] { ChapterMapping.unconverted(chapters, markers: markers) }

    /// The chapters the lists and the strip show: unconverted, View ▸ Show Chapters on, through the filter. (View ▸ Show
    /// Markers is the views' check, as for markers.)
    var visibleChapters: [MappedChapter] {
        ChapterLayer.visibleChapters(chapters, markers: markers, filter: filter, showChapters: MarkerSettings.showChapters())
    }

    /// Markers and visible chapters interleaved by frame, for the lists.
    var listRows: [MarkerListRow] { ChapterLayer.rows(markers: visibleMarkers, chapters: visibleChapters) }

    /// The Inspector's Chapters row: file markers of the chapter kind (de-duplicated), not Comments.
    var chapterCount: Int { chapters.filter { $0.kind == .chapter }.count }

    /// "12 markers · 8 from file" (the Markers window's header).
    var countLabel: String {
        ChapterLayer.countLabel(markersShown: visibleMarkers.count, markersTotal: markers.count,
                                chaptersShown: visibleChapters.count,
                                chaptersTotal: MarkerSettings.showChapters() ? unconvertedChapters.count : 0)
    }

    func go(to chapter: MappedChapter) { go(toFrame: chapter.frame) }

    /// Convert to Marker (a row or the selection) and Convert All File Markers to Markers: the item's color through the
    /// D-C13 table (`ChapterMapping.convert`), its kind's keyword, its comment as notes, an XMP item's stated duration
    /// else one frame (D-C8 revised), D-C14 stable ids skipped, through the import merge rule. One undo step.
    func convert(_ items: [MappedChapter]) {
        guard isActive, state == .ready, !items.isEmpty else { NSSound.beep(); return }
        let r = ChapterMapping.convert(items, into: markers)
        if !r.added.isEmpty {
            revealMarkers()
            apply(markers + r.added, action: items.count == 1 ? "Convert File Marker to Marker" : "Convert File Markers to Markers",
                  log: .convert)
        }
        NSLog("%@", MarkerLog.convertedChapters(r))
        show(ChapterLayer.convertNotice(r))
    }

    /// Mark ▸ Convert All File Markers to Markers: every file marker not converted yet, shown or not.
    func convertAllChapters() { convert(unconvertedChapters) }

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

    /// The media as Premiere Pro XML describes it (docs/MARKER_EXPORT_PLAN.md §5): its URL (written into the exported
    /// file, nowhere else), frame count, picture size and audio, all from the player's own reading. Audio channels are
    /// summed across the file's audio tracks; the rate and depth are the first track's. Nil with no file.
    var premiereMedia: PremiereXML.Media? {
        guard let fileURL, let engine, let md = engine.metadata else { return nil }
        let tracks = md.audioTracks
        return PremiereXML.Media(url: fileURL, frameCount: lastFrame + 1, width: md.width, height: md.height,
                                 audioChannels: tracks.reduce(0) { $0 + max($1.channelCount, 0) },
                                 audioSampleRate: Int((tracks.first?.sampleRate ?? 0).rounded()),
                                 audioBitDepth: tracks.first?.bitDepth ?? 16)
    }

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

    var visibleMarkers: [Marker] { ChapterLayer.visibleMarkers(markers, filter: filter) }

    // MARK: Adding

    /// M and ⌥M. On the frame on screen; with In and Out set, one marker from In to Out, and the marks are cleared (D4).
    /// ONE MARKER PER FRAME: if a marker already starts on that frame (the In frame, for a span), its editor opens instead
    /// and nothing is added, whichever of M, ⌥M or the menu asked (`MarkerRules`). The In and Out are kept in that case,
    /// for the editor's Set from In and Out.
    ///
    /// ⚠️ THE FIRST BUILD CHECKED THIS ON PLAIN M ONLY. ⌥M made a draft at the keypress and inserted it on Done without
    /// asking, which is how the first attended run got two markers on 01:00:01:19 and on 01:00:04:03 (2026-11-15, the
    /// store's `created` times against the log's `add` lines: §12).
    func addMarker(edit: Bool) {
        guard isActive, let frame = markFrame else { NSSound.beep(); return }
        let span: (Int, Int)? = { if let i = inPoint, let o = outPoint, o >= i { return (i, o) } else { return nil } }()
        let start = span?.0 ?? frame
        if let existing = MarkerRules.occupant(of: start, in: markers) {
            openEditor(existing)
            return
        }
        let draft = span.map { Marker(frame: $0.0, duration: $0.1 - $0.0 + 1) } ?? Marker(frame: frame)
        if span != nil {
            inPoint = nil
            outPoint = nil
        }
        revealMarkers()
        if edit {
            editorIsNew = true
            editorMarker = draft
        } else {
            apply(markers + [draft], action: "Add Marker", log: .add)
        }
    }

    /// Adding a marker while View ▸ Show Markers is off turns it back on (Robbie, 2026-11-15): a marker you just made is
    /// never invisible.
    private func revealMarkers() {
        if !MarkerSettings.show() { UserDefaults.standard.set(true, forKey: MarkerSettings.showKey) }
    }

    /// Mark ▸ Edit Marker… (⇧M): the marker starting at the playhead, else the nearest one starting before it.
    func editMarkerAtPlayhead() {
        // A chapter selected in a list: it can't be edited, so say so (and offer Convert) rather than opening a marker.
        if isActive, let i = selectedChapter, let c = visibleChapters.first(where: { $0.fileIndex == i }) {
            showChapterNote(c)
            return
        }
        guard isActive, let f = engine?.currentFrame, let m = MarkerRules.markerToEdit(at: f, in: markers) else {
            NSSound.beep(); return
        }
        openEditor(m)
    }

    /// Edit on a chapter (double-click after the jump, ⇧M with it selected, the row menu's Edit…): the read-only note,
    /// on the player window, brought forward from the Markers window as the editor is.
    func showChapterNote(_ chapter: MappedChapter) {
        chapterNote = chapter
        if let w = deck?.window, !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
    }

    /// The note's Convert: that chapter alone, one undo step.
    func convertFromNote() {
        guard let c = chapterNote else { return }
        chapterNote = nil
        convert([c])
    }

    // MARK: Editing

    /// The editor is a sheet on this marker's PLAYER window; from the Markers window that window is brought forward so
    /// the sheet is seen.
    func openEditor(_ marker: Marker) {
        editorIsNew = false
        editorMarker = marker
        if let w = deck?.window, !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
    }

    /// The sheet's Save. Returns why it cannot be saved (another marker starts on that frame), or nil when saved.
    @discardableResult
    func commitEditor(_ edited: Marker) -> String? {
        if let other = MarkerRules.occupant(of: edited.frame, in: markers, excluding: edited.id) {
            let at = basis?.label(other.frame) ?? "that frame"
            return "A marker is already at \(at). One marker per frame."
        }
        var m = edited
        m.modified = Date()
        if editorIsNew {
            apply(markers + [m], action: "Add Marker", log: .add)
        } else if markers.contains(where: { $0.id == m.id }) {
            apply(markers.map { $0.id == m.id ? m : $0 }, action: "Edit Marker", log: .edit)
        }
        editorMarker = nil
        editorIsNew = false
        return nil
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
    func go(to marker: Marker) { go(toFrame: marker.frame) }

    func go(toFrame frame: Int) {
        guard let deck, deck.transportKeys?.canMovePlayhead == true else { NSSound.beep(); return }
        deck.transportKeys?.seek(toFrame: frame)
    }

    /// ⇧↑/⇧↓: the visible markers' and visible chapters' frames together, each once (D-C6).
    func goToNeighbour(forward: Bool) {
        guard isActive, let f = engine?.currentFrame else { NSSound.beep(); return }
        let stops = ChapterLayer.navigationFrames(visibleMarkers: visibleMarkers, visibleChapters: visibleChapters)
        guard let target = ChapterMapping.neighbour(of: f, forward: forward, in: stops) else { NSSound.beep(); return }
        go(toFrame: target)
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
            // Typed as timecode entry is: "1000000" is 01:00:00:00, a pasted label works too.
            guard let t = TypedTimecode(trimmed), !t.isRelative,
                  let count = t.labelFrameCount(nfr: b.nfr, fps: b.rate, dropFrame: false) else { return false }
            new = TimecodeBasis(startFrame: count, nfr: b.nfr, rate: b.rate, dropFrame: false, hasTimecode: false).label(0)
        }
        startOverride = new
        doc?.startOverride = new
        save()
        NSLog("%@", MarkerLog.changed(count: markers.count, action: .startOverride))
        return true
    }

    // MARK: Import (called by MarkerFileIO)

    func importMarkers(_ incoming: [Marker]) -> ResolveEDL.MergeResult {
        let r = ResolveEDL.merge(incoming, into: markers)
        if !r.added.isEmpty {
            revealMarkers()
            apply(markers + r.added, action: "Import Markers", log: .add)
        }
        return r
    }

    // MARK: Thumbnails, panels, delete all

    /// Regenerate Thumbnails (gear, toolbar: nil = every marker) or Regenerate Thumbnail (row menu).
    func regenerateThumbnails(_ ids: Set<UUID>? = nil) {
        regenerateThumbnails(frames: ids.map { ids in Set(markers.filter { ids.contains($0.id) }.map(\.frame)) })
    }

    /// These frames' thumbnails (a chapter row's Regenerate Thumbnail), or every one when nil.
    func regenerateThumbnails(frames: Set<Int>?) {
        if state == .ready { syncThumbnails(ifChanged: true) }   // with the current rate (`ThumbnailFeed`'s note)
        let n = thumbnails.regenerate(frames)
        NSLog("%@", MarkerLog.regenerate(thumbnails: n))
    }

    func presentImport() { MarkerFileIO.importEDL(into: self, window: deck?.window) }
    func presentExport() { MarkerFileIO.export(from: self, window: deck?.window) }

    /// Settings ▸ Delete All Stored Markers…: every stored document and every cached thumbnail, and the markers on screen
    /// in every window, which are the same markers. No undo (the confirmation says so).
    static func deleteAllStored() {
        let n = MarkerStore.standard().deleteAll()
        MarkerThumbnailCache.standard().deleteAll()
        for model in all.allObjects { model.clearAfterDeleteAll() }
        NSLog("%@", MarkerLog.deletedAllStored(documents: n))
    }

    private func clearAfterDeleteAll() {
        if let um = deck?.window?.undoManager { um.removeAllActions(withTarget: self) }
        markers = []
        startOverride = nil
        doc?.markers = []
        doc?.startOverride = nil
        editorMarker = nil
        syncThumbnails()
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
        syncThumbnails()
        NSLog("%@", MarkerLog.changed(count: markers.count, action: log))
    }

    /// The thumbnailer gets the markers' AND the chapters' frames (§4.1: the union, so deleting a marker never deletes a
    /// chapter's thumbnail on the same frame) and the file's current rate. Always after a load or a change (as before);
    /// `ifChanged` (metadata, Regenerate, chapters mapped) only when the frames or the rate differ from what it was last
    /// given.
    private func syncThumbnails(ifChanged: Bool = false) {
        let changed = feed.update(frames: ChapterLayer.thumbnailFrames(markers: markers, chapters: chapters), rate: basis?.rate)
        guard changed || !ifChanged else { return }
        thumbnails.sync(frames: feed.frames, rate: feed.rate)
    }

    private func save() {
        guard state == .ready, var d = doc else { return }
        // Remember markers between sessions (§5.2): off when the file opened, or turned off since — nothing is written.
        guard persisting, MarkerSettings.remember() else { doc?.markers = markers; doc?.startOverride = startOverride; return }
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
