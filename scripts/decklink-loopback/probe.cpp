// DeckLink loopback probe (S7-5). READ-ONLY: queries attributes, profiles, configuration (Get* only) and status of every
// DeckLink device. Enables no input or output, sets nothing, activates no profile. Not part of the app bundle.
//   zsh scripts/decklink-loopback/build.sh && build/decklink-loopback/probe
#include <CoreFoundation/CoreFoundation.h>
#include <cstdio>
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
            si(bmdDeckLinkStatusPCIExpressLinkWidth, "st PCIeLinkWidth", false);
            si(bmdDeckLinkStatusPCIExpressLinkSpeed, "st PCIeLinkSpeed", false);
            st->Release();
        }
        dl->Release(); idx++;
    }
    it->Release();
    return 0;
}
