# Manifold — known bugs

Shipping defects that are understood but not yet fixed. Each entry states what is wrong, why
nobody has reported it (if that is the interesting part), and what it blocks.

---

## Live sources never publish their frame size, so every stream is framed as 16:9

**Status:** open. **Found:** 2026-08-10, during the window-sizing audit. **Blocks:** the
window-sizing arc (Arc B) — must be fixed first.

`engine.displaySize` is nil for every live source. NDI, WHEP and SRT all push decoded frames
straight into the shared renderer and never set it — the only writers are the file paths:

- `FrameEngine.swift` — set on AVFoundation load, and in `applyLibavMetadata` for the MXF/libav
  path; cleared to nil on stop.
- `AVPlayerEngine.swift` — same, for the AVPlayer engine.

Two things read it, and both degrade quietly:

1. `ContentView.videoAspect` falls back to **16:9** whenever `displaySize` is nil. So the video
   rect, and with it the framing-guide overlay and the caption overlay (both attached to that
   rect), are laid out for a 16:9 picture regardless of the stream's actual shape.
2. `WindowConfigurator.updateNSView` returns early on a nil `displaySize`, so a streaming window
   gets **no aspect lock at all** and keeps whatever shape it last had.

The picture itself is not stretched — the CAMetalLayer's `drawableSize` is set from the pixel
buffer, so the decoded frame is scaled into whatever rect SwiftUI computed. The bug is that the
rect is the wrong shape: a portrait or 4:3 stream is letterboxed inside a 16:9 box instead of
being framed to its own aspect, and the guides and captions land on the wrong lines.

**Why nobody has reported it:** every stream tested to date has been 16:9, which is exactly the
fallback. The bug is invisible until someone points a phone-shaped or SD source at it.

**Fix:** give the live sources a path to publish their frame dimensions, the same way the file
paths do, so `videoAspect` and the window both track the real shape. This must land before the
window-sizing work — the new sizing computes the window from the video's aspect, so it would be as
wrong for streams as the current fallback is, only more visibly.
