import Foundation
import VideoToolbox
import MediaToolbox

/// Opts this process in to Apple's professional-video-workflow plug-ins, once, at launch — and
/// reports whether they are actually installed, which is a **different question** from whether we
/// asked for them.
///
/// ⚠️ **CALLING THE REGISTRATION FUNCTIONS IS NOT THE SAME AS HAVING THE PLUG-INS.** Both functions
/// exist on every macOS, return `void`, and cannot fail. They succeed identically on a machine with
/// Pro Video Formats installed and on one without it. **So presence must be PROBED — it cannot be
/// inferred from the call returning.** That is what `availability` is for.
///
/// Background: `docs/BUGS.md` → *"VideoToolbox plug-in codecs and MediaToolbox plug-in format
/// readers are OPT-IN PER PROCESS"*. Before this existed, Manifold called neither, which is why
/// "AVFoundation cannot open MXF" looked like a property of AVFoundation for so long.
@MainActor
final class ProVideoWorkflow: ObservableObject {

    static let shared = ProVideoWorkflow()
    private init() {}

    /// Whether the plug-in bundles are installed — THREE STATES, and `.unknown` is a real answer
    /// meaning *the probe has not finished*, not a synonym for absent. Same three-state rule as
    /// `DeclaredPixelAspect`, `LayoutConfidence`, `CaptionDataPresence` and `KeychainRead`.
    ///
    /// ⚠️ **`.installed` MEANS THE PACKAGE IS ON DISK. IT DOES NOT PROMISE A DECODE WILL SUCCEED**
    /// — see the note on `probeInstalledBundles()`. Treat it as a gate, never as a guarantee.
    enum Availability: Equatable {
        /// Registration has not finished, so nothing has been probed yet.
        case unknown
        /// The plug-in directory exists and holds bundles. `bundles` is the inventory, sorted.
        case installed(bundles: [String])
        /// Pro Video Formats (`com.apple.pkg.ProVideoFormats`) is not installed.
        case notInstalled
    }

    @Published private(set) var availability: Availability = .unknown

    /// `DNXDecoder.bundle` specifically — the one that decodes `AVdh`/`AVdn`. The MXF routing
    /// decision needs this rather than "some plug-ins are installed", because the package could in
    /// principle be partially present.
    var hasDNxDecoder: Bool {
        guard case .installed(let bundles) = availability else { return false }
        return bundles.contains("DNXDecoder.bundle")
    }

    private var registration: Task<Void, Never>?

    /// The plug-in directory. Not a search path — this is the single location the installer uses,
    /// and the bundles are loaded by VideoToolbox's and MediaToolbox's own machinery, not by us.
    private static let pluginDirectory = "/Library/Video/Professional Video Workflow Plug-Ins"

    // MARK: - Registration

    /// Start registration. Idempotent, returns immediately, and the work runs **off the main
    /// actor**.
    ///
    /// ⚠️ **REGISTRATION IS NOT FREE AND THAT IS WHY IT IS NOT INLINE.** MEASURED on the build Mac:
    /// `VTRegisterProfessionalVideoWorkflowVideoDecoders()` **7.4–10.0 ms**,
    /// `MTRegisterProfessionalVideoWorkflowFormatReaders()` **4.1–5.0 ms** — **12–15 ms combined**,
    /// or most of a 60 Hz frame, on a launch path that three separate fixes on 2026-09-09 spent
    /// effort clearing (see *"`LicenseManager.bootstrap` blocks the main actor for the whole of
    /// launch"*). Repeat calls cost 0.3 ms, so the functions are internally idempotent — but that
    /// does not make the FIRST call cheap, and the first call is the one on the launch path.
    ///
    /// Same discipline as the licensing Keychain gather: the work goes to a detached task and the
    /// main actor is never blocked on it.
    func beginRegistrationAtLaunch() {
        guard registration == nil else { return }
        registration = Task.detached(priority: .userInitiated) {
            // ⚠️ ORDER MATTERS AND IS NOT INTERCHANGEABLE WITH THE PROBE. Register first, probe
            // second: the probe is a statement about this process's capability, and before the
            // calls the process has none regardless of what is on disk.
            VTRegisterProfessionalVideoWorkflowVideoDecoders()
            MTRegisterProfessionalVideoWorkflowFormatReaders()
            let found = Self.probeInstalledBundles()
            // Logged for the same reason the DeckLink enumeration is: a tester's log has to be
            // able to say WHICH of the two machines it came from. "MXF opens on mine and not on
            // yours" is otherwise unanswerable, and this is the line that answers it.
            switch found {
            case .installed(let bundles):
                print("ProVideoWorkflow: registered; Pro Video Formats installed "
                    + "(\(bundles.count) bundles, DNxHR decoder "
                    + "\(bundles.contains("DNXDecoder.bundle") ? "present" : "ABSENT"))")
            case .notInstalled:
                print("ProVideoWorkflow: registered, but Pro Video Formats is NOT installed — "
                    + "plug-in codecs and the MXF format reader are unavailable in this process")
            case .unknown:
                break   // unreachable: the probe never returns .unknown
            }
            await MainActor.run { self.availability = found }
        }
    }

    /// Await registration. ⚠️ **EVERY PATH THAT OPENS A FILE MUST AWAIT THIS FIRST**, because the
    /// registration is off-main and therefore no longer ordered against the first open by
    /// construction. Starting it here too means a caller that forgets `beginRegistrationAtLaunch()`
    /// still gets a correct answer rather than a silently unregistered process.
    ///
    /// Cheap after the first launch-time call: awaiting an already-finished `Task` is a no-op.
    func ready() async {
        beginRegistrationAtLaunch()
        await registration?.value
    }

    // MARK: - The presence probe

    /// ⚠️ **WHAT THIS PROBE ANSWERS, AND WHAT IT DELIBERATELY DOES NOT.**
    ///
    /// It answers **"is Pro Video Formats installed"** by listing the plug-in directory. It does
    /// **not** answer *"will a DNxHR decode succeed"*. Those are different questions and the cheap
    /// one was chosen on purpose:
    ///
    /// | probe | answers | MEASURED cost |
    /// |---|---|---|
    /// | list the plug-in directory *(this one)* | the package is installed | **1.0–1.4 ms cold, 0.06 ms warm** |
    /// | `VTDecompressionSessionCreate` for `AVdh` | the decoder actually instantiates | **8–102 ms, or 40 SECONDS — see below** |
    ///
    /// ⚠️ **THE SESSION-CREATE PROBE IS RULED OUT FOR LAUNCH, AND THE REASON IS NOT MERELY COST.**
    /// **Its answer depends on the format description you probe with, and both ways of getting that
    /// wrong are catastrophic.** MEASURED with the plug-ins registered FIRST, so the description is
    /// the only variable, on a machine where the decoder demonstrably works (60 frames decoded
    /// bit-identically — `docs/BUGS.md`, the narrow-plan entry):
    ///
    /// | description passed to the probe | status | a session probe concludes | time |
    /// |---|---|---|---|
    /// | **without `ADHR`** (`FormatName`, `Depth`) | **−12902** | ⚠️ **ABSENT — WRONG** | 79 ms |
    /// | with `ADHR` | 0 | PRESENT — correct | 8 ms |
    /// | NULL extensions | 0 | PRESENT — correct | ⚠️ **20,468 ms** |
    /// | empty dictionary | 0 | PRESENT — correct | ⚠️ **40,470 ms** |
    ///
    /// ⚠️ **ROW ONE IS A FALSE NEGATIVE IN THE ONE DIRECTION THAT MATTERS.** `ADHR` is necessary
    /// and sufficient for this decoder; a probe that omits it reports **absent on a machine where
    /// the decoder works**. Nothing surfaces — the app would silently route **every** DNxHR file to
    /// libav and reintroduce the 4:4:4 green-and-magenta defect on a machine that could have
    /// decoded it correctly. A probe that fails safe-looking is worse than no probe.
    ///
    /// ⚠️ **AND ROWS THREE AND FOUR RETURN SUCCESS AFTER TWENTY AND FORTY SECONDS.** They are not
    /// slow paths — they **segfault `DNXDecoder` inside `VTDecoderXPCService`** (`parse_metadata`
    /// calls `CFDictionaryGetValue` with no null check) and are then recovered by VideoToolbox,
    /// which retries and eventually answers correctly. **A launch probe that hangs the app for half
    /// a minute and then tells you the truth is still a launch probe that hangs the app for half a
    /// minute.** The related wedge — `VTDecompressionSessionInvalidate` blocking forever after that
    /// crash, measured at seven minutes at 0 % CPU — is in the same entry.
    ///
    /// So the cheap probe is not a compromise chosen for speed. **It is the only one of the two
    /// that cannot be wrong in a way nobody notices.**
    ///
    /// **The authoritative answer is the decode attempt itself**, which happens when a file is
    /// opened. So the routing decision must still handle that failing, and must not treat
    /// `.installed` as a promise. A bundle can be present and broken; only the decode knows.
    ///
    /// ⚠️ **Do NOT substitute `VTCopyVideoDecoderList`.** It does not enumerate plug-in codecs at
    /// all — AVC-Intra, DVCPRO HD, IMX and Uncompressed are equally absent from it while installed.
    /// Any reasoning built on that list is void; the directory listing is the evidence.
    private nonisolated static func probeInstalledBundles() -> Availability {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: pluginDirectory)
        else { return .notInstalled }                       // directory absent → package absent
        let bundles = names.filter { $0.hasSuffix(".bundle") }.sorted()
        return bundles.isEmpty ? .notInstalled : .installed(bundles: bundles)
    }
}
