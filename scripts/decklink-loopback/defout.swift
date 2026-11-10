// defout: logs every change of the system default output device, with the host time [CADENCE] uses (docs/CARD_CLOCK_FINDINGS.md §10.13). Not in the app.
//   defout <seconds> <out>   polls five times a second. Reads only: it changes no device setting and no default.
//   defout get               prints the default output: host time, id, name.
//   defout set <name part>   makes the output device whose name contains <name part> the system default output (§10.17, step 2). Reads the
//                            current default first and prints it, refuses unless exactly one output device matches, and reads back after.
//                            Changes nothing else: not the system (alert) output, not any device's settings.
import CoreAudio
import Foundation
import QuartzCore

func defaultOutput() -> AudioObjectID {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v = AudioObjectID(0); var n = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, &v); return v
}
func name(_ id: AudioObjectID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: Unmanaged<CFString>?; var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v) == noErr, let s = v?.takeRetainedValue() else { return "?" }
    return s as String
}
func outputDevices() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var n = UInt32(0); AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n)
    var ids = [AudioObjectID](repeating: 0, count: Int(n) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, &ids)
    return ids.filter { id in
        var s = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var m = UInt32(0); return AudioObjectGetPropertyDataSize(id, &s, 0, nil, &m) == noErr && m > 0
    }
}
let args = CommandLine.arguments
if args.count == 2 && args[1] == "get" { let d = defaultOutput(); print(String(format: "%.3f %u %@", CACurrentMediaTime(), d, name(d))); exit(0) }
if args.count == 3 && args[1] == "set" {
    let before = defaultOutput(); print(String(format: "%.3f before %u %@", CACurrentMediaTime(), before, name(before)))
    let m = outputDevices().filter { name($0).contains(args[2]) }
    guard m.count == 1 else { print("refused: \(m.count) output devices match \"\(args[2])\": \(m.map { name($0) })"); exit(2) }
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v = m[0]; let t = CACurrentMediaTime()
    let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &v)
    usleep(300_000); let after = defaultOutput()
    print(String(format: "%.3f set %u %@ status %d", t, v, name(v), st)); print(String(format: "%.3f after %u %@", CACurrentMediaTime(), after, name(after)))
    exit(st == noErr && after == v ? 0 : 3)
}
guard args.count == 3, let secs = Double(args[1]), let out = FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: args[2], contents: nil); return args[2] }()) else {
    print("defout <seconds> <out>"); exit(1)
}
var last = AudioObjectID(0); let end = CACurrentMediaTime() + secs
while CACurrentMediaTime() < end {
    let d = defaultOutput()
    if d != last {
        last = d
        out.write(String(format: "%.3f %@ %@\n", CACurrentMediaTime(), ISO8601DateFormatter().string(from: Date()), name(d)).data(using: .utf8)!)
    }
    usleep(200_000)
}
