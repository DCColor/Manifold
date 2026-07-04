#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Uniform: the YCbCr->RGB matrix coefficients (varies by 601/709/2020).
// Passed as the three non-trivial coefficients of the standard form:
//   R = Y + a*Cr
//   G = Y - b*Cb - c*Cr
//   B = Y + d*Cb
struct ColorParams {
    float a;  // Cr -> R
    float b;  // Cb -> G
    float c;  // Cr -> G
    float d;  // Cb -> B
    int isFullRange;       // 0 = video/legal range (expand), nonzero = full range (passthrough)
    int chromaConvention;  // full-range chroma only: 0 = full-swing (÷255), 1 = Resolve (×219/224)
};

vertex VertexOut passthroughVertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 passthroughFragment(VertexOut in [[stage_in]],
                                     texture2d<float> lumaTex   [[texture(0)]],
                                     texture2d<float> chromaTex [[texture(1)]],
                                     constant ColorParams &params [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float y  = lumaTex.sample(s, in.texCoord).r;
    float2 cbcr = chromaTex.sample(s, in.texCoord).rg;

    // Range handling. Chroma is ALWAYS centered (subtract the neutral 128/255) —
    // that's a chroma offset, not range expansion, and applies to both ranges.
    // What differs is the SCALE: video/legal data is encoded in 16–235 (luma) /
    // 16–240 (chroma) and must be expanded to 0–1; full-range data already spans
    // 0–1 and must NOT be expanded (expanding it is the double-expansion bug).
    float cb, cr;
    if (params.isFullRange != 0) {
        // Full range: luma passthrough. Chroma centered, then scaled per the
        // selected convention (legal branch and luma are untouched by this).
        if (params.chromaConvention == 1) {
            // Resolve: chroma scaled by 219/224 — Resolve expands full-range
            // chroma by the LUMA factor (255/219), so the matching inverse is
            // (×255/255)·(219/224). Renders a Resolve full file (Cr≈226) correct.
            cb = (cbcr.r - 128.0/255.0) * (219.0/224.0);
            cr = (cbcr.g - 128.0/255.0) * (219.0/224.0);
        } else {
            // Full-swing / spec: chroma centered only, scale 255 (no expansion).
            cb = cbcr.r - 128.0/255.0;
            cr = cbcr.g - 128.0/255.0;
        }
    } else {
        // Video/legal range: expand luma 16–235→0–1 and chroma 16–240→0–1.
        y  = (y - 16.0/255.0) * (255.0/219.0);
        cb = (cbcr.r - 128.0/255.0) * (255.0/224.0);
        cr = (cbcr.g - 128.0/255.0) * (255.0/224.0);
    }

    // YCbCr -> RGB using the matrix coefficients passed in.
    float r = y + params.a * cr;
    float g = y - params.b * cb - params.c * cr;
    float b = y + params.d * cb;

    return float4(r, g, b, 1.0);
}

// MARK: - GPU scopes (Phase 1 prototype: luma waveform)

// Uniforms for waveformKernel. Mirrors WaveformParams in MetalVideoRenderer.swift
// (field order + type must match exactly).
struct WaveformParams {
    uint width;      // source (offscreen) width in pixels
    uint height;     // source (offscreen) height in pixels
    uint scopeW;     // horizontal column buckets (histogram width)
    uint bins;       // luma bins (histogram height) — 256 for the CPU-matching prototype
    uint rowStride;  // process every rowStride-th source row (match CPU rowStride=2)
};

// Luma waveform histogram, computed directly on the GPU-resident offscreen texture
// (post-shader display RGB, range-expanded). One thread per source pixel; each thread
// bins its pixel's Rec.709 luma into a per-column column of the histogram via an atomic
// increment. Output layout matches the CPU path EXACTLY: hist[row*scopeW + bucket],
// row = (bins-1) - bin so luma-max sits at the top row.
//
// The offscreen texture is rgb10a2Unorm; Metal decodes it to a normalized float4 on
// read (no manual 10-bit unpack — that's the CPU path's rgb10a2Channels job). Computing
// 709 luma on the normalized float and binning to (bins-1) is equivalent to the CPU's
// 8-bit-domain luma within rounding.
kernel void waveformKernel(texture2d<float, access::read> offscreen [[texture(0)]],
                           device atomic_uint *hist                 [[buffer(0)]],
                           constant WaveformParams &p               [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    // Guard the ragged edge (grid is rounded up to the threadgroup size).
    if (gid.x >= p.width || gid.y >= p.height) return;
    // Row subsample: match the CPU, which walks rows 0, rowStride, 2*rowStride, …
    if ((gid.y % p.rowStride) != 0u) return;

    float4 c = offscreen.read(gid);
    // Rec.709 luma on the normalized display RGB (same coeffs as the CPU path).
    float luma = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    // Round-to-nearest into [0, bins-1] — mirrors the CPU's Int(luma*255 + 0.5).
    int bin = int(luma * float(p.bins - 1u) + 0.5);
    bin = clamp(bin, 0, int(p.bins) - 1);

    uint bucket = (gid.x * p.scopeW) / p.width;      // source column -> scope bucket
    uint row = (p.bins - 1u) - uint(bin);            // luma-max at top, matching CPU
    atomic_fetch_add_explicit(&hist[row * p.scopeW + bucket], 1u, memory_order_relaxed);
}

// MARK: - GPU scopes (Phase 2: RGB parade)

// Uniforms for paradeKernel. Same layout as WaveformParams; `colW` is the PER-CHANNEL
// column-bucket count (each of R/G/B occupies its own colW×bins histogram region).
struct ParadeParams {
    uint width;      // source (offscreen) width in pixels
    uint height;     // source (offscreen) height in pixels
    uint colW;       // per-channel horizontal column buckets
    uint bins;       // value bins (histogram height) — 1024 (10-bit), like the waveform
    uint rowStride;  // process every rowStride-th source row (full-res: 1)
};

// RGB parade: three per-channel value histograms (R, G, B), computed directly on the
// rgb10a2 offscreen. Mirrors waveformKernel but bins EACH channel's value instead of a
// single luma. ONE buffer, three contiguous regions laid out [R | G | B], each colW*bins:
//   hist[channel*colW*bins + row*colW + bucket],  row = (bins-1)-bin  (value-max at top).
// Column/bucket mapping and row convention match the CPU parade exactly. Full-res.
kernel void paradeKernel(texture2d<float, access::read> offscreen [[texture(0)]],
                         device atomic_uint *hist               [[buffer(0)]],
                         constant ParadeParams &p               [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    if ((gid.y % p.rowStride) != 0u) return;

    float4 c = offscreen.read(gid);
    uint bucket = (gid.x * p.colW) / p.width;        // source column -> per-channel bucket
    uint region = p.colW * p.bins;                   // per-channel histogram size
    float scale = float(p.bins - 1u);

    // Per channel: round value to [0, bins-1], row = (bins-1)-bin (value-max at top).
    int rb = clamp(int(c.r * scale + 0.5), 0, int(p.bins) - 1);
    int gb = clamp(int(c.g * scale + 0.5), 0, int(p.bins) - 1);
    int bb = clamp(int(c.b * scale + 0.5), 0, int(p.bins) - 1);
    uint rRow = (p.bins - 1u) - uint(rb);
    uint gRow = (p.bins - 1u) - uint(gb);
    uint bRow = (p.bins - 1u) - uint(bb);
    atomic_fetch_add_explicit(&hist[0u * region + rRow * p.colW + bucket], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[1u * region + gRow * p.colW + bucket], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[2u * region + bRow * p.colW + bucket], 1u, memory_order_relaxed);
}

// MARK: - GPU scopes (Phase 3: vectorscope)

// Uniforms for vectorscopeKernel. `plane` is the square chroma-plane side; `chromaScale`
// is VectorscopeScopeModel.chromaScaleFrac (chroma-units → fraction of the plane).
struct VectorscopeParams {
    uint width;        // source (offscreen) width in pixels
    uint height;       // source (offscreen) height in pixels
    uint plane;        // square chroma-plane side (histogram is plane×plane)
    uint rowStride;    // process every rowStride-th source row (full-res: 1)
    float chromaScale; // chromaScaleFrac — chroma units → fraction of the plane
};

// Vectorscope: a 2-D chroma-plane scatter (Cb horizontal, Cr vertical) on the offscreen.
// Per pixel: Rec.709 luma, then Cb=(B-Y)/1.8556, Cr=(R-Y)/1.5748 in the 0–255 domain
// (channels ×255 to match the CPU path's 8-bit chroma magnitude), mapped to plane pixels
// with center = plane/2 and s = chromaScale*plane. Cr is flipped (up) for display, exactly
// like the CPU path. Out-of-plane chroma is skipped (matches the CPU's bounds guard).
// Output: hist[py*plane + px], a plane×plane 2-D histogram aligned to the graticule.
kernel void vectorscopeKernel(texture2d<float, access::read> offscreen [[texture(0)]],
                              device atomic_uint *hist                 [[buffer(0)]],
                              constant VectorscopeParams &p            [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    if ((gid.y % p.rowStride) != 0u) return;

    float4 c = offscreen.read(gid);
    // 0–255 domain to match the CPU chroma magnitude (identical formulas/coeffs).
    float r = c.r * 255.0, g = c.g * 255.0, b = c.b * 255.0;
    float y  = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    float cb = (b - y) / 1.8556;
    float cr = (r - y) / 1.5748;

    float center = float(p.plane) * 0.5;
    float s = p.chromaScale * float(p.plane);       // chroma units -> plane pixels
    int px = int(center + cb * s + 0.5);
    int py = int(center - cr * s + 0.5);            // Cr up (Y flip), matching CPU
    if (px >= 0 && px < int(p.plane) && py >= 0 && py < int(p.plane)) {
        atomic_fetch_add_explicit(&hist[uint(py) * p.plane + uint(px)], 1u, memory_order_relaxed);
    }
}

// MARK: - GPU scopes (Phase 4: CIE chromaticity)

// Uniforms for cieKernel. Mirrors CIEParams in MetalVideoRenderer.swift (field order + type
// must match exactly). planeW/planeH is the 2-D histogram size; primariesCode/transferCode
// are the source's CICP codes (select the RGB→XYZ matrix + the EOTF); u/v Min/Max are the
// u'v' plane bounds (shared with the graticule draw code so scatter + overlay align).
struct CIEParams {
    uint  width;         // source (offscreen) width in pixels
    uint  height;        // source (offscreen) height in pixels
    uint  planeW;        // histogram width  (u' axis)
    uint  planeH;        // histogram height (v' axis)
    int   primariesCode; // CICP primaries (1=709, 9=2020, 11/12=P3); default→709
    int   transferCode;  // CICP transfer  (1=709, 13=sRGB, 16=PQ, 18=HLG); default→gamma 2.4
    uint  useUV;         // 1 = u'v' (Stage A only supports this; xy deferred)
    float uMin;          // u' plane lower bound
    float uMax;          // u' plane upper bound
    float vMin;          // v' plane lower bound
    float vMax;          // v' plane upper bound
};

// sRGB EOTF (piecewise) — transferCode 13.
static inline float cieSrgbEOTF(float e) {
    return (e <= 0.04045) ? (e / 12.92) : pow((e + 0.055) / 1.055, 2.4);
}

// ST 2084 (PQ) EOTF — transferCode 16. Normalized [0,1]; absolute nit scale is irrelevant
// for chromaticity (the u'v' ratio is scale-invariant).
static inline float ciePqEOTF(float e) {
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    float Ep = pow(max(e, 0.0), 1.0 / m2);
    float num = max(Ep - c1, 0.0);
    float den = c2 - c3 * Ep;
    return pow(num / den, 1.0 / m1);
}

// HLG inverse OETF (scene linear) — transferCode 18. The display OOTF is OMITTED: it is a
// per-channel monotone scaling that does not change the R:G:B ratio in a way that matters for
// chromaticity, so u'v' is unaffected (Stage A). Add the OOTF if luminance-accurate plotting
// is ever needed.
static inline float cieHlgInvOETF(float e) {
    const float a = 0.17883277;
    const float b = 0.28466892;
    const float c = 0.55991073;
    return (e <= 0.5) ? (e * e / 3.0) : ((exp((e - c) / a) + b) / 12.0);
}

static inline float cieLinearize(float e, int transferCode) {
    switch (transferCode) {
        case 13: return cieSrgbEOTF(e);                 // sRGB
        case 16: return ciePqEOTF(e);                   // PQ / ST 2084
        case 18: return cieHlgInvOETF(e);               // HLG
        default: return pow(max(e, 0.0), 2.4);          // 709 (1) / unknown → gamma 2.4
    }
}

// Linear source-primaries RGB → CIE XYZ. Rows are the standard RGB→XYZ matrices; selected by
// CICP primaries code (matrix, NOT the YCbCr matrix — primaries are independent of it).
static inline float3 cieRGBtoXYZ(float3 rgb, int primariesCode) {
    float3 r0, r1, r2;   // matrix rows
    switch (primariesCode) {
        case 9:   // Rec.2020
            r0 = float3(0.6369580, 0.1446169, 0.1688809);
            r1 = float3(0.2627002, 0.6779981, 0.0593017);
            r2 = float3(0.0000000, 0.0280727, 1.0609851);
            break;
        case 11:  // DCI-P3 — treated as P3-D65 for now (DCI white-point nuance deferred)
        case 12:  // Display P3 (P3-D65)
            r0 = float3(0.4865709, 0.2656677, 0.1982173);
            r1 = float3(0.2289746, 0.6917385, 0.0792869);
            r2 = float3(0.0000000, 0.0451134, 1.0439444);
            break;
        default:  // Rec.709 / sRGB (1, 13) and fallback
            r0 = float3(0.4124564, 0.3575761, 0.1804375);
            r1 = float3(0.2126729, 0.7151522, 0.0721750);
            r2 = float3(0.0193339, 0.1191920, 0.9503041);
            break;
    }
    return float3(dot(r0, rgb), dot(r1, rgb), dot(r2, rgb));
}

// CIE chromaticity scope: per-pixel u'v' scatter on the SOURCE-primaries, transfer-ENCODED
// offscreen RGB (only YCbCr→RGB + range expansion has been applied). Each thread linearizes
// its pixel by transferCode, converts source-primaries linear RGB → XYZ, projects to CIE 1976
// u'v', and bins into a planeW×planeH 2-D histogram. Output layout hist[row*planeW + col],
// row flipped so v'-up (image row order). Near-black (tiny denominator) and NaN are skipped.
kernel void cieKernel(texture2d<float, access::read> offscreen [[texture(0)]],
                      device atomic_uint *hist                 [[buffer(0)]],
                      constant CIEParams &p                    [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;

    float4 c = offscreen.read(gid);
    // Linearize the transfer-encoded source RGB (primaries preserved — no gamut change).
    float3 lin = float3(cieLinearize(c.r, p.transferCode),
                        cieLinearize(c.g, p.transferCode),
                        cieLinearize(c.b, p.transferCode));
    if (any(isnan(lin))) return;

    float3 xyz = cieRGBtoXYZ(lin, p.primariesCode);
    float denom = xyz.x + 15.0 * xyz.y + 3.0 * xyz.z;
    if (denom < 1e-6) return;                            // near-black: no meaningful chromaticity
    float up = 4.0 * xyz.x / denom;                     // CIE 1976 u'
    float vp = 9.0 * xyz.y / denom;                     // CIE 1976 v'
    if (isnan(up) || isnan(vp)) return;

    // Map u'v' → plane, normalized by the shared bounds; flip v for image row order.
    float fu = (up - p.uMin) / (p.uMax - p.uMin);
    float fv = (vp - p.vMin) / (p.vMax - p.vMin);
    int col = int(fu * float(p.planeW));
    int row = int((1.0 - fv) * float(p.planeH));
    if (col >= 0 && col < int(p.planeW) && row >= 0 && row < int(p.planeH)) {
        atomic_fetch_add_explicit(&hist[uint(row) * p.planeW + uint(col)], 1u, memory_order_relaxed);
    }
}
