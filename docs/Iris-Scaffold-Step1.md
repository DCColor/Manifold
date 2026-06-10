# Iris — Scaffold (Step 1)

**Graviton Tools · `com.graviton.iris` · `github.com/DCColor/Iris`**

This is the starting skeleton plus the first runnable milestone: an app window that opens a local `.mov`/`.mp4` and plays it. It also lays down the architectural seams (`FrameSource`, `FrameSink`) we'll fill in later, and sets up the `IrisCore` engine package the DC Color Live Companion will eventually share.

> These are starter files written for you to run tomorrow — they haven't been compiled on a Mac yet, so the first build is also the first test. If anything doesn't compile, that's expected and we'll fix it together; nothing here is complicated to repair.

---

## How to use this tomorrow (≈5 minutes to a running app)

**1. Install the one tool we need.** In your Regular terminal:

```bash
brew install xcodegen
```

(That's the only new dependency. XcodeGen turns a small readable `project.yml` into the `.xcodeproj`, so we never hand-edit the merge-hostile project file — and Claude Code can add files/targets by editing one YAML file.)

**2. Create the files.** Easiest path with your workflow: open this document and tell Claude Code:

> "Create every file listed in Iris-Scaffold-Step1.md at the paths shown, with the exact contents given. Do not add any other dependencies. In particular, never use `arthenica/ffmpeg-kit` — it's retired."

Or create them by hand from the blocks below.

**3. Generate the project and run.** In the Regular terminal, from the repo root:

```bash
xcodegen generate
open Iris.xcodeproj
```

In Xcode: select the **Iris** scheme, pick the **Signing & Capabilities** tab, set your Team (your Apple Developer account), then **Run** (⌘R). Click **Open…**, choose a `.mov` or `.mp4` off your desktop, and it should play.

---

## Folder tree

```
Iris/
├── project.yml                    # XcodeGen spec (the only project definition we edit)
├── .gitignore
├── README.md
├── App/                           # The Iris.app target
│   ├── IrisApp.swift              # @main entry point
│   ├── ContentView.swift          # Root UI: video surface + open/play controls
│   └── VideoSurfaceView.swift     # Bridges an AppKit video layer into SwiftUI
└── Packages/
    └── IrisCore/                  # The engine — a local Swift Package, no UI
        ├── Package.swift
        └── Sources/
            └── IrisCore/
                ├── AVPlayerEngine.swift   # Step-1 playback engine (wraps AVPlayer)
                ├── FrameSource.swift       # SEAM: inputs (NDI/SRT/WHEP/file decode) become these
                └── FrameSink.swift         # SEAM: outputs (screen, DeckLink) become these
```

Two things worth understanding about this layout:

- **`IrisCore` is a separate package with no UI on purpose.** That boundary is the portability insurance for the Companion app: anything that knows about windows, buttons, or dccolor.live stays *out* of `IrisCore`. The Companion becomes "`IrisCore` + a side window," nothing more.
- **`FrameSource` / `FrameSink` exist now but aren't used yet.** They're the seams from our architecture discussion. Reading them today costs nothing; having them in place means every future input and output has an obvious shape to conform to.

---

## Files

### `project.yml`

The whole project definition. When you add a file under `App/`, XcodeGen picks it up automatically on the next `xcodegen generate` — you rarely touch this.

```yaml
name: Iris
options:
  bundleIdPrefix: com.graviton
  deploymentTarget:
    macOS: "15.0"
  createIntermediateGroups: true

packages:
  IrisCore:
    path: Packages/IrisCore

targets:
  Iris:
    type: application
    platform: macOS
    sources:
      - App
    dependencies:
      - package: IrisCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.graviton.iris
        PRODUCT_NAME: Iris
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_NSHumanReadableCopyright: "© 2026 Graviton Tools"
        INFOPLIST_KEY_LSApplicationCategoryType: "public.app-category.video"
        SWIFT_VERSION: "5.0"
        CODE_SIGN_STYLE: Automatic
        ENABLE_HARDENED_RUNTIME: YES
```

A few deliberate choices here:

- **macOS 15 minimum**, as we agreed — maximizes the EDR/AVFoundation API surface.
- **`SWIFT_VERSION: 5.0`** (Swift 5 *language mode*, not an old compiler). Swift 6's strict concurrency checking throws a lot of confusing actor-isolation errors that aren't worth fighting while you're learning. We get a calmer ride now and can flip to Swift 6 mode deliberately later.
- **No app sandbox yet** (hardened runtime is on, for notarization later). A sandboxed app has to do a fiddly "security-scoped resource" dance just to keep reading a file you opened. Since a pro tool like this is most naturally distributed via Developer ID + notarization rather than the Mac App Store, we skip that complexity for now. If you ever want the Mac App Store, we add the sandbox and the file-access handling then.

### `.gitignore`

```gitignore
# Xcode
build/
DerivedData/
*.xcuserstate
xcuserdata/

# XcodeGen regenerates this — it's a build artifact, not source
*.xcodeproj

# Swift Package Manager
.build/
.swiftpm/

# macOS
.DS_Store
```

Note we **ignore `*.xcodeproj`**: with XcodeGen the project file is generated output, so it never goes in git. The consequence: after a fresh clone you always run `xcodegen generate` once before opening. That's the trade for never having a project-file merge conflict again.

### `README.md`

```markdown
# Iris

A modern, professional macOS video player. Graviton Tools.

## Setup

Requires [XcodeGen](https://github.com/yonyz/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open Iris.xcodeproj
```

The `.xcodeproj` is generated and git-ignored — run `xcodegen generate` after any fresh clone.

## Architecture

- `Packages/IrisCore` — the UI-free playback engine (shared with the future DC Color Live Companion).
- `App/` — the Iris.app macOS UI.

> Dependency rule: never use `arthenica/ffmpeg-kit` (retired April 2025). When ffmpeg is added for MXF/DNxHR, use the maintained `kingslay/FFmpegKit`, pinned, LGPL build only.
```

---

### `Packages/IrisCore/Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IrisCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "IrisCore", targets: ["IrisCore"])
    ],
    targets: [
        .target(
            name: "IrisCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
```

> `swift-tools-version` is the version of the *package format* — that's fine to keep current. `.swiftLanguageMode(.v5)` is what actually puts the code in the calmer Swift 5 mode.

### `Packages/IrisCore/Sources/IrisCore/FrameSource.swift`

```swift
import CoreMedia

/// A source of decoded video frames.
///
/// This is a seam, not yet used. Later, each input becomes a `FrameSource`:
/// local file decode, NDI receive, SRT (demux + decode), and WHEP (WebRTC playback).
/// Because they all conform to one protocol, the renderer never has to know
/// where a frame came from.
public protocol FrameSource: AnyObject {
    /// Called whenever a new decoded video frame is ready.
    /// A `CMSampleBuffer` carries the pixels plus presentation timing and format info.
    var onVideoFrame: ((CMSampleBuffer) -> Void)? { get set }

    func start() throws
    func stop()
}
```

### `Packages/IrisCore/Sources/IrisCore/FrameSink.swift`

```swift
import CoreMedia

/// A consumer of decoded video frames.
///
/// This is a seam, not yet used. The on-screen renderer will always be a sink.
/// A Blackmagic DeckLink **output** (feeding a reference monitor) becomes an
/// optional second sink fed from the same decoded frames.
public protocol FrameSink: AnyObject {
    func consume(_ sampleBuffer: CMSampleBuffer)
}
```

### `Packages/IrisCore/Sources/IrisCore/AVPlayerEngine.swift`

This is the actual step-1 engine. It wraps `AVPlayer` — Apple's high-level player — which is the gentlest possible way to get a file on screen, and which we keep permanently as the HLS backend later. The lower-level frame-based engine (the `FrameSource` path) arrives at step 4.

```swift
import AVFoundation
import Combine

/// Step-1 playback engine: a thin wrapper over AVPlayer.
///
/// `@MainActor` means every method runs on the main thread — correct for
/// anything touching playback/UI state. `ObservableObject` + `@Published`
/// is how SwiftUI watches a class for changes and re-draws when they happen.
@MainActor
public final class AVPlayerEngine: ObservableObject {

    /// The underlying player. The video view reads this to display frames.
    public let player = AVPlayer()

    /// Published so SwiftUI can swap the play/pause icon automatically.
    @Published public private(set) var isPlaying = false

    public init() {}

    /// Load a local file URL into the player.
    public func load(url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
    }

    public func play() {
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }
}
```

> `isPlaying` here is set optimistically. Later we'll observe `AVPlayer.timeControlStatus` so the state is accurate even when playback stalls or reaches the end — but that's polish, not needed to see video.

---

### `App/IrisApp.swift`

```swift
import SwiftUI

@main
struct IrisApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 460)
        }
    }
}
```

> `@main` marks the program's entry point. `App` and `Scene` are SwiftUI's way of describing "an app made of windows" — `WindowGroup` is one resizable window containing our `ContentView`.

### `App/VideoSurfaceView.swift`

The one genuinely new concept in step 1. SwiftUI can't display an `AVPlayer` directly; the display surface (`AVPlayerLayer`) is an AppKit thing. `NSViewRepresentable` is the official bridge that wraps an AppKit `NSView` so SwiftUI can place it.

```swift
import SwiftUI
import AVFoundation

/// Bridges an AppKit video layer into SwiftUI.
///
/// SwiftUI has no native video view, so we host an `AVPlayerLayer`
/// (AppKit) and expose it to SwiftUI through `NSViewRepresentable`.
struct VideoSurfaceView: NSViewRepresentable {
    let player: AVPlayer

    // Called once to build the AppKit view.
    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    // Called when SwiftUI state changes; keep the player reference current.
    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        nsView.playerLayer.player = player
    }
}

/// An NSView whose *backing layer* is an AVPlayerLayer.
/// "Layer-backed" means the view draws via Core Animation, which is
/// what lets us use a specialized layer type as the view's surface.
final class PlayerNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVPlayerLayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
```

> `AVPlayerLayer` already tone-maps HDR content sensibly on an EDR display, so HDR files will look reasonable from day one. True, explicit EDR *headroom control* comes when we move to the Metal render path at step 6 — for now the system handles it.

### `App/ContentView.swift`

```swift
import SwiftUI
import IrisCore

struct ContentView: View {
    // @StateObject creates and owns the engine for this view's lifetime.
    @StateObject private var engine = AVPlayerEngine()
    @State private var isImporterPresented = false

    var body: some View {
        VStack(spacing: 0) {
            VideoSurfaceView(player: engine.player)
                .background(.black)

            HStack(spacing: 16) {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Open…", systemImage: "folder")
                }

                Button {
                    engine.togglePlayPause()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24)
                }
                .keyboardShortcut(.space, modifiers: [])

                Spacer()
            }
            .padding(12)
        }
        // The system file picker. Step 1 = native QuickTime/MP4 only;
        // MXF and other formats arrive when we add the ffmpeg backend (step 5).
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                engine.load(url: url)
                engine.play()
            }
        }
    }
}
```

> `@StateObject` vs `@State`: `@State` is for simple values (a Bool), `@StateObject` is for a reference-type object the view should create once and keep. `$isImporterPresented` (the `$`) passes a two-way binding so the file picker can flip the Bool back to `false` when it closes.

---

## Standing rules (so future sessions don't drift)

1. **Never add `arthenica/ffmpeg-kit`.** It was retired and its binaries pulled in April 2025; AI tools reach for it reflexively. When we add ffmpeg for MXF/DNxHR (step 5), use the maintained `kingslay/FFmpegKit`, pinned to a version, **LGPL build only** (not a `-gpl` one) so the commercial license stays clean.
2. **The `.xcodeproj` is generated.** Edit `project.yml`, then `xcodegen generate`. Never hand-edit the project file.
3. **Keep `IrisCore` UI-free and dccolor.live-free.** That boundary is what lets the Companion reuse it cleanly.
4. **Commit as one step:** `git add -A && git commit -m "..." && git push` together, so GitHub always matches local.

First commit, once it builds and runs:

```bash
git add -A && git commit -m "Scaffold: XcodeGen project, IrisCore package, AVPlayer step-1 playback" && git push
```

---

## What you'll have, and what's next

**Running:** a window that opens a local `.mov`/`.mp4`, plays it, with Open and play/pause (spacebar) controls, and HDR content tone-mapped by the system.

**Next sessions, in order:**

- **Step 2** — round out the AVPlayer engine: scrubber, current-time/duration, accurate state from `timeControlStatus`.
- **Step 3** — the metadata inspector (codec, frame size/rate, container, the nclc color tags, markers). Cheap and high-value, pure AVFoundation.
- **Step 4** — the `FrameSource`/synchronizer engine: real frame-level playback via VideoToolbox, sitting beside the AVPlayer engine behind a shared interface.
- **Step 5** — the ffmpeg backend → MXF demux + ProRes (VideoToolbox) / DNxHR (ffmpeg) decode.

We'll take each one slowly, and I'll explain every new Swift concept the first time it shows up.
