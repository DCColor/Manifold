// SDI A/V offset control (docs/CARD_CLOCK_FINDINGS.md §10.16, after the 1c wire results): plays a file to one device's output with no
// anchor loop, so a capture of the loop shows what the card and the capture path do to A/V alignment by themselves. Not in the app.
// Picture: raw v210 1920×1080 frames on stdin (ffmpeg decoding the file: -f rawvideo -c:v v210 -). Frame n is scheduled at stream time
// n × the mode's frame duration. Sound: the file's own PCM, 48 kHz 32-bit stereo interleaved (ffmpeg -f s32le -ac 2), sample m scheduled
// at stream time m / 48000 (bmdAudioOutputStreamTimestamped). Both on one StartScheduledPlayback(0) timeline, so picture n and the samples
// that belong to it (from n × samples per frame) are handed to the card for the same instant: the SDK's own alignment and nothing else.
// Sets no profile and writes no configuration. Run with Manifold closed.
//   ffmpeg -i f.mov -t S -f rawvideo -c:v v210 - | build/decklink-loopback/syncout --device 0 --rate 5994|2398 --audio f.s32 --seconds S
// --flush-at T [--flush-every P] [--flush-lead MS] (§10.20 C0, the 1c probe): at stream time T (then every P s), FlushBufferedAudioSamples
// mid-run, read the card's stream time, and schedule the file again from its own sample at that time + MS (default 10), so the wire
// shows what a flush does to a running timestamped stream: what plays between the flush and the restart, and where the restart lands.
// --overlay-at T [--overlay-every P] (§10.22): with NO flush, schedule the negative of everything queued from the stream time + the lead
// to the end of the queue: zeros on the wire there if the card adds to queued samples too, the inverted sound if it replaces them.
// --audio-depth MS: keep the audio queue MS past the card's position (topped up at each frame) instead of 250 ms past the newest picture.
#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <csignal>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>
#include "DeckLinkAPI.h"

static std::atomic<bool> gStop{false};
static void onSignal(int) { gStop = true; }

static const int W = 1920, H = 1080, RB = 5120;   // v210 1080: 1920 / 6 × 16 bytes a row
static const size_t FRAME_BYTES = (size_t)RB * H;
static const int POOL = 12;                        // frames queued ahead: 200 ms at 59.94, 500 ms at 23.976
static const double AUDIO_AHEAD = 0.25;            // audio scheduled this far past the newest scheduled picture

struct Player : public IDeckLinkVideoOutputCallback {
    IDeckLinkOutput *out; BMDTimeValue dur; BMDTimeScale scale; FILE *audio;
    int64_t nextFrame = 0, maxFrames = 0, audioNext = 0; bool videoEOF = false, audioEOF = false;
    std::atomic<long> completed{0}, late{0}, dropped{0}, flushed{0}; long shortAudio = 0, readFail = 0;
    std::vector<int32_t> abuf;
    double flushAt = -1, flushEvery = 0, flushLead = 0.010; int flushes = 0;
    double overlayAt = -1, overlayEvery = 0; int overlays = 0; std::vector<int32_t> obuf; double audioDepth = 0;
    Player(IDeckLinkOutput *o, BMDTimeValue d, BMDTimeScale s, FILE *a, int64_t mf) : out(o), dur(d), scale(s), audio(a), maxFrames(mf) {}

    // One picture from stdin into the frame and onto the timeline at its own index. False at the end of the input.
    bool scheduleNext(IDeckLinkMutableVideoFrame *f) {
        if (videoEOF || nextFrame >= maxFrames) return false;
        IDeckLinkVideoBuffer *b = nullptr; void *bytes = nullptr;
        if (f->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&b) != S_OK || !b) return false;
        b->StartAccess(bmdBufferAccessWrite); b->GetBytes(&bytes);
        size_t got = 0; while (got < FRAME_BYTES) { size_t r = fread((uint8_t *)bytes + got, 1, FRAME_BYTES - got, stdin); if (!r) break; got += r; }
        b->EndAccess(bmdBufferAccessWrite); b->Release();
        if (got < FRAME_BYTES) { videoEOF = true; if (got) readFail++; return false; }
        out->ScheduleVideoFrame(f, nextFrame * dur, dur, scale);
        nextFrame++;
        return true;
    }
    // Audio through the end of the newest scheduled picture plus AUDIO_AHEAD, each sample at its own index. Never blocks.
    void topUpAudio() {
        int64_t until = (int64_t)((double)nextFrame * dur / scale * 48000.0 + AUDIO_AHEAD * 48000.0);
        if (audioDepth > 0) {   // --audio-depth: hold the queue at a fixed depth past the card's position instead
            BMDTimeValue now = 0; double sp = 0;
            if (out->GetScheduledStreamTime(48000, &now, &sp) == S_OK && sp > 0) until = now + (int64_t)(audioDepth * 48000.0);
            else until = (int64_t)(audioDepth * 48000.0);
        }
        while (!audioEOF && audioNext < until) {
            const int64_t want = std::min<int64_t>(until - audioNext, 4800);
            abuf.resize((size_t)want * 2);
            const size_t r = fread(abuf.data(), 8, (size_t)want, audio);
            if (r == 0) { audioEOF = true; break; }
            uint32_t written = 0;
            if (out->ScheduleAudioSamples(abuf.data(), (uint32_t)r, audioNext, 48000, &written) != S_OK) { audioEOF = true; break; }
            if (written < r) { shortAudio++; fseeko(audio, -(off_t)(r - written) * 8, SEEK_CUR); audioNext += written; break; }
            audioNext += written;
        }
    }
    // The C0 probe: flush, then restart the file at its own sample index a lead past the card's stream time now.
    void flushAndRestart() {
        uint32_t before = 0, after = 0; BMDTimeValue now = 0; double speed = 0;
        out->GetBufferedAudioSampleFrameCount(&before);
        const HRESULT hr = out->FlushBufferedAudioSamples();
        out->GetBufferedAudioSampleFrameCount(&after);
        out->GetScheduledStreamTime(48000, &now, &speed);
        const int64_t restart = now + (int64_t)(flushLead * 48000.0);
        const int64_t dropped = audioNext - restart;
        printf("[syncout] flush #%d → 0x%08X at stream sample %lld (%.3f s): buffered %u before, %u after; scheduled up to %lld; restart at %lld (%+lld samples against the old end)\n",
               ++flushes, (unsigned)hr, (long long)now, now / 48000.0, before, after, (long long)audioNext, (long long)restart, (long long)-dropped);
        fflush(stdout);
        audioNext = restart; audioEOF = false;
        fseeko(audio, (off_t)restart * 8, SEEK_SET);
        topUpAudio();
        uint32_t refilled = 0; out->GetBufferedAudioSampleFrameCount(&refilled);
        printf("[syncout] flush #%d: rescheduled to %lld, card holds %u\n", flushes, (long long)audioNext, refilled); fflush(stdout);
    }
    void overlayNegative() {
        uint32_t before = 0; BMDTimeValue now = 0; double speed = 0;
        out->GetBufferedAudioSampleFrameCount(&before);
        out->GetScheduledStreamTime(48000, &now, &speed);
        const int64_t from = now + (int64_t)(flushLead * 48000.0), to = audioNext;
        if (to <= from) return;
        const off_t keep = ftello(audio);
        obuf.resize((size_t)(to - from) * 2);
        fseeko(audio, (off_t)from * 8, SEEK_SET);
        const size_t r = fread(obuf.data(), 8, (size_t)(to - from), audio);
        fseeko(audio, keep, SEEK_SET);
        for (size_t i = 0; i < r * 2; i++) obuf[i] = obuf[i] == INT32_MIN ? INT32_MAX : -obuf[i];
        uint32_t written = 0;
        const HRESULT hr = out->ScheduleAudioSamples(obuf.data(), (uint32_t)r, from, 48000, &written);
        uint32_t after = 0; out->GetBufferedAudioSampleFrameCount(&after);
        printf("[syncout] overlay #%d → 0x%08X at stream sample %lld: the negative of %lld..%lld (%zu samples), written %u; buffered %u before, %u after\n",
               ++overlays, (unsigned)hr, (long long)now, (long long)from, (long long)to, r, written, before, after);
        fflush(stdout);
    }
    HRESULT ScheduledFrameCompleted(IDeckLinkVideoFrame *f, BMDOutputFrameCompletionResult r) override {
        switch (r) { case bmdOutputFrameCompleted: completed++; break; case bmdOutputFrameDisplayedLate: late++; break;
                     case bmdOutputFrameDropped: dropped++; break; case bmdOutputFrameFlushed: flushed++; return S_OK; default: break; }
        if (gStop) return S_OK;
        if (!scheduleNext(static_cast<IDeckLinkMutableVideoFrame *>(f))) gStop = true;
        if (overlayAt >= 0) {
            BMDTimeValue now = 0; double sp = 0; out->GetScheduledStreamTime(scale, &now, &sp);
            if ((double)now / scale >= overlayAt) { overlayNegative(); overlayAt = overlayEvery > 0 ? overlayAt + overlayEvery : -1; }
        }
        if (flushAt >= 0) {
            BMDTimeValue now = 0; double sp = 0; out->GetScheduledStreamTime(scale, &now, &sp);
            if ((double)now / scale >= flushAt) { flushAndRestart(); flushAt = flushEvery > 0 ? flushAt + flushEvery : -1; return S_OK; }
        }
        topUpAudio();
        return S_OK;
    }
    HRESULT ScheduledPlaybackHasStopped() override { return S_OK; }
    HRESULT QueryInterface(REFIID, LPVOID *ppv) override { *ppv = nullptr; return E_NOINTERFACE; }
    ULONG AddRef() override { return 1; }
    ULONG Release() override { return 1; }
};

int main(int argc, char **argv) {
    int device = 0; std::string rate = "5994", audioPath; double seconds = 60, flushAt = -1, flushEvery = 0, flushLeadMs = 10, overlayAt = -1, overlayEvery = 0, audioDepthMs = 0;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i]; auto nx = [&]() { return std::string(i + 1 < argc ? argv[++i] : ""); };
        if (a == "--device") device = std::stoi(nx()); else if (a == "--rate") rate = nx();
        else if (a == "--audio") audioPath = nx(); else if (a == "--seconds") seconds = std::stod(nx());
        else if (a == "--flush-at") flushAt = std::stod(nx()); else if (a == "--flush-every") flushEvery = std::stod(nx());
        else if (a == "--flush-lead") flushLeadMs = std::stod(nx());
        else if (a == "--audio-depth") audioDepthMs = std::stod(nx());
        else if (a == "--overlay-at") overlayAt = std::stod(nx()); else if (a == "--overlay-every") overlayEvery = std::stod(nx());
    }
    BMDDisplayMode mode; BMDTimeValue dur; BMDTimeScale scale;
    if (rate == "5994") { mode = bmdModeHD1080p5994; dur = 1001; scale = 60000; }
    else if (rate == "2398") { mode = bmdModeHD1080p2398; dur = 1001; scale = 24000; }
    else { printf("[syncout] --rate 5994|2398\n"); return 2; }
    FILE *audio = fopen(audioPath.c_str(), "rb"); if (!audio) { printf("[syncout] cannot read --audio\n"); return 2; }
    signal(SIGINT, onSignal); signal(SIGTERM, onSignal);
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance(); if (!it) { printf("[syncout] no driver\n"); return 2; }
    IDeckLink *dl = nullptr; for (int k = 0; k <= device; k++) { if (dl) dl->Release(); if (it->Next(&dl) != S_OK) return 2; }
    IDeckLinkOutput *out = nullptr; if (dl->QueryInterface(IID_IDeckLinkOutput, (void **)&out) != S_OK) return 2;
    HRESULT hr = out->EnableVideoOutput(mode, bmdVideoOutputFlagDefault);
    printf("[syncout] EnableVideoOutput(%s) → 0x%08X\n", rate.c_str(), (unsigned)hr); if (hr != S_OK) return 3;
    hr = out->EnableAudioOutput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger, 2, bmdAudioOutputStreamTimestamped);
    printf("[syncout] EnableAudioOutput(48 kHz, 32-bit, 2 ch, timestamped) → 0x%08X\n", (unsigned)hr); if (hr != S_OK) { out->DisableVideoOutput(); return 3; }
    const int64_t maxFrames = (int64_t)(seconds * scale / dur);
    Player p(out, dur, scale, audio, maxFrames);
    p.flushAt = flushAt; p.flushEvery = flushEvery; p.flushLead = flushLeadMs / 1000.0; p.overlayAt = overlayAt; p.overlayEvery = overlayEvery; p.audioDepth = audioDepthMs / 1000.0;
    std::vector<IDeckLinkMutableVideoFrame *> pool;
    for (int k = 0; k < POOL; k++) {
        IDeckLinkMutableVideoFrame *f = nullptr;
        if (out->CreateVideoFrame(W, H, RB, bmdFormat10BitYUV, bmdFrameFlagDefault, &f) != S_OK || !f) { printf("[syncout] CreateVideoFrame failed\n"); return 3; }
        pool.push_back(f);
    }
    out->SetScheduledFrameCompletionCallback(&p);
    out->BeginAudioPreroll();
    for (auto *f : pool) if (!p.scheduleNext(f)) break;
    p.topUpAudio();
    out->EndAudioPreroll();
    uint32_t bv = 0, ba = 0; out->GetBufferedVideoFrameCount(&bv); out->GetBufferedAudioSampleFrameCount(&ba);
    hr = out->StartScheduledPlayback(0, scale, 1.0);
    printf("[syncout] prerolled %lld frames, %lld samples (card holds %u frames, %u samples) · StartScheduledPlayback → 0x%08X\n",
           (long long)p.nextFrame, (long long)p.audioNext, bv, ba, (unsigned)hr);
    fflush(stdout);
    while (!gStop) usleep(100000);
    usleep(300000);   // the last scheduled pictures reach the wire
    BMDTimeValue stopAt = 0; out->StopScheduledPlayback(0, &stopAt, scale);
    usleep(200000);
    out->SetScheduledFrameCompletionCallback(nullptr);
    printf("[syncout] stopped at stream %lld/%lld: frames scheduled %lld, completed %ld, late %ld, dropped %ld, flushed %ld · audio samples scheduled %lld, short writes %ld · %s\n",
           (long long)stopAt, (long long)scale, (long long)p.nextFrame, p.completed.load(), p.late.load(), p.dropped.load(), p.flushed.load(),
           (long long)p.audioNext, p.shortAudio, p.videoEOF ? "input ended" : "time reached");
    out->DisableAudioOutput(); out->DisableVideoOutput();
    for (auto *f : pool) f->Release();
    out->Release(); dl->Release(); it->Release(); fclose(audio);
    return 0;
}
