# Audio sync on live streams

> **DRAFT, 2026-10-05.** User guide section. Every figure here comes from
> `AUDIO_RESAMPLER_DESIGN.md` §19 (19.1–19.14) and `BUGS.md`. "Notes for the editor" at the end lists
> the claims still waiting on a measurement, and the screenshots needed.

---

## 1. Why sound and picture can be out of sync on a live stream

A live stream passes through three hands before it reaches Manifold:

- **The sender.** The encoder that makes the stream (OBS, a hardware encoder, an NDI source). It
  stamps sound and picture with times. Many senders stamp them slightly apart, and the amount changes
  with the sender's settings.
- **The server.** The service that relays the stream (Cloudflare Stream, MediaMTX). Some servers add
  an offset of their own.
- **The network.** It delays sound and picture, but it does not change the times they are stamped
  with.

Manifold plays sound and picture exactly as the stream stamps them, and it holds them steady once
playing. It does not guess at a sender's or a server's offset, and it never corrects one for you.

If the stream arrives with its sound early or late, Manifold plays it early or late. The only way to
know by how much is to measure it, with a clip made for the job. That is what calibration does
(section 3). The result goes into the **audio offset** (section 2).

---

## 2. The audio offset

The audio offset moves the sound against the picture for the stream you are watching.

- **Positive = sound later.** +40 ms plays the sound 40 ms later than the stream says.
- **Negative = sound earlier.** −40 ms plays it 40 ms earlier.
- **Range: −250 to +500 ms.**

A change takes effect at once, with no gap or click in the sound.

### Where to find it

While a stream is playing, the control bar has an **A/V** menu.

[Screenshot: the A/V menu open on a live stream — stageD/M01-av-menu.png]

| Menu item | What it does |
|---|---|
| Sound later +1 ms (⌥]) | Moves the sound 1 ms later |
| Sound earlier −1 ms (⌥[) | Moves the sound 1 ms earlier |
| Sound later +10 ms (⇧⌥]) | Moves the sound 10 ms later |
| Sound earlier −10 ms (⇧⌥[) | Moves the sound 10 ms earlier |
| Reset to 0 ms | Removes the offset |
| Save +40 ms to "*stream name*" | Stores the current offset with the saved stream |
| Revert to Saved (+0 ms) | Goes back to the stored value |
| Calibrate… | Opens calibration (section 3) |
| Save Sync Clip… | Saves a sync clip to disk (section 4) |
| Download ProRes Sync Clips… | Opens the download page for the full-quality clips (section 4) |

### Nudging with the keyboard

1. Click the video window so it is in front.
2. Press **⌥]** to move the sound 1 ms later, or **⌥[** to move it 1 ms earlier.
3. Add **⇧** to move it 10 ms at a time.

The keys are the two bracket keys to the right of P on a US keyboard. On other layouts, use the keys
in that same position. The keys do nothing while you are typing in a text field. Holding a key down
repeats it.

### Knowing an offset is on

Whenever the offset is not 0:

- a cyan **A/V +40 ms** badge sits in the control bar;
- the window title ends with **— A/V +40 ms**.

Nothing is drawn over the picture.

[Screenshot: the control bar badge and the window title with an offset of +80 ms — stageB/A02-whep-plus80.png]

**Known limits:**
- The control bar hides itself a few seconds after you stop moving the pointer, and the badge hides
  with it. The window title keeps showing the offset.
- In full screen there is no window title, so nothing shows that an offset is on.

### Saving an offset with a saved stream

An offset you set while connected lasts until you disconnect. To keep it:

1. Set the offset (by keyboard, by the menu, or by calibration).
2. Choose **A/V ▸ Save +40 ms to "*stream name*"**.

The next time you connect to that stream, Manifold starts with the saved value.
**Revert to Saved** goes back to the saved value if you have nudged away from it. Both items are
greyed out when the current offset already matches the saved one.

Save a value only on a stream whose offset is the same each time you connect. On WebRTC (WHEP)
streams from Cloudflare and MediaMTX it can change from one connection to the next (section 5), so
apply it for the session there.

You can also type a value into the **Audio offset** field when you edit a saved stream (Connect
Stream… ▸ edit). A value outside −250 to +500 ms is refused under the field, and nothing is saved.

[Screenshot: the saved-stream sheet with the Audio offset field — stageB/C01-sheet-field-mediamtx.png]
[Screenshot: the range error under the field — stageB/F01-sheet-range-error-visible.png]

**Streams with no saved entry** (an NDI source, or a URL connected without saving it): the menu reads
"Not a saved stream: this offset lasts for this connection only". The offset returns to 0 when you
disconnect.

### Why sound can only be made a little earlier on some streams

Making sound **later** always works: Manifold holds the sound back a little longer.

Making sound **earlier** means playing sound Manifold has already received, sooner. It can only do
that with sound it is already holding, and it keeps a safety margin of about 160 ms so playback never
runs dry. How much sound it holds depends on the stream:

- On some streams there is room for 200 ms or more.
- On others there is very little, or none. In our tests, Cloudflare's SRT output had no room at all,
  session after session.

When you ask for more than there is room for, Manifold refuses the whole change. The offset stays
where it was, and a banner explains:

- **"Can move sound earlier by at most 9 ms on this stream right now. It stays at −130 ms."** That much
  is available. A change of up to that amount will be accepted, including a few seconds later.
- **"Can't move sound any earlier on this stream right now — it arrives too close to when it plays."**
  There is no room at all on this stream.
- **"The audio offset can be set from −250 to +500 ms. It stays at +500 ms."** You reached the end of
  the range.

[Screenshot: the "at most N ms" banner — stageB/E01-srt-refusal-figure.png]
[Screenshot: the "can't move sound any earlier" banner — stageB/A2-02-whep-refusal-none-left.png]

If the sound needs to be earlier than Manifold can make it, correct it at the sender instead, if the
sender has its own audio sync setting.

---

## 3. Calibrating, step by step

Calibration measures how far apart sound and picture are in the stream as Manifold plays it, and
offers the offset that fixes it. **Manifold never applies a value by itself.** Nothing changes until
you press Apply.

### What you need

- A Manifold sync clip at the **same frame rate as the sender's output** (section 4).
- The sender playing that clip on a loop, with the clip's sound going into the stream.
- Manifold connected to the stream.

### Steps

1. **Get the right clip.** With the stream connected, choose **A/V ▸ Save Sync Clip…**. The panel
   names the stream's frame rate ("This stream is 23.976 fps.") and preselects the matching clip.
   Save it.
2. **Play it on the sender, on a loop.** Section 4 shows how in OBS and in DaVinci Resolve. Turn off
   any other sound source on the sender (microphones, other clips), so the stream carries only the
   clip's beeps.
3. **Let the stream settle.** Wait about a minute after connecting. A stream that has just connected
   can take up to a minute to settle. On Cloudflare's WebRTC (WHEP) output, wait about four minutes
   (section 5).
4. **Open calibration:** **A/V ▸ Calibrate…**
5. **Press Start.** Leave the clip playing, and don't touch the offset while it measures. If the
   offset changes during a run, calibration starts again ("The audio offset changed — measuring
   again.").
6. **Wait for the result.** It usually takes 15 to 60 seconds. While it works, the sheet shows:
   - **Pairs found: N of 10**: each pair is one flash matched with its beep. It needs at least 10.
   - **spread**: how much the pairs disagree. It must be less than one frame.
   - a line saying what it is waiting for (see section 6, "Calibration won't give a result").

   [Screenshot: the sheet while measuring — stageD/S2-whep5994-02-progress.png]

7. **Read the result.** The sheet says, for example:
   - **"Sound is heard 40 ms late."** (or early, or "in sync with the picture");
   - the figure measured over the last 10 pairs;
   - **"Current offset 0 ms → proposed −40 ms."**

   [Screenshot: the result, with Apply and Save offered — stageD/S2-whep5994-03-result.png]

8. **Apply it.** Choose one:
   - **Apply and Save:** applies the value now and stores it with the saved stream, for every later
     connection.
   - **Apply for Session:** applies it until you disconnect. On NDI, and on streams with no saved
     entry, this is the only choice.
   - **Cancel:** changes nothing.
   - **Measure Again:** runs another measurement without applying.
9. **Check it.** After applying, the sheet says "Start again to check: it should read close to 0 ms."
   Press **Start**. In our tests the check read within about 3 ms of 0.

   [Screenshot: the applied state — stageD/S2-whep5994-04-applied.png]
   [Screenshot: the check reading in sync — stageD/S2-whep5994-05-recheck.png]

10. **Close the sheet**, and stop the clip on the sender when you are done.

### Good to know

- **Calibration includes the offset already applied.** If an offset is on and you calibrate again,
  the proposal is the new total, not an amount to add.
- **"Not applicable."** If the fix is to make the sound earlier by more than the stream has room for
  (section 2), the sheet says so: "Not applicable: moving sound 27 ms earlier needs more of the stream
  buffered than it has. At most 0 ms is available on this stream right now." Apply is greyed out. The
  measurement is still correct; the stream just can't be corrected from Manifold's end.

  [Screenshot: the "Not applicable" result — stageD/X01-result-not-applicable.png]

- **What calibration measures:** the stream as it reaches Manifold. It does not measure your display,
  your speakers or your SDI chain. Those delays are the same for every stream and are not part of the
  audio offset.
- **When a calibration stops being right:** after any change on the sender (section 6), after
  reconnecting to some servers (section 5), and on Cloudflare SRT during long sessions (section 5).

---

## 4. The sync clips

Each sync clip is black, with one white frame at a time, and a short beep that starts exactly on that
white frame and lasts exactly one frame. Calibration measures the time between the flash and the
beep as they arrive.

### The clips that come with Manifold

There is one clip for each of seven frame rates: 23.976, 24, 25, 29.97, 30, 50 and 59.94.

- **To get one:** **A/V ▸ Save Sync Clip…** (or **Get Sync Clip…** in the calibration sheet). It
  preselects the clip for the stream's frame rate. You can pick another from the menu in the panel.
- **The file:** `manifold-sync-23.976p-h264.mov`. It is 1920×1080 H.264 with uncompressed audio, and
  16 to 20 seconds long.
- **They loop exactly.** Sound and picture end on the same sample, so the clip can loop for hours
  without drifting.

If the stream's rate matches no clip, the panel says so: "This stream is 60 fps: there is no 60 fps
clip, 59.94p is the nearest." In that case, set the sender's output to one of the clip rates for the
calibration (section 6).

[Screenshot: the Save Sync Clip panel with its rate line and rate menu — NEW CAPTURE NEEDED]

> **If you have `.mp4` sync clips from an earlier tester build, delete them.** OBS doesn't trim
> their sound at the loop point, so they drift by 10–15 ms on every loop.

### The ProRes masters

The same clips in ProRes 422 with 24-bit PCM sound, about 60 seconds each, for finishing and
playout systems. They are a separate download: **A/V ▸ Download ProRes Sync Clips…** or **Help ▸
Download Sync Clips…** opens the download page in your browser. They also loop exactly.

[Screenshot: Help ▸ Download Sync Clips… — stageD/M02-help-menu.png]

### The label on the clip

Each clip has a grey label burned into the picture, for example:

`Manifold sync clip   23.976p   code 23-29-31-37 x1   frame 000024`

- **23.976p:** the clip's frame rate. Check that it matches the sender's output.
- **code 23-29-31-37:** the flashes are not evenly spaced. The gaps between them run 23, 29, 31 and
  37 frames, then repeat. Because of this uneven pattern, calibration can never match a beep to the
  wrong flash. It can read an offset of up to about ±2 seconds without confusion.
- **x1 / x2:** the size of each step in that pattern. x1 means the gaps are counted in frames. The 50
  and 59.94 clips are x2: the gaps are doubled (46, 58, 62 and 74 frames), so the beeps stay far enough
  apart.
- **frame 000024:** the frame number within the clip, from 0. Use it to check that the sender is not
  dropping or repeating frames.

The beep is a 1 kHz tone at −20 dBFS. Between beeps there is a very quiet hiss (−60 dBFS). It is
there on purpose: it keeps the encoder sending sound continuously. Don't remove it or gate it.

[Screenshot: one frame of the 23.976 clip with its label, and a flash frame — NEW CAPTURE NEEDED]

### Playing a clip from OBS

1. In the scene you stream from, add a **Media Source**.
2. Choose the sync clip as its local file.
3. Turn on **Loop**.
4. Turn on **Restart playback when source becomes active**.
5. Mute every other sound source in that scene (Mic/Aux, Desktop Audio, other media), so the stream
   carries only the clip's sound.
6. In **Settings ▸ Video**, set the **output frame rate (FPS)** to the clip's rate, e.g. 23.976. Apply
   it.
7. Make the source visible. It starts and keeps looping.
8. Start streaming, connect Manifold, and calibrate (section 3).

[Screenshot: the OBS Media Source properties with Loop on — NEW CAPTURE NEEDED]
[Screenshot: OBS Settings ▸ Video with FPS set to 23.976 — NEW CAPTURE NEEDED]

**Why the frame rate matters:** with OBS at 60 fps and the 23.976 clip, each flash lands on whichever
60 fps frame comes next. In our tests that scattered the readings by about one 60 fps frame
(roughly 19 ms) from one connection to the next. With OBS set to 23.976, the same setup agreed within
2–3 ms.

When the calibration is done, set the frame rate back if you changed it, and **calibrate again at
the rate you will actually stream at.** Changing the sender's frame rate can change its offset
(section 6).

### Playing a clip from DaVinci Resolve over SDI

Use this when your programme goes out of Resolve over SDI into an encoder.

1. Use a **ProRes master** at your project's frame rate.
2. Put it on a timeline whose frame rate matches the clip.
3. Set Resolve's video output (DeckLink or UltraStudio) to the same frame rate, with audio on the SDI
   output.
4. Turn on loop playback and play.
5. On the encoder (OBS's DeckLink input, or a hardware encoder), check the stream's frame rate matches
   the clip.
6. Connect Manifold to the stream and calibrate (section 3).

This chain (Resolve → SDI → OBS → Cloudflare WHEP) was one of our test setups. The sender played
in sync, and Manifold held sync across the session.

[Screenshot: Resolve timeline with the master, loop on, and the video output settings — NEW CAPTURE NEEDED]

---

## 5. Notes for each kind of stream

### Cloudflare Stream, SRT output

- **Calibrate it, and expect either direction.** The offset on Cloudflare's SRT output has differed
  from session to session. In one, sound arrived about 70–80 ms **early**. In two later ones it
  arrived about 30–40 ms **late**.
  - **Sound early:** calibration proposes a positive offset (sound later). That always applies.
  - **Sound late:** calibration proposes a negative offset, and on this path it will almost certainly
    say "Not applicable". There is no room to make sound earlier here (section 2). Correct it at the
    sender, or use Cloudflare's WebRTC (WHEP) output.
- **Long sessions:** the offset can change during a session, by a different amount each time. We
  have measured a slow drift of up to about 40 ms in 25 minutes, and a sudden 44 ms jump partway
  through a 90-minute session. Calibrate again every 20–30 minutes, or use Cloudflare's WebRTC (WHEP)
  output.
- **The sender must publish over SRT** for Cloudflare's SRT output to play. A stream published with
  WebRTC (WHIP) could not be played over SRT in our tests: Manifold connected but received nothing.

### Cloudflare Stream, WebRTC (WHEP) output

- **Calibrate after each connection, and apply it for the session.** The offset can be different
  every time you connect. In one test with OBS, three connections to the same stream read 36 ms early,
  7 ms late and 1 ms early. A saved value would be wrong after the next reconnect.
- **Wait about four minutes after connecting before you calibrate.** The timing Manifold works from
  is still settling for the first few minutes. A value taken in the first minute can be off by tens of
  milliseconds a few minutes later.
- **Once calibrated, it holds for long sessions.** We measured under 10 ms of drift over 4½ hours.
- There is plenty of room to make sound earlier on this path.

### MediaMTX

- **Set `useAbsoluteTimestamp: true`** on the MediaMTX path you play over WebRTC (WHEP). Without it,
  MediaMTX replaces the sender's timing information, and sound can drift slowly away from the picture
  over a long session. With OBS at 23.976 that drift is about a quarter of a second an hour.
  Reconnecting resets it.
- **Calibrate each session.** MediaMTX's WebRTC output can carry an offset of its own that is
  different on every connection. We measured anything from about −20 to +40 ms. It is not in the
  content: the same stream read through MediaMTX's other outputs was in sync.
- So use **Apply for Session** on MediaMTX, not Apply and Save. A saved value would be wrong after the
  next reconnect.

### NDI

- **Session only.** An NDI source has no saved entry, so a calibration applies until you disconnect.
  The calibration sheet says "NDI: a result applies to this session only." and offers only **Apply for
  Session**.
- **Calibrate each session**, and again after any change on the sender.
- **Senders differ:**
  - **OBS with DistroAV:** steady. Three reconnects agreed within 2–3 ms (with OBS's output frame rate
    set to the clip's rate). It does carry an offset of its own, so calibrate.
  - **Some other senders wander by 10–20 ms within a session.** On those, a calibration is good to
    about ±10–20 ms at best, and only for that session.
- **"Clocked" or paced NDI output:** some senders have a setting that paces their video output. In
  our tests, turning it on or off moved one sender's offset by about 85 ms. Calibrate again after
  changing it.

[Screenshot: the calibration sheet on NDI, Apply for Session only — stageD/N02-result-ndi-session-only.png]

### HLS

- **No audio offset and no calibration.** Apple's player plays HLS and controls its own audio, so
  Manifold can't move it.
- The A/V control reads **"A/V offset — not on HLS"**, greyed out. Its menu still offers the sync
  clips. Calibration says "Calibration isn't available on HLS." and Start is disabled.
- The Audio offset field is greyed out for HLS streams: "Not for HLS — Apple's player owns the audio."

[Screenshot: the HLS A/V menu — stageD/H01-hls-av-menu.png]
[Screenshot: the calibration sheet on HLS — stageD/H02-sheet-hls-disabled.png]

### SDI output (DeckLink)

- **SDI audio follows the same offset as the computer's audio.** When you change the offset during a
  live stream, the SDI audio moves with it and crossfades, with no click.
- **The offset belongs to the live stream.** When you disconnect and play a file, SDI has no offset.
- Calibration measures the stream, not your SDI chain (card, converters, monitor).
- **Known limit: keep sound-earlier offsets small with SDI.** In testing, SDI audio broke up beyond
  about −30 ms, while the computer's audio still played cleanly to −80 ms. Going back to a smaller
  offset clears it within a second.

---

## 6. Troubleshooting

### Sync was right, and now it isn't

**Calibrate again after any change on the sender.** Each of these has moved a sender's offset by tens
of milliseconds in our tests:

- **changing the frame rate.** Moving OBS's output from 60 to 23.976 moved its NDI offset by about
  85 ms;
- **changing output or encoder settings**, or restarting the encoder;
- **turning "clocked" or paced NDI output on or off** (about 85 ms on one sender);
- **switching to a different encoder or sender.** Each has its own offset.

Also calibrate again after reconnecting to Cloudflare or MediaMTX over WebRTC (WHEP) (section 5),
and every 20–30 minutes on long Cloudflare SRT sessions.

### The results jump around between runs

Usually the stream's frame rate doesn't match the clip's.

1. Look at the rate line in the calibration sheet or the Save Sync Clip panel. "This stream is 60 fps:
   there is no 60 fps clip, 59.94p is the nearest" means they don't match.
2. Set the sender's output frame rate to the clip's rate (section 4), or use the clip for the
   stream's own rate.
3. Calibrate again.

If the rates match and results still vary by 10–20 ms, the sender itself may be wandering (section 5,
NDI). Take the value that comes up most often, and calibrate again in each session.

### "Can move sound earlier by at most N ms on this stream right now"

The stream doesn't arrive far enough ahead of when it plays for Manifold to make the sound that much
earlier (section 2).

- You can apply up to N ms. The rest stays uncorrected.
- The figure changes with the stream. Try again a little later.
- To fix the rest, correct it at the sender, if it has an audio sync setting.

### Calibration won't give a result

The line under "Pairs found" says what it is waiting for:

| The sheet says | What to do |
|---|---|
| "Waiting for the clip's flashes and beeps." | Check the clip is playing and visible on the sender, its sound is not muted, and its sound goes into the stream. Check Manifold isn't muted. |
| "Flashes seen: N, beeps heard: N. Matching them by the clip's code…" | It is seeing the clip. Wait. If one count stays at 0, that half of the clip isn't reaching the stream. |
| "The pairs disagree by more than a frame: still listening." | Check the clip's rate matches the stream's (above). Other sound sources on the sender can also interfere. Mute them. |
| "Waiting for the figure to hold within ±2 ms over five pairs." | The sender is wandering slightly. Wait, or press Stop and Start again. |
| "The figure is still moving (N ms a second): the stream is settling." | The stream has just connected or recovered from a network hiccup. Wait. |
| "Waiting for the stream's frame rate." | The stream hasn't reported its rate yet. Wait a few seconds. |

If nothing has settled after two minutes, press **Stop**, check the sender, and start again.

### Contacting support

If sync is still wrong, or something here doesn't match what you see:

1. Leave Manifold running, and don't quit it.
2. Choose **Manifold ▸ Export Diagnostics…** and save the file.
3. Send it to us with:
   - what you were sending from (encoder and version), and its output frame rate;
   - the server and connection type (Cloudflare SRT, Cloudflare WHEP, MediaMTX, NDI, HLS);
   - the clip you calibrated with;
   - what the calibration sheet showed (the result and the check);
   - whether SDI output was on;
   - roughly when it happened.

Stream keys, passphrases and the private part of each stream address are removed from the file.
The server's name stays, so we can tell which service you were using.

[Screenshot: Manifold ▸ Export Diagnostics… — NEW CAPTURE NEEDED]

---

## Notes for the editor (remove before publishing)

### Claims to re-check before this ships

- **Cloudflare SRT, both directions:** "about 70–80 ms early" is 2026-09-29 (§18.13, the device
  agreed). "About 30–40 ms late" is 2026-10-05 (+27 ms, on the drifting MP4, §19.10 item 3) and
  2026-10-06 on the loop-exact `.mov` (§19.14):
  - seven readings over three reconnects, +37.7 … +43.4 ms;
  - Not Applicable every time, 0.0 ms of advance available.
  - Whether the direction depends on the session, the OBS set-up or Cloudflare is not known. The
    guide says "either direction" for that reason.
- **Cloudflare SRT "a sudden 44 ms jump" and "every 20–30 min":** the 90-minute hold (§19.8 D5) ran
  2026-10-06 (§19.14) at O = 0, because nothing could be applied:
  - +41.27 → +44.19 → −0.14 → +0.54 ms at +0 / +30 / +60 / +90;
  - one −44 ms step between +30 and +60, in a span with a 1.48 s input gap;
  - ❌ against the ±10 ms band.
  - "Up to about 40 ms in 25 minutes" is still §19.5's slope figure. The step is new.
- **Cloudflare SRT "the sender must publish over SRT":** from one attempt on 2026-10-06 (§19.14 §2). A
  WHIP-published input gave 0 bytes in 32 s on the SRT output. Not checked against Cloudflare's
  documentation. Confirm before publishing.
- **Cloudflare WHEP "different every connection; wait about four minutes":** 2026-10-06, §19.14 §1.
  - Three connections read −35.6 / +6.6 / −0.9 ms (means of two each, all at +4 min with the
    SR-fit slope in use). Each tracks Manifold's SR-line offset at the time to within 0.8 ms, as on
    MediaMTX.
  - The line moved 7–25 ms in the first four minutes, which is the reason for "four minutes".
  - The WHEP re-check read −2.50 ms. That is within step 9's "about 3 ms" but not the ±2 ms band.
  - The 2026-10-05 "about 40 ms late" was dropped: one session on the drifting clip.
  - Whether Cloudflare's SRs or Manifold's fit makes the per-connection offset is not separated.
    "Apply for Session, not Save" rests on the measurement either way.
- **MediaMTX per-session offset:** cause not yet separated (MediaMTX's WebRTC output vs Manifold's
  reading of it). It needs a browser WHEP read (BUGS.md, OPEN 2026-10-01). If it turns out to be
  Manifold's, section 5 changes.
- **SDI:** the −30 ms limit is from one session's log plus an ear check on speakers Robbie judged
  inadequate. All SDI ear checks and device A/V on SDI are deferred to the Release-build check on the
  Resolve workstation (§19.10 item 2, §19.12).
- **The redaction sentence** matches `DiagnosticsRedactor` today: URL paths, queries, passphrases,
  stream IDs and keys are blanked; host and port survive. The support list assumes the BUGS.md
  pre-ship item "Export Diagnostics: add a Sync section per session". Until that lands, diagnostics
  carry no sync section.
- **The ProRes download** (`manifold-sync-clips-v1.zip`) is not uploaded yet, and its contents are
  not decided (BUGS.md pre-ship).
- **The Resolve steps** are written from §18.24's chain. Resolve-side loop playback of a master has
  not been checked on its own.
- **"Wait about a minute after connecting"** is general advice from §19.10 choice 2 (a 40 s settle on
  SRT) and §19.13 (NDI's 20–50 s start-up settle). It is not a rule the app enforces.
- **BUGS.md OPEN 2026-10-05, calibration sheet rate warning:** if built, update "The results jump
  around between runs".

### Screenshots

Existing captures are in `~/Desktop/manifold-shots/`. ⚠️ Several stage B window titles show test
names ("SRT debug URL", "MediaMTX Whip - Locla"). Recapture those with a plainly named saved stream
before publishing. Stage D captures predate the `.mov` clips (§19.11), so any visible clip file name
reads `.mp4`.

| Placeholder | Existing capture | Notes |
|---|---|---|
| A/V menu open on a live stream | `stageD/M01-av-menu.png` | |
| Control bar badge and window title, +80 ms | `stageB/A02-whep-plus80.png` | test stream name in title |
| Saved-stream sheet, Audio offset field | `stageB/C01-sheet-field-mediamtx.png` | |
| Range error under the field | `stageB/F01-sheet-range-error-visible.png` | |
| "At most N ms" banner | `stageB/E01-srt-refusal-figure.png` (alt. `D01-srt-refusal-at-most.png`) | title reads "SRT debug URL" |
| "Can't move sound any earlier" banner | `stageB/A2-02-whep-refusal-none-left.png` | |
| (optional) range-end banner | `stageB/B04-srt-range-banner.png` | |
| Calibration: measuring | `stageD/S2-whep5994-02-progress.png` | |
| Calibration: result with Apply and Save | `stageD/S2-whep5994-03-result.png` | |
| Calibration: applied | `stageD/S2-whep5994-04-applied.png` | |
| Calibration: check in sync | `stageD/S2-whep5994-05-recheck.png` | |
| (optional) calibration idle | `stageD/S2-whep5994-01-sheet-idle.png` | |
| (optional) the same, no saved stream | `stageD/S1-srt23976-01…05` | |
| "Not applicable" result | `stageD/X01-result-not-applicable.png` | |
| NDI, Apply for Session only | `stageD/N02-result-ndi-session-only.png` (also `N01`, `N03`) | |
| HLS A/V menu | `stageD/H01-hls-av-menu.png` (older, plain-text control: `stageB/C04-hls-control-disabled.png`) | |
| HLS calibration sheet | `stageD/H02-sheet-hls-disabled.png` | |
| (optional) HLS nudge banner, field greyed | `stageB/C05-hls-nudge-note.png`, `stageB/C02-sheet-field-hls-disabled.png` | |
| Help ▸ Download Sync Clips… | `stageD/M02-help-menu.png` | |
| Save Sync Clip panel (rate line, rate menu) | — | **new capture** |
| A frame of the 23.976 clip with its label, and a flash frame | — | **new capture** (can be pulled from the clip with ffmpeg) |
| OBS Media Source properties, Loop on | — | **new capture** |
| OBS Settings ▸ Video, FPS 23.976 | — | **new capture** |
| Resolve timeline, loop on, video output settings | — | **new capture** |
| Manifold ▸ Export Diagnostics… | — | **new capture** |
