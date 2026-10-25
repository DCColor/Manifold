// v210 compare (S7-5 HDMI half): decodes two v210 frames of the same geometry and says how the second (received)
// differs from the first (handed, e.g. Manifold's [SDI-DUMP]): per channel, how many components are identical, max |Δ|,
// the |Δ| histogram, the received values' low two bits, and how many components each 8-bit rule explains:
//   trunc  rx = tx & ~3                       (10 → 8 by dropping two bits, re-expanded with zeros)
//   round  rx = min(1020, (tx + 2) & ~3)      (10 → 8 by rounding)
//   repl   rx = (v8 << 2) | (v8 >> 6), v8 = round(tx / 4)   (8 → 10 by bit replication)
// Not in the app.   build/decklink-loopback/v210cmp handed.v210 received.v210 width height
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <map>
#include <vector>

static std::vector<uint8_t> load(const char *p) {
    std::vector<uint8_t> v; FILE *f = fopen(p, "rb"); if (!f) { printf("cannot read %s\n", p); exit(2); }
    fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET); fread(v.data(), 1, v.size(), f); fclose(f); return v;
}
// Components in v210 order per 6-pixel group: Cb Y Cr Y Cb Y Cr Y Cb Y Cr Y; channel 0 = Y, 1 = Cb, 2 = Cr.
static void decode(const std::vector<uint8_t> &b, long w, long h, long rb, std::vector<uint16_t> &val, std::vector<uint8_t> &ch) {
    static const uint8_t order[12] = {1, 0, 2, 0, 1, 0, 2, 0, 1, 0, 2, 0};
    for (long y = 0; y < h; y++) {
        const uint32_t *row = (const uint32_t *)(b.data() + y * rb);
        for (long g = 0; g < (w + 5) / 6; g++) {
            uint16_t c[12];
            for (int k = 0; k < 4; k++) { uint32_t x = row[g * 4 + k]; c[k * 3] = x & 0x3FF; c[k * 3 + 1] = (x >> 10) & 0x3FF; c[k * 3 + 2] = (x >> 20) & 0x3FF; }
            const long px = std::min<long>(6, w - g * 6), n = px * 2;   // 2 components per pixel
            for (long k = 0; k < n; k++) { val.push_back(c[k]); ch.push_back(order[k]); }
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 5) { printf("usage: v210cmp handed.v210 received.v210 width height\n"); return 2; }
    const long w = atol(argv[3]), h = atol(argv[4]), rb = ((w + 47) / 48) * 128;
    auto a = load(argv[1]), b = load(argv[2]);
    if ((long)a.size() != rb * h || (long)b.size() != rb * h) { printf("size: handed %zu received %zu expected %ld\n", a.size(), b.size(), rb * h); return 2; }
    if (memcmp(a.data(), b.data(), a.size()) == 0) { printf("BYTE-IDENTICAL (%zu bytes)\n", a.size()); return 0; }
    std::vector<uint16_t> ta, tb; std::vector<uint8_t> ca, cb; decode(a, w, h, rb, ta, ca); decode(b, w, h, rb, tb, cb);
    const char *nm[3] = {"Y", "Cb", "Cr"};
    for (int c = 0; c < 3; c++) {
        long n = 0, same = 0, trunc = 0, rnd = 0, repl = 0, maxd = 0; std::map<int, long> hist; long low[4] = {0, 0, 0, 0};
        std::map<std::pair<int, int>, long> pairs;   // (handed, received) for the first differing values
        for (size_t i = 0; i < ta.size(); i++) {
            if (ca[i] != c) continue;
            const int t = ta[i], r = tb[i]; n++;
            if (t == r) same++;
            if (r == (t & ~3)) trunc++;
            if (r == std::min(1020, (t + 2) & ~3)) rnd++;
            { int v8 = std::min(255, (t + 2) >> 2); if (r == ((v8 << 2) | (v8 >> 6))) repl++; }
            const int d = r - t; hist[d]++; if (abs(d) > maxd) maxd = abs(d);
            low[r & 3]++;
            if (t != r && pairs.size() < 12) pairs[{t, r}]++;
        }
        printf("%-2s n=%ld identical=%ld (%.4f%%) max|Δ|=%ld · trunc %.4f%% round %.4f%% repl %.4f%% · received low bits 00:%ld 01:%ld 10:%ld 11:%ld\n",
               nm[c], n, same, 100.0 * same / n, maxd, 100.0 * trunc / n, 100.0 * rnd / n, 100.0 * repl / n, low[0], low[1], low[2], low[3]);
        printf("   Δ histogram:"); for (auto &e : hist) printf(" %+d:%ld", e.first, e.second); printf("\n");
        printf("   first differing (handed→received):"); for (auto &e : pairs) printf(" %d→%d", e.first.first, e.first.second); printf("\n");
    }
    return 1;
}
