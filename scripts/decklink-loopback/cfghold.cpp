// DeckLink configuration hold (idle-output test, 2026-10-25): holds bmdDeckLinkConfigVideoOutputIdleOperation on one
// device at black or last frame for N seconds, so the setting stays in force across output stops and starts made by
// other processes (the SDK makes configuration global while the object is held, §2.5.15). Reads and logs the prior
// value; never calls WriteConfigurationToPreferences; on exit, SIGINT or SIGTERM sets the prior value back and
// releases. Run the probe after. Not in the app.
//   build/decklink-loopback/cfghold --device 0 --idle black|last --seconds 300
#include <CoreFoundation/CoreFoundation.h>
#include <csignal>
#include <cstdio>
#include <string>
#include <unistd.h>
#include "DeckLinkAPI.h"

static volatile sig_atomic_t stopRequested = 0;
static void onSignal(int) { stopRequested = 1; }
static const char *name(int64_t v) {
    return v == bmdIdleVideoOutputBlack ? "black ('blac')" : v == bmdIdleVideoOutputLastFrame ? "last frame ('lafa')" : "other";
}

int main(int argc, char **argv) {
    int device = 0; double seconds = 60; std::string idle;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i]; auto nx = [&]() { return std::string(i + 1 < argc ? argv[++i] : ""); };
        if (a == "--device") device = std::stoi(nx()); else if (a == "--seconds") seconds = std::stod(nx());
        else if (a == "--idle") idle = nx();
    }
    if (idle != "black" && idle != "last") { printf("--idle takes black or last\n"); return 2; }
    const int64_t want = idle == "black" ? bmdIdleVideoOutputBlack : bmdIdleVideoOutputLastFrame;
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance(); if (!it) return 2;
    IDeckLink *dl = nullptr; for (int k = 0; k <= device; k++) { if (dl) dl->Release(); if (it->Next(&dl) != S_OK) return 2; }
    IDeckLinkConfiguration *cfg = nullptr;
    if (dl->QueryInterface(IID_IDeckLinkConfiguration, (void **)&cfg) != S_OK || !cfg) { printf("[cfghold] no configuration interface\n"); return 2; }
    int64_t prior = 0;
    if (cfg->GetInt(bmdDeckLinkConfigVideoOutputIdleOperation, &prior) != S_OK) { printf("[cfghold] cannot read the idle operation\n"); cfg->Release(); return 2; }
    signal(SIGINT, onSignal); signal(SIGTERM, onSignal);
    HRESULT sr = cfg->SetInt(bmdDeckLinkConfigVideoOutputIdleOperation, want);
    int64_t now = 0; cfg->GetInt(bmdDeckLinkConfigVideoOutputIdleOperation, &now);
    printf("[cfghold] OutputIdleOperation before %s; SetInt(%s) → 0x%08X; now %s (not written to preferences)\n", name(prior), idle.c_str(),
           (unsigned)sr, name(now));
    fflush(stdout);
    for (double waited = 0; waited < seconds && !stopRequested; waited += 0.1) usleep(100000);
    HRESULT rr = cfg->SetInt(bmdDeckLinkConfigVideoOutputIdleOperation, prior);
    cfg->GetInt(bmdDeckLinkConfigVideoOutputIdleOperation, &now);
    printf("[cfghold] restored OutputIdleOperation → 0x%08X; now %s; releasing%s\n", (unsigned)rr, name(now), stopRequested ? " (on signal)" : "");
    fflush(stdout);
    cfg->Release(); dl->Release(); it->Release();
    return 0;
}
