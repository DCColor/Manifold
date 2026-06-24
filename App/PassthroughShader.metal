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

    // Video-range expansion (the engine forces video-range output).
    y = (y - 16.0/255.0) * (255.0/219.0);
    float cb = (cbcr.r - 128.0/255.0) * (255.0/224.0);
    float cr = (cbcr.g - 128.0/255.0) * (255.0/224.0);

    // YCbCr -> RGB using the matrix coefficients passed in.
    float r = y + params.a * cr;
    float g = y - params.b * cb - params.c * cr;
    float b = y + params.d * cb;

    return float4(r, g, b, 1.0);
}
