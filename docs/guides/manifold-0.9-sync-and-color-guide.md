# Manifold 0.9 Guide

**Live stream sync and color management · Manifold 0.9.0 · October 2026**

> **Two ideas run through this whole guide.** Manifold never guesses: it plays sound and picture exactly as the stream stamps them, and shows color exactly as the source declares it, and it tells you when something has been changed. And what you see in the window is not always what goes out: the display transform changes only the window, while the scopes, SDI/HDMI output and exported frames always carry the picture itself.

## Part 1 · Live stream sync

### Why a live stream can be out of sync

A live stream passes through three hands before it reaches Manifold:

- **The sender** (OBS, a hardware encoder, an NDI source) stamps sound and picture with times. Many senders stamp them slightly apart, and the amount changes with the sender's settings.
- **The server** (Cloudflare Stream, MediaMTX) relays the stream. Some servers add an offset of their own.
- **The network** delays sound and picture, but it doesn't change the times they are stamped with.

Manifold plays sound and picture exactly as the stream stamps them and holds them steady once playing. It doesn't guess at a sender's or server's offset, and it never corrects one for you. If a stream arrives with its sound early or late, the only way to know by how much is to measure it. That's what **calibration** does, and the result goes into the **audio offset**.

### Two sides: the sender and Manifold

Sync work always happens in two places, and it helps to keep them apart:

- **The sender side** is wherever the stream is made: OBS, a hardware encoder, or DaVinci Resolve feeding an encoder over SDI. This is often a different computer, in a different room. **The sync clip plays here.** Calibration measures what the sender puts into the stream, so the clip has to go through the sender exactly as your programme does.
- **The Manifold side** is the Mac watching the stream. **Calibration runs here,** and the result is applied here, as Manifold's audio offset. Nothing on the sender changes.

Manifold is also where you get the clip: it carries a copy for every frame rate, so you save one from Manifold and take it to the sender.

### The workflow at a glance

**In Manifold (to get the clip):**

1. Connect the stream.
2. Choose **A/V ▸ Save Sync Clip…** and save the clip for the stream's frame rate.
3. Copy that file to the sender computer, if the sender is a different machine.

**On the sender:**

4. Play the clip on a loop as part of the programme, with its sound going into the stream and every other sound source muted.

**In Manifold (to measure and fix):**

5. Wait about a minute, then choose **A/V ▸ Calibrate…** and press **Start**.
6. Read the result and press **Apply and Save** (or **Apply for Session**).
7. Press **Start** again to check: it should read close to 0 ms.

**Afterwards:** stop the clip on the sender. Calibrate again whenever anything changes on the sender.

### The audio offset

The audio offset moves the sound against the picture for the stream you're watching.

- **Positive = sound later.** +40 ms plays the sound 40 ms later than the stream says.
- **Negative = sound earlier.** −40 ms plays it 40 ms earlier.
- **Range:** −250 to +500 ms. A change takes effect at once, with no gap or click.

While a stream is playing, the control bar has an **A/V** menu. From the keyboard, with the video window in front:

- **⌥]** moves the sound 1 ms later, **⌥[** 1 ms earlier. Add **⇧** to move 10 ms at a time.
- **Reset to 0 ms** removes the offset.
- **Save to "stream name"** stores the current offset with the saved stream, so it's applied every time you connect. **Revert to Saved** goes back to the stored value.

You can also type a value into the **Audio offset** field when you edit a saved stream. Whenever an offset is on, a badge in the control bar and the end of the window title show it (for example **A/V +40 ms**). Streams with no saved entry, such as an NDI source or a URL you didn't save, keep an offset only until you disconnect.

### Why sound can only be made a little earlier on some streams

Making sound **later** always works: Manifold holds it back a little longer. Making sound **earlier** means playing sound Manifold has already received, sooner, and it keeps a safety margin so playback never runs dry. On some streams there's room for 200 ms or more; on others there's very little or none.

If you ask for more than there's room for, Manifold refuses the change, leaves the offset where it was and says so, for example "Can move sound earlier by at most 9 ms on this stream right now." If the sound needs to be earlier than that, correct it at the sender if it has an audio sync setting.

### Calibrating, step by step

Calibration measures how far apart sound and picture are in the stream as Manifold plays it, and offers the offset that fixes it. **Manifold never applies a value by itself.** Nothing changes until you press Apply.

**Step 1, in Manifold: get the clip.**

1. With the stream connected, choose **A/V ▸ Save Sync Clip…**. The panel names the stream's frame rate and preselects the matching clip. Save it.
2. If the sender is another computer, copy the file over to it (AirDrop, a shared drive, a USB stick). The clip is just a video file; nothing links it to Manifold.

**Step 2, on the sender: play the clip into the stream.**

3. Add the clip to the programme you're streaming and set it to loop (see the OBS and DaVinci Resolve sections below).
4. Mute every other sound source on the sender (microphones, other clips, desktop audio), so the stream carries only the clip's beeps.
5. Check the sender's output frame rate matches the clip's rate.

**Step 3, in Manifold: measure and apply.**

6. **Let the stream settle.** A stream that has just connected can take up to a minute to settle.
7. **Open calibration:** **A/V ▸ Calibrate…** and press **Start**. Leave the clip playing on the sender and don't touch the offset; if it changes, calibration starts again.
8. **Wait for the result,** usually 15 to 60 seconds. The sheet shows how many flash-and-beep pairs it has found (it needs 10), how much they disagree, and what it's waiting for.
9. **Read the result,** for example "Sound is heard 40 ms late" and "Current offset 0 ms → proposed −40 ms".
10. **Apply it:** **Apply and Save** stores it with the saved stream; **Apply for Session** lasts until you disconnect (the only choice on NDI and unsaved streams); **Cancel** changes nothing; **Measure Again** runs another measurement.
11. **Check it.** Press **Start** again. It should read close to 0 ms.

**Step 4, on the sender: put the programme back.** Stop the clip and unmute your normal sound sources.

Good to know:

- **Calibration includes the offset already applied.** The proposal is always the new total, not an amount to add.
- **"Not applicable"** means the fix needs sound earlier by more than the stream has room for. The measurement is still correct; correct it at the sender.
- **Calibration measures the stream as it reaches Manifold,** not your display, speakers or SDI chain. Those delays are the same for every stream.

### The sync clips

The sync clips are made to be **played on the sender**, never in Manifold itself. Each clip is black with an occasional white flash frame, and a one-frame beep that starts exactly on the flash. The flashes are deliberately unevenly spaced (a repeating 23-29-31-37 frame code), so calibration can never pair a beep with the wrong flash and can read offsets up to about ±2 seconds.

- **Built into Manifold, for taking to the sender:** one clip for each of 23.976, 24, 25, 29.97, 30, 50 and 59.94 fps, from **A/V ▸ Save Sync Clip…** (or **Get Sync Clip…** in the calibration sheet). They loop exactly, so they can run for hours without drifting.
- **Download set:** **Help ▸ Download Sync Clips…** gets a zip with the same loop clips, ProRes 422 masters with 24-bit PCM sound for finishing and playout systems, an OBS scene collection template, and a README.
- **The label** burned into each clip shows its frame rate, the code, and a frame counter you can use to check the sender isn't dropping or repeating frames.
- **The quiet hiss between beeps is deliberate.** It keeps the encoder sending sound continuously. Don't remove or gate it.
- **Match the frame rate.** If the stream's rate matches no clip, the panel says so. Set the sender's output to one of the clip rates for the calibration.
- **Playing a clip in Manifold's own window does nothing for calibration.** Calibration measures the stream, so the clip has to be part of what the sender sends.

### On the sender: playing a clip from OBS

1. In the scene you stream from, add a **Media Source** with the sync clip as its local file.
2. Turn on **Loop** and **Restart playback when source becomes active**.
3. Mute every other sound source in that scene.
4. In **Settings ▸ Video**, set the output frame rate to the clip's rate (for example 23.976) and apply.
5. Start streaming. Then, in Manifold, connect and calibrate.

The frame rate matters: with OBS at 60 fps and the 23.976 clip, readings scattered by about one 60 fps frame between connections; at 23.976 they agreed within 2–3 ms. If you changed the rate, set it back afterwards and **calibrate again at the rate you'll actually stream at**.

### On the sender: playing a clip from DaVinci Resolve over SDI

1. Put a ProRes master at your project's frame rate on a timeline with the same rate.
2. Set Resolve's video output to that rate, with audio on SDI.
3. Turn on loop playback and play.
4. Check the encoder's stream rate matches the clip. Then, in Manifold, connect and calibrate.

### Notes for each kind of stream

- **Cloudflare, WebRTC (WHEP):** calibrate it. The offset held steady across reconnects but differed between sender sessions, so **Apply and Save** is fine; calibrate again when the sender starts a new session. Once calibrated, it held for 4½ hours in testing.
- **Cloudflare, SRT:** calibrate it, and expect either direction. When the sound arrives late, there's usually no room to make it earlier on this path, so the sheet says "Not applicable": correct it at the sender or use WHEP. The offset can change during a long session, so calibrate again every 20–30 minutes, or use WHEP.
- **MediaMTX:** set `useAbsoluteTimestamp: true` on any path you play over WHEP; without it, sound slowly drifts away from the picture (about a quarter of a second an hour with OBS at 23.976). One calibration holds across reconnects.
- **NDI:** a calibration applies for the session only. Calibrate each session and after any change on the sender. OBS with DistroAV is steady; some other senders wander by 10–20 ms within a session.
- **HLS:** no offset and no calibration. Apple's player owns the audio, so Manifold can't move it.
- **SDI output:** SDI audio follows the same offset as the computer's audio and moves with it. The offset belongs to the live stream; a file has none. Keep sound-earlier offsets small when SDI is on: in testing, SDI audio could break up beyond about −30 ms.

> **Lower latency in 0.9.0 doesn't change sync.** WHEP now plays 100 ms sooner and NDI 50 ms sooner. Both move sound and picture together, so a saved offset still holds.

### When sync was right and now it isn't

Calibrate again after any change on the sender side. Each of these has moved a sender's offset by tens of milliseconds in testing:

- changing the frame rate;
- changing output or encoder settings, or restarting the encoder;
- turning "clocked" or paced NDI output on or off;
- switching to a different encoder or sender.

If results jump around between runs, the stream's frame rate usually doesn't match the clip's. If calibration won't give a result, read the line under "Pairs found": it says what it's waiting for, most often that the clip's sound or picture isn't reaching the stream. That's a sender-side problem: check the clip is playing and visible in the program output, its sound isn't muted, and it's routed into the stream.

## Part 2 · Color management

### The model in one paragraph

Every source has **tags** that say what its color is: primaries, transfer curve and matrix (for example Rec. 709, or Rec. 2020 PQ). Manifold reads them and builds **the picture** from them, optionally changed by an **override** or a **LUT**. The picture is what the scopes measure, what SDI and HDMI carry, and what Export Frame saves. Separately, each window has a **display transform** that decides how that picture is turned into light on your screen. Changing the display transform changes only the window.

### Reading the transform chain

**Color ▸ Show/Hide Transform Chain** (⌥⌘4) opens the readout that explains everything between the source and your screen:

- **Source:** the source's color, and whether it was declared by the source or assumed. A stream that declares nothing is treated as Rec. 709 and the readout says so.
- **Chroma:** the color resolution being used (4:2:0, 4:2:2 or 4:4:4, and bit depth).
- **Transform:** the display transform in use and what it's doing.
- **Display:** your display and its curve, from its macOS profile.
- **Headroom:** for HDR, how much brightness headroom the display offers, or that it's in SDR mode. Manifold only reports this; it doesn't cap or tone-map the picture.
- **Buffer:** for SRT and WHEP, how much of the stream is buffered.

Overrides and LUTs are marked in the readout, and the window title says when one is on, so a changed picture is never silent.

### The three display transforms

Choose per window from the control bar, the Color menu, or **⌥⌘1 / ⌥⌘2 / ⌥⌘3**.

- **macOS:** macOS color-manages the picture for your display, as QuickTime, Safari and most Mac apps do. Use it to see what a client sees in those apps. Note that macOS decodes Rec. 709 video with a lighter curve (about gamma 1.96) than a reference monitor, which is the familiar "QuickTime looks washed out compared with Resolve" effect.
- **Reference:** the picture shown with the **BT.1886** curve a reference monitor uses (gamma 2.4 on a display with a true black). Use it to judge the picture the way you would in a grading suite.
- **Bypass:** no color management at all. The picture's values go to the screen untouched. Use it for diagnostics, or on a display that is itself set to exactly the source's standard. A window in Bypass says so in its title.

### Hold to compare

- Hold **C** to see the other of macOS and Reference while the key is down.
- Hold **⇧C** to see Bypass.
- With a LUT on, hold **⌥C** to see the picture without it.

Let go and the window is back where it was. A badge and the window title say what you're comparing against.

### Reference mode and display calibration

Reference promises the light a BT.1886 reference monitor would put out. How it gets there depends on one per-display setting in the transform chain, under **This display**:

- **Unchecked (the default):** Manifold reads your display's macOS profile and converts the picture so that, after the display's own curve, the light lands on BT.1886. **White** and **Black** are the display's white and black levels in cd/m²; Black 0 gives exactly gamma 2.4.
- **Checked, "Calibrated to Rec. 709 / BT.1886 in the display":** the display itself applies BT.1886 (a hardware-calibrated monitor, or a TV in a calibrated picture mode), so Manifold sends the values untouched. White and Black are greyed out.
- **It's remembered per display,** not per window, so moving a window to another display can change the picture.
- **It applies in Reference only.** In macOS and Bypass the section is greyed and reads "Applies in Reference mode only".

> **Only tick it if the display really is calibrated to BT.1886.** Manifold trusts the setting. On a display that isn't, the picture will be wrong in Reference mode and nothing will say so.

### HDR in the window

PQ and HLG sources are shown as HDR when macOS HDR is on for the display. The **Headroom** line says how much the display offers, follows the window to another display, and updates when HDR is switched or brightness changes. If the display is in SDR mode, the readout says so. Manifold never caps or tone-maps the picture.

### Overriding a source's color tags

Sometimes a file or stream is tagged wrong, or not tagged at all. Override it from the **Color** control:

- **Presets:** Rec. 709, Rec. 2020 PQ, Rec. 2020 HLG, P3-D65 PQ or Rec. 2020 SDR. **Color ▸ Next Tag Override** steps through them.
- **One tag at a time:** set primaries, transfer and matrix separately in the **Override** section. Combinations Manifold can't display as stated are greyed out with the reason.
- **Reset to File's Tags** (or **Reset to Stream's Tags**) at the top of the Color control undoes it at once.
- **On a file,** an override lasts until you open another file. **On SRT, WHEP, HLS and NDI streams,** you can save it with the saved stream so it comes back every time you connect.

An override changes the picture, so the window, scopes, SDI color tag and readout all change together. The readout warns when an H.264 or HEVC file's container tags disagree with its own video stream; the container's tags are used unless you override them.

### LUTs

**Load LUT…** in the Color control applies a `.cube` LUT (1D, 3D, or shaper + 3D) to the window's picture, and the scopes, SDI output and exported frames see it too. It stays on when you open another source.

- **Interpolation:** tetrahedral by default, or trilinear. Results were checked against DaVinci Resolve.
- **LUT Outputs** says what color space the LUT produces. Leave it at **Same as Source (no change)** for looks and creative LUTs that stay in the source's space. Change it only for a LUT that converts to another space, such as Rec. 709 to PQ. A conversion LUT with a display transform baked in for a standard (for example LogC to Rec. 709) is described by the standard it outputs: Rec. 709.
- **Display or calibration LUTs** made for one particular monitor aren't supported in this slot.
- **Recent LUTs** remembers each LUT with its output space. **Bypass LUT** turns it off without unloading it.
- A file that isn't a valid `.cube` is refused with a message saying why.

### What reaches SDI and HDMI

- **Always the picture,** after any override or LUT, and never the window's display transform or calibration setting.
- **Each frame is labelled** with its color space and transfer (SDR, PQ or HLG), so a reference monitor that follows the signal can switch on its own. PQ also sends HDR10 metadata: the source's own values, or standard defaults when it has none, and the DeckLink menu says which.
- **P3-D65 and DCI-P3 sources are converted to Rec. 2020 for SDI,** so a monitor following the Rec. 2020 label shows them correctly. The window, scopes and exports are unaffected.
- **Known limitation:** over HDMI, an HLG picture goes out without its HLG signal. SDI carries HLG.

### Quick answers

- **"It looks different in QuickTime."** Switch the window to **macOS** to see what QuickTime shows, and hold **C** to flip back to Reference.
- **"I want to judge the grade on my desk display."** Use **Reference**, and set the display's calibration settings honestly in the transform chain.
- **"This file is tagged wrong."** Use an override, then **Reset to File's Tags** when you're done.
- **"This stream is log footage."** Load your conversion LUT and set **LUT Outputs** to the standard it produces.
- **"The scopes didn't change when I switched modes."** That's correct. Scopes measure the picture, not your display.
