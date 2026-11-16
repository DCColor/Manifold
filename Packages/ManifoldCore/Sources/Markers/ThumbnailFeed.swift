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
public enum ThumbnailQueue {
    /// The lowest wanted frame with no thumbnail that has not given up, or nil: nothing starts while one is in flight,
    /// while no view shows thumbnails, while the file plays (NEVER BLOCKS PLAYBACK, `MarkerThumbnailer`), or before
    /// the file's rate is known.
    public static func next(wanted: Set<Int>, made: Set<Int>, givenUp: Set<Int>, rate: Double, inFlight: Int?,
                            shown: Bool, playing: Bool) -> Int? {
        guard shown, inFlight == nil, rate > 0, rate.isFinite, !playing else { return nil }
        return wanted.subtracting(made).subtracting(givenUp).min()
    }
}
