# Manifold 0.5.0 — tester notes

Thanks for taking this. Manifold is a reference video player and analysis tool for
colourists — local files, plus live streams over NDI, WHEP (DC Color Live) and SRT,
with GPU scopes and SDI output via DeckLink.

This is a **Profile build**, which means the diagnostic telemetry is compiled in. It
runs at full speed but it logs a lot, on purpose. Some rough edges are debug
affordances that won't ship.

---

## First, the one thing I actually need

Everything else on this list is a bonus. This is the ask:

**Run a WHEP stream for five minutes on your worst network, then export diagnostics.**

Manifold ▸ Export Diagnostics… writes a plain text file. It'll ask three questions
first — connection type, roughly where you are, what you were doing. Please answer
them; without that the numbers in the file can't be interpreted.

Then do it again somewhere else if you can. Wifi in a coffee shop, a hotel, tethered
to a phone, anything worse than a good wired connection. **The variation between
runs is the data I need**, not the absolute numbers. Everything looks fine on my
machine on ethernet, which is exactly the problem.

The file is plain text and lists what it redacted. You can read it before you send
it. It does not contain passphrases, stream keys, or URL paths.

---

## Things I know are fragile

### Buffering and stutter on live streams

Manifold holds a small buffer before displaying live frames — 400ms for WHEP,
250ms for SRT. If the network is worse than that buffer can absorb, you'll see
stutter or brief freezes.

- **Does it stutter, and when?** Steady stutter, or occasional hitches?
- **Does it recover on its own?**
- If you're comfortable with it: `⌃⌥]` raises the buffer, `⌃⌥[` lowers it. If
  raising it fixes the stutter, that's useful to know and roughly how far you had
  to go.

Export diagnostics *after* a bad run, not after restarting.

### 1080p29.97 out to SDI

On my machine this doesn't lock — but Resolve can't do it on that machine either,
so I think it's my hardware or my monitor, not Manifold. **You have different
hardware, so you're the test.**

If you can, try a 1080p29.97 file with DeckLink output on and tell me whether the
monitor locks. A 1080p23.98 or 1080p25 file is the useful comparison — if those
lock and 29.97 doesn't, it's the frame rate; if 1080p doesn't lock at all, it's the
resolution. UHD works fine here.

### First launch without NDI installed

If you have a machine without the NDI runtime, launching there is genuinely useful
— I've never been able to test it, because mine has NDI installed. The streaming
menu should say something honest rather than showing an empty source list.

Same for **running without a DeckLink attached** — the output button should degrade
gracefully rather than doing something odd.

### Local network permission

The first time you open the streaming menu, macOS will ask for local network access
(NDI discovery uses mDNS). If you decline it, NDI discovery will silently find
nothing — so if the NDI list is empty, check that first.

### SRT connect goes black for a moment

SRT has no way to ask the sender for a keyframe, so after connecting the picture
stays black until the sender's next one — usually about a second. That's expected,
and the app should tell you it's waiting rather than looking hung. If it looks hung
with no explanation, that's a bug.

If you want to try SRT: OBS ▸ Settings ▸ Stream ▸ Custom, server
`srt://0.0.0.0:9000?mode=listener`, stream key blank. Then connect Manifold to
`srt://127.0.0.1:9000`. Two OBS quirks that are OBS's fault, not Manifold's: the
listener drops its output when the viewer disconnects, so you have to restart
streaming between attempts, and OBS sometimes hangs on Stop Streaming and needs a
force quit.

---

## Worth poking at

Not stress points, just areas that would benefit from another pair of eyes.

- **Files** — ProRes, DNx, MXF, HDR. Anything that won't open, or opens wrong.
- **The inspector** — it reports what a file actually declares, including when it
  declares nothing. If it says something you know to be wrong, I want to hear it.
- **Scopes** — `⌃⌥W` waveform, `⌃⌥P` parade, `⌃⌥V` vectorscope, plus CIE. They
  can collide with the control bar at smaller window sizes; that's known.
- **Stream bookmarks** — Connect Stream ▸ Manage. Saving, editing, passphrases.
- **JKL shuttle**, space, arrows.
- **`⌃⌥E`** exports the current frame as a PNG.

---

## What isn't built yet

Please don't spend time on these — I know:

- **Colour management modes** (Reference / OS / Bypass) — not built. Right now
  Manifold shows the same thing macOS shows, which is not reference-accurate in the
  shadows. This is next.
- **LUT loading** — not built.
- **HDR tone-mapping control** — HDR displays correctly, but you can't set a peak
  luminance or choose clip vs roll-off yet.
- **SRT is H.264 SDR only** — no HEVC, no HDR over SRT yet.
- **HLS** — not implemented.
- **Multiple windows** — opens, but streaming sources are shared between windows
  and will interfere. Known, and being worked on.
- **No keyboard shortcut reference** in the app yet. Sorry.
- **Audio scrubbing** — deliberately not implemented; playback pauses when you
  scrub.

---

## Reporting

For anything that goes wrong, the most useful thing by far is **Export Diagnostics
immediately afterwards, before restarting the app.** The log is a rolling buffer, so
a restart loses it.

Tell me what you were doing, what you expected, and what happened. Rough timing
helps — the log has timestamps.

If the app crashes rather than misbehaving, macOS will offer a crash report; that's
worth having too.
