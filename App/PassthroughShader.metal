#include <metal_stdlib>
using namespace metal;

// Full-screen quad: position + texture coordinates.
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Vertex shader: emits a full-screen triangle/quad from vertex IDs.
// We draw 4 vertices as a triangle strip covering the whole viewport.
vertex VertexOut passthroughVertex(uint vertexID [[vertex_id]]) {
    // Quad corners in clip space and matching tex coords.
    float2 positions[4] = {
        float2(-1.0, -1.0),  // bottom-left
        float2( 1.0, -1.0),  // bottom-right
        float2(-1.0,  1.0),  // top-left
        float2( 1.0,  1.0)   // top-right
    };
    // Texture coords: flip Y so the image is upright (Metal tex origin is top-left,
    // clip-space Y is bottom-up).
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

// Fragment shader: sample NV12 (luma + chroma planes), convert YCbCr -> RGB
// with Rec.709 video-range coefficients.
fragment float4 passthroughFragment(VertexOut in [[stage_in]],
                                     texture2d<float> lumaTex   [[texture(0)]],
                                     texture2d<float> chromaTex [[texture(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // Sample luma (R8) and chroma (RG8 = Cb, Cr).
    float y  = lumaTex.sample(s, in.texCoord).r;
    float2 cbcr = chromaTex.sample(s, in.texCoord).rg;

    // Video-range expansion: Y in [16/255, 235/255], CbCr in [16/255, 240/255]
    // centered at 128/255. Bring to full-range, center chroma at 0.
    y = (y - 16.0/255.0) * (255.0/219.0);
    float cb = (cbcr.r - 128.0/255.0) * (255.0/224.0);
    float cr = (cbcr.g - 128.0/255.0) * (255.0/224.0);

    // Rec.709 YCbCr -> RGB.
    float r = y + 1.5748 * cr;
    float g = y - 0.1873 * cb - 0.4681 * cr;
    float b = y + 1.8556 * cb;

    return float4(r, g, b, 1.0);
}
