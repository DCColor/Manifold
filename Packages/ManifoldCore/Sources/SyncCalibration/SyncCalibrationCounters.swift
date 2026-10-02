//
//  SyncCalibrationCounters.swift — SyncCalibration
//
//  How much detector work this process has done, ever (docs/AUDIO_RESAMPLER_DESIGN.md §19.10). The
//  claim "calibration off = zero work" is checked against these: every buffer calibration mode's beep
//  detector scans and every frame its flash detector samples counts. Logged at calibration start and
//  stop and at the end of every live-audio session.
//
//  The DEBUG `[AV-CONTENT]` probe (pre-ship removal) uses the same beep detector class whenever a
//  DEBUG app's telemetry is on; its scans are counted APART (`debugProbeBuffersScanned`), so a Profile
//  run still shows calibration's own zero. Release has no probe: that figure is always 0 there.
//

import Foundation

public enum SyncCalibrationCounters {
    public struct Snapshot: Sendable, Equatable {
        public var audioBuffersScanned = 0
        public var framesSampled = 0
        public var tonesFound = 0
        public var flashesFound = 0
        public var debugProbeBuffersScanned = 0
        public var text: String {
            "\(audioBuffersScanned) audio buffer(s) scanned, \(framesSampled) frame(s) sampled, "
                + "\(tonesFound) tone(s) and \(flashesFound) flash(es) found"
                + (debugProbeBuffersScanned > 0 ? " (and \(debugProbeBuffersScanned) by the DEBUG [AV-CONTENT] probe)" : "")
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var value = Snapshot()

    public static var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }

    public static func countAudioBuffer(tones: Int) {
        lock.lock(); value.audioBuffersScanned += 1; value.tonesFound += tones; lock.unlock()
    }

    public static func countDebugProbeBuffer() {
        lock.lock(); value.debugProbeBuffersScanned += 1; lock.unlock()
    }

    public static func countFrame(flash: Bool) {
        lock.lock(); value.framesSampled += 1; if flash { value.flashesFound += 1 }; lock.unlock()
    }
}
