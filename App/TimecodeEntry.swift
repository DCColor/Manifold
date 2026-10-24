import SwiftUI
import AppKit
import ManifoldCore
import ShortcutRegistry

// ══════════════════════════════════════════════════════════════════════════════════════════
// TIMECODE ENTRY — type a position, land on it.
//
// Three pieces in this file, in dependency order:
//   1. `TimecodeEntry`        — the pure value. What has been typed, and what frame it means.
//   2. `TransportKeyMonitor`  — the app's only NSEvent monitor: per-window entry state, the
//                               type-to-enter capture, AND the ← / → / ⇧← / ⇧→ frame stepping.
//                               (Named for what it does; it is not only about timecode entry.)
//   3. `TimecodeEntryOverlay` — the large centred display.
//
// ── THE ONE ARITHMETIC RULE EVERYTHING HERE OBEYS ─────────────────────────────────────────
//
// A frame index is `round(seconds × EXACT rate)` and a TC field split is at the INTEGER rate.
// Those are two different numbers for every NTSC-family rate (23.976 vs 24, 29.97 vs 30) and
// conflating them is the whole class of bug this feature can have:
//
//   * EXACT rate (23.976…) answers "which picture is at this time" — it is what `currentFrame`,
//     `totalFrames`, `stepFrame` and the seek path have always used.
//   * INTEGER rate (24) answers "how do the digits group" — SMPTE labels count 24 frames per
//     timecode second at 23.976, which is exactly why 23.976 exists as a rate.
//
// So: digits → fields → FRAME COUNT uses the integer rate; frame → SECONDS uses the exact rate.
// `FrameEngine.currentSourceTimecode` was doing the second step with the integer rate, which put
// the readout 0.1% ahead of the picture — one frame per ~1000, and the reason a typed timecode
// could not have round-tripped before this change. See the note there.
// ══════════════════════════════════════════════════════════════════════════════════════════

// MARK: - 1. The value

/// What has been typed, and nothing else — no engine, no view, no side effects. Kept separate so
/// the fill-from-the-right rule and the clamp are readable in one place rather than smeared through
/// a key handler.
struct TimecodeEntry: Equatable {

    /// Absolute ("go here") vs relative ("go this far from where I am"). Chosen by the first
    /// keystroke and changeable at any point — pressing `+` after typing digits keeps the digits and
    /// makes them an offset, because that is what someone who typed the wrong kind of number wants.
    enum Sign: Equatable { case absolute, plus, minus }

    /// The most digits an HH:MM:SS:FF entry can hold. Further keystrokes are IGNORED rather than
    /// shifting the leading digit out: silently discarding the hour someone just typed is a worse
    /// failure than a keystroke that visibly does nothing.
    static let maxDigits = 8

    var sign: Sign = .absolute
    /// Most-significant first, so `[1, 1, 5]` prints as `115` and means 1 second 15 frames. The
    /// fill-from-the-right behaviour is a property of how this is RENDERED and converted, not of
    /// how it is stored — storing it right-aligned would make every append an insert.
    private(set) var digits: [Int] = []

    var isEmpty: Bool { digits.isEmpty }
    var isRelative: Bool { sign != .absolute }

    mutating func append(_ digit: Int) {
        guard (0...9).contains(digit), digits.count < Self.maxDigits else { return }
        digits.append(digit)
    }

    /// Remove the last digit typed. NOT in the settled design, and added deliberately: an entry
    /// field with no correction key makes a mistyped digit cost the whole entry (⎋ then retype),
    /// which is the kind of small hostility that gets a feature called broken.
    mutating func backspace() {
        if digits.isEmpty { sign = .absolute } else { digits.removeLast() }
    }

    /// The four SMPTE fields, filled from the right and NORMALIZED — `115` is 1 second 15 frames,
    /// and `75` at 24 fps is 3 seconds 3 frames rather than an invalid 75-frame field.
    ///
    /// Normalizing rather than rejecting is the NLE convention (Avid and Resolve both do it) and it
    /// is the only reading that keeps "fill from the right" honest: if the frames field is where the
    /// last two digits land, then a two-digit number larger than the frame rate has to mean
    /// something, and "that many frames" is the only thing it can mean.
    func fields(nfr: Int) -> (h: Int, m: Int, s: Int, f: Int) {
        var value = 0
        for d in digits { value = value * 10 + d }
        // Split off the two-digit groups from the right: FF, SS, MM, then whatever is left is HH.
        var f = value % 100; value /= 100
        var s = value % 100; value /= 100
        var m = value % 100; value /= 100
        var h = value
        guard nfr > 0 else { return (h, m, s, f) }
        s += f / nfr;  f %= nfr
        m += s / 60;   s %= 60
        h += m / 60;   m %= 60
        return (h, m, s, f)
    }

    /// The entry read as a plain FRAME COUNT — no drop-frame adjustment and no origin.
    ///
    /// ⚠️ THIS IS THE RIGHT CONVERSION FOR A DURATION AND THE WRONG ONE FOR A TIMECODE LABEL, and
    /// the difference is drop-frame. DF skips LABELS at minute boundaries, not frames, so an offset
    /// of "one second" is `nfr` frames whether or not the file is DF — while an absolute DF label
    /// has to run the inverse of the label-skipping to find its frame. Absolute entry therefore goes
    /// through `TimecodeReader.parse` (below) and only relative entry uses this.
    func frameCount(nfr: Int) -> Int {
        let (h, m, s, f) = fields(nfr: nfr)
        return ((h * 60 + m) * 60 + s) * nfr + f
    }

    /// The masked display: `__:__:12:15` after typing `1215`. The underscores are the feature —
    /// they show WHERE the next digit will land, so the fill-from-the-right rule is something you
    /// watch happen rather than something you have to have been told.
    ///
    /// `dropFrame` only chooses the separator before the frames field (SMPTE `;`), and it comes from
    /// the FILE. There is no way to type a `;` and no way to assert drop-frame from the keyboard:
    /// the file's cadence is not the user's to declare.
    func masked(dropFrame: Bool) -> String {
        // Right-align the typed digits into 8 slots; unfilled slots are underscores.
        var slots = [Character](repeating: "_", count: Self.maxDigits)
        for (i, d) in digits.reversed().enumerated() {
            slots[Self.maxDigits - 1 - i] = Character(String(d))
        }
        let hh = String(slots[0...1]), mm = String(slots[2...3])
        let ss = String(slots[4...5]), ff = String(slots[6...7])
        let last = dropFrame ? ";" : ":"
        let body = "\(hh):\(mm):\(ss)\(last)\(ff)"
        switch sign {
        case .absolute: return body
        case .plus:     return "+" + body
        // U+2212 MINUS SIGN, not a hyphen: at the overlay's size a hyphen next to monospaced digits
        // reads as a dash in the number rather than as a sign.
        case .minus:    return "−" + body
        }
    }
}

// MARK: - The file's frame of reference

/// Everything about the CURRENT FILE that entry needs, snapshotted when entry opens.
///
/// Snapshotted rather than read live, because the arithmetic must not change under the user
/// mid-entry — and because it makes the resolve step a pure function of (entry, context) that can be
/// reasoned about without an engine in scope.
struct TimecodeContext: Equatable {
    /// EXACT rate (23.976…). Frame ↔ seconds.
    let rate: Double
    /// INTEGER rate (24). TC field grouping only. See the header note.
    let nfr: Int
    let dropFrame: Bool
    /// The file's start timecode as a frame count, or 0 when the file declares none.
    let startFrame: Int
    /// FALSE when the file has no timecode track. Entry still works — the origin is simply 0 — but
    /// the overlay says which of the two the user is typing, because they are different questions
    /// with identical-looking answers.
    let hasTimecode: Bool
    /// Index of the last decodable frame. The clamp's ceiling.
    let lastFrame: Int
    /// Where the playhead is now. The origin for a relative entry.
    let currentFrame: Int

    /// Nil when this deck cannot accept an entry: no file, no duration, or no usable rate. Callers
    /// treat nil as "do not open entry" rather than opening an entry that cannot commit.
    ///
    /// `@MainActor` because every field it reads is main-actor state on the engine. The TYPE stays
    /// unisolated on purpose — once built it is a plain snapshot of numbers, and `resolve` has to be
    /// callable (and reasonable about) anywhere.
    @MainActor
    init?(engine: FrameEngine) {
        let declared = engine.metadata?.frameRate ?? 0
        let tc = engine.tcInfo
        // Same precedence the rest of the app uses: the metadata rate is authoritative, the timecode
        // track's own rate is the fallback for a file whose video rate did not read.
        let resolved = declared > 0 ? declared : (tc?.fps ?? 0)
        guard resolved > 0, engine.duration > 0, engine.hasMedia else { return nil }
        rate = resolved
        nfr = max(Int(resolved.rounded()), 1)
        dropFrame = tc?.dropFrame ?? false
        startFrame = tc?.startFrame ?? 0
        hasTimecode = tc != nil
        lastFrame = engine.totalFrames
        currentFrame = engine.currentFrame
    }
}

extension TimecodeEntry {

    /// Which edge the result was pinned to, if any. Drives the overlay's confirmation — a clamp is
    /// the one outcome where landing somewhere other than what was typed is correct, so it is also
    /// the one outcome that has to be SAID rather than left for the user to infer from a playhead.
    enum Clamp: Equatable { case start, end }

    /// The whole of the entry semantics: digits + context → a frame index on this file's timeline.
    ///
    /// ONE PATH FOR BOTH FILES WITH AND WITHOUT TIMECODE. The only difference is the origin —
    /// `startFrame` for a file that declares one, 0 for a file that does not — which is why the
    /// syntax needs no mode and the user needs to learn nothing extra. The overlay still tells them
    /// which they are looking at, because "01:00:00:00" means something different in the two cases.
    func resolve(in ctx: TimecodeContext) -> (frame: Int, clamp: Clamp?) {
        let wanted: Int
        switch sign {
        case .plus:  wanted = ctx.currentFrame + frameCount(nfr: ctx.nfr)
        case .minus: wanted = ctx.currentFrame - frameCount(nfr: ctx.nfr)
        case .absolute:
            var (h, m, s, f) = fields(nfr: ctx.nfr)
            // ── ⚠️ DROP-FRAME HAS LABELS THAT ARE NOT TIMES ─────────────────────────────────
            //
            // At 29.97 DF the labels `MM:00;00` and `MM:00;01` do not exist for any minute that is
            // not a multiple of ten — that skipping IS drop-frame. They are still eight digits
            // somebody can type, and `TimecodeReader.parse` will happily run its inverse over them
            // and hand back a frame two BEFORE the minute (00:01:00;00 resolves to 1798, which is
            // labelled 00:00:59;28). Landing two frames earlier than the minute you typed reads as
            // an off-by-two bug, and it breaks the promise the whole feature rests on: type what
            // you see, land there.
            //
            // So an illegal label clamps FORWARD to the first frame that minute actually has. It is
            // the same principle as the start/end clamp — an unreachable request resolves to the
            // nearest reachable one — and it is deliberately silent, because unlike the bounds
            // clamp the user has not asked for somewhere outside the file. They have named a minute
            // that exists; only the frame within it does not, and `;02` IS that minute's start.
            if ctx.hasTimecode, ctx.dropFrame, s == 0, m % 10 != 0 {
                let dropped = TimecodeReader.droppedFramesPerMinute(fps: ctx.rate)
                if f < dropped { f = dropped }
            }
            if ctx.hasTimecode {
                // Round-trip through the SAME reader the file was loaded with, so the drop-frame
                // inverse is the one already proven against real media rather than a second copy of
                // that arithmetic living here. Building the canonical string first is what lets a
                // normalized entry (`75` → 3s 3f) reach it in the form it expects.
                let label = String(format: "%02d:%02d:%02d%@%02d",
                                   h, m, s, ctx.dropFrame ? ";" : ":", f)
                let absolute = TimecodeReader.parse(timecode: label, fps: ctx.rate)?.startFrame
                    ?? ((h * 60 + m) * 60 + s) * ctx.nfr + f
                // The typed value is a position on the SOURCE's timecode; the engine seeks on the
                // FILE's timeline, which starts at frame 0. An entry earlier than the file's start
                // timecode therefore goes negative here and clamps to the first frame below —
                // "before the beginning of this file" has exactly one sensible destination.
                wanted = absolute - ctx.startFrame
            } else {
                wanted = ((h * 60 + m) * 60 + s) * ctx.nfr + f
            }
        }
        if wanted < 0 { return (0, .start) }
        if wanted > ctx.lastFrame { return (ctx.lastFrame, .end) }
        return (wanted, nil)
    }
}

// MARK: - 2. The transport keys

/// PER-WINDOW KEYBOARD TRANSPORT: timecode entry's modal state, and the frame and edge seeks the transport
/// shortcuts ask for.
///
/// ⚠️ IT NO LONGER READS KEYSTROKES ITSELF. Until the shortcut registry (docs/SHORTCUTS_AUDIT.md §4.4) this class
/// ran its own `NSEvent` monitor, for two reasons that still hold and now apply to every key: a monitor can
/// DECLINE a keystroke (a digit typed into a text field must reach the field; a hidden `.keyboardShortcut` button
/// would have swallowed it, because key equivalents are dispatched before the first responder sees the key), and
/// it can read EXACT modifier flags (AppKit's key-equivalent matcher cannot tell ⇧← from ←, audit C7). Both are
/// now `ShortcutCenter`'s one monitor and the registry's `KeyDispatcher`, which hands this class the keys that are
/// entry's (`entryKey`, `openKey`) and calls its seeks through the window's shortcut handlers. The name is kept:
/// it is still the window's keyboard transport, and ContentView names it in a dozen places.
///
/// Owned by `ContentView` as a `@StateObject`, like `WindowChrome` and for the same reason — two
/// windows are two decks, and an entry in one must not appear in or seek the other.
@MainActor
final class TransportKeyMonitor: ObservableObject {

    /// Entry is open and the overlay is up. While true, the dispatcher gives every bare key to `entryKey`, so
    /// nothing moves behind the overlay.
    @Published private(set) var isActive = false

    /// What has been typed so far. Rendered by the overlay every keystroke.
    @Published private(set) var entry = TimecodeEntry()

    /// The file's frame of reference, snapshotted at open. Nil while inactive.
    @Published private(set) var context: TimecodeContext?

    /// Held briefly after a commit that CLAMPED, so the user is told rather than left to work out
    /// why the playhead is not where they typed. Nil after an exact landing — a commit that did what
    /// it was asked needs no announcement.
    @Published private(set) var clampNotice: ClampNotice?

    struct ClampNotice: Equatable {
        /// Where it actually landed, formatted the same way the readout formats it.
        let landed: String
        let message: String
    }

    private weak var deck: WindowDeck?
    private weak var engine: FrameEngine?
    private var noticeTask: Task<Void, Never>?

    /// How long a clamp notice stays up. Long enough to read six words, short enough that it is gone
    /// before the user has finished looking at the frame they landed on.
    private static let noticeDuration: Duration = .milliseconds(1400)

    // MARK: Wiring

    /// Called from `ContentView.onAppear`. Idempotent.
    func attach(deck: WindowDeck, engine: FrameEngine) {
        self.deck = deck
        self.engine = engine
        deck.transportKeys = self
    }

    /// Called from `ContentView.onDisappear`: a closed window's entry must not stay open.
    func detach() {
        noticeTask?.cancel()
        cancel()
    }

    // MARK: Keys the dispatcher hands over

    /// Entry is open: Return / Enter commit, Esc cancels, Delete removes a digit, digits and signs type.
    /// ⚠️ EVERYTHING ELSE BARE IS SWALLOWED, and that is deliberate: with the overlay up, Space, J/K/L, D, N and the
    /// arrows would all act on the picture behind it. ⎋ and ⏎ are the two ways out.
    func entryKey(_ event: KeyEvent) -> Bool {
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.keypadEnter: commit(); return true
        case KeyCode.escape: cancel(); return true
        case KeyCode.delete, KeyCode.forwardDelete: backspace(); return true
        default: break
        }
        if let digit = Self.digit(in: event.characters) { append(digit); return true }
        if Self.isPlus(event.characters) { setSign(.plus); return true }
        if Self.isMinus(event.characters) { setSign(.minus); return true }
        return true
    }

    /// Entry is closed: a digit, + or − opens it, when this deck can accept one (`begin` answers false for an empty
    /// or gated window, and the key then falls through as it always has).
    func openKey(_ event: KeyEvent) -> Bool {
        if let digit = Self.digit(in: event.characters), begin(sign: .absolute) { append(digit); return true }
        if Self.isPlus(event.characters), begin(sign: .plus) { return true }
        if Self.isMinus(event.characters), begin(sign: .minus) { return true }
        return false
    }

    private static func digit(in characters: String) -> Int? {
        guard characters.count == 1, let scalar = characters.unicodeScalars.first,
              ("0"..."9").contains(Character(scalar)) else { return nil }
        return Int(String(scalar))
    }

    /// `=` is accepted as `+` because the plus on a US layout is shifted and every NLE that has ever
    /// had timecode entry accepts the unshifted key for it. `_` likewise for `−`.
    private static func isPlus(_ characters: String) -> Bool { characters == "+" || characters == "=" }
    private static func isMinus(_ characters: String) -> Bool { characters == "-" || characters == "_" }

    // MARK: Seeks the transport shortcuts ask for

    /// The same gate every position control carries: a deck that does not hold the transport may not move a
    /// playhead, and a deck showing a LIVE SOURCE has none (NDI/WHEP/SRT push straight at the renderer and never
    /// load the engine). Not gated on `hasMedia`: `stepFrame` is a safe no-op with no duration, so an arrow in an
    /// empty window stays silent rather than beeping, as it always has.
    var canMovePlayhead: Bool {
        deck?.gate.transportEnabled == true && deck?.gate.positionControlsEnabled == true
    }

    /// ⇧← / ⇧→: ONE SECOND, COMPUTED FROM THE FILE'S RATE, not a fixed frame count (decision 5, 2026-10-23,
    /// matching DaVinci Resolve R20 p728). A second is a unit a colourist thinks in and it is the same distance at
    /// 24 and at 60.
    ///
    /// `round(rate)` — the INTEGER rate — and not the exact one, deliberately: at 23.976 that is 24
    /// frames, which advances the TIMECODE READOUT by exactly one second and the wall clock by
    /// 1.001 s. The readout is what the user is watching, so the digits are what should come out
    /// round. Same nfr-vs-exact split this file states in full at the top.
    var framesPerSecondStep: Int {
        let rate = engine?.metadata?.frameRate ?? 0
        return max(Int((rate > 0 ? rate : 24).rounded()), 1)
    }

    /// Home / End: the first or the last frame, by the same quarter-frame landing `commit` uses (see there).
    func goToEdge(end: Bool) {
        guard let engine, let ctx = TimecodeContext(engine: engine) else { return }
        let frame = end ? ctx.lastFrame : 0
        engine.exactSeek(to: min(max((Double(frame) + 0.25) / ctx.rate, 0), engine.duration))
    }

    // MARK: State transitions

    /// Open entry. False — and no state change — when this deck has nothing to seek in, or when the
    /// gate says it may not seek. False is what makes the keystroke fall through to the system
    /// exactly as it did before this feature existed.
    @discardableResult
    func begin(sign: TimecodeEntry.Sign = .absolute) -> Bool {
        // ── THE GATE, AND IT WAS MISSING ON THIS ROUTE ────────────────────────────────────────
        //
        // Entry IS a seek, so it is a position control and carries the same pair `arrowStep` does:
        // a deck that does not hold the transport may not move a playhead, and a deck showing a
        // live source has no playhead to move. There are two ways in and only one of them asked.
        // ContentView's CLICK route guards itself (`if position { transportKeys.begin() }`); the
        // TYPE-TO-ENTER route in `handle` called straight through, so a digit typed into a gated
        // window opened the overlay, PAUSED the engine and seeked on ⏎ — the one control in the
        // 0.6.2 set that was never actually gated, in a window whose banner says the transport is
        // somewhere else.
        //
        // ⚠️ ASKED HERE AND NOT AT THE CALL SITES. This is the funnel both routes already share,
        // and it is the funnel that PAUSES — a gate at the call sites would have to be repeated
        // and could drift, whereas a `false` from here cannot open entry by any path.
        guard deck?.gate.transportEnabled == true,
              deck?.gate.positionControlsEnabled == true else { return false }
        // Asked BEFORE the pause and answered again after it: a deck that cannot accept an entry
        // must not have its playback stopped by a stray keystroke.
        guard let engine, TimecodeContext(engine: engine) != nil else { return false }
        // OPENING ENTRY PAUSES. Typing a destination while the picture runs means committing to a
        // frame that has already gone past by the time ⏎ lands, and it means a relative entry's
        // origin is stale the moment it is snapshotted. Resuming is left to the user: after a seek
        // you are looking at a frame, and the tool's job is to stop there rather than to guess that
        // you wanted motion again.
        if engine.isPlaying { engine.pause() }
        // ⚠️ SNAPSHOT AFTER THE PAUSE, NOT BEFORE. `currentFrame` is the origin every relative entry
        // is measured from, so it has to be the frame the picture actually STOPPED on.
        guard let ctx = TimecodeContext(engine: engine) else { return false }
        noticeTask?.cancel()
        clampNotice = nil
        context = ctx
        entry = TimecodeEntry(sign: sign)
        isActive = true
        return true
    }

    func append(_ digit: Int) { entry.append(digit) }
    func backspace() { entry.backspace() }
    func setSign(_ sign: TimecodeEntry.Sign) { entry.sign = sign }

    /// ⎋ — the playhead does not move. Nothing was seeked on the way in (the pause is not a seek), so
    /// there is nothing to undo.
    func cancel() {
        isActive = false
        entry = TimecodeEntry()
        context = nil
    }

    /// ⏎ — resolve, clamp, seek.
    func commit() {
        defer {
            isActive = false
            entry = TimecodeEntry()
            context = nil
        }
        guard let engine, let ctx = context else { return }
        // An empty entry is a no-op rather than a seek to frame 0: ⏎ on nothing typed means "never
        // mind", and the destructive reading of an empty field is never the one someone wanted.
        guard !entry.isEmpty else { return }

        let (frame, clamp) = entry.resolve(in: ctx)

        // ⚠️ A QUARTER OF A FRAME PAST THE BOUNDARY, NOT ON IT. `beginReading` builds its time range
        // with `CMTime(seconds:preferredTimescale: 600)`, and 600 cannot represent a 1001-based frame
        // boundary exactly — at 23.976 the rounding lands just BEFORE the intended frame's
        // presentation time, so an exact `frame / rate` can start the reader on the previous frame.
        // A quarter-frame nudge (~10 ms at 24 fps) is far inside the frame and far outside the
        // 1/600 s (1.67 ms) grid, so it always resolves to the frame that was asked for. It cannot
        // disturb the readout, which re-derives from the decoded frame's own PTS.
        let seconds = min(max((Double(frame) + 0.25) / ctx.rate, 0), engine.duration)
        engine.exactSeek(to: seconds)

        guard let clamp else { return }
        // Landing on the last frame is usually self-evident, but only if you know where the end was;
        // typing 09:00:00:00 into a ten-second clip and silently arriving at 00:00:09:23 looks like
        // the entry was misread. Say it, briefly.
        let landedFrame = ctx.startFrame + frame
        let landed = ctx.hasTimecode
            ? TimecodeReader.format(frameCount: landedFrame, nfr: ctx.nfr,
                                    fps: ctx.rate, dropFrame: ctx.dropFrame)
            : TimecodeReader.format(frameCount: frame, nfr: ctx.nfr, fps: ctx.rate, dropFrame: false)
        clampNotice = ClampNotice(
            landed: landed,
            message: clamp == .end ? "clamped to the last frame"
                                   : "clamped to the first frame")
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else { return }
            self?.clampNotice = nil
        }
    }
}

// MARK: - 3. The overlay

/// The large centred entry display. Sized to be read from the back of a grading suite, which is the
/// whole reason it is not simply an editable version of the control bar's readout: the person typing
/// a timecode is usually not the person sitting at the keyboard.
struct TimecodeEntryOverlay: View {

    let entry: TimecodeEntry
    let context: TimecodeContext
    let clampNotice: TransportKeyMonitor.ClampNotice?

    var body: some View {
        VStack(spacing: 12) {
            Text(heading)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(.white.opacity(0.55))

            Text(entry.masked(dropFrame: context.dropFrame))
                .font(.system(size: 68, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                // A narrow window must not clip the digits; shrinking is the only failure mode that
                // keeps every field visible.
                .minimumScaleFactor(0.35)

            Text(footnote)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 28)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// ⚠️ THE HEADING IS THE HONEST-METADATA PART OF THIS FEATURE. `01:00:00:00` typed into a file
    /// with a timecode track is a POSITION ON THAT TRACK; typed into a file without one it is an
    /// offset from the head of the file. The digits look identical and the destinations are not, so
    /// the overlay states which question is being answered — the same distinction the inspector
    /// makes by omitting its Start TC row.
    private var heading: String {
        if entry.isRelative { return context.hasTimecode ? "OFFSET · TIMECODE" : "OFFSET" }
        return context.hasTimecode ? "TIMECODE" : "POSITION · NO TIMECODE TRACK"
    }

    private var footnote: String {
        if entry.isRelative {
            return "⏎ go   ⎋ cancel   ·   offset from the current frame"
        }
        return context.hasTimecode
            ? "⏎ go   ⎋ cancel   ·   source timecode"
            : "⏎ go   ⎋ cancel   ·   from the start of the file"
    }
}

/// The brief "it clamped" confirmation, shown in the overlay's place after a commit that could not
/// go where it was asked. Same geometry as the entry overlay so it reads as the same object
/// resolving, not as a new one appearing.
struct TimecodeClampOverlay: View {

    let notice: TransportKeyMonitor.ClampNotice

    var body: some View {
        VStack(spacing: 12) {
            Text(notice.landed)
                .font(.system(size: 68, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
            Text(notice.message)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 28)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
