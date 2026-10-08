## HEVC 4:2:2 10-bit over SRT
Moved into the plan (2026-10-07): COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b.

## HEVC over WHEP
Status: idea (2026-10-07)
Version: ?

What: Negotiate and decode HEVC on WHEP, alongside H.264.

Why: 10-bit HDR over WebRTC. WHEP is H.264-only today, and OBS's H.264 HDR is 8-bit, so it bands
(COLOR_MANAGEMENT_FINDINGS.md §6.9, *The OBS re-check*).

Open questions:
- Browser and server HEVC support is uneven (MediaMTX, Cloudflare).
- Negotiation, and falling back to H.264 when the server won't offer HEVC.

Depends on: HEVC over SRT (shared parser/decoder work).
Size guess: ?

## Timecoded markers with EDL export
Status: idea (2026-10-06)
Version: 1.5?

What: Drop markers on the timeline at the current timecode, with a colour and a note, and export them as a marker EDL that Resolve (and others) can import.

Why: A reviewer watching in Manifold can flag shots ("sky too cyan at 01:02:14:05") and hand the colourist a file that lands as markers on their timeline, instead of a typed list of timecodes.

Must:
- Markers carry source timecode, not elapsed time.
- Export round-trips into Resolve without retyping.

Open questions:
- Which EDL flavour(s): Resolve's marker EDL, Avid locators, CSV?
- Files only, or live streams too (timecode on streams isn't always present)?
- Saved with the file, or per session?

Depends on: shortcut registry (marker keys), reliable timecode readout.
Size guess: medium.

## Social Reframes with Export
Status: idea (2026-10-06)
Version: 1.5?

What: We already have ability to preview social framing but no way to  pan, zoom or move the image underneath that framing.  Once set we should also have the ability to export to Apple included export types like ProRes and h264/HEVC

Why: Literally everyone has asked me if we can export when they see the social previews

Must:
- pan/zoom/reframe within the dimensions of the social framing preset
- export as previewed to ProRes or h264/HEVC
- not touch the original file and when social preview is turned of or export done returns to the original loaded file

Open questions:
- How to pan/scan within the player window
- Can we export without needing 3rd party tools

Depends on: unsure
Size guess: large

## Load Audio Files Only
Status: idea (2026-10-06)
Version: 1.5?

What: Ability to load audio files with no video - stereo, mono, 5.1 etc

Why: QuickTime, Screen etc all do it and its expectation that many users will have

Must:
- open pcm, aac, mp3, m4a
- audio declarations/channel assignments just as with married audio to a video file
- clear thats audio only - via removing video frame, onscreen text or some other method
- still support DECKLINK by putting a black or template video image with the audio when sent via decklink

Open questions:
- Do we need anything else to support various codecs/containers that are audio only?
- Can we export without needing 3rd party tools

Depends on: unsure
Size guess: medium

## Load Still Images
Status: idea (2026-10-06)
Version: 1.5?

What: Ability to load stills - png, jpeg, tiff and HDR image formats like AVIF, JPEGR

Why: QuickTime, Screen etc all do it and its expectation that many users will have

Must:
- open all standard SDR image formats.  HDR formats are a bonus
- read embeded color profiles and either display correctly or convert to standard space like sRGB/709

Open questions:
- Do we need anything else to support various codecs/containers for still images?

Depends on: unsure
Size guess: medium

## Load DCPs and IMFs for viewing
Status: idea (2026-10-06)
Version: 1.5?

What: Ability to load a DCP or IMF package to preview

Why: Resolve loads DCPs and IMFS just like they were any other single file but thats open resolve, start a project etc its a lot of steps

Must:
- parse the package and render audio/video just like another file
- Convert from XYZ to a chosen color space  - this probably needs a picker but Rec709/Display P3 etc would work
- Protect the DCP/IMF package from corruption or messing with XMLs.  Hash must not be modified 

Open questions:
- What are the licensing ramifications ?

Depends on: unsure
Size guess: Large

## Dolby Vision - Mezzanine + DV XML
Status: idea (2026-10-06)
Version: 1.5?

What: Ability to load a PQ encoded ProRes + marry a Dolby Vision XML

Why: Quickly preview Dolby Vision files 

Must:
- parse the XML trim metadata in real time and accurently to the mezzanine
- No XML editing
- Protect the XML and never modify it

Open questions:
- What are the licensing ramifications ?

Depends on: unsure
Size guess: Large