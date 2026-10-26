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
    int chromaConvention;  // full-range chroma only: 0 = full-swing (no scale), 1 = Resolve (x219/224)
    // Stage 3b S1 (D4): +½ luma pixel, in the buffer's normalized u, for x422 — standard 4:2:2 chroma
    // is CO-SITED with the even luma sample, and the unshifted sample treats it as centre-sited.
    // With the shift, luma pixel 2k reads chroma sample k exactly and 2k+1 the mean of k and k+1.
    // EXACTLY 0.0 for x420 and x444, so those take the same arithmetic as before (u + 0.0 == u):
    // 4:2:0's own siting is a separate stage, and 4:4:4 has nothing to site.
    float chromaShiftU;
    // Nonzero = this buffer was widened from an 8-bit source (see "8-bit sources" below). Mirrors
    // ColorParams.eightBitSource in MetalVideoRenderer.swift.
    int eightBitSource;
    // Interlaced I3: nonzero = an x420 buffer holding a woven interlaced picture; chroma per field (below).
    int fieldChroma;
};

// MARK: - Sample domain (10-bit x420)
//
// (Stage 3b: x422 and x444 are sampled too — the SAME 10-bit MSB-aligned encoding, only the chroma plane's
// size differs, so everything below holds for them unchanged. Native chroma: CLAUDE.md.)
// The decode contract is ALWAYS x420 (kCVPixelFormatType_420YpCbCr10BiPlanar*, both the AVFoundation
// and libav paths), whose 10-bit samples are MSB-ALIGNED in a 16-bit word and are sampled here as
// .r16Unorm / .rg16Unorm. So Metal normalizes a 10-bit code C as:
//
//     (C << 6) / 65535  =  C / 1023.984375
//
// NOT C/1023, and emphatically not the 8-bit C/255 these constants used to assume. Expanding a 10-bit
// sample with 8-bit constants left legal white at ~0.9932-0.9980 instead of 1.0, and — worse — put
// NEUTRAL chroma (Cb=Cr=512) at -0.00195 instead of 0, which the YCbCr matrix turned into a ~5-code
// R/G/B spread on grays (measured on the legal white/black fixtures). Working in the same domain the
// sampler actually uses makes both exact: legal white 940 -> 1.0, neutral chroma 512 -> 0.0, no cast.
//
// (MetalVideoRenderer still has an .r8Unorm/.rg8Unorm branch for 8-bit buffers, but it is currently
// UNREACHABLE — every decode path requests a 10-bit carrier — so these constants are not per-depth.
// If an 8-bit decode path is ever reintroduced, they become per-depth and must be passed in. An 8-bit
// SOURCE in a 10-bit carrier is the next block's business, not this one's.)
constexpr constant float kCodeMax     = 1023.984375;      // 65535/64 — max normalized 10-bit MSB-aligned code
constexpr constant float kLumaBlack   = 64.0 / kCodeMax;  // legal luma floor  (was 16/255)
constexpr constant float kLumaSwing   = kCodeMax / 876.0; // luma 64..940      (was 255/219)
constexpr constant float kChromaMid   = 512.0 / kCodeMax; // neutral chroma    (was 128/255)
constexpr constant float kChromaSwing = kCodeMax / 896.0; // chroma 64..960    (was 255/224)
// Full-range luma has a swing too — it is just a different one (0..1023, not 64..940). Without it,
// full white (1023) normalizes to 1023/1023.984 = 0.99904 and lands ~1 code short of 1.0. Same family
// as the legal-branch error above, ~4x smaller. Both branches now scale luma; only the factor differs.
constexpr constant float kFullLumaSwing = kCodeMax / 1023.0;   // full-range luma 0..1023
// Resolve's full-range chroma factor is a swing RATIO, so it is domain-independent: at 10-bit it is
// 876/896, which is bit-for-bit the same number as the 8-bit 219/224. Left as-is deliberately.
constexpr constant float kResolveChromaScale = 219.0 / 224.0;

// MARK: - 8-bit sources (exactly ×4)
//
// Every 8-bit source reaches this shader in a 10-bit carrier, and VideoToolbox — its decoder asked for
// x420 / x422, and VTPixelTransferSession from an IOSurface-backed source (the SRT / WHEP promotes) —
// widens 8-bit FULL-SCALE (≈ v·1023/255), not BT.709 / BT.2100's ×4. Measured, every value lies in
// 4v … 4v+3: mid-grey 128 → 514, white 235 → 943, neutral chroma 128 → 513 in x422
// (COLOR_MANAGEMENT_FINDINGS.md §6.10, *S3/S4 follow-up*). So for a buffer the producer flagged 8-bit,
// each sample is taken to floor(code/4)·4, which is exactly 4v for every one of those maps (the code
// being the sample's top ten bits: below). NDI's transfer, from plain memory, is already ×4; its flag
// changes nothing there (§6.10, *8-bit sources mapped exactly ×4*, E6′).
//
// ⚠️ PER TEXEL, BEFORE INTERPOLATION. 4:2:0 upsampling and the 4:2:2 co-siting shift both land between
// chroma samples; clearing the bits of an interpolated value would floor a MEAN (514 between 512 and
// 516 → 512). So chroma is filtered here by hand from four quantised texels. Luma needs no filter: the
// fragment reads the centre of its own texel (the clean-aperture note below), so its sample IS the texel.
//
// ⚠️ TRUNCATE, NEVER ROUND. The 10-bit code of an MSB-aligned sample is its top ten bits (U >> 6), and
// VideoToolbox's x422 output does NOT leave the low six bits zero: from an 8-bit source it writes a
// 16-bit full-scale value (measured: Cb 240 → 963 + 63/64, mid-grey → 513 + 63/64; x420's are zero).
// Rounding v·kCodeMax took 963.98 to 964, which then survived the clear (measured: Cb 963.9 on the
// export). Truncated, every value measured is 4v … 4v+3. So this is floor(code / 4) · 4 with code the
// truncation, in one floor: the fraction of v·kCodeMax/4 is at most (3 + 63/64)/4, and 1/1024 absorbs
// float error below an exact multiple without reaching the next one.
//
// Unflagged buffers (every 10-bit source, libav files, which sws already widens ×4) never reach these.
static inline float exactTimes4(float v) {
    return floor(v * (kCodeMax * 0.25) + (1.0 / 1024.0)) * 4.0 / kCodeMax;
}
static inline float2 exactTimes4(float2 v) {
    return float2(exactTimes4(v.x), exactTimes4(v.y));
}

// The bilinear filter `filter::linear` + `clamp_to_edge` would apply, over quantised texels. The
// sub-texel fraction is snapped to 1/256, as the sampler's fixed-point weights are: the fractions this
// shader asks for are 0, ¼, ½ and ¾ (exact), and the float error in reaching them must not leak in.
static inline float2 sampleChromaExactTimes4(texture2d<float> tex, float2 uv) {
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 p = uv * size - 0.5;
    float2 i0 = floor(p);
    float2 f = rint((p - i0) * 256.0) / 256.0;
    int2 hi = int2(size) - 1;
    uint2 a = uint2(clamp(int2(i0), int2(0), hi));
    uint2 b = uint2(clamp(int2(i0) + 1, int2(0), hi));
    float2 c00 = exactTimes4(tex.read(uint2(a.x, a.y)).rg);
    float2 c10 = exactTimes4(tex.read(uint2(b.x, a.y)).rg);
    float2 c01 = exactTimes4(tex.read(uint2(a.x, b.y)).rg);
    float2 c11 = exactTimes4(tex.read(uint2(b.x, b.y)).rg);
    return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

// MARK: - Interlaced 4:2:0 (I3, docs/INTERLACED_FINDINGS.md §8)
//
// In a woven interlaced 4:2:0 picture chroma row c belongs to field c mod 2, so the bilinear sample above (which
// mixes neighbouring chroma rows) mixes the two fields. Here each line takes its chroma from ITS OWN FIELD's rows.
// Chroma row c sits at frame line 2c + 0.5 (MPEG-2 interlaced siting, which is where the progressive sample already
// puts it), so only the neighbours change: line y of field f = y mod 2 mixes that field's two nearest chroma rows,
// t = (y − 2f − 0.5) / 4 → rows 2⌊t⌋ + f and 2⌊t⌋ + 2 + f, weight frac(t) — 5/8·3/8 and 1/8·7/8 on the top field,
// 7/8·1/8 and 3/8·5/8 on the bottom, clamped within the field at the edges. Restated from `InterlacedChroma.taps`
// (FileScan), which the unit tests pin. Horizontally each row is sampled exactly as the progressive path samples it.
// The line is the BUFFER's (from the luma texture): the crop is on the even grid, so its parity is the source's.

// One chroma row, filtered horizontally only: the progressive path's horizontal filter over quantised texels (8-bit).
static inline float2 sampleChromaRowExactTimes4(texture2d<float> tex, float u, uint row) {
    const float w = float(tex.get_width());
    const float p = u * w - 0.5;
    const float i0 = floor(p);
    const float f = rint((p - i0) * 256.0) / 256.0;
    const int hi = int(w) - 1;
    const uint a = uint(clamp(int(i0), 0, hi)), b = uint(clamp(int(i0) + 1, 0, hi));
    return mix(exactTimes4(tex.read(uint2(a, row)).rg), exactTimes4(tex.read(uint2(b, row)).rg), f);
}

static inline float2 sampleChromaOwnField(texture2d<float> lumaTex, texture2d<float> chromaTex, float2 uv, bool eightBit) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    const int h = int(chromaTex.get_height());
    const int y = int(floor(uv.y * float(lumaTex.get_height())));
    const int f = y & 1;
    const float t = (float(y - 2 * f) - 0.5) * 0.25;
    const float j0 = floor(t);
    const float wB = t - j0;
    const int last = max((h - 1 - f) / 2, 0);
    const int ra = min(2 * clamp(int(j0), 0, last) + f, h - 1);
    const int rb = min(2 * clamp(int(j0) + 1, 0, last) + f, h - 1);
    float2 a, b;
    if (eightBit) {
        a = sampleChromaRowExactTimes4(chromaTex, uv.x, uint(ra));
        b = sampleChromaRowExactTimes4(chromaTex, uv.x, uint(rb));
    } else {
        // At a row's centre the sampler's vertical weight is 0: the row itself, filtered horizontally.
        a = chromaTex.sample(s, float2(uv.x, (float(ra) + 0.5) / float(h))).rg;
        b = chromaTex.sample(s, float2(uv.x, (float(rb) + 0.5) / float(h))).rg;
    }
    return mix(a, b, wB);
}

// The ACTIVE PICTURE's uv range inside the decoded buffer — the encoded raster with the declared
// clean aperture removed. Mirrors CropRect in MetalVideoRenderer.swift (field order + type must
// match exactly). (0,0,1,1) is the no-crop identity and is what every source without a cropping
// `clap` binds, so this pass is byte-for-byte what it was on those files.
struct CropRect {
    float u0;  // left   edge, normalized
    float v0;  // top    edge, normalized
    float u1;  // right  edge, normalized
    float v1;  // bottom edge, normalized
};

// ── THE ONE PLACE THE CLEAN APERTURE IS APPLIED TO PIXELS ────────────────────────────────────
//
// The render target is the ACTIVE PICTURE (see `ensureOffscreenTexture`), and this remaps the
// full-screen quad's texture coordinates onto the aperture's sub-rect of the decoded buffer. So
// the offscreen holds picture and nothing else, and every consumer of the offscreen ring — the
// four scope kernels, the DeckLink v210 convert, the ⌃⌥E export, the display copy — inherits the
// crop with no plumbing of its own, because all of them derive geometry from the TEXTURE.
//
// ⚠️ BIT-EXACT, NOT A RESAMPLE, AND THAT IS A PROPERTY OF THE RECT RATHER THAN OF THIS CODE.
// `CleanApertureCrop.resolve` guarantees an even, integral rect, and the destination is exactly
// its size, so fragment `i` samples the centre of texel `x + i` and `filter::linear` returns that
// texel unchanged. Chroma keeps the identical sample phase it had uncropped. See the resolver for
// why the even grid is the whole of the constraint.
vertex VertexOut passthroughVertex(uint vertexID [[vertex_id]],
                                   constant CropRect &crop [[buffer(0)]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    // Unit texture coordinates, y DOWN (0 = top). Vertices 0/1 are the clip-space BOTTOM, so they
    // carry t=1 and must land on the crop's BOTTOM edge, v1.
    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    float2 t = texCoords[vertexID];
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = float2(mix(crop.u0, crop.u1, t.x), mix(crop.v0, crop.v1, t.y));
    return out;
}

// MARK: - The Interpretation LUT (colour S6, L1 — docs/COLOR_MANAGEMENT_FINDINGS.md §6.11, *S6 — LUT*)
//
// ⚠️ OFF BY CONSTRUCTION, NOT BY A BRANCH. The three constants are set only when the renderer builds a LUT
// pipeline (`MetalVideoRenderer.makeLUTInstall`). The everyday pipeline is specialised with an EMPTY
// constant set (Metal will not build one from the unspecialised function), so none is defined, `kLUTOn` is
// false, the LUT arguments do not exist, and the compiler is left with the fragment as it was before S6
// (P1: 0 codes).
//
// THE CONTRACT IS `LUTCube`'s CPU REFERENCE (`CubeLUTEvaluator.swift`), line for line:
//   t = clamp((x − min) / (max − min), 0, 1)   — D2: input outside the domain is clamped
//   p = t·(n − 1),  i = min(⌊p⌋, n − 2),  f = p − i
// 1D per channel, linear; 3D trilinear (8 nodes) or tetrahedral (4, by the order of fr, fg, fb — the same
// six branches and the same tie-breaking as the reference, which is what makes the discriminator agree).
//
// ⚠️ BY HAND, WITH read() AND float WEIGHTS — NOT A LINEAR SAMPLER. Apple GPUs snap filter weights to 1/256
// (the 8-bit chroma note above), and a sampled 3D LUT needs a half-texel offset that is the classic source
// of a shifted LUT. Reading the nodes needs neither. Input is the R′G′B′ the decode just produced — the
// offscreen's own domain, legal 64 → 0.0 and 940 → 1.0, which is Resolve's (§6.11, *S6*, finding 2).
constant bool lutHasShaper   [[function_constant(0)]];
constant bool lutHasCube     [[function_constant(1)]];
constant bool lutTetrahedral [[function_constant(2)]];
constant bool kLUTShaper      = is_function_constant_defined(lutHasShaper) && lutHasShaper;
constant bool kLUTCube        = is_function_constant_defined(lutHasCube) && lutHasCube;
constant bool kLUTOn          = kLUTShaper || kLUTCube;
constant bool kLUTTetrahedral = is_function_constant_defined(lutTetrahedral) && lutTetrahedral;

// Mirrors LUTShaderParams in MetalVideoRenderer.swift (field order + type must match exactly).
struct LUTParams {
    float4 shaperMin;   // xyz used
    float4 shaperMax;
    float4 cubeMin;
    float4 cubeMax;
    uint   shaperSize;
    uint   cubeSize;
    uint   pad0, pad1;
};

/// One axis: the lower node and the fraction towards the next.
static inline float lutPosition(float x, float lo, float hi, uint n, thread uint &i) {
    float t = clamp((x - lo) / (hi - lo), 0.0f, 1.0f);
    float p = t * float(n - 1);
    i = min(uint(floor(p)), n - 2);
    return p - float(i);
}

static inline float3 lutShaper(float3 v, device const float4 *rows, constant LUTParams &p) {
    float3 out;
    for (uint c = 0; c < 3; c++) {
        uint i;
        float f = lutPosition(v[c], p.shaperMin[c], p.shaperMax[c], p.shaperSize, i);
        float a = rows[i][c], b = rows[i + 1][c];
        out[c] = a + (b - a) * f;
    }
    return out;
}

static inline float3 lutCubeTrilinear(float3 v, texture3d<float, access::read> t, constant LUTParams &p) {
    uint r0, g0, b0;
    float fr = lutPosition(v.r, p.cubeMin.r, p.cubeMax.r, p.cubeSize, r0);
    float fg = lutPosition(v.g, p.cubeMin.g, p.cubeMax.g, p.cubeSize, g0);
    float fb = lutPosition(v.b, p.cubeMin.b, p.cubeMax.b, p.cubeSize, b0);
    #define N(dr, dg, db) t.read(uint3(r0 + dr, g0 + dg, b0 + db)).rgb
    float3 c00 = N(0, 0, 0) * (1 - fr) + N(1, 0, 0) * fr;
    float3 c10 = N(0, 1, 0) * (1 - fr) + N(1, 1, 0) * fr;
    float3 c01 = N(0, 0, 1) * (1 - fr) + N(1, 0, 1) * fr;
    float3 c11 = N(0, 1, 1) * (1 - fr) + N(1, 1, 1) * fr;
    #undef N
    float3 c0 = c00 * (1 - fg) + c10 * fg;
    float3 c1 = c01 * (1 - fg) + c11 * fg;
    return c0 * (1 - fb) + c1 * fb;
}

static inline float3 lutCubeTetrahedral(float3 v, texture3d<float, access::read> t, constant LUTParams &p) {
    uint r0, g0, b0;
    float fr = lutPosition(v.r, p.cubeMin.r, p.cubeMax.r, p.cubeSize, r0);
    float fg = lutPosition(v.g, p.cubeMin.g, p.cubeMax.g, p.cubeSize, g0);
    float fb = lutPosition(v.b, p.cubeMin.b, p.cubeMax.b, p.cubeSize, b0);
    #define N(dr, dg, db) t.read(uint3(r0 + dr, g0 + dg, b0 + db)).rgb
    float3 c000 = N(0, 0, 0), c111 = N(1, 1, 1);
    if (fr > fg) {
        if (fg > fb)      return c000 * (1 - fr) + N(1, 0, 0) * (fr - fg) + N(1, 1, 0) * (fg - fb) + c111 * fb;
        else if (fr > fb) return c000 * (1 - fr) + N(1, 0, 0) * (fr - fb) + N(1, 0, 1) * (fb - fg) + c111 * fg;
        else              return c000 * (1 - fb) + N(0, 0, 1) * (fb - fr) + N(1, 0, 1) * (fr - fg) + c111 * fg;
    } else {
        if (fb > fg)      return c000 * (1 - fb) + N(0, 0, 1) * (fb - fg) + N(0, 1, 1) * (fg - fr) + c111 * fr;
        else if (fb > fr) return c000 * (1 - fg) + N(0, 1, 0) * (fg - fb) + N(0, 1, 1) * (fb - fr) + c111 * fr;
        else              return c000 * (1 - fg) + N(0, 1, 0) * (fg - fr) + N(1, 1, 0) * (fr - fb) + c111 * fb;
    }
    #undef N
}

// E1: returns half4, matching the rgba16Float render target.
//
// This is NOT cosmetic and NOT a precision downgrade — it is REQUIRED for correctness.
// Returning float4 into a half target makes the ROP do the float32→half conversion, and this
// GPU's ROP TRUNCATES toward zero rather than rounding to nearest (measured: 2048/2048 samples
// truncate, 951 disagree with round-to-nearest). Truncation is a SYSTEMATIC DARK BIAS of up to
// one half-ULP — about 0.5 of a 10-bit code near white, always downward, never up.
//
// That bias is not academic: it reached the SDI output. With a float4 return, the v210 encoder
// produced 1,176,120 components on the full-range ramp that were EVERY ONE of them one code
// DARKER than the rgb10a2 path had produced. Converting to half here instead makes the shader
// do the narrowing with correct round-to-nearest (measured: 4096/4096), leaving the ROP nothing
// to truncate. The result is unbiased (mean ≈ 0) with max error ~0.25 of a 10-bit code — i.e.
// strictly BETTER than the ±0.5-code rounding of the rgb10a2Unorm grid this replaced.
//
// The arithmetic below is unchanged and still runs in float32; only the final write narrows.
// Keep the return type in step with renderPixelFormat: a float4 return into a half target
// silently reintroduces the dark bias.
fragment half4 passthroughFragment(VertexOut in [[stage_in]],
                                     texture2d<float> lumaTex   [[texture(0)]],
                                     texture2d<float> chromaTex [[texture(1)]],
                                     constant ColorParams &params [[buffer(0)]],
                                     // Colour S6: present only in the LUT pipelines (function constants).
                                     texture3d<float, access::read> lutCube [[texture(2), function_constant(kLUTCube)]],
                                     device const float4 *lutShaperRows   [[buffer(1), function_constant(kLUTShaper)]],
                                     constant LUTParams &lutParams         [[buffer(2), function_constant(kLUTOn)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float y  = lumaTex.sample(s, in.texCoord).r;
    float2 cbcr;
    if (params.fieldChroma != 0) {
        // Interlaced I3: a woven interlaced x420 picture, chroma from each line's own field (above).
        if (params.eightBitSource != 0) y = exactTimes4(y);
        cbcr = sampleChromaOwnField(lumaTex, chromaTex, in.texCoord + float2(params.chromaShiftU, 0.0),
                                    params.eightBitSource != 0);
    } else if (params.eightBitSource != 0) {
        // An 8-bit source: every sample exactly ×4 (the block above).
        y = exactTimes4(y);
        cbcr = sampleChromaExactTimes4(chromaTex, in.texCoord + float2(params.chromaShiftU, 0.0));
    } else {
        cbcr = chromaTex.sample(s, in.texCoord + float2(params.chromaShiftU, 0.0)).rg;
    }

    // Range handling. Chroma is ALWAYS centered (subtract the neutral, code 512) —
    // that's a chroma offset, not range expansion, and applies to both ranges.
    // What differs is the SCALE: video/legal data is encoded in 64–940 (luma) /
    // 64–960 (chroma) at 10-bit and must be expanded to 0–1; full-range data already
    // spans 0–1 and must NOT be expanded (expanding it is the double-expansion bug).
    // All constants are in the 10-bit sample domain — see the kCodeMax block above.
    float cb, cr;
    if (params.isFullRange != 0) {
        // Full range: luma spans the WHOLE code range, so it is not expanded — but it still has
        // to be taken out of the MSB-aligned sample domain (code/1023.984) into the display domain
        // (code/1023), or full white lands ~1 code short of 1.0. This is a domain correction, NOT a
        // range expansion — the black point stays at 0 and the transfer stays straight.
        y *= kFullLumaSwing;
        // Chroma centered, then scaled per the selected convention (luma is untouched by that).
        if (params.chromaConvention == 1) {
            // Resolve: chroma scaled by 219/224 — Resolve expands full-range
            // chroma by the LUMA factor, so the matching inverse is that swing
            // ratio. Renders a Resolve full file (Cr≈226 @8-bit) correct.
            cb = (cbcr.r - kChromaMid) * kResolveChromaScale;
            cr = (cbcr.g - kChromaMid) * kResolveChromaScale;
        } else {
            // Full-swing / spec: chroma centered only, no expansion.
            cb = cbcr.r - kChromaMid;
            cr = cbcr.g - kChromaMid;
        }
    } else {
        // Video/legal range: expand luma 64–940→0–1 and chroma 64–960→0–1.
        y  = (y - kLumaBlack) * kLumaSwing;
        cb = (cbcr.r - kChromaMid) * kChromaSwing;
        cr = (cbcr.g - kChromaMid) * kChromaSwing;
    }

    // YCbCr -> RGB using the matrix coefficients passed in.
    float r = y + params.a * cr;
    float g = y - params.b * cb - params.c * cr;
    float b = y + params.d * cb;

    // Colour S6, L1: the Interpretation LUT, on the R′G′B′ just computed. Compiled in ONLY in the LUT
    // pipelines (the function constants below); the pipeline built without constant values is this
    // function as it was before S6, so a window with no LUT runs exactly today's code.
    if (kLUTOn) {
        float3 v = float3(r, g, b);
        if (kLUTShaper) { v = lutShaper(v, lutShaperRows, lutParams); }
        if (kLUTCube) {
            v = kLUTTetrahedral ? lutCubeTetrahedral(v, lutCube, lutParams)
                                : lutCubeTrilinear(v, lutCube, lutParams);
        }
        return half4(half3(v), 1.0h);
    }

    // Narrow to half HERE (round-to-nearest) rather than letting the ROP truncate — see the
    // header comment. NOT clamped: the rgba16Float target carries >1.0 and negatives, which is
    // the whole point of E1. (Superwhite already exists in SDR: the legal ramp peaks at 1.00098.)
    return half4(half3(r, g, b), 1.0h);
}

// MARK: - Display copy stage (EXPERIMENT — structural prototype, IDENTITY transform)
//
// ⚠️ EXPERIMENT 2 SCAFFOLD — not a feature. Replaces the 1:1 blit from the offscreen ring to the
// drawable with a 1:1 RENDER PASS, so a display-only transform has somewhere to live that is
// DOWNSTREAM of the offscreen. Applies NO colour math: it is an identity copy, and is here purely
// to establish that the structural change is free and bit-exact before any transform is written.
//
// The offscreen is NOT modified by this stage, which is the whole point: the scopes, the DeckLink
// v210 convert and the frame export all read the offscreen ring and cannot observe this pass.
//
// `read()` at the fragment's own pixel coordinate rather than a sampler: fragment (x,y) reads texel
// (x,y), so the 1:1 mapping is a property of the addressing, not of a filter mode that a later edit
// could change. (Measured: sampler with filter::nearest is also bit-identical at 1920x1080 and
// 3840x2160 — but only the read() form is 1:1 BY CONSTRUCTION.)
// ⚠️ THIS STAGE IS NOW A RESAMPLE, NOT A 1:1 COPY, AND THAT IS DELIBERATE.
//
// The drawable is sized from the LAYOUT (the display raster), not from the source — see
// `MetalVideoRenderer.setLayoutSize`. So the offscreen (SOURCE resolution) and the drawable
// (DISPLAY resolution) differ in general, and `read()` at the fragment's own pixel coordinate —
// which is what this used to do — would crop the top-left corner of the source into the drawable
// instead of scaling it.
//
// THE RESAMPLE IS NOT NEW WORK. Core Animation was already scaling the presented drawable into the
// layer's bounds; this stage does the same arithmetic one step earlier, at a filter we choose, and
// before the present rather than after it. What IS new is that a 1080p source in a 4K window is now
// resampled ONCE, to the display raster, instead of being presented at 1080p and upscaled by the
// compositor.
//
// ⚠️ ITS uv STAYS 0…1 AND THAT IS NOT AN OVERSIGHT. The clean-aperture crop is applied at the
// offscreen pass above, so by the time this stage runs the offscreen IS the clean raster — the
// active picture and nothing else. Applying the aperture again here would crop the picture a
// second time; there is exactly one crop in the pipeline and it is not this one.
//
// `filter::linear` — bilinear. Correct for the scale-up case (the common one: a 1080p source in a
// window larger than 1080p on a 2x display). It is deliberately NOT the `.none` interpolation the
// SCOPES use: a scope trace is a measurement and must stay crisp, but a picture being scaled to a
// monitor wants a smooth filter. Note this stage reads the offscreen and writes the DRAWABLE, so it
// cannot be observed by the scopes, the DeckLink v210 convert or the frame export — all of which
// read the offscreen ring at source resolution.
struct DisplayCopyVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex DisplayCopyVertexOut displayCopyVertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 p = positions[vertexID];
    DisplayCopyVertexOut out;
    out.position = float4(p, 0.0, 1.0);
    // Clip space has y UP; texture coordinates have y DOWN and origin at the top-left. Flipping y
    // here is what keeps the picture the right way up — the previous read() form got this for free
    // because [[position]] is already a top-left-origin framebuffer coordinate.
    out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
    return out;
}

fragment half4 displayCopyFragment(DisplayCopyVertexOut in [[stage_in]],
                                   texture2d<half, access::sample> src [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge,
                        filter::linear, mip_filter::none);
    return src.sample(s, in.uv);
}

// ── THE REFERENCE DISPLAY TRANSFORM — colour S1, docs/COLOR_MANAGEMENT_FINDINGS.md §6.11 ─────────
//
// A SEPARATE FRAGMENT, NOT A UNIFORM ON `displayCopyFragment`, so OS and Bypass keep the identity copy
// above and cannot change: they never run this function. Same vertex stage, same sampler, same
// resample; only the colour arithmetic after the sample differs. Like the copy, it writes the
// DRAWABLE, so the scopes, the DeckLink v210 convert and the export (all of which read the offscreen)
// never see it.
//
// Two modes, chosen on the CPU (`MetalVideoRenderer.referencePlan`):
//
//   0 — BT.1886 FOR A DISPLAY DESCRIBED BY ITS PROFILE. D = BT.1886 drive from Lb/Lw (normalised
//       black-to-white), then encoded for the curve the DECLARED SOURCE profile carries:
//       out = D^(1/γ_declared). The layer keeps today's source declaration (§6.6), so ColorSync
//       linearises with γ_declared, recovers D, and converts it for the display.
//       ⚠️ THE §6.6 TRAP: applying 2.4 here and then declaring γ2.4 would be undone by ColorSync and
//       look exactly like OS. The declaration is deliberately left alone; only this encode changes.
//   1 — A DISPLAY CALIBRATED TO REC.709 / BT.1886 IN ITS OWN HARDWARE, WITH WIDE-GAMUT PRIMARIES.
//       The layer declares nothing (no conversion), and this converts the source primaries to 709 in
//       2.4-linear light and re-encodes with 1/2.4. A 709 source on a calibrated display never comes
//       here: it takes the identity copy, so its code values reach the display untouched.
//
// Sub-black clamps to 0 before any fractional power, so nothing can become NaN. Superwhite passes.
struct ReferenceParams {
    float a;            // BT.1886 a, Lw normalised to 1
    float b;            // BT.1886 b
    float blackRatio;   // Lb / Lw
    float invGamma;     // 1 / γ of the declared source profile (mode 0)
    uint  mode;         // 0 = BT.1886 for the profile, 1 = calibrated display, primaries → 709
    uint  pad0, pad1, pad2;
    float4 row0;        // mode 1: source → Rec.709 linear matrix, rows (w unused)
    float4 row1;
    float4 row2;
};

fragment half4 displayReferenceFragment(DisplayCopyVertexOut in [[stage_in]],
                                        texture2d<float, access::sample> src [[texture(0)]],
                                        constant ReferenceParams& p [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge,
                        filter::linear, mip_filter::none);
    float4 c = src.sample(s, in.uv);
    float3 v = c.rgb;
    float3 outRGB;
    if (p.mode == 0) {
        float3 l = p.a * pow(max(v + p.b, 0.0), 2.4);
        float3 d = max((l - p.blackRatio) / (1.0 - p.blackRatio), 0.0);
        outRGB = pow(d, p.invGamma);
    } else {
        float3 lin = pow(max(v, 0.0), 2.4);
        float3 lin709 = float3(dot(p.row0.xyz, lin), dot(p.row1.xyz, lin), dot(p.row2.xyz, lin));
        outRGB = pow(max(lin709, 0.0), 1.0 / 2.4);
    }
    return half4(half3(outRGB), half(c.a));
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
    float kr;        // YCbCr luma coeff for R (from source colorMatrixCode) — 2020 weights luma differently
    float kb;        // YCbCr luma coeff for B
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
    // Luma on the normalized display RGB, weighted by the SOURCE YCbCr matrix (Kr/Kb chosen
    // host-side from colorMatrixCode) — a 2020 source weights luma differently than 709. Kg
    // derives from Kr/Kb, so 709 / 2020 / 601 all fall out of these two coefficients.
    float kg = 1.0 - p.kr - p.kb;
    float luma = p.kr * c.r + kg * c.g + p.kb * c.b;
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
    float kr;          // YCbCr luma coeff for R (from source colorMatrixCode) — drives WHERE chroma lands
    float kb;          // YCbCr luma coeff for B
};

// Vectorscope: a 2-D chroma-plane scatter (Cb horizontal, Cr vertical) on the offscreen.
// Per pixel: SOURCE-matrix luma (Kr/Kb from colorMatrixCode, host-side), then
// Cb=(B-Y)/(2(1-Kb)), Cr=(R-Y)/(2(1-Kr)) in the 0–255 domain (709: 1.8556/1.5748, 2020:
// 1.8814/1.4746) — so 2020 chroma lands where a 2020 scope expects, not the 709 position.
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
    float kg = 1.0 - p.kr - p.kb;
    float y  = p.kr * r + kg * g + p.kb * b;
    float cb = (b - y) / (2.0 * (1.0 - p.kb));
    float cr = (r - y) / (2.0 * (1.0 - p.kr));

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
// must match exactly). planeW/planeH is the 2-D histogram size; `curve` and `rgbToXYZ` come from
// `ColorimetryTable` on the host (colour S3) — this file holds no primaries of its own; u/v Min/Max
// are the u'v' plane bounds (shared with the graticule draw code so scatter + overlay align).
struct CIEParams {
    uint  width;         // source (offscreen) width in pixels
    uint  height;        // source (offscreen) height in pixels
    uint  planeW;        // histogram width  (horizontal axis)
    uint  planeH;        // histogram height (vertical axis)
    int   curve;         // ScopeCurve: 0 = gamma 2.4, 13 = sRGB, 16 = PQ, 18 = HLG
    uint  useUV;         // 1 = CIE 1976 u'v', 0 = CIE 1931 xy
    // Plane bounds. GENERIC per-axis bounds (not literally u'/v'): the host fills them with the
    // active mode's bounds — u'v' (0/0.62, 0/0.60) or xy (0/0.75, 0/0.85). u* = horizontal
    // axis, v* = vertical axis. Same bounds are used by the graticule so overlay + scatter align.
    float uMin;          // horizontal-axis lower bound
    float uMax;          // horizontal-axis upper bound
    float vMin;          // vertical-axis lower bound
    float vMax;          // vertical-axis upper bound
    float rgbToXYZ[9];   // linear source RGB -> XYZ, row-major, from the source's primaries
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

static inline float cieLinearize(float e, int curve) {
    switch (curve) {
        case 13: return cieSrgbEOTF(e);                 // sRGB
        case 16: return ciePqEOTF(e);                   // PQ / ST 2084
        case 18: return cieHlgInvOETF(e);               // HLG
        default: return pow(max(e, 0.0), 2.4);          // 709 family / unknown → gamma 2.4
    }
}

// Linear source-primaries RGB → CIE XYZ, with the host's matrix (primaries, NOT the YCbCr matrix).
static inline float3 cieRGBtoXYZ(float3 rgb, constant CIEParams &p) {
    return float3(p.rgbToXYZ[0] * rgb.r + p.rgbToXYZ[1] * rgb.g + p.rgbToXYZ[2] * rgb.b,
                  p.rgbToXYZ[3] * rgb.r + p.rgbToXYZ[4] * rgb.g + p.rgbToXYZ[5] * rgb.b,
                  p.rgbToXYZ[6] * rgb.r + p.rgbToXYZ[7] * rgb.g + p.rgbToXYZ[8] * rgb.b);
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
    float3 lin = float3(cieLinearize(c.r, p.curve),
                        cieLinearize(c.g, p.curve),
                        cieLinearize(c.b, p.curve));
    if (any(isnan(lin))) return;

    float3 xyz = cieRGBtoXYZ(lin, p);

    // Project to the active chromaticity space. `a` = horizontal coord, `b` = vertical coord.
    float a, b;
    if (p.useUV != 0u) {
        // CIE 1976 u'v'.
        float denom = xyz.x + 15.0 * xyz.y + 3.0 * xyz.z;
        if (denom < 1e-6) return;                        // near-black: no meaningful chromaticity
        a = 4.0 * xyz.x / denom;                         // u'
        b = 9.0 * xyz.y / denom;                         // v'
    } else {
        // CIE 1931 xy.
        float denom = xyz.x + xyz.y + xyz.z;
        if (denom < 1e-6) return;
        a = xyz.x / denom;                               // x
        b = xyz.y / denom;                               // y
    }
    if (isnan(a) || isnan(b)) return;

    // Map to the plane, normalized by the active-mode bounds; flip the vertical axis for
    // image row order. Same bounds the graticule uses, so overlay + scatter align in both modes.
    float fa = (a - p.uMin) / (p.uMax - p.uMin);
    float fb = (b - p.vMin) / (p.vMax - p.vMin);
    int col = int(fa * float(p.planeW));
    int row = int((1.0 - fb) * float(p.planeH));
    if (col >= 0 && col < int(p.planeW) && row >= 0 && row < int(p.planeH)) {
        atomic_fetch_add_explicit(&hist[uint(row) * p.planeW + uint(col)], 1u, memory_order_relaxed);
    }
}

// MARK: - DeckLink output (RGB offscreen -> v210 10-bit, BT.709 LIMITED range)

// Uniforms for rgbToV210. Mirrors RGBToV210Params in MetalVideoRenderer.swift (field order + type
// must match exactly). Dimensions are decoupled: the kernel reads the SOURCE offscreen (clamped)
// and writes the OUTPUT-sized v210 buffer, so a native-res mismatch never reads out of bounds.
struct RGBToV210Params {
    uint srcWidth;      // offscreen (source) width in pixels
    uint srcHeight;     // offscreen (source) height in pixels
    uint dstWidth;      // DeckLink output width (e.g. 3840)
    uint dstHeight;     // DeckLink output height (e.g. 2160)
    uint dstRowWords;   // v210 row stride in 32-bit WORDS (= rowBytes/4; 4K = 10240/4 = 2560)
    float kr;           // BT YCbCr matrix luma coeff for R (selected by source colorMatrixCode)
    float kb;           // BT YCbCr matrix luma coeff for B
    uint chromaMode;    // V210ChromaMode (ColorimetryModel): 0 pair average (4:2:0, as before),
                        // 1 co-sited sample (4:2:2), 2 the D3 halfband (4:4:4)
    uint gamutConvert;  // colour S7, D4: 1 → rendered P3 → Rec.2020 before the encode (SDI only); 0 → as read
    int  gamutCurve;    // ScopeCurve: the picture's curve, decoded before gamutMatrix and re-encoded after
    float gamutMatrix[9];   // linear rendered-P3 → linear Rec.2020, row-major (SDIPrimariesConversion.matrix)
    // SDI scaling (§6.11, *SDI scaling*): the picture's rectangle in the output, and the tap counts of the resample.
    // Read only by the placed kernels below; rgbToV210 (native) never reads them.
    uint picX;          // on the v210 6-pixel group (D9)
    uint picY;
    uint picW;
    uint picH;
    uint tapsH;         // horizontal luma taps per output pixel
    uint tapsC;         // horizontal chroma taps per output chroma sample (co-sited, even pixels)
    uint tapsV;         // vertical taps per output row
};

// ── Colour S7, D4: P3 → Rec.2020 for SDI. The arithmetic of `SDIPrimariesConversion.apply` (ColorimetryModel), which
// is the reference P7 measures against: power curves on the magnitude with the sign kept (sub-black and superwhite
// survive), PQ and HLG from 0, and the inverse of each after the matrix.
static inline float v210Linearize(float e, int curve) {
    switch (curve) {
        case 13: {
            const float a = fabs(e);
            const float l = (a <= 0.04045) ? (a / 12.92) : pow((a + 0.055) / 1.055, 2.4);
            return copysign(l, e);
        }
        case 16: return ciePqEOTF(e);
        case 18: return cieHlgInvOETF(max(e, 0.0));
        default: return copysign(pow(fabs(e), 2.4), e);
    }
}
static inline float v210Encode(float l, int curve) {
    switch (curve) {
        case 13: {
            const float a = fabs(l);
            const float e = (a <= 0.0031308) ? (12.92 * a) : (1.055 * pow(a, 1.0 / 2.4) - 0.055);
            return copysign(e, l);
        }
        case 16: {
            const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
            const float y = pow(max(l, 0.0), m1);
            return pow((c1 + c2 * y) / (1.0 + c3 * y), m2);
        }
        case 18: {
            const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
            const float x = max(l, 0.0);
            return (x <= 1.0 / 12.0) ? sqrt(3.0 * x) : (a * log(12.0 * x - b) + c);
        }
        default: return copysign(pow(fabs(l), 1.0 / 2.4), l);
    }
}
// One offscreen pixel as SDI carries it: read, and converted when the frame's signal asks for it.
static inline float3 v210ReadPixel(texture2d<float, access::read> offscreen, uint2 at, constant RGBToV210Params &p) {
    const float3 c = offscreen.read(at).rgb;
    if (p.gamutConvert == 0u) return c;
    const float3 l = float3(v210Linearize(c.r, p.gamutCurve), v210Linearize(c.g, p.gamutCurve), v210Linearize(c.b, p.gamutCurve));
    const float3 o = float3(p.gamutMatrix[0] * l.r + p.gamutMatrix[1] * l.g + p.gamutMatrix[2] * l.b,
                            p.gamutMatrix[3] * l.r + p.gamutMatrix[4] * l.g + p.gamutMatrix[5] * l.b,
                            p.gamutMatrix[6] * l.r + p.gamutMatrix[7] * l.g + p.gamutMatrix[8] * l.b);
    return float3(v210Encode(o.r, p.gamutCurve), v210Encode(o.g, p.gamutCurve), v210Encode(o.b, p.gamutCurve));
}

// 10-bit LIMITED-range luma (Y' 64..940). Same scale for every matrix; only the yf weights differ.
static inline uint v210_Y(float yf) {
    return uint(clamp(round(64.0 + 876.0 * yf), 64.0, 940.0));
}
// Chroma from a subsampled PAIR (average the two pixels' (chan - yf) then scale). `denom` is the
// matrix-dependent excursion: 2*(1-Kb) for Cb, 2*(1-Kr) for Cr (709: 1.8556/1.5748, 2020: 1.8814/
// 1.4746). Cb/Cr 64..960.
static inline uint v210_C(float c0, float yf0, float c1, float yf1, float denom) {
    float cn = 0.5 * ((c0 - yf0) + (c1 - yf1)) / denom;   // normalized [-0.5, 0.5]
    return uint(clamp(round(512.0 + 896.0 * cn), 64.0, 960.0));
}
// One already-normalized chroma value [-0.5, 0.5] → its 10-bit code. Modes 1 and 2.
static inline uint v210_Cn(float cn) {
    return uint(clamp(round(512.0 + 896.0 * cn), 64.0, 960.0));
}

// Convert the display offscreen (rgb10a2 normalized RGB — transfer-ENCODED, SOURCE-primaries) to
// v210 (10-bit YUV 4:2:2), LIMITED range, for DeckLink output. The YCbCr matrix (Kr/Kb) is chosen
// by the source's colorMatrixCode (D5) — 709 / 2020 / 601 — so wide-gamut sources encode correctly.
// (The offscreen is in the picture's primaries; the OUTPUT tag is set separately on the frame by the
// bridge, from the frame's own signal. Colour S7, D4: a P3-tagged picture is converted to Rec.2020 here,
// for SDI only, because SDI has no P3 tag; see v210ReadPixel.)
//
// v210 packs 6 pixels into 4 little-endian 32-bit words (16 bytes), 3 components per word, each 10
// bits low→high, top 2 bits unused. Standard Apple/FFmpeg layout (kCMPixelFormat_422YpCbCr10):
//   Word0 = Cb0 | (Y0<<10) | (Cr0<<20)
//   Word1 = Y1  | (Cb2<<10) | (Y2<<20)
//   Word2 = Cr2 | (Y3<<10) | (Cb4<<20)
//   Word3 = Y4  | (Cr4<<10) | (Y5<<20)
// Chroma is 4:2:2: for a 4:2:0 source Cb0/Cr0 from px0&1, Cb2/Cr2 from px2&3, Cb4/Cr4 from px4&5
// (averaged); for 4:2:2 and 4:4:4 sources see `chromaMode` below.
// One thread per 6-pixel group; writes 4 words at row*dstRowWords + groupX*4.
kernel void rgbToV210(texture2d<float, access::read> offscreen [[texture(0)]],
                      device uint *dst               [[buffer(0)]],
                      constant RGBToV210Params &p    [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    const uint groupX = gid.x;   // output 6-pixel group column
    const uint y      = gid.y;
    const uint groups = (p.dstWidth + 5u) / 6u;
    if (groupX >= groups || y >= p.dstHeight) return;

    const uint x0 = groupX * 6u;
    const uint sy = min(y, p.srcHeight - 1u);

    // Matrix (Kr/Kb) chosen upstream by the source colorMatrixCode. Kg + chroma denominators derive
    // from Kr/Kb, so 709 / 2020 / 601 all fall out of these two coefficients.
    const float kr = p.kr, kb = p.kb, kg = 1.0 - kr - kb;
    const float denomB = 2.0 * (1.0 - kb);   // Cb excursion
    const float denomR = 2.0 * (1.0 - kr);   // Cr excursion

    // Read 6 source pixels (clamped to src bounds — resolution guard).
    float3 c[6];
    float  yf[6];
    for (uint i = 0u; i < 6u; i++) {
        const uint sx = min(x0 + i, p.srcWidth - 1u);
        c[i]  = v210ReadPixel(offscreen, uint2(sx, sy), p);
        yf[i] = kr * c[i].r + kg * c[i].g + kb * c[i].b;
    }

    const uint Y0 = v210_Y(yf[0]), Y1 = v210_Y(yf[1]), Y2 = v210_Y(yf[2]);
    const uint Y3 = v210_Y(yf[3]), Y4 = v210_Y(yf[4]), Y5 = v210_Y(yf[5]);

    // ── CHROMA, PER SOURCE (Stage 3b S1, D3/D4) ──────────────────────────────────────────────
    // The offscreen is RGB, so the kernel cannot see how much chroma the picture had; the renderer
    // passes it per frame (`chromaMode`, from the buffer rendered into that ring slot).
    uint Cb0, Cr0, Cb2, Cr2, Cb4, Cr4;
    if (p.chromaMode == 1u) {
        // 4:2:2 SOURCE: the even pixel's own chroma. The shader's co-sited upsample put chroma
        // sample k exactly on pixel 2k, so this returns the source's chroma: nothing is reduced.
        Cb0 = v210_Cn((c[0].b - yf[0]) / denomB); Cr0 = v210_Cn((c[0].r - yf[0]) / denomR);
        Cb2 = v210_Cn((c[2].b - yf[2]) / denomB); Cr2 = v210_Cn((c[2].r - yf[2]) / denomR);
        Cb4 = v210_Cn((c[4].b - yf[4]) / denomB); Cr4 = v210_Cn((c[4].r - yf[4]) / denomR);
    } else if (p.chromaMode == 2u) {
        // 4:4:4 SOURCE: the one reduction, with a proper filter (D3). A 7-tap co-sited halfband,
        // [-1, 0, 9, 16, 9, 0, -1] / 32, centred on each even pixel; unity at DC, zero at Nyquist, so
        // a one-pixel chroma alternation reduces to its mean instead of aliasing onto the wire. Reads
        // pixels x0-3 … x0+7, MIRRORED about the edge pixel (-1 → 1, W → W-2): the extension a
        // symmetric odd-length filter needs. Edge REPLICATION breaks a one-pixel alternation at the
        // border (measured: 499 and 618 where 512 is right). Taps restated from
        // V210ChromaMode.halfbandTaps.
        const int lastX = int(p.srcWidth) - 1;
        float cbN[11], crN[11];
        for (int i = 0; i < 11; i++) {
            int sx = int(x0) + i - 3;
            sx = sx < 0 ? -sx : (sx > lastX ? 2 * lastX - sx : sx);
            sx = clamp(sx, 0, lastX);   // a raster narrower than 4 px: never read out of bounds
            const float3 px = v210ReadPixel(offscreen, uint2(uint(sx), sy), p);
            const float  py = kr * px.r + kg * px.g + kb * px.b;
            cbN[i] = (px.b - py) / denomB;
            crN[i] = (px.r - py) / denomR;
        }
        // Centre of output pair j (pixel x0+2j) is index 3+2j.
        float hb[6];
        for (int j = 0; j < 3; j++) {
            const int m = 3 + 2 * j;
            hb[2 * j]     = (16.0 * cbN[m] + 9.0 * (cbN[m - 1] + cbN[m + 1]) - (cbN[m - 3] + cbN[m + 3])) / 32.0;
            hb[2 * j + 1] = (16.0 * crN[m] + 9.0 * (crN[m - 1] + crN[m + 1]) - (crN[m - 3] + crN[m + 3])) / 32.0;
        }
        Cb0 = v210_Cn(hb[0]); Cr0 = v210_Cn(hb[1]);
        Cb2 = v210_Cn(hb[2]); Cr2 = v210_Cn(hb[3]);
        Cb4 = v210_Cn(hb[4]); Cr4 = v210_Cn(hb[5]);
    } else {
        // 4:2:0, and anything else: today's pair average, unchanged, so the 4:2:0 wire is
        // byte-for-byte what it was (P1). Its siting is a separate stage (D4).
        Cb0 = v210_C(c[0].b, yf[0], c[1].b, yf[1], denomB);
        Cr0 = v210_C(c[0].r, yf[0], c[1].r, yf[1], denomR);
        Cb2 = v210_C(c[2].b, yf[2], c[3].b, yf[3], denomB);
        Cr2 = v210_C(c[2].r, yf[2], c[3].r, yf[3], denomR);
        Cb4 = v210_C(c[4].b, yf[4], c[5].b, yf[5], denomB);
        Cr4 = v210_C(c[4].r, yf[4], c[5].r, yf[5], denomR);
    }

    const uint w0 = Cb0 | (Y0 << 10) | (Cr0 << 20);
    const uint w1 = Y1  | (Cb2 << 10) | (Y2 << 20);
    const uint w2 = Cr2 | (Y3 << 10) | (Cb4 << 20);
    const uint w3 = Y4  | (Cr4 << 10) | (Y5 << 20);

    const uint base = y * p.dstRowWords + groupX * 4u;   // word index (Apple Silicon is LE)
    dst[base + 0u] = w0;
    dst[base + 1u] = w1;
    dst[base + 2u] = w2;
    dst[base + 3u] = w3;
}

// ── SDI scaling (§6.11, *SDI scaling*; Robbie's D2–D9, 2026-10-23) ────────────────────────────────────────────────
// A source whose raster is not the output mode's is PLACED in it, centred on the v210 6-pixel group, with video black
// (Y 64, Cb/Cr 512) around it — and scaled only when it does not fit. rgbToV210 above is the native path and is not
// touched: a source that IS the mode still runs it, byte for byte.

// The four words of one all-black 6-pixel group (Cb 512, Y 64, Cr 512).
static inline void v210WriteBlack(device uint *dst, uint base) {
    dst[base + 0u] = 0x20010200u;
    dst[base + 1u] = 0x04080040u;
    dst[base + 2u] = 0x20010200u;
    dst[base + 3u] = 0x04080040u;
}

// UNSCALED placement. picX is a multiple of 6, so output group g carries source group g − picX/6 exactly: every
// component inside the picture is computed as rgbToV210 computes it for the source at its own size (the same reads,
// the same clamps and mirrors at the SOURCE edges, the same chroma mode), and every pixel outside is black.
kernel void rgbToV210Placed(texture2d<float, access::read> offscreen [[texture(0)]],
                            device uint *dst               [[buffer(0)]],
                            constant RGBToV210Params &p    [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    const uint groupX = gid.x;
    const uint y      = gid.y;
    const uint groups = (p.dstWidth + 5u) / 6u;
    if (groupX >= groups || y >= p.dstHeight) return;
    const uint base = y * p.dstRowWords + groupX * 4u;
    const uint x0 = groupX * 6u;
    if (y < p.picY || y >= p.picY + p.picH || x0 < p.picX || x0 >= p.picX + p.picW) { v210WriteBlack(dst, base); return; }

    const uint sx0 = x0 - p.picX;            // a multiple of 6: the source's own group
    const uint sy  = min(y - p.picY, p.srcHeight - 1u);
    const float kr = p.kr, kb = p.kb, kg = 1.0 - kr - kb;
    const float denomB = 2.0 * (1.0 - kb);
    const float denomR = 2.0 * (1.0 - kr);

    float3 c[6];
    float  yf[6];
    for (uint i = 0u; i < 6u; i++) {
        const uint sx = min(sx0 + i, p.srcWidth - 1u);
        c[i]  = v210ReadPixel(offscreen, uint2(sx, sy), p);
        yf[i] = kr * c[i].r + kg * c[i].g + kb * c[i].b;
    }
    uint Y[6];
    for (uint i = 0u; i < 6u; i++) Y[i] = (sx0 + i < p.picW) ? v210_Y(yf[i]) : 64u;

    uint Cb[3], Cr[3];
    if (p.chromaMode == 1u) {
        for (uint j = 0u; j < 3u; j++) {
            Cb[j] = v210_Cn((c[2u * j].b - yf[2u * j]) / denomB); Cr[j] = v210_Cn((c[2u * j].r - yf[2u * j]) / denomR);
        }
    } else if (p.chromaMode == 2u) {
        // The 4:4:4 halfband of rgbToV210, restated: mirrored about the SOURCE's edge pixel.
        const int lastX = int(p.srcWidth) - 1;
        float cbN[11], crN[11];
        for (int i = 0; i < 11; i++) {
            int sx = int(sx0) + i - 3;
            sx = sx < 0 ? -sx : (sx > lastX ? 2 * lastX - sx : sx);
            sx = clamp(sx, 0, lastX);
            const float3 px = v210ReadPixel(offscreen, uint2(uint(sx), sy), p);
            const float  py = kr * px.r + kg * px.g + kb * px.b;
            cbN[i] = (px.b - py) / denomB;
            crN[i] = (px.r - py) / denomR;
        }
        for (int j = 0; j < 3; j++) {
            const int m = 3 + 2 * j;
            Cb[j] = v210_Cn((16.0 * cbN[m] + 9.0 * (cbN[m - 1] + cbN[m + 1]) - (cbN[m - 3] + cbN[m + 3])) / 32.0);
            Cr[j] = v210_Cn((16.0 * crN[m] + 9.0 * (crN[m - 1] + crN[m + 1]) - (crN[m - 3] + crN[m + 3])) / 32.0);
        }
    } else {
        for (uint j = 0u; j < 3u; j++) {
            Cb[j] = v210_C(c[2u * j].b, yf[2u * j], c[2u * j + 1u].b, yf[2u * j + 1u], denomB);
            Cr[j] = v210_C(c[2u * j].r, yf[2u * j], c[2u * j + 1u].r, yf[2u * j + 1u], denomR);
        }
    }
    for (uint j = 0u; j < 3u; j++) if (sx0 + 2u * j >= p.picW) { Cb[j] = 512u; Cr[j] = 512u; }

    dst[base + 0u] = Cb[0] | (Y[0] << 10) | (Cr[0] << 20);
    dst[base + 1u] = Y[1]  | (Cb[1] << 10) | (Y[2] << 20);
    dst[base + 2u] = Cr[1] | (Y[3] << 10) | (Cb[2] << 20);
    dst[base + 3u] = Y[4]  | (Cr[2] << 10) | (Y[5] << 20);
}

// SCALED placement, pass 1 of 2: the vertical Lanczos-3 (D4), source width × picture height, into an rgba32Float
// intermediate. Each pixel is read as SDI carries it (v210ReadPixel: S7's P3 → 2020 when the frame asks), so the filter
// runs in the output's R'G'B' code space, as the 4:4:4 halfband does. Taps and weights come from the CPU
// (`SDIResampleTaps`, double precision, normalised; mirrored at the source edge).
kernel void sdiResampleVertical(texture2d<float, access::read>  offscreen [[texture(0)]],
                                texture2d<float, access::write> inter     [[texture(1)]],
                                constant RGBToV210Params &p   [[buffer(0)]],
                                constant int   *idxV          [[buffer(1)]],
                                constant float *wV            [[buffer(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.srcWidth || gid.y >= p.picH) return;
    float3 acc = float3(0.0);
    const uint row = gid.y * p.tapsV;
    for (uint k = 0u; k < p.tapsV; k++) {
        const float w = wV[row + k];
        if (w != 0.0) acc += w * v210ReadPixel(offscreen, uint2(gid.x, uint(idxV[row + k])), p);
    }
    inter.write(float4(acc, 1.0), gid);
}

// SCALED placement, pass 2 of 2: the horizontal Lanczos-3 and the v210 pack. Luma per output pixel with the luma
// taps; chroma per output chroma sample — co-sited with the even pixels, as 4:2:2 is sited — with the chroma taps,
// whose kernel is twice as wide (half the bandwidth). Chroma is the matrix applied to the chroma-filtered R'G'B'
// (the matrix is linear, so this is filtering Cb and Cr). Outside the picture, black.
kernel void rgbToV210Scaled(texture2d<float, access::read> inter [[texture(0)]],
                            device uint *dst               [[buffer(0)]],
                            constant RGBToV210Params &p    [[buffer(1)]],
                            constant int   *idxH           [[buffer(2)]],
                            constant float *wH             [[buffer(3)]],
                            constant int   *idxC           [[buffer(4)]],
                            constant float *wC             [[buffer(5)]],
                            uint2 gid [[thread_position_in_grid]]) {
    const uint groupX = gid.x;
    const uint y      = gid.y;
    const uint groups = (p.dstWidth + 5u) / 6u;
    if (groupX >= groups || y >= p.dstHeight) return;
    const uint base = y * p.dstRowWords + groupX * 4u;
    const uint x0 = groupX * 6u;
    if (y < p.picY || y >= p.picY + p.picH || x0 < p.picX || x0 >= p.picX + p.picW) { v210WriteBlack(dst, base); return; }

    const uint r = y - p.picY;
    const float kr = p.kr, kb = p.kb, kg = 1.0 - kr - kb;
    const float denomB = 2.0 * (1.0 - kb);
    const float denomR = 2.0 * (1.0 - kr);
    const uint px0 = x0 - p.picX;            // even: picX is a multiple of 6

    uint Y[6];
    for (uint i = 0u; i < 6u; i++) {
        const uint px = px0 + i;
        if (px >= p.picW) { Y[i] = 64u; continue; }
        float3 acc = float3(0.0);
        const uint t = px * p.tapsH;
        for (uint k = 0u; k < p.tapsH; k++) {
            const float w = wH[t + k];
            if (w != 0.0) acc += w * inter.read(uint2(uint(idxH[t + k]), r)).rgb;
        }
        Y[i] = v210_Y(kr * acc.r + kg * acc.g + kb * acc.b);
    }
    uint Cb[3], Cr[3];
    for (uint j = 0u; j < 3u; j++) {
        const uint px = px0 + 2u * j;
        if (px >= p.picW) { Cb[j] = 512u; Cr[j] = 512u; continue; }
        float3 acc = float3(0.0);
        const uint t = (px / 2u) * p.tapsC;
        for (uint k = 0u; k < p.tapsC; k++) {
            const float w = wC[t + k];
            if (w != 0.0) acc += w * inter.read(uint2(uint(idxC[t + k]), r)).rgb;
        }
        const float yc = kr * acc.r + kg * acc.g + kb * acc.b;
        Cb[j] = v210_Cn((acc.b - yc) / denomB);
        Cr[j] = v210_Cn((acc.r - yc) / denomR);
    }
    dst[base + 0u] = Cb[0] | (Y[0] << 10) | (Cr[0] << 20);
    dst[base + 1u] = Y[1]  | (Cb[1] << 10) | (Y[2] << 20);
    dst[base + 2u] = Cr[1] | (Y[3] << 10) | (Cb[2] << 20);
    dst[base + 3u] = Y[4]  | (Cr[2] << 10) | (Y[5] << 20);
}
