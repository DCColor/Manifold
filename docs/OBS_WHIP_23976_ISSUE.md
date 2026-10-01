**Title:** WHIP output: video RTP timestamps run ~66.6 ppm fast at 23.976 fps (rounded per-frame increments accumulate)

### Summary

With the WHIP output at 23.976 fps (24000/1001), the video RTP timestamps advance 66.6 ppm faster than real time: about 4 ms per minute, or 240 ms per hour, relative to the audio. Each frame's duration is rounded to whole 90 kHz ticks and the rounded values are summed, so the rounding error accumulates instead of staying bounded.

### Where it happens (OBS 32.2.2, bundled libdatachannel v0.24.2)

`plugins/obs-webrtc/whip-output.cpp`, `WHIPOutput::Data()`, video branch:

```cpp
127:	rtp_config->timestamp = videoLayerState->rtpTimestamp;
128:	int64_t duration = packet->dts_usec - videoLayerState->lastVideoTimestamp;
130:	Send(packet->data, packet->size, duration, video_track, video_sr_reporter);
133:	videoLayerState->lastVideoTimestamp = packet->dts_usec;
134:	videoLayerState->rtpTimestamp = rtp_config->timestamp;
```

`WHIPOutput::Send()`:

```cpp
707:	auto elapsed_seconds = double(duration) / (1000.0 * 1000.0);
710:	uint32_t elapsed_timestamp = rtp_config->secondsToTimestamp(elapsed_seconds);
713:	rtp_config->timestamp = rtp_config->timestamp + elapsed_timestamp;
726:	track->send(sample);
```

libdatachannel v0.24.2, `src/rtppacketizationconfig.cpp`, which rounds to the nearest tick:

```cpp
46: uint32_t RtpPacketizationConfig::getTimestampFromSeconds(double seconds, uint32_t clockRate) {
47: 	return uint32_t(int64_t(round(seconds * double(clockRate))));
```

`dts_usec` is whole microseconds (`libobs/obs-internal.h`: `packet->dts * MICROSECOND_DEN / packet->timebase_den`, integer division). So at 23.976 each frame's duration is 41,708 or 41,709 µs, which is 3753.72 or 3753.81 ticks. Both round to **3754**, every frame, against the exact **3753.75**. That's +0.25 ticks per frame: 0.25 / 3753.75 = **+66.6 ppm**.

libdatachannel's packetizer can compute the timestamp from total elapsed time (`startTimestamp + secondsToTimestamp(frameInfo->timestampSeconds)`, `src/rtppacketizer.cpp`), but only when the message carries a `FrameInfo`. OBS sends a plain byte vector, so the summed value is used.

### Affected frame rates

The table below follows from the arithmetic, plus a simulation of the code path above. Only 23.976 is measured; see the next section.

| Frame rate | Exact ticks per frame | Result |
|---|---|---|
| 23.976 | 3753.75 | +66.6 ppm (video fast) |
| 59.94 | 1501.5 | −111 ppm (video slow): µs durations 16683/16683/16684 round to 1501/1501/1502 |
| 24, 25, 29.97, 30, 50, 60 | whole numbers | no error |

Audio is unaffected: a 20 ms Opus packet is 20,000 µs, exactly 960 ticks at 48 kHz.

### Measurements (23.976)

Measured from the receiving side over 30+ minute sessions, OBS 32.2.2 on macOS. Each RTP clock was compared with the receiver's wall clock:

| Session | Video RTP vs wall | Audio RTP vs wall | Video − audio |
|---|---|---|---|
| media source scene, via MediaMTX | +71.9 ppm | +5.4 ppm | +66.5 ppm |
| DeckLink SDI input, via Cloudflare Stream | +60.8 ppm | −6.7 ppm | +67.5 ppm |
| DeckLink SDI input, via MediaMTX | +60.1 ppm | −6.6 ppm | +66.7 ppm |

Over 1380 s, the predicted A/V content drift on the received RTP timestamps is 91.9 ms. We measured −92.1, −92.05 and −92.06 ms with a flash/beep test signal. OBS's local recording of the same output holds A/V flat (+0.02 ms over the same span), so capture and the canvas are fine. Only the WHIP RTP stamping is off.

### Why it often goes unnoticed

OBS's RTCP Sender Reports pair each RTP timestamp with the wall-clock time at send, so they carry the +66.6 ppm slope. A receiver that follows SRs, behind a relay that passes them through or regenerates consistent ones, corrects the error. We verified this on Cloudflare Stream, and on MediaMTX with `useAbsoluteTimestamp: true`.

Receivers or relays without usable SRs drift steadily. Lip-sync starts correct and is about 240 ms off after an hour. MediaMTX with default settings, which generates its own arrival-based SRs, drifts this way.

### Steps to reproduce

1. Settings → Video → FPS: 23.976 (shown as 23.98).
2. Stream with the WHIP output to any WHIP server, for example MediaMTX.
3. Log the received video RTP timestamps on the server or receiver side.
4. Every frame advances by exactly 3754 (expected: a mix averaging 3753.75). Over 10+ minutes, video RTP gains about 66.6 ppm on both the wall clock and the audio RTP.

### Suggested fix

Derive each video timestamp from total elapsed time rather than summing rounded per-frame steps. Either option keeps the error within one tick instead of accumulating, and neither needs a libdatachannel change:

- **In `WHIPOutput`:** keep the first packet's `dts_usec` and set `rtp_config->timestamp = base + secondsToTimestamp((dts_usec - first_dts_usec) / 1e6)`. This replaces the running sum.
- **Via libdatachannel:** attach a `FrameInfo` carrying the frame's total elapsed time, so the packetizer computes `startTimestamp + round(elapsed × 90000)` itself.

Using the packet's rational `dts` / `timebase_den` directly, instead of truncated microseconds, would make the timestamps exact.

### Environment

- OBS 32.2.2 (macOS 26.5.1, Apple M4 Max)
- bundled libdatachannel v0.24.2
- 1920×1080 at 24000/1001, H.264, Opus 48 kHz
- WHIP to MediaMTX v1.21.1 and to Cloudflare Stream
- Log: [Help → Log Files → Upload Current Log File]
