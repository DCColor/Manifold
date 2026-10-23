# DeckLink loopback tools

Command-line checks for what reaches the SDI wire: colour S7-5's SDI half, `docs/COLOR_MANAGEMENT_FINDINGS.md` §6.11,
*S7-5 by loopback*. They are built against the SDK headers in `docs/BlackmagicDeckLinkSDK16.0/Mac/include` into
`build/decklink-loopback/` (gitignored), and are never part of the app bundle. None of them writes a configuration item
or activates a profile.

| file | what it is |
|---|---|
| `build.sh` | `zsh scripts/decklink-loopback/build.sh [probe] [capture] [ancout]` (default: `probe`) |
| `probe.cpp` | **Read-only.** For every device: identity, sub-device, active profile and the profiles on offer, duplex, connections, the input and output connection settings (`Get*` only), and status: input lock, detected mode, flags, colorspace and dynamic range, output mode, busy, PCIe |
| `capture.cpp` | Enables one device's input (format detection, 10-bit YUV) for N seconds. For each received frame, see the table below. Prints a line whenever any of it changes, then a summary |
| `ancout.cpp` | Positive control: black 1080p25 frames carrying two VANC test packets (0x51 / 0x01 and 0x61 / 0x01). **On the 8K Pro loop its packets never arrived, while the driver's own ST 2108-1 packets did**, so it is not a working control (§6.11) |

What `capture` records for each received frame:
- the detected mode and format flags;
- colorspace, EOTF, HDR flag and the 12 static values, as the SDK reports them;
- every ancillary packet (DID / SDID, line, data space, payload);
- a raw-VANC header scan;
- the v210's full FNV-1a, and the sampled FNV that Manifold's `[SIGNAL-TRACE]` prints;
- with `--ref`, a byte compare against a reference v210, such as Manifold's `[SDI-DUMP]`.

```sh
zsh scripts/decklink-loopback/build.sh probe capture
build/decklink-loopback/probe
build/decklink-loopback/capture --device 0 --seconds 5 --ref <sdi-NNN.v210> --label meta [--dumpdir d --dumpmax 4]
```

On the build Mac (2026-10-23) the loop is device 0's output into its own SDI input: profile `1dfd`, one full-duplex
sub-device; devices 1–3 are inactive. Check that DaVinci Resolve is not running before an output starts.
