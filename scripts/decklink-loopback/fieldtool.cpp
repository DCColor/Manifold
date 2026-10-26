// Interlaced I2 field checks (docs/INTERLACED_FINDINGS.md §11). Not in the app. Two modes:
//
//   fieldtool marks <file.v210> <width> <height> [rowBytes]
//       For each frame in a raw v210 file (one or many frames back to back), the picture number each FIELD carries in
//       the marker band (scripts/interlaced/generate-i2.sh): rows 0–63, 20 blocks across the picture; blocks 0–15 the
//       number's bits (LSB first), blocks 16–19 the check pattern 1 0 1 0. Field 1 (top) is the even rows (0-based),
//       field 2 the odd rows. Prints "frame N: top T bottom B" (or "?" when a field's band does not read).
//   fieldtool cmp <a.v210> <b.v210> <width> <height> [rowBytes]
//       Field by field: a's top field against b's top and b's bottom, and a's bottom against both, per channel:
//       identical %, within ±1 %, max |Δ|, mean |Δ|. A field-correct pair is close on the same field and far on the
//       other wherever the two fields differ.
//
// Marker band geometry is the PICTURE's: `--band x0 w` (default 0 and the width) for a picture placed in the frame.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>

static std::vector<uint8_t> load(const char *p) {
    std::vector<uint8_t> v; FILE *f = fopen(p, "rb"); if (!f) { printf("cannot read %s\n", p); exit(2); }
    fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET); fread(v.data(), 1, v.size(), f); fclose(f); return v;
}
static long rowBytesFor(long w) { return ((w + 47) / 48) * 128; }
// Component k (0-based) of row y: v210 packs Cb Y Cr Y Cb Y Cr Y Cb Y Cr Y per 6 pixels in 4 words.
static uint16_t comp(const uint8_t *frame, long rb, long y, long k) {
    const uint32_t *row = (const uint32_t *)(frame + y * rb);
    const uint32_t word = row[(k / 12) * 4 + (k % 12) / 3];
    return (word >> (10 * ((k % 12) % 3))) & 0x3FF;
}
static uint16_t luma(const uint8_t *frame, long rb, long y, long x) { return comp(frame, rb, y, 2 * x + 1); }

// One field's number: majority-free, strict — rows 10..54 of the parity, every row must read the same number with the
// check pattern, else -1.
static long fieldMark(const uint8_t *fr, long rb, int parity, long x0, long bw) {
    long got = -2;
    for (long y = 10 + parity; y < 56; y += 2) {
        long v = 0; bool ok = true;
        for (int b = 0; b < 20; b++) {
            const long x = x0 + (long)((b + 0.5) * bw / 20.0);
            const int bit = luma(fr, rb, y, x) > 512;
            if (b < 16) v |= (long)bit << b;
            else if (bit != ((b % 2) == 0)) ok = false;
        }
        if (!ok) return -1;
        if (got == -2) got = v; else if (got != v) return -1;
    }
    return got;
}

int main(int argc, char **argv) {
    if (argc < 5) { printf("usage: fieldtool marks|cmp …\n"); return 2; }
    std::string mode = argv[1];
    long x0 = 0, bw = -1; std::vector<std::string> pos;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--band") && i + 2 < argc) { x0 = atol(argv[i + 1]); bw = atol(argv[i + 2]); i += 2; }
        else pos.push_back(argv[i]);
    }
    if (mode == "marks") {
        const long w = atol(pos[1].c_str()), h = atol(pos[2].c_str());
        const long rb = pos.size() > 3 ? atol(pos[3].c_str()) : rowBytesFor(w);
        if (bw < 0) bw = w;
        auto d = load(pos[0].c_str()); const long fb = rb * h;
        for (long f = 0; f * fb + fb <= (long)d.size(); f++) {
            const long t = fieldMark(d.data() + f * fb, rb, 0, x0, bw), b = fieldMark(d.data() + f * fb, rb, 1, x0, bw);
            printf("frame %ld: top %s bottom %s\n", f, t < 0 ? "?" : std::to_string(t).c_str(), b < 0 ? "?" : std::to_string(b).c_str());
        }
        return 0;
    }
    if (mode == "cmp") {
        const long w = atol(pos[2].c_str()), h = atol(pos[3].c_str());
        const long rb = pos.size() > 4 ? atol(pos[4].c_str()) : rowBytesFor(w);
        auto a = load(pos[0].c_str()), b = load(pos[1].c_str());
        if ((long)a.size() < rb * h || (long)b.size() < rb * h) { printf("short file\n"); return 2; }
        const char *names[2] = {"top", "bottom"}, *ch[3] = {"Y", "Cb", "Cr"};
        int worst = 0;
        for (int fa = 0; fa < 2; fa++) for (int fbp = 0; fbp < 2; fbp++) {
            long n[3] = {0}, same[3] = {0}, one[3] = {0}, mx[3] = {0}; double sum[3] = {0};
            for (long r = 0; r < h / 2; r++) {
                const long ya = 2 * r + fa, yb = 2 * r + fbp;
                for (long k = 0; k < 2 * w; k++) {
                    const int c = (k % 2) ? 0 : ((k / 2) % 2 ? 2 : 1);
                    const long dlt = labs((long)comp(a.data(), rb, ya, k) - (long)comp(b.data(), rb, yb, k));
                    n[c]++; same[c] += dlt == 0; one[c] += dlt <= 1; mx[c] = std::max(mx[c], dlt); sum[c] += dlt;
                }
            }
            for (int c = 0; c < 3; c++) {
                printf("a.%-6s vs b.%-6s %-2s identical %8.4f %%  ±1 %8.4f %%  max %4ld  mean %8.4f\n", names[fa], names[fbp], ch[c],
                       100.0 * same[c] / n[c], 100.0 * one[c] / n[c], mx[c], sum[c] / n[c]);
                if (fa == fbp) worst = std::max<int>(worst, (int)mx[c]);
            }
        }
        printf("same-field max |Δ| %d\n", worst);
        return 0;
    }
    printf("unknown mode\n"); return 2;
}
