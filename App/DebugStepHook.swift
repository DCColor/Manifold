import Foundation
import QuartzCore
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

/// MEASUREMENT ONLY (pre-ship removal, docs/BUGS.md). `MANIFOLD_DEBUG_TRANSPORT="wait 15;play;wait 20;seek 300;pause;step 1;shuttle 2;loop"`:
/// once a file has loaded, run each step on the engine, as the keys do. Seek, step and shuttle are key-only and an unattended run
/// sends no keystrokes. Each step logs the host time and the clock, for `cardlock-summary.py`. Unset, nothing happens.
@MainActor
enum DebugTransportHook {
    private static let steps = (ProcessInfo.processInfo.environment["MANIFOLD_DEBUG_TRANSPORT"] ?? "")
        .split(separator: ";").map { $0.split(separator: " ").map(String.init) }
    private static var ran = false

    static func run(engine: FrameEngine) {
        guard !steps.isEmpty, !ran, engine.currentURL != nil else { return }
        ran = true
        Task { @MainActor in
            for step in steps {
                let arg = step.count > 1 ? Double(step[1]) ?? 0 : 0
                if step[0] == "wait" { try? await Task.sleep(for: .seconds(arg)); continue }
                print(String(format: "[TRANSPORT] %@ host %.6f clock %.6f", step.joined(separator: " "), CACurrentMediaTime(), engine.currentSyncTime().seconds))
                switch step[0] {
                case "play": engine.play()
                case "pause": engine.pause()
                case "seek": engine.seek(to: arg)
                case "step": engine.stepFrame(by: Int(arg))
                case "shuttle": engine.setShuttleRate(Float(arg))
                case "loop": engine.toggleLoop()
                default: print("[TRANSPORT] unknown step")
                }
            }
            print("[TRANSPORT] done")
        }
    }
}
#endif
