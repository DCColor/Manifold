@preconcurrency import AVFoundation

/// The AVFoundation half of the scrub seam: an `AVPlayer` used as a **decoder and never as a
/// transport** — rate 0, muted, no layer, no synchronizer — with an `AVPlayerItemVideoOutput`
/// pulled for one frame per scrub position.
///
/// Measured warm at 20 Hz across the ProRes / H.264 / HEVC corpus: **6.7–31.3 ms mean**
/// (docs/BUGS.md; harness `docs/scrub-fixtures/avpvomeas.swift`). It covers everything
/// AVFoundation can open and **nothing** in MXF, which is why the seam has a second half.
///
/// ── THE FOUR TRAPS, THREE OF WHICH RETURN A PLAUSIBLE WRONG ANSWER ────────────────────────────
///
/// All four are from `docs/scrub-fixtures/README.md`, where the harness that found them lives.
/// They are not hypothetical: each one produced a believable number before it was understood.
///
///  1. **A NON-NIL BUFFER IS NOT THE STOP CONDITION.** `copyPixelBuffer` hands back the *pre-seek*
///     frame if asked before the new one has decoded, and it is a perfectly valid buffer.
///     Accepting it reports ~0 ms for a picture that never changed. The acceptance test is a
///     **changed `itemTimeForDisplay`**, which is what `lastDisplay` below is for.
///  2. **A TOLERANCED SEEK CAN LEGITIMATELY LAND BACK ON THE DISPLAYED FRAME**, and then there is
///     no changed display time to wait for — waiting anyway would burn the whole deadline on a
///     correct outcome. The seek's own completion is the stop signal for that case, and it is
///     reported as "no new frame" (nil) rather than as a timeout. On 4K H.264 at 20 Hz this was
///     **26 of 40** positions in the harness, so it is the common path on long-GOP, not a corner.
///
///     ⚠️ MEASURED IN THE APP, AND IT IS BIGGER THAN THE HARNESS NUMBER AND NOT A DEFECT:
///     dragging the whole length of a 4K H.264 fixture issued **89** positions and delivered
///     **14** distinct frames — 75 "already on screen". Infinite tolerance snaps to the nearest
///     SYNC SAMPLE, so on long-GOP the picture tracks a drag at **GOP granularity, not frame
///     granularity**, and 14 is about the keyframe count of that file. All-intra is unaffected
///     (ProRes delivered 119 of 119 on the same drag), because there every frame is a sync
///     sample. Returning nil for those 75 is the correct outcome — presenting a frame already on
///     screen is wasted work — but *"the drag updates the picture at the measured rate"* is a
///     claim about all-intra, and any release note that states it unqualified will be wrong
///     about half the corpus. Same trap as "Property 1" in docs/BUGS.md.
///  3. **BLOCKING MAIN MAKES THE ROUTE LOOK BROKEN.** AVPlayer delivers seek completions and item
///     KVO on the **main queue**. The poll therefore runs on `pollQueue` and main is never waited
///     on; a version that polled on main would time out on every position and read as a decoder
///     that cannot keep up.
///  4. **`resident_size` CANNOT SEE THE PIXEL BUFFERS** — the decoder's `CVPixelBufferPool` is
///     IOSurface-backed and charged elsewhere. Not a correctness trap here, but it is why no
///     memory assertion is made in this file.
@MainActor
public final class AVPlayerScrubProducer: NSObject, ScrubFrameProducer {
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private var statusObservation: NSKeyValueObservation?

    /// Polling happens HERE, never on main — trap 3. Serial, so at most one poll loop exists and
    /// `closed` needs no memory barrier beyond the queue's own ordering plus the lock below.
    private let pollQueue = DispatchQueue(label: "com.graviton.manifold.scrub.avf", qos: .userInitiated)

    /// The display time of the frame most recently ACCEPTED. The whole of trap 1 is this variable:
    /// a pulled buffer is only new if its `itemTimeForDisplay` differs from this.
    private var lastDisplay = CMTime.invalid
    private let lastDisplayLock = NSLock()

    /// Read on `pollQueue`, written on main. A closed producer's in-flight poll must stop touching
    /// AVFoundation objects that are being torn down.
    private let closedLock = NSLock()
    private var _closed = false
    private var closed: Bool { closedLock.lock(); defer { closedLock.unlock() }; return _closed }

    /// Upper bound on one poll, in seconds. NOT a tuning constant for the rate — the coalescer
    /// paces on the decoder's completion, so this only bounds a decode that never lands at all
    /// (a stalled network volume). Generous against the measured 31.3 ms worst mean and the
    /// 215.6 ms worst-ever install, so it can only fire on a genuine stall.
    private let pollDeadline: Double = 0.5

    public private(set) var isReady = false
    public var onReadyChanged: (() -> Void)?

    /// ⚠️ BUILT AT LOAD, NOT LAZILY ON FIRST DRAG — and that is a measured decision, not a
    /// preference. The warm-vs-cold gap IS the install cost: 11.9–47.1 ms mean for
    /// `AVURLAsset` → `readyToPlay`, **215.6 ms worst first-ever**. A per-drag lifecycle pays it
    /// on every grab, where it is a visible stall on the first movement of the scrubber; paid at
    /// load it is invisible behind everything else a load does.
    ///
    /// Returns immediately — readiness is observed, never waited for. `pixelFormat` comes from the
    /// engine (`FrameEngine.videoPixelFormat`) so the scrub frame and the playback frame are the
    /// same decode contract by construction rather than by two constants agreeing.
    public init(url: URL, pixelFormat: OSType) {
        // A FILE option: it forces a walk an HLS playlist cannot cheaply serve, so it is only
        // asked for on file URLs. Precise timing is what makes a toleranced seek land where the
        // duration says it should.
        let opts: [String: Any] = url.isFileURL ? [AVURLAssetPreferPreciseDurationAndTimingKey: true] : [:]
        let asset = AVURLAsset(url: url, options: opts)
        item = AVPlayerItem(asset: asset)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        // A DECODER, NOT A TRANSPORT. Rate 0 keeps it off the clock entirely; the mute and the
        // stalling flag exist so it can never make a sound or wait on a buffer for a picture
        // nobody is playing.
        player.rate = 0
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        super.init()

        if item.status == .readyToPlay {
            isReady = true
        } else {
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                // KVO for an AVPlayerItem arrives on the main queue, but that is a documented
                // behaviour rather than a guarantee for every key, so the hop is explicit.
                Task { @MainActor [weak self] in
                    guard let self, !self.isReady, item.status == .readyToPlay else { return }
                    self.isReady = true
                    self.statusObservation = nil
                    self.onReadyChanged?()
                }
            }
        }
    }

    public func decode(at seconds: Double, completion: @escaping (ScrubFrame?) -> Void) {
        guard isReady, !closed else { completion(nil); return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)

        // INFINITE TOLERANCE BOTH SIDES — AVPlayer's own scrub, and QuickTime's. It is what makes
        // the seek cheap enough to do at drag rate; the price is accuracy, and the price is
        // measured: 0.5 frames on all-intra, up to 10.4 on 4K H.264. `ScrubFrame.pts` carries what
        // was actually delivered so nothing downstream has to assume it got what it asked for.
        let seekDone = SeekFlag()
        player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity) { _ in
            seekDone.set()
        }

        let t0 = CACurrentMediaTime()
        pollQueue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(nil) }; return }
            var result: ScrubFrame?
            while CACurrentMediaTime() - t0 < self.pollDeadline {
                if self.closed { break }
                let itemTime = self.player.currentTime()
                var display = CMTime.invalid
                if let pb = self.output.copyPixelBuffer(forItemTime: itemTime,
                                                        itemTimeForDisplay: &display) {
                    self.lastDisplayLock.lock()
                    let last = self.lastDisplay
                    let isNew = !last.isValid || display != last
                    if isNew { self.lastDisplay = display }
                    self.lastDisplayLock.unlock()

                    if isNew {
                        result = ScrubFrame(pixelBuffer: pb,
                                            pts: display.isNumeric ? display.seconds : .nan)
                        break
                    }
                    // TRAP 1: this is the PRE-SEEK frame. Keep waiting — unless the seek has
                    // finished, in which case the toleranced seek genuinely landed back on it
                    // (TRAP 2) and there is nothing new to wait for.
                    if seekDone.isSet { break }
                }
                usleep(150)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func close() {
        closedLock.lock(); _closed = true; closedLock.unlock()
        statusObservation = nil
        onReadyChanged = nil
        isReady = false
        // Teardown order matters and none of it blocks main. Cancelling pending seeks first stops
        // AVPlayer calling back into an item we are about to drop; removing the output stops the
        // poll loop (already bailing on `closed`) from being handed a buffer from a dying pool.
        player.rate = 0
        player.cancelPendingPrerolls()
        item.remove(output)
        player.replaceCurrentItem(with: nil)
    }
}

/// A one-way flag set from AVPlayer's completion (main) and read from `pollQueue`. `NSLock` rather
/// than a plain `Bool` because those are two different threads and a torn read here would
/// reintroduce trap 2 as an intermittent timeout.
private final class SeekFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
