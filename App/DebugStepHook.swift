import Foundation
import ManifoldCore

#if DEBUG
/// MEASUREMENT ONLY (pre-ship removal, docs/BUGS.md). `MANIFOLD_DEBUG_STEPS="1,1,-1,10"`: once a file has loaded,
/// press each step in turn through `FrameEngine.stepFrame(by:)` (the path ← / → take), 1.5 s apart, log where it
/// landed and write the support export set (into `MANIFOLD_FRAME_EXPORT_DIR`). Frame steps are key-only and an
/// unattended run sends no keystrokes (docs/BUGS.md, 2026-10-17: "Frame step could not be driven without a
/// keystroke"). Unset, nothing happens.
@MainActor
enum DebugStepHook {
    private static let steps: [Int] = (ProcessInfo.processInfo.environment["MANIFOLD_DEBUG_STEPS"] ?? "")
        .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    private static var ran = false

    static func run(engine: FrameEngine, renderer: MetalVideoRenderer?) {
        guard !steps.isEmpty, !ran, let renderer, engine.currentURL != nil else { return }
        ran = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            print(String(format: "[STEP-HOOK] start frame %d of %d t=%.6f", engine.currentFrame, engine.totalFrames,
                         engine.currentTime))
            for (i, step) in steps.enumerated() {
                engine.stepFrame(by: step)
                try? await Task.sleep(for: .milliseconds(1500))
                print(String(format: "[STEP-HOOK] %d by %d → frame %d of %d t=%.6f", i, step, engine.currentFrame,
                             engine.totalFrames, engine.currentTime))
                renderer.exportFrameForSupport(window: nil)
            }
            print("[STEP-HOOK] done")
        }
    }
}
#endif
