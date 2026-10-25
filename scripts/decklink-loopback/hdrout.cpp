// DeckLink HDR signalling control (S7-5 HDMI half): outputs a mid-grey 1080p25 v210 frame on one device for N seconds,
// tagged with the given colorspace, EOTF, HDR flag and (optionally) static values, so a capture of the HDMI loop shows
// what the input reports for a known signal, independent of Manifold. Uses the card's output as any playback app does;
// sets no configuration and no profile. Run with Manifold closed. Not in the app.
//   build/decklink-loopback/hdrout --device 0 --seconds 4 --colorspace 2020|709 --eotf 0|2|3 [--flag] [--maxcll 1234]
#include <CoreFoundation/CoreFoundation.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <unistd.h>
#include "DeckLinkAPI.h"

int main(int argc, char **argv) {
    int device = 0, eotf = 0; double seconds = 4, maxcll = -1; bool flag = false; BMDColorspace cs = bmdColorspaceRec709;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i]; auto nx = [&]() { return std::string(i + 1 < argc ? argv[++i] : ""); };
        if (a == "--device") device = std::stoi(nx()); else if (a == "--seconds") seconds = std::stod(nx());
        else if (a == "--eotf") eotf = std::stoi(nx()); else if (a == "--flag") flag = true;
        else if (a == "--maxcll") maxcll = std::stod(nx());
        else if (a == "--colorspace") cs = nx() == "2020" ? bmdColorspaceRec2020 : bmdColorspaceRec709;
    }
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance(); if (!it) return 2;
    IDeckLink *dl = nullptr; for (int k = 0; k <= device; k++) { if (dl) dl->Release(); if (it->Next(&dl) != S_OK) return 2; }
    IDeckLinkOutput *out = nullptr; if (dl->QueryInterface(IID_IDeckLinkOutput, (void **)&out) != S_OK) return 2;
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
    const int frames = (int)(seconds * 25);
    for (int i = 0; i < frames; i++) out->ScheduleVideoFrame(fr, i * 1000, 1000, 25000);
    printf("[hdrout] scheduled %d frames · StartScheduledPlayback → 0x%08X\n", frames, (unsigned)out->StartScheduledPlayback(0, 25000, 1.0));
    fflush(stdout);
    usleep((useconds_t)(seconds * 1e6));
    BMDTimeValue stop = 0; out->StopScheduledPlayback(0, &stop, 25000);
    fr->Release(); out->DisableVideoOutput(); out->Release(); dl->Release(); it->Release();
    return 0;
}
