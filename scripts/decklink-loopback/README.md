# DeckLink loopback tools

Command-line checks for what reaches the SDI and HDMI wires: colour S7-5, `docs/COLOR_MANAGEMENT_FINDINGS.md` §6.11,
*S7-5 by loopback* (SDI) and *S7-5 by loopback — HDMI*. They are built against the SDK headers in
`docs/BlackmagicDeckLinkSDK16.0/Mac/include` into `build/decklink-loopback/` (gitignored), and are never part of the app
bundle. None of them activates a profile. **One configuration write exists:** `capture --input hdmi` (below).

| file | what it is |
|---|---|
| `build.sh` | `zsh scripts/decklink-loopback/build.sh [probe] [capture] [ancout] [hdrout] [v210cmp] [cfghold]` (default: `probe`) |
| `probe.cpp` | **Read-only.** For every device: identity, sub-device, active profile and the profiles on offer, duplex, connections, the input and output connection settings (`Get*` only), and status: input lock, detected mode, flags, colorspace and dynamic range, output mode, busy, PCIe; the HDMI output's actual mode and format flags, TMDS / FRL rates, and the received EDID decoded (maker, name, CTA-861 HDR static metadata EOTFs, colorimetry, deep colour) |
| `capture.cpp` | Enables one device's input (format detection, 10-bit YUV) for N seconds. For each received frame, see the table below. Prints a line whenever any of it changes, then a summary |
| `hdrout.cpp` | Control: a mid-grey 1080p25 frame with a chosen colorspace, EOTF, HDR flag and static values (`--maxcll`, or `--zero` for all 0), so a capture shows what the input reports for a known signal. `--then-*` switches to a second signal **within the same output session** (shown synchronously). `--rec2020out` holds `bmdDeckLinkConfigRec2020Output` on for the run (read first, never written to preferences, restored). Run with Manifold closed |
| `cfghold.cpp` | Holds `bmdDeckLinkConfigVideoOutputIdleOperation` at black or last frame for N seconds, so it stays in force across other processes' output stops and starts. Reads and logs the prior value, never writes preferences, restores and releases on exit or signal. While a capture runs, pass-through (`pcln`) feeds the card's own HDMI input back out during a stop, so the idle setting is not what the input sees then |
| `v210cmp.cpp` | Byte compare of two v210 frames, per channel: identical count, max \|Δ\|, Δ histogram, received low bits, and how many components each 10 → 8-bit rule explains |
| `ancout.cpp` | Positive control: black 1080p25 frames carrying two VANC test packets (0x51 / 0x01 and 0x61 / 0x01). **On the 8K Pro loop its packets never arrived, while the driver's own ST 2108-1 packets did**, so it is not a working control (§6.11) |

What `capture` records for each received frame:
- the detected mode and format flags;
- colorspace, EOTF, HDR flag and the 12 static values, as the SDK reports them;
- every ancillary packet (DID / SDID, line, data space, payload);
- a raw-VANC header scan;
- the v210's full FNV-1a, and the sampled FNV that Manifold's `[SIGNAL-TRACE]` prints;
- with `--ref`, a byte compare against a reference v210, such as Manifold's `[SDI-DUMP]`;
- the input's detection status (format, colorspace, dynamic range), the HDMI output's format flags, and Dolby Vision
  metadata if present.

**`--input hdmi`** (approved by Robbie for S7-5's HDMI half, 2026-10-25) reads and logs the device's
`bmdDeckLinkConfigVideoInputConnection`, refuses unless it is SDI, sets HDMI for the run, and on exit (or SIGINT /
SIGTERM) sets the prior value back and releases the configuration object. It never calls
`WriteConfigurationToPreferences`, so per the SDK manual (§2.5.15) the change cannot outlive the process. Run the probe
after every such capture and confirm `cfg VideoInputConnection SDI`.

On HDMI, read the static values with care: the input keeps reporting the **last DRM InfoFrame it received** (EOTF 2,
flag set and the old values) after the output stops sending one, until the link relocks. The ancillary packet DID 0x41
SDID 0x0C is present only while an InfoFrame is arriving, so it is the reliable sign of one (§6.11).

**Compare HDMI signals within one output session.** An idle card passes its input through
(`CapturePassThrough` `pcln`), and the gap between two output sessions can reset an HDMI sink by itself; a control
that changes signal by restarting `hdrout` measures that gap, not the signal (§6.11, *S7-5 HDMI follow-up*). Use
`--then-*`. The probe also reads `cfg Rec2020Output`.

```sh
zsh scripts/decklink-loopback/build.sh probe capture
build/decklink-loopback/probe
build/decklink-loopback/capture --device 0 --seconds 5 --ref <sdi-NNN.v210> --label meta [--dumpdir d --dumpmax 4]
build/decklink-loopback/capture --device 0 --input hdmi --seconds 5 --ref <sdi-NNN.v210> --label meta && build/decklink-loopback/probe
build/decklink-loopback/v210cmp <handed.v210> <received.v210> 1920 1080
```

On the build Mac (2026-10-23) the loop is device 0's output into its own SDI input: profile `1dfd`, one full-duplex
sub-device; devices 1–3 are inactive. On 2026-10-25 device 0's HDMI output was looped into its own HDMI input (the only
HDMI input; the received EDID reads "BMD HDMI"). Check that DaVinci Resolve is not running before an output starts:
look for the executable inside the Resolve bundle in `ps`, not `pgrep -f`, which matches any shell whose command line
merely mentions it.
