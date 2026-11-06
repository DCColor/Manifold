// devclock: a Core Audio output device's sample clock against the host (docs/CARD_CLOCK_FINDINGS.md). Not in the app.
//   devclock list                     every output device's name and UID
//   devclock <uid> <seconds> <out>    an IOProc on that device that writes nothing, logging once a second:
//                                     "<host s> <sample time> <rate scalar>" from the callback's inNow timestamp.
// The IOProc leaves its output buffers untouched, so it adds no sound. It changes no device setting and no default.
import CoreAudio
import Foundation

func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ zero: T) -> T {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = zero; var n = UInt32(MemoryLayout<T>.size)
    _ = AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v); return v
}
func devices() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var n: UInt32 = 0; AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n)
    var ids = [AudioObjectID](repeating: 0, count: Int(n) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, &ids); return ids
}
func str(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    (prop(id, sel, kAudioObjectPropertyScopeGlobal, "" as CFString) as String)
}
func hasOutput(_ id: AudioObjectID) -> Bool {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var n: UInt32 = 0; AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n); return n > 0
}
let args = CommandLine.arguments
if args.count == 2, args[1] == "list" {
    let def: AudioObjectID = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0)
    for d in devices() where hasOutput(d) {
        let rate: Double = prop(d, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0)
        print("\(d == def ? "*" : " ") \(str(d, kAudioObjectPropertyName))\t\(str(d, kAudioDevicePropertyDeviceUID))\t\(rate)")
    }
    exit(0)
}
guard args.count == 4, let secs = Double(args[2]), let dev = devices().first(where: { str($0, kAudioDevicePropertyDeviceUID) == args[1] }) else {
    print("usage: devclock list | devclock <uid> <seconds> <out>"); exit(1)
}
guard let out = fopen(args[3], "w") else { print("cannot write \(args[3])"); exit(1) }
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
let scale = Double(tb.numer) / Double(tb.denom) / 1e9
var last: UInt64 = 0
var proc: AudioDeviceIOProcID?
var keep: [DispatchSourceSignal] = []
let st = AudioDeviceCreateIOProcIDWithBlock(&proc, dev, nil) { now, _, _, _, _ in
    let t = now.pointee
    if t.mHostTime &- last >= UInt64(1 / scale) {
        last = t.mHostTime
        fputs(String(format: "%.9f %.3f %.9f\n", Double(t.mHostTime) * scale, t.mSampleTime, t.mRateScalar), out); fflush(out)
    }
}
guard st == noErr, let proc else { print("IOProc refused: \(st)"); exit(1) }
guard AudioDeviceStart(dev, proc) == noErr else { print("start refused"); exit(1) }
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let stop = DispatchGroup(); stop.enter()
for sig in [SIGTERM, SIGINT] { let s = DispatchSource.makeSignalSource(signal: sig); s.setEventHandler { stop.leave() }; s.resume(); keep.append(s) }
_ = stop.wait(timeout: .now() + secs)
AudioDeviceStop(dev, proc); AudioDeviceDestroyIOProcID(dev, proc); fclose(out)
