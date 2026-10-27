// Interlaced I4 (docs/INTERLACED_FINDINGS.md §14): the window's field view, measured outside the app.
//
//   i4cmp <woven.rgba16f> <display.rgba16f> <width> <height> <bytesPerRow> <view> <order> [--marks]
//
// <view> weave | field1 | field2 | deinterlace; <order> topFirst | bottomFirst | none. The woven file is the export's
// `.rgba16f` (the offscreen ring: what the scopes, SDI and export read). The display file is the `.display.rgba16f` read-back
// (MANIFOLD_DISPLAY_READBACK=1): the texture the window's display copy sampled. The reference is built from the woven file by
// §14.2's rules, independently of the app's code:
//   Field 1 is the first field in time (top when no order is stated); Field 2 the other. Rows: top field = even rows.
//   field1 / field2: every output row y is woven row (y & ~1) | parity, clamped to the field's last row.
//   deinterlace: the kept field (Field 1) as stored; every other row the float32 mean of the kept rows above and below,
//   rounded to half (round to nearest even); an edge row repeats its one neighbour.
//   weave: the display is the woven frame itself.
// Prints exact bytes, rows that differ, and the largest difference in half-float ULPs.
//
// --rtz: the deinterlace reference rounds its mean toward zero (to test which rounding the GPU's half store uses).
// --marks: also decodes the I2 marker band (rows 0–63: 20 blocks, 0–15 the picture number LSB first, 16–19 the check pattern
// 1 0 1 0; luma from Rec. 709 R'G'B', 1 above 0.5) on every row of the woven and the display picture, and prints the numbers
// seen on the even and odd rows of each.
//
// Build: clang++ -std=c++17 -O2 -o i4cmp i4cmp.cpp
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <string>
#include <vector>
#include <map>
#include <set>

static std::vector<uint16_t> load(const char* p, size_t n) {
    std::vector<uint16_t> v(n / 2);
    FILE* f = fopen(p, "rb"); if (!f) { perror(p); exit(2); }
    size_t got = fread(v.data(), 1, n, f); fclose(f);
    if (got != n) { fprintf(stderr, "%s: %zu of %zu bytes\n", p, got, n); exit(2); }
    return v;
}
static float h2f(uint16_t h) { _Float16 x; memcpy(&x, &h, 2); return (float)x; }
static bool rtz = false;   // --rtz: the reference's mean rounds toward zero instead of to nearest even
static uint16_t f2h(float f) {
    _Float16 x = (_Float16)f; uint16_t h; memcpy(&h, &x, 2);
    if (rtz && std::fabs((float)x) > std::fabs(f)) h -= 1;   // one representable half toward zero (finite, non-zero)
    return h;
}
// Distance in representable halves (sign-magnitude to a monotone integer line).
static int ulp(uint16_t a, uint16_t b) {
    auto key = [](uint16_t h) { return (h & 0x8000) ? -(int)(h & 0x7fff) : (int)(h & 0x7fff); };
    return std::abs(key(a) - key(b));
}

int main(int argc, char** argv) {
    if (argc < 8) { fprintf(stderr, "usage: i4cmp woven display width height bytesPerRow view order [--marks]\n"); return 2; }
    int W = atoi(argv[3]), H = atoi(argv[4]), bpr = atoi(argv[5]);
    std::string view = argv[6], order = argv[7];
    bool marks = false;
    for (int i = 8; i < argc; i++) { if (std::string(argv[i]) == "--marks") marks = true; if (std::string(argv[i]) == "--rtz") rtz = true; }
    auto wv = load(argv[1], (size_t)bpr * H), dv = load(argv[2], (size_t)bpr * H);
    int stride = bpr / 2;   // halves per row
    int first = order == "bottomFirst" ? 1 : 0;
    int parity = view == "field2" ? 1 - first : first;
    int last = ((H - 1) & 1) == parity ? H - 1 : H - 2;

    std::vector<uint16_t> ref(wv.size());
    for (int y = 0; y < H; y++) {
        uint16_t* out = &ref[(size_t)y * stride];
        const uint16_t* a = nullptr; const uint16_t* b = nullptr;
        if (view == "weave") a = &wv[(size_t)y * stride];
        else if (view == "field1" || view == "field2") {
            int r = (y & ~1) | parity; if (r > last) r = last; a = &wv[(size_t)r * stride];
        } else if ((y & 1) == parity) a = &wv[(size_t)y * stride];
        else if (y == 0) a = &wv[(size_t)1 * stride];
        else if (y + 1 > last) a = &wv[(size_t)(y - 1) * stride];
        else { a = &wv[(size_t)(y - 1) * stride]; b = &wv[(size_t)(y + 1) * stride]; }
        for (int x = 0; x < W * 4; x++)
            out[x] = b ? f2h((h2f(a[x]) + h2f(b[x])) * 0.5f) : a[x];
        for (int x = W * 4; x < stride; x++) out[x] = dv[(size_t)y * stride + x];   // row padding is not picture
    }
    size_t exact = 0, total = 0; int maxU = 0; std::set<int> badRows; size_t interpExact = 0, interpTotal = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W * 4; x++) {
        size_t i = (size_t)y * stride + x; total++;
        bool interp = view == "deinterlace" && (y & 1) != parity;
        if (interp) interpTotal++;
        if (ref[i] == dv[i]) { exact++; if (interp) interpExact++; continue; }
        int u = ulp(ref[i], dv[i]); if (u > maxU) maxU = u; badRows.insert(y);
    }
    size_t wovenSame = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W * 4; x++) { size_t i = (size_t)y * stride + x; if (wv[i] == dv[i]) wovenSame++; }
    printf("view %s order %s parity %d | display vs reference: %zu / %zu halves exact (%.6f %%), %zu rows differ, max %d ULP",
           view.c_str(), order.c_str(), view == "weave" ? -1 : parity, exact, total, 100.0 * exact / total, badRows.size(), maxU);
    if (view == "deinterlace") printf(" | interpolated %zu / %zu exact", interpExact, interpTotal);
    printf(" | display == woven: %zu / %zu\n", wovenSame, total);

    if (marks) {
        auto decode = [&](const std::vector<uint16_t>& v, int y, bool& ok) {
            int bw = W / 20; unsigned n = 0; ok = true;
            for (int k = 0; k < 20; k++) {
                int x = k * bw + bw / 2; const uint16_t* p = &v[(size_t)y * stride + (size_t)x * 4];
                float Y = 0.2126f * h2f(p[0]) + 0.7152f * h2f(p[1]) + 0.0722f * h2f(p[2]);
                int bit = Y > 0.5f;
                if (k < 16) n |= (unsigned)bit << k; else if (bit != ((k % 2) == 0)) ok = false;
            }
            return n;
        };
        for (int which = 0; which < 2; which++) {
            const auto& v = which ? dv : wv;
            std::map<unsigned, int> even, odd; int broken = 0;
            for (int y = 0; y < 64; y++) {
                bool ok; unsigned n = decode(v, y, ok);
                if (!ok) { broken++; continue; }
                (y & 1 ? odd : even)[n]++;
            }
            printf("  marks %-7s even rows:", which ? "display" : "woven");
            for (auto& [n, c] : even) printf(" %u×%d", n, c);
            printf(" | odd rows:");
            for (auto& [n, c] : odd) printf(" %u×%d", n, c);
            printf(" | check pattern broken on %d rows\n", broken);
        }
    }
    return 0;
}
