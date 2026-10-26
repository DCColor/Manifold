// DeckLink loopback probe (S7-5). READ-ONLY: queries attributes, profiles, configuration (Get* only) and status of every
// DeckLink device. Enables no input or output, sets nothing, activates no profile. Not part of the app bundle.
//   zsh scripts/decklink-loopback/build.sh && build/decklink-loopback/probe
#include <CoreFoundation/CoreFoundation.h>
#include <cstdio>
#include <cstring>
#include <string>
#include "DeckLinkAPI.h"

static std::string str(CFStringRef s) {
    if (!s) return "";
    char buf[512]; CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(s); return buf;
}
static std::string fcc(int64_t v) {
    char c[5] = {(char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v, 0};
    for (int i = 0; i < 4; i++) if (c[i] < 32 || c[i] > 126) { char b[24]; snprintf(b, sizeof b, "0x%llx", (long long)v); return b; }
    return std::string("'") + c + "'";
}
static std::string conns(int64_t m) {
    std::string s;
    struct { int64_t b; const char *n; } t[] = {{bmdVideoConnectionSDI, "SDI"}, {bmdVideoConnectionHDMI, "HDMI"},
        {bmdVideoConnectionOpticalSDI, "OpticalSDI"}, {bmdVideoConnectionComponent, "Component"},
        {bmdVideoConnectionComposite, "Composite"}, {bmdVideoConnectionSVideo, "SVideo"}, {bmdVideoConnectionEthernet, "Ethernet"}};
    for (auto &e : t) if (m & e.b) { if (!s.empty()) s += "+"; s += e.n; }
    return s.empty() ? "none" : s;
}

static std::string fmtFlags(int64_t f) {   // BMDFormatFlags (DeckLinkAPI.h)
    std::string s;
    struct { int64_t b; const char *n; } t[] = {{bmdFormatRGB444, "RGB444"}, {bmdFormatYUV444, "YUV444"}, {bmdFormatYUV422, "YUV422"},
        {bmdFormatYUV420, "YUV420"}, {bmdFormat8BitDepth, "8-bit"}, {bmdFormat10BitDepth, "10-bit"}, {bmdFormat12BitDepth, "12-bit"}};
    for (auto &e : t) if (f & e.b) { if (!s.empty()) s += " "; s += e.n; }
    return std::to_string(f) + " (" + (s.empty() ? "none" : s) + ")";
}
// What the HDMI sink advertises in its EDID's CTA-861 extension: HDR static metadata (EOTFs), colorimetry, and the
// HDMI VSDB / HF-VSDB deep-colour bits. On the loop the sink is the card's own HDMI input.
static void ctaDecode(const uint8_t *e, uint32_t sz) {
    if (sz < 256 || e[128] != 0x02) { printf("    %-26s no CTA-861 extension\n", "EDID CTA"); return; }
    const uint8_t *c = e + 128; const int d = c[2] ? c[2] : 127;
    printf("    %-26s rev %u · underscan %s basic-audio %s YCbCr444 %s YCbCr422 %s\n", "EDID CTA", c[1], c[3] & 0x80 ? "y" : "n",
           c[3] & 0x40 ? "y" : "n", c[3] & 0x20 ? "y" : "n", c[3] & 0x10 ? "y" : "n");
    for (int i = 4; i < d && i < 127;) {
        const int tag = c[i] >> 5, len = c[i] & 31; const uint8_t *b = c + i + 1;
        if (tag == 7 && len >= 1) {
            const int x = b[0];
            if (x == 6 && len >= 3)
                printf("    %-26s EOTFs:%s%s%s%s · static metadata type 1 %s%s\n", "EDID HDR static block", b[1] & 1 ? " SDR" : "",
                       b[1] & 2 ? " trad-HDR" : "", b[1] & 4 ? " PQ" : "", b[1] & 8 ? " HLG" : "", b[2] & 1 ? "yes" : "no",
                       len >= 4 ? (" · desired max " + std::to_string(b[3]) + (len >= 5 ? " maxFALL " + std::to_string(b[4]) : "") + (len >= 6 ? " min " + std::to_string(b[5]) : "") + " (coded)").c_str() : "");
            else if (x == 5 && len >= 3)
                printf("    %-26s%s%s%s%s%s%s%s%s%s\n", "EDID colorimetry block", b[1] & 1 ? " xvYCC601" : "", b[1] & 2 ? " xvYCC709" : "",
                       b[1] & 4 ? " sYCC601" : "", b[1] & 8 ? " opYCC601" : "", b[1] & 16 ? " opRGB" : "", b[1] & 32 ? " BT2020cYCC" : "",
                       b[1] & 64 ? " BT2020YCC" : "", b[1] & 128 ? " BT2020RGB" : "", b[2] & 128 ? " DCI-P3" : "");
            else if (x == 0 && len >= 2) printf("    %-26s 0x%02x (QY %d QS %d)\n", "EDID video capability", b[1], (b[1] >> 7) & 1, (b[1] >> 6) & 1);
            else printf("    %-26s extended tag %d, %d B\n", "EDID block", x, len);
        } else if (tag == 3 && len >= 3) {
            const uint32_t oui = b[0] | b[1] << 8 | b[2] << 16;
            if (oui == 0x000C03 && len >= 6)
                printf("    %-26s deep colour: 30-bit %s 36-bit %s 48-bit %s Y444 %s · max TMDS %u MHz\n", "EDID HDMI VSDB", b[5] & 0x10 ? "y" : "n",
                       b[5] & 0x20 ? "y" : "n", b[5] & 0x40 ? "y" : "n", b[5] & 0x08 ? "y" : "n", len >= 7 ? b[6] * 5u : 0u);
            else if (oui == 0xC45DD8 && len >= 7)
                printf("    %-26s max TMDS %u MHz · DC_420 30 %s 36 %s 48 %s · max FRL code %u\n", "EDID HF-VSDB", b[4] * 5u, b[6] & 1 ? "y" : "n",
                       b[6] & 2 ? "y" : "n", b[6] & 4 ? "y" : "n", len >= 8 ? (unsigned)(b[7] >> 4) : 0u);
            else printf("    %-26s OUI %06x, %d B\n", "EDID vendor block", oui, len);
        } else printf("    %-26s tag %d, %d B\n", "EDID block", tag, len);
        i += len + 1;
    }
    printf("    %-26s", "EDID CTA bytes");
    for (int i = 0; i < 128; i++) printf("%s%02x", i % 32 ? " " : (i ? "\n                               " : " "), c[i]);
    printf("\n");
}

int main() {
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) { printf("no DeckLink driver\n"); return 1; }
    IDeckLink *dl; int idx = 0;
    while (it->Next(&dl) == S_OK) {
        CFStringRef m = nullptr, d = nullptr; dl->GetModelName(&m); dl->GetDisplayName(&d);
        printf("[%d] %s / %s\n", idx, str(m).c_str(), str(d).c_str());
        IDeckLinkProfileAttributes *a = nullptr;
        if (dl->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&a) == S_OK) {
            int64_t v; CFStringRef s;
            auto gi = [&](BMDDeckLinkAttributeID id, const char *n, int how) {
                if (a->GetInt(id, &v) != S_OK) { printf("    %-26s n/a\n", n); return; }
                if (how == 1) printf("    %-26s %s\n", n, fcc(v).c_str());
                else if (how == 2) printf("    %-26s %s\n", n, conns(v).c_str());
                else printf("    %-26s %lld\n", n, (long long)v);
            };
            gi(BMDDeckLinkPersistentID, "PersistentID", 0); gi(BMDDeckLinkTopologicalID, "TopologicalID", 0);
            gi(BMDDeckLinkSubDeviceIndex, "SubDeviceIndex", 0); gi(BMDDeckLinkNumberOfSubDevices, "NumberOfSubDevices", 0);
            gi(BMDDeckLinkProfileID, "ProfileID (active)", 1); gi(BMDDeckLinkDuplex, "Duplex", 1);
            gi(BMDDeckLinkVideoInputConnections, "VideoInputConnections", 2);
            gi(BMDDeckLinkVideoOutputConnections, "VideoOutputConnections", 2);
            gi(BMDDeckLinkVideoIOSupport, "VideoIOSupport", 0);
            if (a->GetString(BMDDeckLinkDeviceHandle, &s) == S_OK) printf("    %-26s %s\n", "DeviceHandle", str(s).c_str());
            bool f;
            auto gf = [&](BMDDeckLinkAttributeID id, const char *n) {
                if (a->GetFlag(id, &f) == S_OK) printf("    %-26s %s\n", n, f ? "yes" : "no"); else printf("    %-26s n/a\n", n); };
            gf(BMDDeckLinkSupportsInputFormatDetection, "InputFormatDetection");
            gf(BMDDeckLinkSupportsHDRMetadata, "SupportsHDRMetadata");
            gf(BMDDeckLinkSupportsColorspaceMetadata, "SupportsColorspaceMetadata");
            gf(BMDDeckLinkSupportsDualLinkSDI, "SupportsDualLinkSDI"); gf(BMDDeckLinkSupportsQuadLinkSDI, "SupportsQuadLinkSDI");
            gf(BMDDeckLinkVANCRequires10BitYUVVideoFrames, "VANCRequires10BitYUV");
            gf(BMDDeckLinkSupportsHANCInput, "SupportsHANCInput");
            gf(BMDDeckLinkHANCRequiresInputFilterConfiguration, "HANCRequiresInputFilter");
            gi(BMDDeckLinkInputHANCUserDataWordsLimit, "InputHANCUserWordsLimit", 0);
            a->Release();
        }
        IDeckLinkProfileManager *pm = nullptr;
        if (dl->QueryInterface(IID_IDeckLinkProfileManager, (void **)&pm) == S_OK) {
            IDeckLinkProfileIterator *pi = nullptr;
            if (pm->GetProfiles(&pi) == S_OK) {
                IDeckLinkProfile *p; std::string list;
                while (pi->Next(&p) == S_OK) {
                    bool act = false; p->IsActive(&act);
                    IDeckLinkProfileAttributes *pa = nullptr; int64_t pid = 0;
                    if (p->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&pa) == S_OK) { pa->GetInt(BMDDeckLinkProfileID, &pid); pa->Release(); }
                    list += fcc(pid) + (act ? "*" : "") + " "; p->Release();
                }
                printf("    %-26s %s (* active)\n", "Profiles", list.c_str()); pi->Release();
            }
            pm->Release();
        }
        IDeckLinkConfiguration *c = nullptr;
        if (dl->QueryInterface(IID_IDeckLinkConfiguration, (void **)&c) == S_OK) {
            int64_t v; bool f;
            if (c->GetInt(bmdDeckLinkConfigVideoInputConnection, &v) == S_OK) printf("    %-26s %s\n", "cfg VideoInputConnection", conns(v).c_str());
            if (c->GetInt(bmdDeckLinkConfigVideoOutputConnection, &v) == S_OK) printf("    %-26s %s\n", "cfg VideoOutputConnection", conns(v).c_str());
            if (c->GetInt(bmdDeckLinkConfigSDIOutputLinkConfiguration, &v) == S_OK) printf("    %-26s %s\n", "cfg SDIOutputLinkConfig", fcc(v).c_str());
            if (c->GetInt(bmdDeckLinkConfigCapturePassThroughMode, &v) == S_OK) printf("    %-26s %s\n", "cfg CapturePassThrough", fcc(v).c_str());
            if (c->GetFlag(bmdDeckLinkConfigRec2020Output, &f) == S_OK) printf("    %-26s %s\n", "cfg Rec2020Output", f ? "true" : "false");
            c->Release();
        }
        IDeckLinkStatus *st = nullptr;
        if (dl->QueryInterface(IID_IDeckLinkStatus, (void **)&st) == S_OK) {
            int64_t v; bool f;
            auto si = [&](BMDDeckLinkStatusID id, const char *n, bool asfcc) {
                if (st->GetInt(id, &v) == S_OK) printf("    %-26s %s\n", n, asfcc ? fcc(v).c_str() : std::to_string(v).c_str()); };
            if (st->GetFlag(bmdDeckLinkStatusVideoInputSignalLocked, &f) == S_OK) printf("    %-26s %s\n", "st InputSignalLocked", f ? "YES" : "no");
            si(bmdDeckLinkStatusDetectedVideoInputMode, "st DetectedInputMode", true);
            si(bmdDeckLinkStatusDetectedVideoInputFormatFlags, "st DetectedFormatFlags", false);
            si(bmdDeckLinkStatusDetectedVideoInputColorspace, "st DetectedColorspace", true);
            si(bmdDeckLinkStatusDetectedVideoInputDynamicRange, "st DetectedDynamicRange", true);
            si(bmdDeckLinkStatusDetectedSDILinkConfiguration, "st DetectedSDILink", true);
            si(bmdDeckLinkStatusCurrentVideoOutputMode, "st CurrentOutputMode", true);
            si(bmdDeckLinkStatusBusy, "st Busy", false);
            // HDMI (S7-5 HDMI half): what the HDMI output actually sends, and the EDID it received from its sink.
            si(bmdDeckLinkStatusHDMIOutputActualMode, "st HDMIOutputActualMode", true);
            if (st->GetInt(bmdDeckLinkStatusHDMIOutputActualFormatFlags, &v) == S_OK) printf("    %-26s %s\n", "st HDMIOutputActualFlags", fmtFlags(v).c_str());
            si(bmdDeckLinkStatusHDMIOutputTMDSLineRate, "st HDMIOutputTMDSLineRate", false);
            si(bmdDeckLinkStatusHDMIOutputFRLRate, "st HDMIOutputFRLRate", false);
            si(bmdDeckLinkStatusHDMIInputFRLRate, "st HDMIInputFRLRate", false);
            if (st->GetFlag(bmdDeckLinkStatusSinkSupportsDolbyVision, &f) == S_OK) printf("    %-26s %s\n", "st SinkSupportsDolbyVision", f ? "yes" : "no");
            {
                uint8_t edid[1024]; uint32_t sz = sizeof edid;
                if (st->GetBytes(bmdDeckLinkStatusReceivedEDID, edid, &sz) == S_OK && sz >= 128) {
                    const uint16_t mfg = (uint16_t)(edid[8] << 8 | edid[9]);
                    char name[14] = "";
                    for (int d = 54; d + 18 <= 126; d += 18)
                        if (edid[d] == 0 && edid[d + 1] == 0 && edid[d + 3] == 0xFC) { memcpy(name, edid + d + 5, 13); for (char &ch : name) if (ch == '\n') ch = 0; }
                    printf("    %-26s %u B · manufacturer %c%c%c product 0x%04x · name \"%s\" · %u extension block(s)\n", "st ReceivedEDID", sz,
                           '@' + ((mfg >> 10) & 31), '@' + ((mfg >> 5) & 31), '@' + (mfg & 31), (unsigned)(edid[10] | edid[11] << 8), name, (unsigned)edid[126]);
                    ctaDecode(edid, sz);
                } else printf("    %-26s none\n", "st ReceivedEDID");
            }
            si(bmdDeckLinkStatusPCIExpressLinkWidth, "st PCIeLinkWidth", false);
            si(bmdDeckLinkStatusPCIExpressLinkSpeed, "st PCIeLinkSpeed", false);
            st->Release();
        }
        dl->Release(); idx++;
    }
    it->Release();
    return 0;
}
