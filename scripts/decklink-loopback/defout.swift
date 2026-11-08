// defout: logs every change of the system default output device, with the host time [CADENCE] uses (docs/CARD_CLOCK_FINDINGS.md §10.13). Not in the app.
//   defout <seconds> <out>   polls five times a second. Reads only: it changes no device setting and no default.
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
let args = CommandLine.arguments
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
