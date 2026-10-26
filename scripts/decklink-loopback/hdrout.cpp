// DeckLink HDR signalling control (S7-5 HDMI half): outputs a mid-grey 1080p25 v210 frame on one device for N seconds,
// tagged with the given colorspace, EOTF, HDR flag and (optionally) static values, so a capture of the HDMI loop shows
// what the input reports for a known signal, independent of Manifold. Uses the card's output as any playback app does;
// sets no profile. Run with Manifold closed. Not in the app.
// --rec2020out is its one configuration write: it reads and logs bmdDeckLinkConfigRec2020Output, sets it true for the
// run only, never calls WriteConfigurationToPreferences, and sets the prior value back and releases on exit.
//   build/decklink-loopback/hdrout --device 0 --seconds 4 --colorspace 2020|709 --eotf 0..7 [--flag] [--maxcll 1234 | --zero]
//                                  [--rec2020out] [--then-eotf N [--then-flag] [--then-zero] [--then-colorspace 709|2020] --then-after S]
// --then-*: after S seconds the SAME scheduled output switches to a second frame with that signal, so a change can be
// seen without the output restarting (an idle card passes its input through, which can reset an HDMI sink).
// --phase cs,eotf,flag,maxcll,seconds (repeatable; maxcll -1 = no values, 0 = all values 0): any number of signals in one
// output session, shown synchronously in order. Overrides the single-frame options.
#include <CoreFoundation/CoreFoundation.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>
#include "DeckLinkAPI.h"

int main(int argc, char **argv) {
    int device = 0, eotf = 0; double seconds = 4, maxcll = -1; bool flag = false, zero = false, rec2020out = false;
    BMDColorspace cs = bmdColorspaceRec709;
    struct Phase { BMDColorspace cs; int eotf; bool flag; double maxcll, seconds; };
    std::vector<Phase> phases;
    int thenEotf = -1; bool thenFlag = false, thenZero = false; double thenAfter = 0; BMDColorspace thenCs = (BMDColorspace)0;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i]; auto nx = [&]() { return std::string(i + 1 < argc ? argv[++i] : ""); };
        if (a == "--device") device = std::stoi(nx()); else if (a == "--seconds") seconds = std::stod(nx());
        else if (a == "--eotf") eotf = std::stoi(nx()); else if (a == "--flag") flag = true;
        else if (a == "--maxcll") maxcll = std::stod(nx()); else if (a == "--zero") zero = true;
        else if (a == "--rec2020out") rec2020out = true;
        else if (a == "--then-eotf") thenEotf = std::stoi(nx()); else if (a == "--then-flag") thenFlag = true;
        else if (a == "--then-zero") thenZero = true; else if (a == "--then-after") thenAfter = std::stod(nx());
        else if (a == "--phase") {
            Phase ph{}; int c = 0, f = 0; double m = -1, sec = 1;
            if (sscanf(nx().c_str(), "%d,%d,%d,%lf,%lf", &c, &ph.eotf, &f, &m, &sec) == 5) {
                ph.cs = c == 2020 ? bmdColorspaceRec2020 : bmdColorspaceRec709; ph.flag = f != 0; ph.maxcll = m; ph.seconds = sec; phases.push_back(ph);
            } else { printf("[hdrout] --phase takes cs,eotf,flag,maxcll,seconds\n"); return 2; }
        }
        else if (a == "--then-colorspace") thenCs = nx() == "2020" ? bmdColorspaceRec2020 : bmdColorspaceRec709;
        else if (a == "--colorspace") cs = nx() == "2020" ? bmdColorspaceRec2020 : bmdColorspaceRec709;
    }
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance(); if (!it) return 2;
    IDeckLink *dl = nullptr; for (int k = 0; k <= device; k++) { if (dl) dl->Release(); if (it->Next(&dl) != S_OK) return 2; }
    IDeckLinkOutput *out = nullptr; if (dl->QueryInterface(IID_IDeckLinkOutput, (void **)&out) != S_OK) return 2;
    IDeckLinkConfiguration *cfg = nullptr; bool prior2020 = false;
    if (rec2020out) {
        if (dl->QueryInterface(IID_IDeckLinkConfiguration, (void **)&cfg) != S_OK || !cfg) { printf("[hdrout] no configuration interface\n"); return 2; }
        HRESULT g = cfg->GetFlag(bmdDeckLinkConfigRec2020Output, &prior2020);
        HRESULT sr = cfg->SetFlag(bmdDeckLinkConfigRec2020Output, true);
        bool now = false; cfg->GetFlag(bmdDeckLinkConfigRec2020Output, &now);
        printf("[hdrout] CONFIG Rec2020Output before %s (0x%08X); SetFlag(true) → 0x%08X; now %s (not written to preferences)\n",
               prior2020 ? "true" : "false", (unsigned)g, (unsigned)sr, now ? "true" : "false");
    }
    HRESULT hr = out->EnableVideoOutput(bmdModeHD1080p25, bmdVideoOutputFlagDefault);
    printf("[hdrout] EnableVideoOutput(1080p25) → 0x%08X\n", (unsigned)hr); if (hr != S_OK) return 3;
    IDeckLinkMutableVideoFrame *fr = nullptr;
    out->CreateVideoFrame(1920, 1080, 5120, bmdFormat10BitYUV, flag ? bmdFrameContainsHDRMetadata : bmdFrameFlagDefault, &fr);
    IDeckLinkVideoBuffer *vb = nullptr;
    if (fr->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&vb) == S_OK && vb->StartAccess(bmdBufferAccessWrite) == S_OK) {
        void *b = nullptr; vb->GetBytes(&b); uint32_t *w = (uint32_t *)b;
        const uint32_t y = 512, c = 512, w0 = c | y << 10 | c << 20, w1 = y | c << 10 | y << 20;   // Y 512, Cb/Cr 512
        for (int i = 0; i < 5120 * 1080 / 4; i += 4) { w[i] = w0; w[i + 1] = w1; w[i + 2] = w0; w[i + 3] = w1; }
        vb->EndAccess(bmdBufferAccessWrite); vb->Release();
    }
    IDeckLinkVideoFrameMutableMetadataExtensions *m = nullptr;
    if (fr->QueryInterface(IID_IDeckLinkVideoFrameMutableMetadataExtensions, (void **)&m) == S_OK) {
        printf("[hdrout] colorspace %s EOTF %d flag %s", cs == bmdColorspaceRec2020 ? "Rec.2020" : "Rec.709", eotf, flag ? "set" : "clear");
        m->SetInt(bmdDeckLinkFrameMetadataColorspace, cs);
        m->SetInt(bmdDeckLinkFrameMetadataHDRElectroOpticalTransferFunc, eotf);
        if (zero) {
            const BMDDeckLinkFrameMetadataID ids[12] = {
                bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedY,
                bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenY,
                bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueY,
                bmdDeckLinkFrameMetadataHDRWhitePointX, bmdDeckLinkFrameMetadataHDRWhitePointY,
                bmdDeckLinkFrameMetadataHDRMaxDisplayMasteringLuminance, bmdDeckLinkFrameMetadataHDRMinDisplayMasteringLuminance,
                bmdDeckLinkFrameMetadataHDRMaximumContentLightLevel, bmdDeckLinkFrameMetadataHDRMaximumFrameAverageLightLevel};
            for (int k = 0; k < 12; k++) m->SetFloat(ids[k], 0);
            printf(" · static all 0");
        }
        if (maxcll >= 0) {   // P3-D65 mastering, 1000 / 0.005, the given MaxCLL and MaxFALL 400: values no fixture uses
            const double v[12] = {0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329, 1000, 0.005, maxcll, 400};
            const BMDDeckLinkFrameMetadataID ids[12] = {
                bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedY,
                bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenY,
                bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueY,
                bmdDeckLinkFrameMetadataHDRWhitePointX, bmdDeckLinkFrameMetadataHDRWhitePointY,
                bmdDeckLinkFrameMetadataHDRMaxDisplayMasteringLuminance, bmdDeckLinkFrameMetadataHDRMinDisplayMasteringLuminance,
                bmdDeckLinkFrameMetadataHDRMaximumContentLightLevel, bmdDeckLinkFrameMetadataHDRMaximumFrameAverageLightLevel};
            for (int k = 0; k < 12; k++) m->SetFloat(ids[k], v[k]);
            printf(" · static P3-D65 1000 / 0.005 MaxCLL %.0f MaxFALL 400", maxcll);
        }
        printf("\n"); m->Release();
    }
    if (!phases.empty()) {
        // Each phase gets its own frame, a copy of the first frame's picture, tagged with that phase's signal.
        const BMDDeckLinkFrameMetadataID ids[12] = {
            bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedY,
            bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenY,
            bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueY,
            bmdDeckLinkFrameMetadataHDRWhitePointX, bmdDeckLinkFrameMetadataHDRWhitePointY,
            bmdDeckLinkFrameMetadataHDRMaxDisplayMasteringLuminance, bmdDeckLinkFrameMetadataHDRMinDisplayMasteringLuminance,
            bmdDeckLinkFrameMetadataHDRMaximumContentLightLevel, bmdDeckLinkFrameMetadataHDRMaximumFrameAverageLightLevel};
        std::vector<IDeckLinkMutableVideoFrame *> pf;
        void *src = nullptr; IDeckLinkVideoBuffer *sb = nullptr;
        fr->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&sb); sb->StartAccess(bmdBufferAccessRead); sb->GetBytes(&src);
        for (auto &ph : phases) {
            IDeckLinkMutableVideoFrame *f = nullptr;
            out->CreateVideoFrame(1920, 1080, 5120, bmdFormat10BitYUV, ph.flag ? bmdFrameContainsHDRMetadata : bmdFrameFlagDefault, &f);
            IDeckLinkVideoBuffer *db = nullptr; void *dst = nullptr;
            if (f->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&db) == S_OK && db->StartAccess(bmdBufferAccessWrite) == S_OK) {
                db->GetBytes(&dst); memcpy(dst, src, 5120 * 1080); db->EndAccess(bmdBufferAccessWrite); }
            if (db) db->Release();
            IDeckLinkVideoFrameMutableMetadataExtensions *pm = nullptr;
            if (f->QueryInterface(IID_IDeckLinkVideoFrameMutableMetadataExtensions, (void **)&pm) == S_OK) {
                pm->SetInt(bmdDeckLinkFrameMetadataColorspace, ph.cs);
                pm->SetInt(bmdDeckLinkFrameMetadataHDRElectroOpticalTransferFunc, ph.eotf);
                if (ph.maxcll >= 0) {
                    const double v[12] = {0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329, 1000, 0.005, ph.maxcll, 400};
                    for (int k = 0; k < 12; k++) pm->SetFloat(ids[k], ph.maxcll == 0 ? 0 : v[k]);
                }
                pm->Release();
            }
            printf("[hdrout] phase: colorspace %s EOTF %d flag %s%s for %.1f s\n", ph.cs == bmdColorspaceRec2020 ? "Rec.2020" : "Rec.709", ph.eotf,
                   ph.flag ? "set" : "clear", ph.maxcll < 0 ? "" : ph.maxcll == 0 ? " · static all 0" : (" · MaxCLL " + std::to_string((int)ph.maxcll)).c_str(), ph.seconds);
            pf.push_back(f);
        }
        sb->EndAccess(bmdBufferAccessRead); sb->Release();
        int fails = 0, shown = 0;
        for (size_t p = 0; p < phases.size(); p++) {
            printf("[hdrout] phase %zu starts\n", p + 1); fflush(stdout);
            for (int i = 0; i < (int)(phases[p].seconds * 25); i++, shown++) { if (out->DisplayVideoFrameSync(pf[p]) != S_OK) fails++; usleep(40000); }
        }
        printf("[hdrout] %d frames shown synchronously, %d refused\n", shown, fails); fflush(stdout);
        for (auto *f : pf) f->Release();
        fr->Release(); out->DisableVideoOutput(); out->Release();
        if (cfg) { cfg->SetFlag(bmdDeckLinkConfigRec2020Output, prior2020); cfg->Release(); }
        dl->Release(); it->Release();
        return 0;
    }
    IDeckLinkMutableVideoFrame *fr2 = nullptr;
    if (thenEotf >= 0) {
        if (thenCs == 0) thenCs = cs;
        out->CreateVideoFrame(1920, 1080, 5120, bmdFormat10BitYUV, thenFlag ? bmdFrameContainsHDRMetadata : bmdFrameFlagDefault, &fr2);
        IDeckLinkVideoBuffer *b1 = nullptr, *b2 = nullptr; void *p1 = nullptr, *p2 = nullptr;
        if (fr->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&b1) == S_OK && fr2->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&b2) == S_OK
            && b1->StartAccess(bmdBufferAccessRead) == S_OK && b2->StartAccess(bmdBufferAccessWrite) == S_OK) {
            b1->GetBytes(&p1); b2->GetBytes(&p2); memcpy(p2, p1, 5120 * 1080);
            b1->EndAccess(bmdBufferAccessRead); b2->EndAccess(bmdBufferAccessWrite);
        }
        if (b1) b1->Release(); if (b2) b2->Release();
        IDeckLinkVideoFrameMutableMetadataExtensions *m2 = nullptr;
        if (fr2->QueryInterface(IID_IDeckLinkVideoFrameMutableMetadataExtensions, (void **)&m2) == S_OK) {
            m2->SetInt(bmdDeckLinkFrameMetadataColorspace, thenCs);
            m2->SetInt(bmdDeckLinkFrameMetadataHDRElectroOpticalTransferFunc, thenEotf);
            if (thenZero) {
                const BMDDeckLinkFrameMetadataID ids[12] = {
                    bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedY,
                    bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenY,
                    bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueY,
                    bmdDeckLinkFrameMetadataHDRWhitePointX, bmdDeckLinkFrameMetadataHDRWhitePointY,
                    bmdDeckLinkFrameMetadataHDRMaxDisplayMasteringLuminance, bmdDeckLinkFrameMetadataHDRMinDisplayMasteringLuminance,
                    bmdDeckLinkFrameMetadataHDRMaximumContentLightLevel, bmdDeckLinkFrameMetadataHDRMaximumFrameAverageLightLevel};
                for (int k = 0; k < 12; k++) m2->SetFloat(ids[k], 0);
            }
            m2->Release();
        }
        printf("[hdrout] then, after %.1f s, on the same output: colorspace %s EOTF %d flag %s%s\n", thenAfter,
               thenCs == bmdColorspaceRec2020 ? "Rec.2020" : "Rec.709", thenEotf, thenFlag ? "set" : "clear", thenZero ? " · static all 0" : "");
    }
    if (fr2) {
        // Two phases: shown synchronously, one frame per 40 ms, so the switch happens when stated (scheduling every frame
        // up front is refused past the driver's queue depth, and the last accepted frame then repeats).
        int fails = 0; const int frames = (int)(seconds * 25), switchAt = (int)(thenAfter * 25);
        for (int i = 0; i < frames; i++) {
            if (out->DisplayVideoFrameSync(i < switchAt ? fr : fr2) != S_OK) fails++;
            if (i == switchAt) { printf("[hdrout] switched to the second frame\n"); fflush(stdout); }
            usleep(40000);
        }
        printf("[hdrout] %d frames shown synchronously, %d refused\n", frames, fails);
        fr->Release(); fr2->Release(); out->DisableVideoOutput(); out->Release(); dl->Release(); it->Release();
        return 0;
    }
    const int frames = (int)(seconds * 25), switchAt = frames;
    int refused = 0;
    for (int i = 0; i < frames; i++) if (out->ScheduleVideoFrame(i < switchAt ? fr : fr2, i * 1000, 1000, 25000) != S_OK) refused++;
    if (refused) printf("[hdrout] ScheduleVideoFrame refused %d of %d frames (the last accepted frame repeats)\n", refused, frames);
    printf("[hdrout] scheduled %d frames · StartScheduledPlayback → 0x%08X\n", frames, (unsigned)out->StartScheduledPlayback(0, 25000, 1.0));
    fflush(stdout);
    usleep((useconds_t)(seconds * 1e6));
    BMDTimeValue stop = 0; out->StopScheduledPlayback(0, &stop, 25000);
    fr->Release(); if (fr2) fr2->Release(); out->DisableVideoOutput(); out->Release();
    if (cfg) {
        HRESULT rr = cfg->SetFlag(bmdDeckLinkConfigRec2020Output, prior2020);
        bool now = false; cfg->GetFlag(bmdDeckLinkConfigRec2020Output, &now);
        printf("[hdrout] CONFIG Rec2020Output restored → 0x%08X; now %s; releasing\n", (unsigned)rr, now ? "true" : "false");
        cfg->Release();
    }
    dl->Release(); it->Release();
    return 0;
}
