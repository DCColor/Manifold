// DeckLink loopback capture check (S7-5). Captures the SDI input of one device and records, per received frame: the
// detected mode and format-detection flags, the frame's colorspace / EOTF / HDR flag and static metadata as the SDK
// reports them, every ancillary packet (DID/SDID, line, data space, payload; ST 2108-1 is DID 0x41 SDID 0x0C), a scan of
// the raw VANC lines for ANC packet headers, and the v210 bytes (full FNV-1a, the sampled FNV Manifold's
// [SIGNAL-TRACE] prints, and a byte compare against a reference v210, e.g. Manifold's [SDI-DUMP] of the same frame).
// Prints a line only when something changes, then a summary. Enables input only. Not in the app.
// --input hdmi (S7-5 HDMI half, approved by Robbie 2026-10-25) is the one configuration write: it reads and logs the
// device's bmdDeckLinkConfigVideoInputConnection, refuses unless it is SDI, sets HDMI for the run, and on exit (or
// SIGINT / SIGTERM) sets the prior value back and releases the configuration object. It never calls
// WriteConfigurationToPreferences, so per the SDK (2.5.15) the change cannot outlive the process. Run the probe after.
//   build/decklink-loopback/capture --device 0 --seconds 6 [--input hdmi] [--ref f.v210] [--dumpdir d --dumpmax 8] [--label x]
#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <csignal>
#include <sys/time.h>
#include <ctime>
#include <cstring>
#include <mutex>
#include <string>
#include <unistd.h>
#include <vector>
#include "DeckLinkAPI.h"

static std::string fcc(int64_t v) {
    char c[5] = {(char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v, 0};
    for (int i = 0; i < 4; i++) if (c[i] < 32 || c[i] > 126) { char b[24]; snprintf(b, sizeof b, "0x%llx", (long long)v); return b; }
    return std::string("'") + c + "'";
}
static uint64_t fnv(const uint8_t *p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL; for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 0x100000001b3ULL; return h;
}
// The [SIGNAL-TRACE] hash: FNV-1a over every 64th 32-bit word (SignalTrace.note, DeckLinkService.swift).
static uint64_t sampled(const uint8_t *p, size_t n) {
    const uint32_t *w = (const uint32_t *)p; uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n / 4; i += 64) h = (h ^ (uint64_t)w[i]) * 0x100000001b3ULL; return h;
}
static std::string flagsStr(int64_t f) {
    std::string s;
    if (f & bmdDetectedVideoInputYCbCr422) s += "YCbCr422 "; if (f & bmdDetectedVideoInputRGB444) s += "RGB444 ";
    if (f & bmdDetectedVideoInput12BitDepth) s += "12bit "; if (f & bmdDetectedVideoInput10BitDepth) s += "10bit ";
    if (f & bmdDetectedVideoInput8BitDepth) s += "8bit "; if (f & bmdDetectedVideoInputDualStream3D) s += "3D ";
    return s.empty() ? "none" : s;
}

struct Args { int device = 0; double seconds = 6; std::string ref, dumpdir, label = "capture", input; int dumpmax = 0; } A;
static volatile sig_atomic_t stopRequested = 0;
// Wall-clock time of day, so a capture's lines can be lined up with another tool's event log.
static std::string wall() {
    timeval tv; gettimeofday(&tv, nullptr); tm lt; localtime_r(&tv.tv_sec, &lt);
    char b[32]; snprintf(b, sizeof b, "%02d:%02d:%02d.%03d", lt.tm_hour, lt.tm_min, lt.tm_sec, (int)(tv.tv_usec / 1000)); return b;
}
static void onSignal(int) { stopRequested = 1; }
static std::string conns(int64_t m) {
    std::string s;
    if (m & bmdVideoConnectionSDI) s += "SDI"; if (m & bmdVideoConnectionHDMI) s += s.empty() ? "HDMI" : "+HDMI";
    if (m & ~(int64_t)(bmdVideoConnectionSDI | bmdVideoConnectionHDMI)) { char b[32]; snprintf(b, sizeof b, "%s0x%llx", s.empty() ? "" : "+", (long long)(m & ~(int64_t)(bmdVideoConnectionSDI | bmdVideoConnectionHDMI))); s += b; }
    return s.empty() ? "none" : s;
}

class Cap : public IDeckLinkInputCallback {
public:
    IDeckLinkInput *in = nullptr; IDeckLinkStatus *st = nullptr;
    std::mutex mu; std::atomic<int> refs{1};
    std::vector<uint8_t> ref;
    long n = 0, dropped = 0, noInput = 0, refSame = 0, refDiff = 0, refSizeMismatch = 0, dumps = 0, s2108 = 0, rawAncFrames = 0;
    long anyPacketFrames = 0, rawVancOK = 0, rawVancFail = 0;
    BMDTimeValue lastT = -1, lastD = 0;
    std::string lastSig, lastAnc, lastFmt; uint64_t lastPic = 0;

    HRESULT QueryInterface(REFIID, LPVOID *) override { return E_NOINTERFACE; }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override { return --refs; }

    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents ev, IDeckLinkDisplayMode *mode, BMDDetectedVideoInputFormatFlags f) override {
        CFStringRef nm = nullptr; mode->GetName(&nm); char buf[128] = ""; if (nm) { CFStringGetCString(nm, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(nm); }
        int64_t cs = 0, dr = 0; if (st) { st->GetInt(bmdDeckLinkStatusDetectedVideoInputColorspace, &cs); st->GetInt(bmdDeckLinkStatusDetectedVideoInputDynamicRange, &dr); }
        printf("[%s] FORMAT CHANGED after rx #%ld: events%s%s%s → %s %s · detected %s· status colorspace %s dynamicRange %s\n", A.label.c_str(), n,
               (ev & bmdVideoInputDisplayModeChanged) ? " mode" : "", (ev & bmdVideoInputFieldDominanceChanged) ? " field" : "",
               (ev & bmdVideoInputColorspaceChanged) ? " colorspace" : "", buf, fcc(mode->GetDisplayMode()).c_str(), flagsStr(f).c_str(),
               fcc(cs).c_str(), fcc(dr).c_str());
        if (ev & bmdVideoInputDisplayModeChanged) {
            in->PauseStreams();
            in->EnableVideoInput(mode->GetDisplayMode(), bmdFormat10BitYUV, bmdVideoInputEnableFormatDetection);
            in->FlushStreams(); in->StartStreams(); lastT = -1;
        }
        fflush(stdout); return S_OK;
    }

    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *fr, IDeckLinkAudioInputPacket *) override {
        if (!fr) return S_OK;
        std::lock_guard<std::mutex> g(mu);
        long i = n++;
        BMDTimeValue t = 0, d = 0; fr->GetStreamTime(&t, &d, 240000);
        if (lastT >= 0 && d > 0 && t - lastT > d + d / 2) dropped += (long)llround((double)(t - lastT) / d) - 1;
        lastT = t; lastD = d;
        const BMDFrameFlags ff = fr->GetFlags();
        if (ff & bmdFrameHasNoInputSource) noInput++;
        // Signal as the SDK reports it on the frame.
        std::string sig;
        {
            IDeckLinkVideoFrameMetadataExtensions *m = nullptr; int64_t cs = -1, eotf = -1; char b[512];
            if (fr->QueryInterface(IID_IDeckLinkVideoFrameMetadataExtensions, (void **)&m) == S_OK && m) {
                m->GetInt(bmdDeckLinkFrameMetadataColorspace, &cs); m->GetInt(bmdDeckLinkFrameMetadataHDRElectroOpticalTransferFunc, &eotf);
                snprintf(b, sizeof b, "colorspace %s EOTF %lld HDR flag %s", cs == bmdColorspaceRec2020 ? "Rec.2020" : cs == bmdColorspaceRec709 ? "Rec.709" : fcc(cs).c_str(),
                         (long long)eotf, (ff & bmdFrameContainsHDRMetadata) ? "set" : "clear");
                sig = b;
                const BMDDeckLinkFrameMetadataID ids[12] = {
                    bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedY,
                    bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenY,
                    bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueY,
                    bmdDeckLinkFrameMetadataHDRWhitePointX, bmdDeckLinkFrameMetadataHDRWhitePointY,
                    bmdDeckLinkFrameMetadataHDRMaxDisplayMasteringLuminance, bmdDeckLinkFrameMetadataHDRMinDisplayMasteringLuminance,
                    bmdDeckLinkFrameMetadataHDRMaximumContentLightLevel, bmdDeckLinkFrameMetadataHDRMaximumFrameAverageLightLevel};
                double v[12]; int got = 0;
                for (int k = 0; k < 12; k++) { v[k] = NAN; if (m->GetFloat(ids[k], &v[k]) == S_OK) got++; }
                if (got) {
                    snprintf(b, sizeof b, " · static (%d/12 readable) R %.5f,%.5f G %.5f,%.5f B %.5f,%.5f W %.5f,%.5f max %.4f min %.5f MaxCLL %.0f MaxFALL %.0f",
                             got, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11]);
                    sig += b;
                } else sig += " · static none readable";
                m->Release();
            } else sig = "no metadata interface";
        }
        // Ancillary packets.
        std::string anc; int npk = 0;
        {
            IDeckLinkVideoFrameAncillaryPackets *ap = nullptr;
            if (fr->QueryInterface(IID_IDeckLinkVideoFrameAncillaryPackets, (void **)&ap) == S_OK && ap) {
                IDeckLinkAncillaryPacketIterator *it = nullptr;
                if (ap->GetPacketIterator(&it) == S_OK && it) {
                    IDeckLinkAncillaryPacket *p;
                    while (it->Next(&p) == S_OK) {
                        npk++; const void *data = nullptr; uint32_t sz = 0; p->GetBytes(bmdAncillaryPacketFormatUInt8, &data, &sz);
                        char b[96]; snprintf(b, sizeof b, "[DID 0x%02X SDID 0x%02X line %u stream %u %s %u B:", p->GetDID(), p->GetSDID(), p->GetLineNumber(),
                                              p->GetDataStreamIndex(), p->GetDataSpace() == bmdAncillaryDataSpaceVANC ? "VANC" : "HANC", sz);
                        anc += b;
                        for (uint32_t k = 0; k < sz && k < 64; k++) { char h[4]; snprintf(h, sizeof h, " %02x", ((const uint8_t *)data)[k]); anc += h; }
                        anc += "]";
                        if (p->GetDID() == 0x41 && p->GetSDID() == 0x0C) s2108++;
                        p->Release();
                    }
                    it->Release();
                }
                ap->Release();
            } else anc = "(no ancillary-packets interface)";
            if (npk) anyPacketFrames++;
        }
        // Raw VANC lines (deprecated interface): look for an ANC data flag 0x000 0x3FF 0x3FF in the 10-bit luma words.
        {
            IDeckLinkVideoFrameAncillary *va = nullptr;
            if (fr->GetAncillaryData(&va) != S_OK || !va) rawVancFail++;
            else {
                rawVancOK++;
                int hits = 0;
                for (uint32_t line = 1; line <= 41 && !hits; line++) {
                    void *buf = nullptr; if (va->GetBufferForVerticalBlankingLine(line, &buf) != S_OK || !buf) continue;
                    const uint32_t *w = (const uint32_t *)buf; const long words = fr->GetRowBytes() / 4;
                    std::vector<uint32_t> y; y.reserve(words * 3);
                    for (long k = 0; k + 3 < words; k += 4) { y.push_back((w[k] >> 10) & 0x3FF); y.push_back(w[k + 1] & 0x3FF); y.push_back((w[k + 1] >> 20) & 0x3FF);
                                                               y.push_back((w[k + 2] >> 10) & 0x3FF); y.push_back(w[k + 3] & 0x3FF); y.push_back((w[k + 3] >> 20) & 0x3FF); }
                    for (size_t k = 0; k + 2 < y.size(); k++) if (y[k] == 0 && y[k + 1] == 0x3FF && y[k + 2] == 0x3FF) { hits = 1; break; }
                }
                if (hits) rawAncFrames++;
                va->Release();
            }
        }
        // Picture bytes.
        uint64_t full = 0, samp = 0; long rb = fr->GetRowBytes(), h = fr->GetHeight(), w = fr->GetWidth(); std::string refres;
        IDeckLinkVideoBuffer *vb = nullptr;
        if (fr->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&vb) == S_OK && vb && vb->StartAccess(bmdBufferAccessRead) == S_OK) {
            void *bytes = nullptr; vb->GetBytes(&bytes); const size_t sz = (size_t)rb * h;
            full = fnv((const uint8_t *)bytes, sz); samp = sampled((const uint8_t *)bytes, sz);
            if (!ref.empty()) {
                if (ref.size() != sz) { refSizeMismatch++; refres = " ref SIZE MISMATCH"; }
                else if (memcmp(ref.data(), bytes, sz) == 0) { refSame++; refres = " = ref"; }
                else {
                    refDiff++; size_t k = 0; while (k < sz && ref[k] == ((uint8_t *)bytes)[k]) k++;
                    char b[64]; snprintf(b, sizeof b, " ≠ ref (first diff byte %zu, row %zu)", k, k / rb); refres = b;
                }
            }
            if (full != lastPic && dumps < A.dumpmax && !A.dumpdir.empty()) {
                char p[1024]; snprintf(p, sizeof p, "%s/%s-rx%05ld.v210", A.dumpdir.c_str(), A.label.c_str(), i);
                if (FILE *f = fopen(p, "wb")) { fwrite(bytes, 1, sz, f); fclose(f); dumps++; }
            }
            vb->EndAccess(bmdBufferAccessRead); vb->Release();
        }
        // The input's detection status as the driver reports it now (not per frame), and on HDMI what the output sends.
        int64_t dff = -1, dcs = 0, ddr = 0, hof = -1; std::string dv;
        if (st) { st->GetInt(bmdDeckLinkStatusDetectedVideoInputFormatFlags, &dff); st->GetInt(bmdDeckLinkStatusDetectedVideoInputColorspace, &dcs);
                  st->GetInt(bmdDeckLinkStatusDetectedVideoInputDynamicRange, &ddr); st->GetInt(bmdDeckLinkStatusHDMIOutputActualFormatFlags, &hof); }
        {
            IDeckLinkVideoFrameMetadataExtensions *m = nullptr;
            if (fr->QueryInterface(IID_IDeckLinkVideoFrameMetadataExtensions, (void **)&m) == S_OK && m) {
                uint32_t dvsz = 0; if (m->GetBytes(bmdDeckLinkFrameMetadataDolbyVision, nullptr, &dvsz) == S_OK && dvsz) dv = " DolbyVision " + std::to_string(dvsz) + " B";
                m->Release();
            }
        }
        char fmt[256]; snprintf(fmt, sizeof fmt, "%ldx%ld rowBytes %ld pix %s%s · status detected %s colorspace %s dynamicRange %s · HDMI out flags %lld%s", w, h, rb,
                                fcc(fr->GetPixelFormat()).c_str(), (ff & bmdFrameHasNoInputSource) ? " NO INPUT" : "", flagsStr(dff).c_str(), fcc(dcs).c_str(), fcc(ddr).c_str(),
                                (long long)hof, dv.c_str());
        const bool picCh = full != lastPic, sigCh = sig != lastSig, ancCh = anc != lastAnc, fmtCh = fmt != lastFmt;
        if (i == 0 || picCh || sigCh || ancCh || fmtCh) {
            printf("[%s] %s rx #%ld t=%.4fs%s%s%s%s · %s · picture FNV %016llx sampled %016llx%s · %s · ANC %d packet(s) %s\n", A.label.c_str(), wall().c_str(), i, (double)t / 240000,
                   picCh ? " PICTURE" : "", sigCh ? " SIGNAL" : "", ancCh ? " ANC" : "", fmtCh ? " FORMAT" : "", fmt,
                   (unsigned long long)full, (unsigned long long)samp, refres.c_str(), sig.c_str(), npk, anc.c_str());
            fflush(stdout);
        }
        lastPic = full; lastSig = sig; lastAnc = anc; lastFmt = fmt;
        return S_OK;
    }
};

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i]; auto nx = [&]() { return std::string(i + 1 < argc ? argv[++i] : ""); };
        if (a == "--device") A.device = std::stoi(nx()); else if (a == "--seconds") A.seconds = std::stod(nx());
        else if (a == "--ref") A.ref = nx(); else if (a == "--dumpdir") A.dumpdir = nx(); else if (a == "--dumpmax") A.dumpmax = std::stoi(nx());
        else if (a == "--label") A.label = nx(); else if (a == "--input") A.input = nx();
    }
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance(); if (!it) { printf("no driver\n"); return 2; }
    IDeckLink *dl = nullptr; for (int k = 0; k <= A.device; k++) { if (dl) dl->Release(); if (it->Next(&dl) != S_OK) { printf("no device %d\n", A.device); return 2; } }
    Cap c;
    if (!A.ref.empty()) { FILE *f = fopen(A.ref.c_str(), "rb"); if (!f) { printf("cannot read ref\n"); return 2; }
        fseek(f, 0, SEEK_END); c.ref.resize(ftell(f)); fseek(f, 0, SEEK_SET); fread(c.ref.data(), 1, c.ref.size(), f); fclose(f); }
    dl->QueryInterface(IID_IDeckLinkStatus, (void **)&c.st);
    if (dl->QueryInterface(IID_IDeckLinkInput, (void **)&c.in) != S_OK) { printf("no input interface\n"); return 2; }
    // --input hdmi: the run's one configuration write (see the header). Held for the run, restored and released after.
    IDeckLinkConfiguration *cfg = nullptr; int64_t priorConn = -1;
    if (!A.input.empty()) {
        if (A.input != "hdmi") { printf("--input takes hdmi\n"); return 2; }
        if (dl->QueryInterface(IID_IDeckLinkConfiguration, (void **)&cfg) != S_OK || !cfg) { printf("no configuration interface\n"); return 2; }
        if (cfg->GetInt(bmdDeckLinkConfigVideoInputConnection, &priorConn) != S_OK) { printf("cannot read VideoInputConnection\n"); cfg->Release(); return 2; }
        printf("[%s] CONFIG VideoInputConnection before: %s\n", A.label.c_str(), conns(priorConn).c_str());
        if (priorConn != bmdVideoConnectionSDI) { printf("[%s] REFUSED: prior input connection is not SDI; nothing set\n", A.label.c_str()); cfg->Release(); return 4; }
        signal(SIGINT, onSignal); signal(SIGTERM, onSignal);
        HRESULT sr = cfg->SetInt(bmdDeckLinkConfigVideoInputConnection, bmdVideoConnectionHDMI);
        int64_t now = -1; cfg->GetInt(bmdDeckLinkConfigVideoInputConnection, &now);
        printf("[%s] CONFIG SetInt(VideoInputConnection, HDMI) → 0x%08X; now %s (not written to preferences)\n", A.label.c_str(), (unsigned)sr, conns(now).c_str());
        if (sr != S_OK || now != bmdVideoConnectionHDMI) { cfg->SetInt(bmdDeckLinkConfigVideoInputConnection, priorConn); cfg->Release(); return 4; }
        usleep(1500000);   // let the input lock to the HDMI signal before reading its detected mode
    }
    auto restore = [&]() {
        if (!cfg) return;
        HRESULT rr = cfg->SetInt(bmdDeckLinkConfigVideoInputConnection, priorConn);
        int64_t now = -1; cfg->GetInt(bmdDeckLinkConfigVideoInputConnection, &now);
        printf("[%s] CONFIG restored VideoInputConnection → 0x%08X; now %s; releasing\n", A.label.c_str(), (unsigned)rr, conns(now).c_str());
        cfg->Release(); cfg = nullptr; fflush(stdout);
    };
    int64_t mode = bmdModeHD1080p25; if (c.st) c.st->GetInt(bmdDeckLinkStatusDetectedVideoInputMode, &mode);
    if (mode == 0 || mode == bmdModeUnknown) mode = bmdModeHD1080p25;
    c.in->SetCallback(&c);
    HRESULT hr = c.in->EnableVideoInput((BMDDisplayMode)mode, bmdFormat10BitYUV, bmdVideoInputEnableFormatDetection);
    printf("[%s] EnableVideoInput(%s, v210, format detection) → 0x%08X\n", A.label.c_str(), fcc(mode).c_str(), (unsigned)hr);
    if (hr != S_OK) { restore(); return 3; }
    c.in->StartStreams();
    for (double waited = 0; waited < A.seconds && !stopRequested; waited += 0.05) usleep(50000);
    if (stopRequested) printf("[%s] stopped early by signal\n", A.label.c_str());
    c.in->StopStreams(); c.in->SetCallback(nullptr); c.in->DisableVideoInput();
    std::lock_guard<std::mutex> g(c.mu);
    printf("[%s] SUMMARY frames=%ld dropped(input, by stream-time gaps)=%ld noInputSource=%ld · ref identical=%ld different=%ld sizeMismatch=%ld · "
           "frames with ANC packets=%ld · ST 2108-1 packets=%ld · raw VANC lines returned on %ld frames, refused on %ld; frames with a raw-VANC ANC header=%ld · dumps=%ld\n",
           A.label.c_str(), c.n, c.dropped, c.noInput, c.refSame, c.refDiff, c.refSizeMismatch, c.anyPacketFrames, c.s2108, c.rawVancOK, c.rawVancFail,
           c.rawAncFrames, c.dumps);
    restore();
    c.in->Release(); if (c.st) c.st->Release(); dl->Release(); it->Release();
    return 0;
}
