//
//  MediaKind.swift
//  ManifoldCore
//
//  What a loaded FILE is (docs/STILLS_AND_AUDIO_ONLY_PLAN.md §3.1). `hasMedia` says a file is loaded; this says which
//  kind, so a control that only means something for moving pictures asks `mediaKind == .video` and the file-name,
//  Inspector and empty-state gates keep asking `hasMedia`.
//

/// `.none` is also what a live source reads as: live transports never load the engine, so a window showing a stream is
/// `.none` with a picture. Ask `feedsRenderer` for "may a picture be in the renderer", never `== .video`, in any code
/// that has to stay true for a stream.
public enum MediaKind: Sendable, Equatable {
    case none
    case video
    /// Drawn by macOS in an `NSImageView`, never by the renderer (docs/STILLS_AND_AUDIO_ONLY_PLAN.md §2).
    case still
    case audioOnly

    /// False when the loaded file gives the renderer nothing to draw, so colour, scopes, raster sizes and frame export
    /// have nothing to act on.
    public var feedsRenderer: Bool {
        switch self {
        case .none, .video: return true
        case .still, .audioOnly: return false
        }
    }
}
