// Interlaced I3 (docs/INTERLACED_FINDINGS.md §12): Manifold's picture against an independent reference built from
// FFmpeg's decode. Not in the app.
//
//   i3cmp <decoded.raw> <pixfmt> <field|frame> <manifold.v210 | manifold.rgba16f> [--sharp] [--rows]
//
// <decoded.raw>: one frame from `ffmpeg -frames:v 1 -f rawvideo -pix_fmt <pixfmt>` (yuv420p, yuv420p10le, yuv422p10le,
// yuv444p10le), 1920×1080, BT.709 limited. 8-bit samples are widened ×4 (BT.709 / BT.2100's 10-bit rule).
//
// THE REFERENCE, stated:
//   4:2:0, `field`: each frame line y (field f = y mod 2) interpolates linearly between the two nearest chroma rows OF
//     ITS FIELD, chroma row c sited at frame line 2c + 0.5 (MPEG-2 interlaced siting): t = (y − 2f − 0.5) / 4, rows
//     2⌊t⌋+f and 2⌊t⌋+2+f, weight frac(t), clamped within the field. `frame`: the progressive upsample (HEAD's), all chroma
//     rows, row c at 2c + 0.5. Horizontally, both: Manifold's 4:2:0 horizontal filter, unchanged by I3 — centre-sited
//     linear, p = x/2 − 0.25, clamped (pixel 0 → c0, pixel 1 → ¾c0 + ¼c1 …).
//   4:2:2: chroma sample k on pixel 2k (co-sited), 2k+1 the mean of k and k+1 (the shader's co-sited sample).
//   4:4:4: each pixel's own chroma.
//   For a .v210 (the wire): luma per pixel; chroma per even pixel as Manifold's v210 kernel reduces the above — 4:2:0 the
//   mean of pixels 2k and 2k+1, 4:2:2 pixel 2k, 4:4:4 the D3 halfband [-1 0 9 16 9 0 -1]/32 mirrored at the edges.
//   For a .rgba16f (the offscreen the window, scopes and export read): R'G'B' back to Y'CbCr with the BT.709 matrix,
//   in 10-bit codes (Y 64 + 876·Y', C 512 + 896·C'), every pixel.
//
// Output: per component and per field, % within ±1 / ±2 / ±3, max |Δ|, mean |Δ|; rows whose mean |Δ| (Cb and Cr) is
// within 2 codes (§9 P6). --sharp: the I3 field fixture's uniform region (x < 960, y < 540), per row, the bleed
// (row − own field's value) / (other field's value − own), as a % of the step. --rows: print every row's figures.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>

static const int W = 1920, H = 1080;
static std::vector<uint8_t> load(const char *p) {
    std::vector<uint8_t> v; FILE *f = fopen(p, "rb"); if (!f) { printf("cannot read %s\n", p); exit(2); }
    fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET);
    if (fread(v.data(), 1, v.size(), f) != v.size()) exit(2); fclose(f); return v;
}
static float halfToFloat(uint16_t h) {
    const uint32_t s = (h >> 15) & 1, e = (h >> 10) & 31, m = h & 1023;
    float v = e == 0 ? std::ldexp((float)m, -24) : e == 31 ? INFINITY : std::ldexp((float)(m | 1024), (int)e - 25);
    return s ? -v : v;
}

int main(int argc, char **argv) {
    if (argc < 5) { printf("usage: i3cmp <decoded.raw> <pixfmt> <field|frame> <manifold.v210|.rgba16f> [--sharp] [--rows]\n"); return 2; }
    const std::string pixfmt = argv[2], mode = argv[3], mpath = argv[4];
    bool sharp = false, rows = false;
    for (int i = 5; i < argc; i++) { if (!strcmp(argv[i], "--sharp")) sharp = true; if (!strcmp(argv[i], "--rows")) rows = true; }
    int cw, ch, depth;
    if (pixfmt == "yuv420p") { cw = W / 2; ch = H / 2; depth = 8; }
    else if (pixfmt == "yuv420p10le") { cw = W / 2; ch = H / 2; depth = 10; }
    else if (pixfmt == "yuv422p10le") { cw = W / 2; ch = H; depth = 10; }
    else if (pixfmt == "yuv444p10le") { cw = W; ch = H; depth = 10; }
    else { printf("pixfmt?\n"); return 2; }
    const bool is420 = ch == H / 2, is422 = !is420 && cw == W / 2;
    const std::vector<uint8_t> raw = load(argv[1]);
    auto sample = [&](size_t i) -> double {
        return depth == 8 ? raw[i] * 4.0 : (double)(raw[2 * i] | (raw[2 * i + 1] << 8));
    };
    const size_t cbOff = (size_t)W * H, crOff = cbOff + (size_t)cw * ch;

    // Reference chroma at full resolution (per pixel), 10-bit codes.
    std::vector<double> rY((size_t)W * H), rCb((size_t)W * H), rCr((size_t)W * H);
    std::vector<double> vCb((size_t)cw * H), vCr((size_t)cw * H);   // after the vertical step, per frame line
    for (int y = 0; y < H; y++) {
        int ra, rb; double wb;
        if (!is420) { ra = rb = y; wb = 0; }
        else if (mode == "field") {
            const int f = y & 1; const double t = (y - 2 * f - 0.5) / 4.0, j0 = std::floor(t);
            const int last = std::max((ch - 1 - f) / 2, 0);
            ra = std::min(2 * std::clamp((int)j0, 0, last) + f, ch - 1);
            rb = std::min(2 * std::clamp((int)j0 + 1, 0, last) + f, ch - 1); wb = t - j0;
        } else {
            const double p = y / 2.0 - 0.25, i0 = std::floor(p);
            ra = std::clamp((int)i0, 0, ch - 1); rb = std::clamp((int)i0 + 1, 0, ch - 1); wb = p - i0;
        }
        for (int k = 0; k < cw; k++) {
            vCb[(size_t)y * cw + k] = (1 - wb) * sample(cbOff + (size_t)ra * cw + k) + wb * sample(cbOff + (size_t)rb * cw + k);
            vCr[(size_t)y * cw + k] = (1 - wb) * sample(crOff + (size_t)ra * cw + k) + wb * sample(crOff + (size_t)rb * cw + k);
        }
    }
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        const size_t o = (size_t)y * W + x;
        rY[o] = sample(o);
        if (cw == W) { rCb[o] = vCb[(size_t)y * cw + x]; rCr[o] = vCr[(size_t)y * cw + x]; continue; }
        double p, i0, f; int a, b;
        if (is420) { p = x / 2.0 - 0.25; }            // centre-sited (chromaShiftU 0)
        else { p = x / 2.0; }                          // co-sited (the +½ pixel shift)
        i0 = std::floor(p); f = p - i0; a = std::clamp((int)i0, 0, cw - 1); b = std::clamp((int)i0 + 1, 0, cw - 1);
        rCb[o] = (1 - f) * vCb[(size_t)y * cw + a] + f * vCb[(size_t)y * cw + b];
        rCr[o] = (1 - f) * vCr[(size_t)y * cw + a] + f * vCr[(size_t)y * cw + b];
    }

    // Manifold's picture, as Y / Cb / Cr per position. v210: chroma on even pixels only. rgba16f: every pixel.
    const bool isV210 = mpath.size() > 5 && mpath.substr(mpath.size() - 5) == ".v210";
    const std::vector<uint8_t> m = load(mpath.c_str());
    std::vector<double> mY((size_t)W * H), mCb((size_t)W * H, NAN), mCr((size_t)W * H, NAN);
    std::vector<double> eCb((size_t)W * H, NAN), eCr((size_t)W * H, NAN);   // the reference at the same sites
    const double kr = 0.2126, kb = 0.0722, kg = 1 - kr - kb;
    if (isV210) {
        const long rb = ((W + 47) / 48) * 128;
        if ((long)m.size() < rb * H) { printf("short v210\n"); return 2; }
        for (int y = 0; y < H; y++) {
            const uint32_t *row = (const uint32_t *)(m.data() + y * rb);
            auto comp = [&](long k) { const uint32_t w = row[(k / 12) * 4 + (k % 12) / 3]; return (double)((w >> (10 * ((k % 12) % 3))) & 0x3FF); };
            for (int x = 0; x < W; x++) mY[(size_t)y * W + x] = comp(2 * x + 1);
            for (int x = 0; x < W; x += 2) {
                const size_t o = (size_t)y * W + x;
                mCb[o] = comp(2 * x); mCr[o] = comp(2 * x + 2);
                if (cw == W) {   // 4:4:4: the halfband
                    auto at = [&](std::vector<double> &c, int xx) { xx = xx < 0 ? -xx : (xx > W - 1 ? 2 * (W - 1) - xx : xx); return c[(size_t)y * W + xx]; };
                    eCb[o] = (16 * at(rCb, x) + 9 * (at(rCb, x - 1) + at(rCb, x + 1)) - (at(rCb, x - 3) + at(rCb, x + 3))) / 32;
                    eCr[o] = (16 * at(rCr, x) + 9 * (at(rCr, x - 1) + at(rCr, x + 1)) - (at(rCr, x - 3) + at(rCr, x + 3))) / 32;
                } else if (is422) { eCb[o] = rCb[o]; eCr[o] = rCr[o]; }
                else { eCb[o] = 0.5 * (rCb[o] + rCb[o + 1]); eCr[o] = 0.5 * (rCr[o] + rCr[o + 1]); }
                eCb[o] = std::clamp(std::round(eCb[o]), 64.0, 960.0); eCr[o] = std::clamp(std::round(eCr[o]), 64.0, 960.0);
            }
        }
    } else {
        if (m.size() < (size_t)W * H * 8) { printf("short rgba16f\n"); return 2; }
        const uint16_t *px = (const uint16_t *)m.data();
        for (size_t o = 0; o < (size_t)W * H; o++) {
            const double r = halfToFloat(px[4 * o]), g = halfToFloat(px[4 * o + 1]), b = halfToFloat(px[4 * o + 2]);
            const double yy = kr * r + kg * g + kb * b;
            mY[o] = 64 + 876 * yy; mCb[o] = 512 + 896 * (b - yy) / (2 * (1 - kb)); mCr[o] = 512 + 896 * (r - yy) / (2 * (1 - kr));
            eCb[o] = rCb[o]; eCr[o] = rCr[o];
        }
    }

    // Statistics.
    struct Acc { long n = 0, w1 = 0, w2 = 0, w3 = 0; double mx = 0, sum = 0;
        void add(double d) { d = std::fabs(d); n++; w1 += d <= 1.0 + 1e-9; w2 += d <= 2.0 + 1e-9; w3 += d <= 3.0 + 1e-9; mx = std::max(mx, d); sum += d; }
        void print(const char *name) const { printf("  %-12s ±1 %8.4f %%  ±2 %8.4f %%  ±3 %8.4f %%  max %6.2f  mean %6.3f  (n %ld)\n", name,
            100.0 * w1 / n, 100.0 * w2 / n, 100.0 * w3 / n, mx, sum / n, n); } };
    Acc aY[2], aCb[2], aCr[2], allY, allC;
    long rowsOk = 0; double worstRow = 0; int worstRowY = -1;
    double bleedMax = 0; long bleedOver1 = 0, bleedRows = 0; double bleedSum = 0;
    for (int y = 0; y < H; y++) {
        const int f = y & 1; double rowSum = 0; long rowN = 0, rowCb = 0; double rowCbSum = 0;
        for (int x = 0; x < W; x++) {
            const size_t o = (size_t)y * W + x;
            const double dy = mY[o] - (isV210 ? std::clamp(std::round(rY[o]), 64.0, 940.0) : rY[o]);
            aY[f].add(dy); allY.add(dy);
            if (std::isnan(mCb[o])) continue;
            const double dcb = mCb[o] - eCb[o], dcr = mCr[o] - eCr[o];
            aCb[f].add(dcb); aCr[f].add(dcr); allC.add(dcb); allC.add(dcr);
            rowSum += std::fabs(dcb) + std::fabs(dcr); rowN += 2;
            if (sharp && x < 960) { rowCbSum += mCb[o]; rowCb++; }
        }
        const double rowMean = rowSum / rowN;
        rowsOk += rowMean <= 2.0 + 1e-9;
        if (rowMean > worstRow) { worstRow = rowMean; worstRowY = y; }
        double bleed = NAN;
        if (sharp && y < 540) {
            // Own field's Cb in region U: field 1 colour A (Cb 352), field 2 colour B (Cb 672); the other is the opposite.
            const double own = f == 0 ? 352 : 672, other = f == 0 ? 672 : 352;
            bleed = 100.0 * (rowCbSum / rowCb - own) / (other - own);
            bleedRows++; bleedSum += bleed; bleedMax = std::max(bleedMax, std::fabs(bleed)); bleedOver1 += std::fabs(bleed) > 1.0;
        }
        if (rows) printf("row %4d f%d  mean|dC| %7.3f%s\n", y, f + 1, rowMean,
                         std::isnan(bleed) ? "" : (std::string("  bleed ") + std::to_string(bleed) + " %").c_str());
    }
    printf("%s vs %s reference (%s, %s)\n", mpath.c_str(), mode.c_str(), pixfmt.c_str(), isV210 ? "v210" : "rgba16f → Y'CbCr");
    allY.print("Y all"); aY[0].print("Y field 1"); aY[1].print("Y field 2");
    allC.print("C all"); aCb[0].print("Cb field 1"); aCb[1].print("Cb field 2"); aCr[0].print("Cr field 1"); aCr[1].print("Cr field 2");
    printf("  rows with mean |dC| <= 2: %ld / %d (%.3f %%); worst row %d (%.3f)\n", rowsOk, H, 100.0 * rowsOk / H, worstRowY, worstRow);
    if (sharp) printf("  bleed, region U (%ld rows): mean %.3f %%, max |%.3f| %%, rows over 1 %%: %ld\n",
                      bleedRows, bleedSum / bleedRows, bleedMax, bleedOver1);
    return 0;
}
