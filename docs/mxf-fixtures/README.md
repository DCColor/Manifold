# MXF fixtures — the libav / AVFoundation comparison harness

One harness, one question: **opened through AVFoundation with the professional-video-workflow
plug-ins registered, does an MXF report the same facts, the same pixels and the same audio as
`LibavFrameSource` does today?**

It exists because of the 2026-09-08 finding in [`../BUGS.md`](../BUGS.md) →
*"CAUSE CONFIRMED — VideoToolbox plug-in codecs and MediaToolbox plug-in format readers are OPT-IN
PER PROCESS"*. Before that, the comparison was impossible: AVFoundation could not open an MXF at
all. It can, once a process asks.

Same convention as [`../scrub-fixtures/`](../scrub-fixtures/) and nothing else in common: single-file
`swiftc` script, built on demand, binary not committed, not in the app target.

## ⚠️ The registration calls are not optional and there is no flag to skip them

```
VTRegisterProfessionalVideoWorkflowVideoDecoders()    VideoToolbox/VTProfessionalVideoWorkflow.h
MTRegisterProfessionalVideoWorkflowFormatReaders()    MediaToolbox/MTProfessionalVideoWorkflow.h
```

`main` calls both before touching AVFoundation or VideoToolbox, and prints that it did, along with
the plug-in bundles it found in `/Library/Video/Professional Video Workflow Plug-Ins`. **A run that
silently forgot would report "AVFoundation cannot open MXF" and look like a finding rather than
like an omission** — which is the error that cost the most time in the investigation behind this.

⚠️ **`pluginkit` cannot see these plug-ins and neither can `VTCopyVideoDecoderList`.** They are
`BNDL` plug-ins loaded by VideoToolbox's and MediaToolbox's own machinery (`CMFactoryFunction`), not
PlugInKit app extensions. An empty result from either enumeration API is not evidence of absence.
The harness lists the bundle directory instead, which is.

## Requirements

- Xcode command-line tools, and `ThirdParty/ffmpeg/lib` built (`scripts/build_ffmpeg.sh`).
- **Pro Video Formats installed** (`com.apple.pkg.ProVideoFormats`) — `AppleMXFImport.bundle` for
  the container and `DNXDecoder.bundle` for DNxHR. Without them every AVFoundation column is empty
  and the harness says so on its first line.

## Build and run

```bash
docs/mxf-fixtures/build-mxfmeas.sh              # OUT=<dir> to build elsewhere

MODE=facts     ./mxfmeas FILE...
MODE=calibrate ./mxfmeas PRORES.mov
MODE=pixels    CALIBRATE=PRORES.mov N=4 ./mxfmeas FILE...
MODE=audio     SECONDS=1.0 ./mxfmeas FILE...
```

`OUTDIR` (default `./mxfmeas-out`) receives the difference-plane dumps. `FLAT_T` (default 4) is the
chroma flatness threshold in 10-bit codes; `PGM_SCALE` (default 8) is the difference dump's gain.

## The three modes

### `facts` — three columns, and the middle one is the point

| what libav CAN report | what Manifold's libav path reports TODAY | what AVFoundation reports |
|---|---|---|

Several rows differ from AVFoundation **only because `LibavFrameSource.StreamInfo` does not carry
the field** — libav has it to give and the app does not ask. Collapsing the two libav columns would
turn a known, documented gap (see `applyLibavMetadata`'s own comment on geometry) into a false
finding about libav. **Where the two libav columns differ, the gap is ours.**

Four things it is deliberately careful about:

- **Colour is compared as CODES, not names.** Both paths already funnel names through the same
  table, so comparing names would test our own table twice and hide a real disagreement behind a
  shared `—`.
- **Pixel aspect prints raw rationals including `0/1`**, labelled `UNSPECIFIED, not 1:1`. Reducing
  or defaulting it is exactly how a "both paths say square" gets manufactured out of one path
  having said nothing.
- **Frame rate is compared as a rational against `minFrameDuration`**, cross-multiplied exactly.
  `nominalFrameRate` is a `Float32` and 23.976 comes back as 23.976025; comparing doubles needs a
  tolerance that hides whether the file is 24000/1001 or 23.98.
- **The raw `AVColorRange` is printed beside Manifold's boolean**, because `isFullRange =
  (range == JPEG)` collapses three states into two and the libav path can never print "Untagged".

### `calibrate` — a gate, and it measures a floor

⚠️ **`MODE=pixels` refuses to run without `CALIBRATE=`, and the calibration runs in the same
process on every run** — not a stamp file that could go stale.

Run on a file both paths already decode, where the answer is known in advance. It does two things:

1. **Proves the harness reads both paths on one scale** — gain ≈ 1.000, offset ≈ 0, luma within a
   code. A stride, alignment or bit-packing error shows up here as a harness bug rather than
   downstream as an MXF finding. *It has already earned its place once*: it caught `gradientMask`
   measuring the interleaved chroma plane's gradient on Cb alone, which was leaking edge samples
   into the flat population at max |Δ| 14.
2. **Measures the floor** — what two *correct* decoders differ by through this contract — which the
   MXF comparison is then judged against instead of against an assumed constant.

⚠️ **Use a calibration file with the same chroma geometry as the fixture.** A 422 file calibrates a
422 fixture, because the 422→420 vertical resample is the step whose floor is being measured.

### `pixels` — and the two fixtures are not the same experiment

Both paths are asked for `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`, the app's own decode
contract — not because it is neutral (it discards 444 chroma and two bits) but because it is what
the scopes, the v210 convert and the frame export actually read.

- **PTS sequences are asserted before any pixel is compared**, and a **raster mismatch aborts**
  rather than compares. Comparing a cropped rect against a full raster produces plausible-looking
  numbers for two different pictures.
- **`OP1A Test.mxf` (HQX 422)** — both decoders believed correct. Full tolerance analysis: per-plane
  percentiles, the affine fit, and chroma segmented flat-vs-edge by local gradient.
- **`Mixed Captions.mxf` (444 12-bit, variable ACT)** — **libav is known-incorrect on this file.**
  The harness captures the decoder's own `Unsupported: variable ACT flag.` off the libav log as
  primary evidence (a 4:4:4-DNx heuristic is the secondary net), then **refuses to run a tolerance
  analysis** and reports the size of a known defect instead. Running one would imply the two are
  candidates for agreement. They are not.

**The affine fit is kept because a pass/fail number cannot distinguish three different causes:**

| fit | means |
|---|---|
| gain ≈ 219/255, offset ≈ 64 | a legal↔full **range remap** — the app's contract says neither path should |
| gain ≈ 1, offset ≈ 0, residual at edges only | the **chroma filter**, expected, not a defect |
| gain ≈ 1, offset ≈ 0, flat residual | a **rounding** difference, expect ≤ 1 code |
| gain ≈ 4 or ≈ ¼ | a **bit-depth shift** — suspect this harness before the file |

The difference planes are dumped as 8-bit PGMs. **Structure in that image is the tell.**

### `audio` — the cross-correlation matrix

Counts cannot answer the question. A five-channel MXF arriving as one AVFoundation track against
five libav streams is either the same audio grouped differently or different audio, and only
correlating the decoded samples can say which. The **full matrix and the permutation** are printed,
not a verdict.

⚠️ **Levels are printed before the matrix, and they are not decoration.** A matrix of zeros has two
completely different causes — the content is silent (correlation is *undefined*, and that is not a
finding) or one path decoded nothing (a bug). The first version of this reported a silent fixture as
*"the two paths are delivering different content"*, which was a false finding; undefined cells now
print `·` and the verdict is withheld.

Roles on both sides are named by the **same** copied bridge, so a role difference is the files'
declarations differing rather than two naming tables.

## ⚠️ Copied code, and why

The harness cannot link ManifoldCore — that is what this convention avoids. So the "Manifold
reports today" column, the decode contract, the swscale conversion and every layout/role name come
from code **copied verbatim**, each marked `⚠️ COPIED FROM`. If a value here disagrees with the app,
**the app is right and this is stale.** Check the copies before believing a surprising row.
