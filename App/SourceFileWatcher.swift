import Foundation

/// PER-WINDOW watch on the file this deck has open: does what is on disk still match what the
/// engine last read?
///
/// ## The bug this exists for
///
/// The control bar's Refresh-metadata button re-reads the current file (`FrameEngine.reinspect`).
/// That is only ever USEFUL after the file has changed underneath us — typically a Flip round-trip
/// — and in every other case the correct outcome is that nothing visibly happens. A tester pressed
/// it on an unchanged file, saw nothing, and reported the button as broken. The button was fine;
/// it had no way to say "there is something here for you".
///
/// So this class supplies the missing half: a per-window flag the button tints itself from. The
/// button keeps working exactly as it did.
///
/// ## What it deliberately does NOT do
///
/// ⚠️ IT NEVER RELOADS ON ITS OWN, and that is a product rule, not an omission. Manifold is a
/// reference tool: someone is judging the frame on screen. Swapping that frame because a
/// background process rewrote the file would replace the thing being judged mid-judgement, with no
/// way to tell what changed or to get the old picture back. **The highlight is information; the
/// press is the decision.** Do not add an auto-reload path here, and do not add a preference for
/// one without settling what happens to a colourist mid-shot.
///
/// ## Polling, not a file-descriptor watch
///
/// The obvious alternative is `DispatchSource.makeFileSystemObjectSource` on an open descriptor.
/// It is rejected here for a reason that is fatal rather than aesthetic: **a descriptor watch
/// follows the INODE, not the path.** The dominant way a well-behaved editor "modifies" a file is
/// to write a temporary alongside it and `rename(2)` it into place — atomic-save, which is what
/// `NSData.write(options: .atomic)` and most Foundation/AVFoundation writers do. After that rename
/// the path holds a NEW inode; the old one is unlinked but still open by us, so the source reports
/// `.delete` (if we asked for it) and then goes permanently silent while the file at the path keeps
/// changing. Getting that right means handling `.delete`/`.rename` by tearing the source down and
/// re-opening the path, with a retry for the window where the path briefly does not exist —
/// i.e. re-implementing polling, badly, on top of a mechanism that also pins an open file
/// descriptor per window and pins the unlinked inode's disk blocks for as long as we hold it.
///
/// Polling has none of that structure to get wrong: it asks about the PATH every time, so a
/// replaced file, a modified file, a deleted file and a vanished network volume are all the same
/// question with different answers.
///
/// WHAT IT COSTS: one `stat(2)`-equivalent every `interval` seconds per window that has a file
/// open, and none at all while the flag is already lit (`poll()` returns early) or while the window
/// is showing a live source. That is not a measurable load — a `stat` on a local volume is
/// microseconds, and the timer carries generous leeway so it coalesces with other wakeups rather
/// than forcing its own. It is NOT run on the main actor, though: on a stalled network mount a
/// single `stat` can block for seconds, and blocking the main thread to answer "has this changed
/// yet?" would be a far worse bug than the one being fixed.
///
/// LATENCY IS THE PRICE: a change is noticed up to `interval` seconds late. For the case this
/// serves — switch to Flip, edit, save, switch back — two seconds is invisible.
///
/// ## ⚠️ WHAT THIS STRUCTURALLY CANNOT SEE — AND WHY THE BUTTON HAS A SECOND REASON TO LIGHT
///
/// A fingerprint of (mtime, size, inode) cannot see a write that edits IN PLACE, keeps the LENGTH
/// and then RESTORES THE MODIFICATION DATE. That is not a hypothetical: it is exactly what Flip
/// does on every in-place write (`preserveMtime` in its patch.js; the trailing `utimesSync` in
/// writeMoovBack, which is the colour-tag path this feature exists for). It is DELIBERATE on
/// Flip's side and not a defect — a metadata edit is not a content change, and a master's
/// modification date carries facility information that a colour-tag correction has no business
/// resetting. Flip's own scan.js documents the same limit against itself, in as many words.
///
/// ⚠️ `st_ctime` IS THE OBVIOUS FOURTH FIELD AND IT IS NOT A WAY OUT. `utimes(2)` bumps it and it
/// cannot be forged, so on a local APFS volume it does catch the write. MEASURED 2026-08-29 across
/// this machine's SMB mounts: on one server it moves, and on another smbfs reports ctime as a
/// MIRROR of mtime — identical before and after — so restoring the mtime restores the ctime with
/// it and the write is invisible again. A field that works on one customer's NAS and fails
/// silently on the next cannot carry a feature. There is no better fingerprint; content hashing
/// is the only thing left and a 40 GB master every two seconds is not a trade anyone wants.
///
/// SO THE HIGHLIGHT HAS TWO INDEPENDENT REASONS, not one. This class supplies the OBSERVED one.
/// The INFERRED one — `sentForEditing`, armed by the Edit in Flip press — covers precisely the
/// case above. See `docs/BUGS.md`, "the Refresh highlight cannot see a Flip edit".
///
/// ## ⚠️ THE COMMIT MESSAGE THAT INTRODUCED THIS FILE IS WRONG. DO NOT GO LOOKING
///
/// `ebb23bf` is titled "…2s polling on mtime/size/fileID **with alias re-resolution across atomic
/// replaces**". THERE IS NO ALIAS OR BOOKMARK RESOLUTION in that commit, in this file, or anywhere
/// this feature touches — `grep -i 'alias\|bookmark'` over the whole diff hits nothing but an
/// unrelated stream-bookmarks sheet. The message describes a design that did not ship. The
/// atomic-replace case is handled by re-stat'ing the PATH every tick, which needs no alias
/// machinery at all (see the section above). The commit is published and its message cannot be
/// rewritten, so the correction lives here, where someone who read that line will land.
@MainActor
final class SourceFileWatcher: ObservableObject {

    /// THE FILE ON DISK DIFFERS FROM WHAT THE ENGINE LAST READ. Drives the reload button's tint and
    /// tooltip; nothing else reads it, and nothing acts on it.
    ///
    /// Set REGARDLESS OF WHETHER THIS WINDOW IS FRONTMOST — that is the point. A Flip round-trip
    /// happens while Manifold is in the background, and the whole value of the signal is that it is
    /// already lit when you switch back. Polling gives this for free; it does not consult
    /// `NSApp.isActive` or the window's key state anywhere.
    ///
    /// This is the OBSERVED reason the button lights — a reading of the file differs from the one
    /// the engine took. Compare `sentForEditing`, which is inferred.
    @Published private(set) var changedOnDisk = false

    /// THE USER SENT THIS FILE SOMEWHERE THAT MIGHT CHANGE IT. Armed by the Edit in Flip press,
    /// which is the one write this class structurally cannot see (see the type comment).
    ///
    /// The inference: nobody opens a file in Flip to LOOK at it — Manifold already shows the
    /// metadata — so the press is strong evidence of intent to modify. Strong, but still evidence
    /// about the USER and not about the file.
    ///
    /// ⚠️ IT DOES NOT COLLAPSE INTO `changedOnDisk`, AND THE REASON IS THE TOOLTIP. One is a thing
    /// we measured; the other is a thing we guessed from a button press, and no reading of the file
    /// supports it. The button has to be able to say WHICH ONE IT IS HOLDING — "this file changed
    /// on disk" is a claim we can defend, and making that sentence cover a press we merely watched
    /// the user make would have the control asserting something we do not know. Collapse the two
    /// and the tooltip must pick a single wording that is either too strong for the inferred case
    /// or too weak for the observed one. Two flags, one highlight, two sentences.
    ///
    /// DELIBERATELY NOT NAMED FOR FLIP. This layer knows about a path and a file; which application
    /// the user sent it to is the BUTTON's business, and the Flip-specific wording lives there.
    /// Anything that opens the file for editing can arm this.
    @Published private(set) var sentForEditing = false

    /// EITHER REASON LIGHTS THE BUTTON, in the same green.
    ///
    /// ONE COLOUR ON PURPOSE. Green already means "there is something waiting for you" on this
    /// control (see the button), and both reasons are true instances of that — there is a reason to
    /// press it, and the press is safe either way. A second tint to carry the confidence difference
    /// was rejected: in a twelve-button row a new colour reads as a THIRD STATE OF THE FIRST
    /// MEANING rather than as a new meaning, which is a worse error than the one it would fix. The
    /// two reasons are distinguished by the TOOLTIP, where `changedOnDisk` wins, because an
    /// observation beats an inference.
    var isHighlighted: Bool { changedOnDisk || sentForEditing }

    /// How often the path is re-examined. See the cost note in the type comment.
    static let interval: Double = 2.0

    /// The path being watched, or nil for "this window has no file" (empty deck, or a live source —
    /// `FrameEngine.currentURL` is nil for both). Nil means the timer is not running at all.
    private var url: URL?

    /// What the file looked like when the engine last read it. Nil means "not established yet": the
    /// next fingerprint to land is ADOPTED rather than compared, which is what makes `rebaseline()`
    /// a two-line operation. See `apply`.
    private var baseline: Fingerprint?

    /// Monotonic counter, same device as `FrameEngine.loadGeneration` and for the same reason: a
    /// fingerprint read is an async hop off and back onto the main actor, so a result can land after
    /// the window has moved to a different file — or after a rebaseline that must not be undone by
    /// a measurement taken before it. Each read carries the generation it was started for and is
    /// discarded if that is no longer current.
    private var generation = 0

    private var timer: DispatchSourceTimer?

    // MARK: - Entry points

    /// Point the watcher at a file (or at nothing). Called from the deck's `currentURL` observer.
    /// Re-baselines unconditionally, including when handed the URL it already has — "the engine has
    /// just read this file" is exactly what a load means.
    func watch(_ url: URL?) {
        self.url = url
        rebaseline()
    }

    /// THE SECOND REASON TO LIGHT: this window has just handed the file to an external editor.
    ///
    /// Cleared by the same `rebaseline()` that clears every other reason — a read is a read,
    /// whatever prompted it — and by nothing else. In particular it does NOT expire: see the note
    /// on `rebaseline`.
    ///
    /// ⚠️ DOES NOT STOP THE POLL. See the guard in `poll`: a window lit only for this reason keeps
    /// taking readings, so a write the fingerprint CAN see upgrades the claim from inferred to
    /// observed on the next tick and the tooltip stops hedging.
    ///
    /// Guarded on having a file at all: with no file there is nothing to reload, and the button
    /// that reads this is disabled anyway.
    func noteSentForEditing() {
        guard url != nil else { return }
        sentForEditing = true
    }

    /// ADOPT WHATEVER IS ON DISK NOW AS THE NEW TRUTH, and clear the highlight.
    ///
    /// Called when the engine reads the file: the reload button's own press, and any load that
    /// publishes fresh metadata (which is how re-opening the SAME path — a second drag of the same
    /// file onto the window — clears the highlight, since `currentURL` does not change and the
    /// observer above never fires).
    ///
    /// ⚠️ THE BASELINE IS TAKEN AT PRESS TIME, BEFORE the reload has finished reading. If the file
    /// is rewritten again DURING the reload, the fingerprint we adopt is older than what the reload
    /// actually got and the button lights up again a moment later. That is the correct direction to
    /// be wrong in: a spurious "there might be something newer" costs one extra press, while the
    /// opposite error — adopting a fingerprint newer than what was read — would leave the deck
    /// silently showing stale metadata with an unlit button, which is the reported bug again.
    /// ⚠️ A READ IS THE ONLY THING THAT CLEARS EITHER REASON, AND NOTHING EXPIRES. Send a file to
    /// Flip, change your mind and never save, and the highlight stands until you press the button —
    /// which re-reads, finds nothing new, and goes dark. That costs ONE PRESS, and it is the same
    /// trade the ⚠️ below already makes: a spurious "there might be something newer" is cheap,
    /// while going dark on a file that did change is the reported bug again. A TIMEOUT would be a
    /// guess about how long someone spends in Flip — a colourist can leave a file open there over
    /// lunch — and one that expires before the save fails silently, in exactly the way this feature
    /// exists to prevent. Clearing when Flip quits is backwards (that is when the hint is most
    /// wanted) and clearing when Manifold becomes key contradicts the whole point of the signal
    /// (see `changedOnDisk`). It is a standing suggestion, cleared by acting on it.
    func rebaseline() {
        generation &+= 1
        baseline = nil
        changedOnDisk = false
        // Both reasons, together: whatever lit the button, the engine has now read the file and the
        // question the highlight was asking has been answered.
        sentForEditing = false
        guard url != nil else {
            timer?.cancel()
            timer = nil
            return
        }
        startTimer()
        // Establish the baseline now rather than waiting up to `interval` for the first tick —
        // otherwise a file rewritten in the first two seconds after a load would be adopted as the
        // baseline and never reported.
        poll()
    }

    // MARK: - The poll

    private func startTimer() {
        guard timer == nil else { return }
        // Main queue, so the handler is already where the state lives; the STAT itself is the part
        // that must not run here, and it does not (see `poll`). A dispatch timer rather than a
        // `Timer`: it fires regardless of run-loop mode, so a menu tracking loop or a live window
        // resize does not stall the watch.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.interval,
                   repeating: Self.interval,
                   leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.resume()
        timer = t
    }

    private func poll() {
        guard let url else { return }
        // ALREADY OBSERVED TO HAVE CHANGED — nothing a further reading could tell us changes the
        // display, and the press re-baselines from a fresh reading anyway. So the steady-state cost
        // of a window sitting on a changed file is zero.
        //
        // ⚠️ GUARDED ON `changedOnDisk` ALONE, NOT ON `isHighlighted`, AND THAT IS NOT AN OVERSIGHT.
        // A window lit only because the file was sent to an editor KEEPS POLLING: if that editor's
        // write turns out to be one the fingerprint can actually see — a MOV grow, or any writer
        // that does not restore the mtime — the next tick promotes the claim from inferred to
        // observed and the tooltip stops hedging. Adding `sentForEditing` to this guard would buy
        // one skipped `stat` and give up the only path by which the weaker claim ever strengthens.
        guard !changedOnDisk else { return }
        let g = generation
        // OFF THE MAIN ACTOR. A `stat` on a local volume is microseconds; on a network mount whose
        // server has gone away it can block for as long as the mount's timeout. The UI must not be
        // hostage to that. `apply` is main-actor isolated, so the `await` is the hop back.
        Task.detached(priority: .utility) { [weak self] in
            let fingerprint = Fingerprint(of: url)
            await self?.apply(fingerprint, generation: g)
        }
    }

    private func apply(_ fingerprint: Fingerprint?, generation g: Int) {
        guard g == generation else { return }   // superseded: different file, or a rebaseline landed
        // ⚠️ NO FINGERPRINT IS NOT A CHANGE. The file is gone, unreadable, or the volume it lives on
        // has unmounted. None of those mean "there is a newer version waiting for you", and lighting
        // the button would be an invitation to press it and get nothing (`reinspect` on a missing
        // file finds no tracks and returns). The baseline is KEPT, so if the path comes back — which
        // is precisely what the middle of an atomic save looks like, a rename with the old file
        // already unlinked — the very next reading is compared against the right thing and reports
        // the replacement. Nothing here retries faster or spins; a missing file costs one failed
        // reading per tick, the same as a present one.
        guard let fingerprint else { return }
        guard let baseline else {
            self.baseline = fingerprint
            return
        }
        if fingerprint != baseline { changedOnDisk = true }
    }

    deinit {
        // The handler holds `self` weakly, so an uncancelled timer would outlive the window and tick
        // forever against nil. Never suspended, so cancelling here cannot trip the
        // "deallocated while suspended" crash.
        timer?.cancel()
    }
}

// MARK: - What "changed" means

/// The three facts about a path that, taken together, decide whether the file behind it is the same
/// file in the same state. Each is here because one of the others misses a real case:
///
///   * **Modification date.** The primary signal, and on its own it is what catches the case this
///     feature was built for. Sub-second precision on APFS, so an in-place rewrite one tick after a
///     load is still distinguishable — a whole-second timestamp would not be, since a metadata edit
///     can land well inside the same second as the load that preceded it.
///
///   * **Size.** Cheap corroboration, and NOT sufficient by itself: ⚠️ FLIP REWRITES COLOUR TAGS IN
///     PLACE and the file usually comes back exactly the same length, because a CICP/NCLC atom is a
///     fixed-width field being overwritten rather than content being inserted. A size-only check
///     would miss the single most important case.
///
///   * **Inode (`st_ino`).** THE REPLACED-FILE CASE. Write-to-temp-then-`rename(2)` produces a
///     different file at the same path, and while that normally moves the timestamp too, a writer
///     that PRESERVES the modification date (`cp -p`, `rsync -t`, a restore from backup, a
///     round-trip through a tool that copies attributes) would otherwise look untouched. The inode
///     changes in every one of those, because it is a different file.
///
/// WHAT STILL SLIPS THROUGH: an edit that rewrites the bytes in place, keeps the length, and then
/// restores the modification date. Nothing short of hashing the content catches that, and hashing a
/// 40 GB master every two seconds is not a trade anyone wants. The button is always pressable,
/// which is the fallback for exactly this.
///
/// `st_ino` is only unique WITHIN a volume, so strictly this is (device, inode) — but the path is
/// fixed for the lifetime of a baseline, and a path that changes volume mid-watch has certainly
/// changed by every other measure here too. Not worth a fourth field.
///
/// ⚠️ FILE SCOPE, NOT NESTED IN THE @MainActor CLASS ABOVE, and that is the point: a global actor
/// on a type propagates to its nested types, and this is READ ON A BACKGROUND TASK (see `poll`).
/// Out here it carries no isolation and the read needs no exemption.
private struct Fingerprint: Equatable, Sendable {
    let modified: Date?
    let size: Int
    let inode: UInt64

    /// Read the path. Nil if it cannot be read at all — missing file, unmounted volume, no
    /// permission. Follows symlinks, which is right: the deck opened the link's target, and that is
    /// the file an editor will have rewritten.
    init?(of url: URL) {
        guard let attrs = try? FileManager.default
            .attributesOfItem(atPath: url.path(percentEncoded: false)) else { return nil }
        modified = attrs[.modificationDate] as? Date
        size     = (attrs[.size] as? NSNumber)?.intValue ?? 0
        inode    = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
