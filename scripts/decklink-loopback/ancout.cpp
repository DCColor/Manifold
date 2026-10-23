// DeckLink loopback positive control (S7-5): outputs black 1080p25 v210 frames on one device for N seconds, each carrying
// one known VANC packet (user data, DID 0x51 SDID 0x01, payload "MANIFOLD-ANC-TEST"), so the capture tool can show
// whether this input path exposes VANC packets at all. Uses the card's output as any playback app does; sets no
// configuration and no profile. Not in the app.   build/decklink-loopback/ancout --device 0 --seconds 4
#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <unistd.h>
#include "DeckLinkAPI.h"

class TestPacket : public IDeckLinkAncillaryPacket {
    std::atomic<int> refs{1};
    const char *payload = "MANIFOLD-ANC-TEST";
    uint8_t did, sdid;
public:
    TestPacket(uint8_t d, uint8_t s) : did(d), sdid(s) {}
    HRESULT QueryInterface(REFIID, LPVOID *) override { return E_NOINTERFACE; }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override { int r = --refs; if (r == 0) delete this; return r; }
    HRESULT GetBytes(BMDAncillaryPacketFormat f, const void **data, uint32_t *size) override {
        if (f != bmdAncillaryPacketFormatUInt8) return E_NOTIMPL;
        if (data) *data = payload; if (size) *size = (uint32_t)strlen(payload); return S_OK;
    }
    uint8_t GetDID() override { return did; }
    uint8_t GetSDID() override { return sdid; }
    uint32_t GetLineNumber() override { return 0; }   // auto
    uint8_t GetDataStreamIndex() override { return 0; }
    BMDAncillaryDataSpace GetDataSpace() override { return bmdAncillaryDataSpaceVANC; }
};

int main(int argc, char **argv) {
    int device = 0; double seconds = 4;
    for (int i = 1; i + 1 < argc; i++) { std::string a = argv[i]; if (a == "--device") device = atoi(argv[++i]); else if (a == "--seconds") seconds = atof(argv[++i]); }
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance(); if (!it) return 2;
    IDeckLink *dl = nullptr; for (int k = 0; k <= device; k++) { if (dl) dl->Release(); if (it->Next(&dl) != S_OK) return 2; }
    IDeckLinkOutput *out = nullptr; if (dl->QueryInterface(IID_IDeckLinkOutput, (void **)&out) != S_OK) return 2;
    HRESULT hr = out->EnableVideoOutput(bmdModeHD1080p25, bmdVideoOutputVANC);
    printf("[ancout] EnableVideoOutput(1080p25, VANC) → 0x%08X\n", (unsigned)hr); if (hr != S_OK) return 3;
    IDeckLinkMutableVideoFrame *fr = nullptr;
    out->CreateVideoFrame(1920, 1080, 5120, bmdFormat10BitYUV, bmdFrameFlagDefault, &fr);
    IDeckLinkVideoBuffer *vb = nullptr;
    if (fr->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&vb) == S_OK && vb->StartAccess(bmdBufferAccessWrite) == S_OK) {
        void *b = nullptr; vb->GetBytes(&b); uint32_t *w = (uint32_t *)b;
        for (int i = 0; i < 5120 * 1080 / 4; i += 4) { w[i] = 0x20010200; w[i + 1] = 0x04080040; w[i + 2] = 0x20010200; w[i + 3] = 0x04080040; }
        vb->EndAccess(bmdBufferAccessWrite); vb->Release();
    }
    IDeckLinkVideoFrameAncillaryPackets *ap = nullptr;
    if (fr->QueryInterface(IID_IDeckLinkVideoFrameAncillaryPackets, (void **)&ap) == S_OK) {
        // A user-data DID, and CEA-708 (0x61/0x01), a DID the driver places on its standard line by itself.
        TestPacket *p = new TestPacket(0x51, 0x01); printf("[ancout] AttachPacket 0x51/0x01 → 0x%08X\n", (unsigned)ap->AttachPacket(p)); p->Release();
        TestPacket *q = new TestPacket(0x61, 0x01); printf("[ancout] AttachPacket 0x61/0x01 → 0x%08X\n", (unsigned)ap->AttachPacket(q)); q->Release();
        ap->Release();
    }
    // Scheduled playback, as Blackmagic's ClosedCaptions sample does; the same frame scheduled for every slot.
    const int frames = (int)(seconds * 25);
    for (int i = 0; i < frames; i++) out->ScheduleVideoFrame(fr, i * 1000, 1000, 25000);
    printf("[ancout] scheduled %d frames · StartScheduledPlayback → 0x%08X\n", frames, (unsigned)out->StartScheduledPlayback(0, 25000, 1.0));
    fflush(stdout);
    usleep((useconds_t)(seconds * 1e6));
    BMDTimeValue stop = 0; out->StopScheduledPlayback(0, &stop, 25000);
    fr->Release(); out->DisableVideoOutput(); out->Release(); dl->Release(); it->Release();
    return 0;
}
