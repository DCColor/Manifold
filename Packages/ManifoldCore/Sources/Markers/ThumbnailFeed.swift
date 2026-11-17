//
//  ThumbnailFeed.swift — what the marker thumbnailer works from, and which frame it starts next (docs/MARKERS_PLAN.md
//  §4.4; docs/BUGS.md "Stored markers get no thumbnails when they load before the file's rate", 2026-11-15).
//
//  ⚠️ THE RATE CAN LAND AFTER THE MARKERS. Opening a file starts two tasks: the markers' fingerprint and store read
//  (`MarkerModel.fileChanged`), and the engine's metadata read (`FrameEngine`, `MediaInspector.metadata`), which carries
//  the frame rate. The fingerprint reads at most 8 MB, so on a large file it usually wins. The first build handed the
//  thumbnailer the rate once, when the markers loaded: 0 if the metadata was not in yet. With rate 0 nothing is ever
//  started, Regenerate included (it removed the cached thumbnails and made none), until a marker changed. Found by the
//  0.9.4 soak's setup on `4067abb`: all three soak files, with markers stored, made no thumbnail in 60 s.
//  Now the model reports every change it sees (markers loaded or changed, the metadata landed, Regenerate) to a
//  `ThumbnailFeed`, which says when the thumbnailer must be told.
//

import Foundation

/// The marker frames and the file's frame rate the thumbnailer is working from.
public struct ThumbnailFeed: Equatable, Sendable {
    public private(set) var frames: Set<Int> = []
    /// 0 while the file's rate is not known.
    public private(set) var rate: Double = 0

    public init() {}

    /// The model's current frames and rate (nil, 0 or not finite: not known yet). True when either changed, so the
    /// thumbnailer must be synced; false for a repeat (the metadata is republished on every inspector refresh).
    @discardableResult
    public mutating func update(frames: Set<Int>, rate: Double?) -> Bool {
        let r = rate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        guard frames != self.frames || r != self.rate else { return false }
        self.frames = frames
        self.rate = r
        return true
    }
}

/// Which marker thumbnail to start next.
///
/// ⚠️ THE DECODER'S ROUTE CAN LAND AFTER THE FRAMES (Stage 2 attended check, 2026-11-17). A file's chapters are read in
/// a few ms and need no store read, so on a FIRST open with no markers stored they reach the thumbnailer before the
/// engine has decided how the file is decoded (`FrameEngine.frameRouteUsesLibav`, set by `installScrubProducer` later in
/// the same load). The first build started a frame anyway; `decode` found no route, dropped it and never asked again,
/// so `premiere_chapters - prores.mov`'s chapter rows stayed blank until Regenerate. Now nothing starts until the route
/// is known (`decoderReady`); `waitingForDecoder` says work is held back for it, and `DecoderWait` starts that work when
/// the engine reports the route decided for THIS file (`FrameEngine.frameRouteDecided`), with no timer.
public enum ThumbnailQueue {
    /// The lowest wanted frame with no thumbnail that has not given up, or nil: nothing starts while one is in flight,
    /// while no view shows thumbnails, while the file plays (NEVER BLOCKS PLAYBACK, `MarkerThumbnailer`), before the
    /// file's rate is known, or before its decoder route is.
    public static func next(wanted: Set<Int>, made: Set<Int>, givenUp: Set<Int>, rate: Double, inFlight: Int?,
                            shown: Bool, playing: Bool, decoderReady: Bool = true) -> Int? {
        guard shown, inFlight == nil, rate > 0, rate.isFinite, !playing, decoderReady else { return nil }
        return wanted.subtracting(made).subtracting(givenUp).min()
    }

    /// A frame would start now but for the decoder route: the thumbnailer must ask again once the route is known
    /// (`DecoderWait`).
    public static func waitingForDecoder(wanted: Set<Int>, made: Set<Int>, givenUp: Set<Int>, rate: Double, inFlight: Int?,
                                         shown: Bool, playing: Bool, decoderReady: Bool) -> Bool {
        !decoderReady && next(wanted: wanted, made: made, givenUp: givenUp, rate: rate, inFlight: inFlight, shown: shown,
                              playing: playing, decoderReady: true) != nil
    }
}

/// Work held back for the decoder route, and the file it is for (§14.6). The thumbnailer resets it with each file (and
/// rebuilds its subscription with a new token), marks it when `ThumbnailQueue.waitingForDecoder` says so, and asks
/// `decided` on each `FrameEngine.frameRouteDecided` event: only an event for its own file, while something waits, starts
/// the work. Another file's event (a stale load's, or another window's engine) does nothing.
public struct DecoderWait: Equatable, Sendable {
    public private(set) var file: URL?
    public private(set) var waiting = false

    public init(file: URL? = nil) { self.file = file }

    /// A new file (or none): nothing waits.
    public mutating func reset(file: URL?) {
        self.file = file
        waiting = false
    }

    /// Work is held back until the route is known.
    public mutating func wait() { waiting = true }

    /// The engine decided the route for `url`. True: start the held-back work now (and stop waiting).
    public mutating func decided(_ url: URL) -> Bool {
        guard waiting, let file, url.standardizedFileURL == file.standardizedFileURL else { return false }
        waiting = false
        return true
    }
}
