// devclock: a Core Audio output device's sample clock against the host (docs/CARD_CLOCK_FINDINGS.md). Not in the app.
//   devclock list                     every output device's name and UID
//   devclock <uid> <seconds> <out>    an IOProc on that device that writes nothing, logging once a second:
//                                     "<host s> <sample time> <rate scalar>" from the callback's inNow timestamp.
// Stage 2 (§10.27, method S) adds, as lines starting with "#":
//   "# latency ..."  the device's reported output latency, the first output stream's latency, the safety offset and the buffer size,
//                    at the start and again whenever any of them changes (read once a second, off the IO thread);
//   "# gap ..."      a callback whose sample time is half a buffer or more off the previous one's plus its buffer (a lost or
//                    repeated cycle); "# wobble ..." one 3 frames or more off but under that (timestamp jitter, S0: ±5–6 frames);
//   "# overload ..." each kAudioDeviceProcessorOverload the device reports.
// The IOProc leaves its output buffers untouched, so it adds no sound. It changes no device setting and no default.
// Build: swiftc -O devclock.swift -o ../../build/decklink-loopback/devclock
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
func outputStreams(_ id: AudioObjectID) -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var n: UInt32 = 0; AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n)
    var ids = [AudioObjectID](repeating: 0, count: Int(n) / 4)
    AudioObjectGetPropertyData(id, &a, 0, nil, &n, &ids); return ids
}
/// Device latency, first output stream's latency, safety offset, buffer frame size, nominal rate: all as the device reports them.
func latencies(_ id: AudioObjectID) -> String {
    let dev: UInt32 = prop(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, 0)
    let safety: UInt32 = prop(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, 0)
    let buffer: UInt32 = prop(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, 0)
    let rate: Double = prop(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0)
    let stream: UInt32 = outputStreams(id).first.map { prop($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, 0) } ?? 0
    return "device \(dev) stream \(stream) safety \(safety) buffer \(buffer) frames, rate \(rate)"
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
let outLock = NSLock()
func emit(_ s: String) { outLock.lock(); fputs(s, out); fflush(out); outLock.unlock() }
emit("# device \(str(dev, kAudioObjectPropertyName)) uid \(args[1])\n")
var lastLatency = latencies(dev)
emit(String(format: "# latency %.9f %@\n", Double(mach_absolute_time()) * scale, lastLatency))
var last: UInt64 = 0
var prevSample = -1.0, prevFrames = 0
var proc: AudioDeviceIOProcID?
var keep: [DispatchSourceSignal] = []
let st = AudioDeviceCreateIOProcIDWithBlock(&proc, dev, nil) { now, _, _, outData, _ in
    let t = now.pointee
    let frames = outData.pointee.mNumberBuffers > 0 && outData.pointee.mBuffers.mNumberChannels > 0
        ? Int(outData.pointee.mBuffers.mDataByteSize) / (4 * Int(outData.pointee.mBuffers.mNumberChannels)) : 0
    if prevSample >= 0, prevFrames > 0 {
        let off = t.mSampleTime - (prevSample + Double(prevFrames))
        // A lost or repeated cycle steps by a buffer; the timestamps themselves wobble by a few frames (S0: ±5–6, in cancelling pairs).
        if abs(off) >= Double(prevFrames) / 2 {
            emit(String(format: "# gap %.9f sample %.3f expected %.3f (%+.1f frames)\n", Double(t.mHostTime) * scale, t.mSampleTime, prevSample + Double(prevFrames), off))
        } else if abs(off) > 2 {
            emit(String(format: "# wobble %.9f %+.1f frames\n", Double(t.mHostTime) * scale, off))
        }
    }
    prevSample = t.mSampleTime; prevFrames = frames
    if t.mHostTime &- last >= UInt64(1 / scale) {
        last = t.mHostTime
        emit(String(format: "%.9f %.3f %.9f\n", Double(t.mHostTime) * scale, t.mSampleTime, t.mRateScalar))
    }
}
guard st == noErr, let proc else { print("IOProc refused: \(st)"); exit(1) }
var ovl = AudioObjectPropertyAddress(mSelector: kAudioDeviceProcessorOverload, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(dev, &ovl, DispatchQueue.global()) { _, _ in
    emit(String(format: "# overload %.9f\n", Double(mach_absolute_time()) * scale))
}
guard AudioDeviceStart(dev, proc) == noErr else { print("start refused"); exit(1) }
let poll = DispatchSource.makeTimerSource(queue: .global())
poll.schedule(deadline: .now() + 1, repeating: 1)
poll.setEventHandler {
    let l = latencies(dev)
    if l != lastLatency { lastLatency = l; emit(String(format: "# latency %.9f %@\n", Double(mach_absolute_time()) * scale, l)) }
}
poll.resume()
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let stop = DispatchGroup(); stop.enter()
for sig in [SIGTERM, SIGINT] { let s = DispatchSource.makeSignalSource(signal: sig); s.setEventHandler { stop.leave() }; s.resume(); keep.append(s) }
_ = stop.wait(timeout: .now() + secs)
poll.cancel()
AudioDeviceStop(dev, proc); AudioDeviceDestroyIOProcID(dev, proc); fclose(out)
