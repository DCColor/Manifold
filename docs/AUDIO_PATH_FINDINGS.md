# Manifold — the audio path: findings from the meter audit

What a single feature request turned up about where audio comes from in this app, what was
measured to establish it, and which of the resulting gaps are real. Written 2026-08-26.

Three of the four gaps are recorded as defects in `BUGS.md`; this document holds the chain that
found them and the measurements, because the measurements are what stop the same ground being
re-litigated — including two plausible-sounding claims that turned out to be false.

---

## The discovery chain — four gaps from one feature

This is the useful part. Nobody set out to audit the audio path; a display feature forced the
question and each answer exposed the next gap:

1. **A request for audio meters** forced the question *where do the samples come from?* — a meter
   has to read something, and until then nothing in the UI had ever asked the audio path for data.
2. **That found the live transports have no audio at all** (WHEP and SRT). The meters were correct
   to report "NO AUDIO TRACK"; the gap was two transports upstream that decode none.
3. **Metering a multi-track file found only one track playing.** The meter showed a single mono bar
   for a file the inspector described as "Audio (3)" — and the meter was right about playback.
4. **Auditing what SDI does with a multi-track file** found that the DeckLink path carries whatever
   track 1 happens to be, in file order, with no layout awareness and no downmix option — so the
   channel *mapping* had never been a decision at all.

Each step is the previous step's answer becoming the next step's question. A meter is an instrument
pointed at a signal path, and pointing an instrument at a path nobody had instrumented is what
found four years of accumulated assumption in one evening.

---

## Gap 1 — WHEP and SRT carry no audio (NDI does)

**Recorded in:** `BUGS.md` → *"WHEP and SRT carry no audio at all, so a remote stream cannot be
monitored or metered"*.

⚠️ **NDI is NOT in this category, and the common statement of this gap gets it wrong.** "Live
sources carry no audio" is false as stated. NDI has a complete audio path: `NDIService.startAudioPump`
runs a dedicated pump thread on connect (regardless of DeckLink), pulls via
`captureAudioFrameForMaxSamples:`, and pushes interleaved Int32 into the shared `AudioTapBuffer`
through `pushInterleavedInt32`. **NDI plays audio and meters correctly today.**

It is also not true that `FrameEngine.audioTrack` being nil explains the live gap — the live
transports do not go through `FrameEngine`'s asset path at all. The gap is per-transport:

- **WHEP** negotiates audio and then deliberately discards it. The offer carries
  `m=audio 9 UDP/TLS/RTP/SAVPF 111` / `a=rtpmap:111 opus/48000/2`, so the server is presumably
  sending Opus; the track's message callback is `ManifoldWHEPDiscardMessage`.
- **SRT** identifies audio elementary streams at demux and skips them, logging the reason:
  `"stream %u: %s / %s (ignored — audio is a later arc)"` (`SRTSession.m`).

**Each transport needs its own work** — WHEP is Opus over RTP, SRT is inside the MPEG-TS mux, and
NDI (already done) has its own format. **WHEP is the priority**, because it is the path clients
actually use. Both land at the same `AudioTapBuffer` the file and NDI paths already feed, so the
meters light up with no change to meter code.

### ✅ The WHEP decoder question is SETTLED (2026-08-27): AudioToolbox, no new dependency

`kAudioFormatOpus` is one of the 51 formats `kAudioFormatProperty_DecodeFormatIDs` reports on this
machine, so `AudioConverter` decodes Opus natively. **Neither `libopus` nor a vendored-FFmpeg
rebuild is needed, and neither should be re-proposed.** Measured level-accurate to 0.1 dB against
FFmpeg's own decode over a 101-packet fixture. Implementation: `WHEPOpusDecoder` in
`App/WebRTC/WHEPAudioDecoder.swift`.

⚠️ Note for anyone re-checking this: the vendored FFmpeg **has no Opus decoder** — an earlier note
in `BUGS.md` said it did, from a `strings` hit on a codec name table that lists every codec
regardless of build config. The full correction, and the right way to test a libav capability, is
in `BUGS.md` and `ThirdParty/ffmpeg/README.md`.

---

## Gap 2 — Multi-track files play only track 1

**Recorded in:** `BUGS.md` → *"A file's second and third audio tracks are unreachable, while the
inspector reports all of them"*.

**Measured** on `/Volumes/DCCOLOR/TEST FLIP/MONO_STEREO_51.mov` (ProRes HQ 4K, 23.98p, three PCM
24-bit/48 kHz audio tracks: mono, stereo, 5.1):

```
FrameEngine: loaded — duration 5.005s, audio tracks: 3 (monitoring #1)
AudioTap[AVF]: format → 48000Hz · 1ch (→ 2ch on SDI)
```

`FrameEngine` took `loadTracks(withMediaType: .audio).first` and built one
`AVAssetReaderTrackOutput` from it. Tracks 2 and 3 were not decoded, not rendered, not tapped and
not sent to SDI. The libav path has the same shape: `LibavAudioSource.open()` scans streams and
`break`s on the first audio stream.

The defect is the app disagreeing with itself: `MediaInspector.audioTracks` enumerates the asset
directly and correctly reports "Audio (3)" while playback offers one. Of the two, the inspector is
the honest one. (Note the *inverse* asymmetry also exists and is documented on
`FrameEngine.audioPresence`: on MXF the inspector is blind and the decoder is right. Neither is
authoritative on its own.)

---

## Gap 3 — the SDI channel mapping is not a decision

**Recorded in:** `BUGS.md` → *"SDI carries the monitored track's channels discretely, with no
downmix option and no statement of the mapping"*.

### ⚠️ Two claims about this that are FALSE — both checked in code and one at runtime

These sound right, and getting them wrong points the fix in exactly the wrong direction.

**FALSE: "multichannel is downmixed to stereo via `AVAssetReaderAudioMixOutput`."**

Nothing in this app uses `AVAssetReaderAudioMixOutput`. The file path uses
`AVAssetReaderTrackOutput` (`FrameEngine.beginReading`), and `audioOutputSettings` sets
`AVNumberOfChannelsKey` from the track's **own ASBD** with a matching `AVChannelLayoutKey` — so
nothing downmixes, and nothing reorders. The DeckLink bridge's entire channel mapping is
`d[c] = s[c]` for `c` in `0..<srcChannels`, padding the remainder to the SDK-legal count with
digital silence (`DeckLinkBridge.mm`, `RenderAudioSamples`). There is no summing anywhere in the
path.

**MEASURED, to settle it.** A purpose-built file whose FIRST audio track is 5.1 (ProRes HQ 1080p,
PCM 24-bit, one 6-channel track) was loaded and the tap reported:

```
AudioTap[AVF]: format → 48000Hz · 6ch (→ 8ch on SDI)
AudioTap[AVF]: int32 interleaved · 48000Hz · 6ch · pts=0.853s
```

**Six channels, not two.** A downmix would have produced 2. Confirmed in the other direction too:
the mono track of the three-track file above produced **1ch**, which a stereo downmix could not do.

**FALSE: "`MAX_AUDIO_CHANNELS = 2` is structural in the C bridge — the ring buffer, silence
generator and frame arithmetic all assume stereo."**

There is no `MAX_AUDIO_CHANNELS` constant anywhere in the repository. The bridge is channel-count
agnostic: `m_srcScratch` is sized `maxFrames * srcChannels`, `m_outScratch` is sized
`maxFrames * dlChannels`, `scheduleSilence` clears `frames * dlChannels`, and the frame arithmetic
is per sample-frame. Six channels already reach SDI as six discrete channels; the start log has
been reporting it all along as `"source %u ch, %u padded silent"`.

### What is actually wrong

The design conclusion drawn from the false premises survives — and is stronger than the premises
were. **A stereo downmix is legitimate and often exactly what a colourist wants**: not every room
is a surround room, and a proper downmix is the right signal to send to a stereo one.

The defect is that there is **no downmix at all, no way to choose one, and no statement of what is
on the wire**. And the danger runs opposite to the intuition: a colourist in a **stereo** room
monitoring a 5.1 track over SDI hears channels 1 and 2 only — **L and R, with the centre channel,
and therefore the dialogue, absent**, because C sits discretely on SDI 3 with nothing folding it in.
That sounds plausible rather than broken, which is what makes it worse than a silent downmix would
have been.

The fix is to make the mapping a **choice** and **state which is active** — full channel count or
stereo downmix — **per destination**, because desktop and SDI may legitimately differ: Mac speakers
are stereo whatever the file is, while the SDI monitor may feed a surround room.

**The desktop half of that choice is banked separately** as *"BANKED: no stereo downmix for
multichannel tracks, on either destination"* in `BUGS.md`, raised once the track selector made
choosing a 5.1 track possible. It carries the 5.1/7.1 role requirements, what to do with a file
that declares no roles, and — importantly — an unverified premise worth settling first: whether
CoreAudio's output unit is ALREADY folding multichannel to a stereo device, which would make the
desktop half a control feature rather than a defect.

### Channel ORDER, and why phase 2 is gated on it

Nothing in `AudioTapBuffer`, `DeckLinkService` or `DeckLinkBridge.mm` reads an `AudioChannelLayout`
— `AudioTapBuffer.Format` carries `sampleRate`, `channelCount`, `deckLinkChannelCount`, `path` and
no roles. So channels go to the wire in file order. **5.1 SMPTE is `L R C LFE Ls Rs`; 5.1 Film is
`L C R Ls Rs LFE`.** A Film-ordered file therefore puts **C on SDI 2** (read as R) and **LFE on
SDI 6** (read as Rs) — the centre channel in a surround speaker. SMPTE order happens to be correct,
which is why this has not bitten yet.

**The desktop path is not affected by this**, and the asymmetry is worth understanding: the
renderer receives buffers carrying the source's `AVChannelLayoutKey` and **CoreAudio does the
role→speaker mapping**. The same buffer is mapped correctly to the Mac's output and written blind
to SDI. The tap is where the roles are dropped.

---

## Gap 4 — the `chan` atom work is mostly already done

**Recorded here** rather than in `BUGS.md`, because the thing usually described as the bug is not
one — it is a stale source comment.

The commonly-cited item is *"the inspector maps channel COUNT to a layout name rather than reading
the chan atom's per-channel descriptions — a 4-channel file reports Quad whatever it declares"*.
**That has already been fixed.** `MediaInspector.channelRoles(from:)` walks
`kAudioChannelLayoutTag_UseChannelDescriptions` per-channel descriptions properly — with a correct
`MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)` flexible-array-member offset
and a bounds check against the reported size — and falls back to known tags via `roleSequence`.
`layoutName(forRoles:)` then maps the role **sequence** to a name, distinguishing exactly the case
that matters:

```swift
"L R C LFE Ls Rs": "5.1 SMPTE",
"L C R Ls Rs LFE": "5.1 Film",
```

And `inferredLayoutName(forChannels:)` returns **nil for 4 channels**, deliberately refusing to
guess ambiguous counts — so a 4-channel file does not report "Quad". Count-derived names survive
only at tier 2, only for counts 1/2/6/8, and are marked `(inferred)` and italicised in the UI so a
guess never reads as a fact.

**Ready-to-do items, in order of size:**

1. **Correct the stale comment** at `App/AudioMeterScope.swift` (the note above the channel-number
   label claiming a 4-channel file reports "Quad" whatever it declares). The meter's per-channel
   role labels are currently blocked by a bug that no longer exists.
2. **Publish the derivation for phase 2.** `channelRoles(from:)` is `private` and terminates in a
   display string. Phase 2 needs it public, the role array carried on `AudioTapBuffer.Format`, and
   `d[c] = s[c]` replaced with a role→wire-index table. **The derivation does not need writing —
   only plumbing.**
3. **Widen the role coverage, which the downmix work needs and the inspector benefits from now.**
   Two specific gaps found 2026-08-27 while scoping the downmix: `roleSequence(forTag:)` handles
   only five tags — for 7.1, ONLY `MPEG_7_1_C`, so `AudioUnit_7_1`, `MPEG_7_1_A/B`, `DTS_7_1`,
   `EAC3_7_1_A`, the ITU variants and the height layouts all yield no roles at all; and
   `channelRoles(from:)` discards `kAudioChannelLayoutTag_UseChannelBitmap` entirely, though
   `mChannelBitmap` is fully role-bearing and distinguishes side from back surrounds by separate
   bits. The bitmap camp is the cheaper of the two and widens coverage before any tag-table work.
4. **Query the card.** The app never reads `IDeckLinkProfileAttributes` /
   `BMDDeckLinkMaximumAudioChannels`, so a too-wide `EnableAudioOutput` aborts the entire output
   start rather than degrading. It also passes `bmdVideoConnectionUnspecified`, so it cannot tell
   SDI (up to 16 channels) from HDMI (up to 8).

**Undeclared files stay unfixable and must be labelled, not guessed:** a 6-channel track with no
`chan` atom yields no roles, gets `"5.1 (inferred)"` from the count alone, and can only honestly be
sent in source order.

---

## Test material

- `/Volumes/DCCOLOR/TEST FLIP/MONO_STEREO_51.mov` — ProRes HQ 3840×2160 23.98p, three PCM
  24-bit/48 kHz audio tracks: mono, stereo, 5.1. The file that exposed gaps 2 and 3.
- A 5.1-first file is trivial to regenerate and is what settles the downmix question, because
  track 1 of the file above is mono:

  ```
  ffmpeg -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=4" \
         -f lavfi -i "sine=frequency=440:duration=4:sample_rate=48000" \
         -filter_complex "[1:a]aformat=channel_layouts=5.1[a51]" \
         -map 0:v -map "[a51]" -c:v prores_ks -profile:v 3 -c:a pcm_s24le FIRST_IS_51.mov
  ```

**How to read the audio path at runtime:** `AudioTapBuffer` logs its established format on the
first buffer and periodically thereafter — `AudioTap[AVF]: format → 48000Hz · 6ch (→ 8ch on SDI)`.
That one line states the decoded channel count and the padded SDI count, and it is the fastest way
to check what the path is actually carrying without instrumenting anything.
