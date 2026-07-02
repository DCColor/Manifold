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
