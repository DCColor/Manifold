# Scheduled playback: embedded audio sometimes never starts while the same sub-device's input is open (DeckLink 8K Pro, 1080p59.94)

For Blackmagic Design developer support. Written 2026-11-11 by Graviton (Manifold, a macOS playback app). Measurements are ours, taken
on an SDI loop with a capture tool built on the same SDK. Internal reference: `CARD_CLOCK_FINDINGS.md` §10.23–§10.26. Revised 2026-11-12:
the failure has so far appeared only while the same sub-device's SDI input was open.

## System

| | |
|---|---|
| Card | DeckLink 8K Pro, output on sub-device "DeckLink 8K Pro (1)" (the card enumerates 4 sub-devices) |
| Profile | 4 sub-devices. Active profile ID `1dfd`, duplex `dxfu` (full duplex), as read by `IDeckLinkProfileAttributes`. Profile name: **to confirm in Desktop Video Setup before sending** |
| Driver | Desktop Video 16.4.0 (`DeckLinkAPI.framework` 16.4) |
| SDK compiled against | Desktop Video SDK 16.0 (`BLACKMAGIC_DECKLINK_API_VERSION` 0x10000000), `DeckLinkAPIDispatch.cpp` from the same SDK. 16.0 (released 2026-04-08) is the current SDK: driver releases 16.4 and 16.5 shipped without new headers |
| Host | Mac Studio (Mac16,9), Apple silicon, macOS 26.7.1 (25G241) |
| Mode | 1080p59.94 (`bmdModeHD1080p5994`), v210, 2 channels 48 kHz 32-bit integer embedded audio |

## Our start sequence, call by call

Each output start gets the device again and runs, on one thread:

1. `DoesSupportVideoMode(bmdVideoConnectionUnspecified, bmdModeHD1080p5994, bmdFormat10BitYUV, bmdNoVideoOutputConversion, bmdSupportedVideoModeDefault, …)` returns supported.
2. `EnableVideoOutput(bmdModeHD1080p5994, bmdVideoOutputFlagDefault)`.
3. `EnableAudioOutput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger, 2, bmdAudioOutputStreamTimestamped)`.
4. `CreateVideoFrame(1920, 1080, 5120, bmdFormat10BitYUV, bmdFrameFlagDefault)` ×4.
5. `SetScheduledFrameCompletionCallback(cb)`.
6. `SetAudioCallback(cb)`, then `BeginAudioPreroll()`. In `RenderAudioSamples(preroll = true)` we call
   `ScheduleAudioSamples(buffer, n, streamTime, 48000, &written)`. `streamTime` is the running count of sample frames already scheduled,
   starting at 0. We repeat until `GetBufferedAudioSampleFrameCount` reaches 3,840 (80 ms; 9,600, 200 ms, before 2026-11-12), then call `EndAudioPreroll()` from
   inside the callback, as the FilePlayback sample does.
7. `ScheduleVideoFrame(frame[i], i × 1001, 1001, 60000)` for i = 0…3.
8. We wait (at most 500 ms) for the audio preroll to complete, and call `EndAudioPreroll()` ourselves if the callback has not. In
   every start measured it was already complete (at 200 ms: 2 audio callbacks, 9,600 samples queued; at 80 ms: 3,840).
9. `StartScheduledPlayback(0, 60000, 1.0)`. A mutex keeps `RenderAudioSamples` from running during this call: the callback
   try-locks and skips that one call.
10. Running: `ScheduledFrameCompleted` refills and reschedules each frame at the next index. `RenderAudioSamples` keeps the audio queue
    80–200 ms deep, always passing a non-NULL `sampleFramesWritten`.

Stop: `StopScheduledPlayback(0, &actual, 60000)`, then we wait for `ScheduledPlaybackHasStopped` (it arrives 0.6–0.8 ms later). Then
`SetScheduledFrameCompletionCallback(NULL)`, `SetAudioCallback(NULL)`, `FlushBufferedAudioSamples()`, `DisableAudioOutput()`,
`DisableVideoOutput()`, and the frames and the output interface are released. The restarts below are a stop followed by a full start
about 3 s later, with video playing throughout on the host.

## The symptom

At 1080p59.94, while a capture client holds **the same sub-device's SDI input** open, about 1 output start in 40 (2.8 %) accepts the
audio and never plays any of it. With the input closed we have not seen it in 408 starts.

- `StartScheduledPlayback` returns `S_OK`, and the picture plays normally: every frame completes, with no late and no dropped frames.
- `RenderAudioSamples` keeps being called at its normal rate (about 600 calls in the 12 s session).
- `GetBufferedAudioSampleFrameCount` stays at the preroll's count for the whole session: nothing is consumed.
- `GetScheduledStreamTime(48000, …)` advances normally, a second and more past the end of the queued audio.
- On the wire the embedded audio is silent for the whole session (measured by capture).
- The next stop and start of the output is normal.

In a normal start, the card's audio consumption point (`streamTime of the queue's end − GetBufferedAudioSampleFrameCount`) is 2–4
samples from `GetScheduledStreamTime(48000)` 10 ms after Start, and stays there.

"Input open" means our capture tool (the same SDK) has called `EnableVideoInput` and `EnableAudioInput` on the output's own sub-device
and `StartStreams`, and receives the output back through an SDI loop cable. In the restart runs below it is opened once, just after the
first output start, and stays open across every later stop and start.

| Rate | Input | Start sequence | Starts | Silent |
|---|---|---|---|---|
| 1080p59.94 | open | earlier sequence, 200 ms audio preroll | 100 | 5 |
| 1080p59.94 | open | the sequence above, 200 ms preroll | 101 | 1 |
| 1080p59.94 | open | earlier sequence, a second configuration | 51 | 1 |
| 1080p59.94 | open | the sequence above, second configuration | 52 | 0 |
| 1080p59.94 | open | the sequence above, 3,203-sample preroll | 102 | 1 |
| 1080p59.94 | open | **the sequence above, 80 ms preroll (current)** | **52** | **3** |
| 1080p23.976 | open | various | 254 | 0 |
| 1080p59.94 | **closed** | **the sequence above, 80 ms preroll (current)** | **408** (4 runs: 102, 102, 102, 102) | **0** |
| 1080p59.94 | **opened and closed during each session, closed at every start** | the sequence above, 80 ms preroll | **102** | **0** |

Every row is one process running repeated stops and starts of the output while video plays on the host. The two bold rows in the
middle use **the same build**: 3 in 52 with the input open, 0 in 408 with it closed (Fisher exact test, one-sided, p = 0.0014). Over
all 59.94 runs, open 10 in 355 against closed 0 in 408 (p = 0.0004). At a true closed rate of 1 in 100, 0 in 408 would happen
1.7 % of the time. The 95 % upper bound on the closed rate is 0.73 %.

**Opening the input during a session did not trigger it.** In the last row, the input was opened 4 s after each output start and
closed 6 s later, 2 s before the next stop, so every start ran with the input closed. In all 100 sessions where it was opened during
playback, the embedded audio already playing carried on: sound from the first received sample, no gap of 1 ms or more, and the audio queue was
never seen to stop draining. Every start after such a session was normal (0 in 102). So far the failure needs the input open **at the
moment the output starts**. 102 starts cannot rule out a smaller effect of an earlier open: at 2.3 % per start, 0 in 102 happens 9 %
of the time.

On this card an open input also moves the output's clock, by up to about ±125 ppm, while it is open. We do not know whether that or
the open input itself is what matters.

The silent starts are not tied to where in the card's frame Start was called. A related, rarer variant has been seen twice in first
sessions, both with the input open: the audio started, but at a consumption point 386 and 989 samples off the video stream time, and
stayed there for the session. Neither has recurred since the sequence changes below.

## What we tried

- **Following the manual's start and stop order.** We now wait for the audio preroll to complete before `EndAudioPreroll`, keep
  `RenderAudioSamples` out of `StartScheduledPlayback`, and wait for `ScheduledPlaybackHasStopped` before tearing down. The rate went
  from 5 in 100 to 1 in 101. That is too few starts to credit the change.
- **Flushing and rescheduling during the session.** `FlushBufferedAudioSamples()`, then scheduling again from 20 ms past
  `GetScheduledStreamTime`. The flush left 5,999 samples queued, and the count then stayed at 5,999 through three such attempts.
  No audio played.
- **A full stop and start of the output.** This has revived the audio every time. It is our recovery now, at the cost of a
  visible restart of the picture. In all 8 silent starts we have logged, the next full start played audio
  normally. That includes the one natural silent start since we made the restart automatic.
- **When that stop and start are back to back** (the start begun within a few milliseconds of `DisableVideoOutput` and the
  release), we found a second failure, at 1080p23.976 while video plays: the new session's queued audio is gone within ~20 ms
  of `StartScheduledPlayback` (`GetBufferedAudioSampleFrameCount` reads 0, or ~3,800 short, while the stream time has advanced
  ~800–1,300 samples), and the embedded audio then plays off its picture for the whole session, mostly 0.85–0.99 s late (once +219 ms, once −3.9 ms
  after a gap). 8 of 11 such restarts at 23.976
  (with 80, 167 and 200 ms audio prerolls alike), 1 of 25 at 59.94. Paused, never. **With 500 ms between the stop and the start,
  12 of 12 were normal.** We now wait 500 ms (question 6).
- **A shallower audio preroll.** We tried prerolling only the audio covering the 4 prerolled video frames (3,203 samples) instead of
  200 ms. Over 102 starts: 1 silent start, the same rate. The card consumed 1 sample and then nothing, and the output restart revived it.
  (We first wrote here that the first video frame was held longer at those starts. That was our analysis: it counted our own
  picture's start-up hold, which is the same at 200 ms, against audio that now began earlier. The picture did not change.)
  Since 2026-11-12 our file playback, in the configuration under test, prerolls 80 ms of audio, or the 4 video frames' duration if
  that is longer (167 ms at 1080p23.976).

## Questions

1. **Does having a sub-device's input open (video and audio input enabled, streams started) affect the start of scheduled audio
   playback on the same sub-device**, in a full-duplex profile? Is this a known issue with `bmdAudioOutputStreamTimestamped` output on
   the DeckLink 8K Pro (or with Desktop Video 16.x), where the audio queue is accepted at Start but never consumed?
2. If an open input is a known factor, is there a supported order: for example, starting the output's streams before the input's, or
   a call that makes the output's audio engage independently of the input?
3. Is our sequence correct as written, in particular the audio preroll depth (80 ms against 4 video frames), and calling
   `EndAudioPreroll` from inside `RenderAudioSamples`?
4. Is there a supported way to restart the audio stream during scheduled playback without stopping the video (for example
   `DisableAudioOutput` / `EnableAudioOutput` while playback runs)?
5. Is there a state we can read after Start that tells us the audio has engaged, short of watching the buffered count?
6. Is there a required settle time after `DisableAudioOutput` / `DisableVideoOutput` before the same output is enabled and started
   again (see "back to back" above)?
