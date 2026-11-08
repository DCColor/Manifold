// devinput: opens a Core Audio device's INPUT for a while, as a second client would, so the device restarts its IO under whatever else is using it
// (docs/CARD_CLOCK_FINDINGS.md §10.11 B6). Not in the app.
//   devinput <uid> <seconds> [queue|engine|voice]
// An input on the device named by UID, not the system default: an AudioQueue (the default), an AVAudioEngine input tap, or the same tap with voice processing,
// which is what a call does and which builds a private aggregate over the device. Each buffer is dropped: nothing is kept, nothing reaches a disk, and no device
// setting or default changes. Voice processing ducks other sound on the Mac while it runs. Prints the host seconds at start and stop, for the run's log.
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let secs = Double(args[2]) else { print("usage: devinput <uid> <seconds> [queue|engine|voice]"); exit(1) }
let mode = args.count > 3 ? args[3] : "queue"
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func hostNow() -> Double { Double(mach_absolute_time()) * Double(tb.numer) / Double(tb.denom) / 1e9 }

if mode != "queue" {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf = args[1] as CFString; var dev = AudioObjectID(0); var n = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = withUnsafePointer(to: &cf) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &n, &dev) }
    guard st == noErr, dev != 0 else { print("[DEVINPUT] no device \(st)"); exit(3) }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    if mode == "voice" { try! input.setVoiceProcessingEnabled(true) }
    else if let unit = input.audioUnit {
        let r = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioObjectID>.size))
        guard r == noErr else { print("[DEVINPUT] device refused \(r)"); exit(3) }
    }
    input.installTap(onBus: 0, bufferSize: 4096, format: nil) { _, _ in }
    print(String(format: "[DEVINPUT] %@ start host %.6f", mode, hostNow())); fflush(stdout)
    do { try engine.start() } catch { print("[DEVINPUT] start failed \(error)"); exit(4) }
    Thread.sleep(forTimeInterval: secs)
    print(String(format: "[DEVINPUT] %@ stop host %.6f", mode, hostNow())); fflush(stdout)
    engine.stop(); input.removeTap(onBus: 0)
    exit(0)
}

var fmt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
var queue: AudioQueueRef?
var st = AudioQueueNewInputWithDispatchQueue(&queue, &fmt, 0, DispatchQueue.global()) { q, buffer, _, _, _ in
    AudioQueueEnqueueBuffer(q, buffer, 0, nil)   // discarded: the point is the open client, not the samples
}
guard st == noErr, let q = queue else { print("[DEVINPUT] queue failed \(st)"); exit(2) }
var uid = args[1] as CFString
st = withUnsafePointer(to: &uid) { AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size)) }
guard st == noErr else { print("[DEVINPUT] device refused \(st)"); exit(3) }
for _ in 0..<3 {
    var b: AudioQueueBufferRef?
    AudioQueueAllocateBuffer(q, 19200, &b)
    if let b { AudioQueueEnqueueBuffer(q, b, 0, nil) }
}
print(String(format: "[DEVINPUT] start host %.6f", hostNow())); fflush(stdout)
st = AudioQueueStart(q, nil)
guard st == noErr else { print("[DEVINPUT] start failed \(st)"); exit(4) }
Thread.sleep(forTimeInterval: secs)
print(String(format: "[DEVINPUT] stop host %.6f", hostNow())); fflush(stdout)
AudioQueueStop(q, true)
AudioQueueDispose(q, true)
