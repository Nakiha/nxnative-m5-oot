// The present: the frame drawn into the drawable, cropped (nvn_mtl.m present_pipeline)
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
struct Crop { float4 rect; float4 edge; };
fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) { return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)); }

// SDR boot/video frames must not be interpreted as PQ when the experimental
// output layer is HDR. Convert sRGB/BT.709 to BT.2020 and ST 2084, at the same
// 203-nit paper white that vi::QueryDisplayHdrPaperWhite reports to the game.
float3 hdr_srgb_linear(float3 x) {
    x = max(x, 0.0f);
    return select(pow((x + 0.055f) / 1.055f, float3(2.4f)), x / 12.92f, x <= 0.04045f);
}
float3 hdr_pq_encode(float3 nits) {
    float3 y = pow(clamp(nits / 10000.0f, 0.0f, 1.0f), float3(2610.0f / 16384.0f));
    return pow((3424.0f / 4096.0f + (2413.0f / 128.0f) * y) / (1.0f + (2392.0f / 128.0f) * y), float3(2523.0f / 32.0f));
}
fragment float4 fs_hdr_sdr(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    float4 v = t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));
    float3 x = hdr_srgb_linear(v.rgb);
    float3 bt2020 = float3(dot(x, float3(0.6274040f, 0.3292820f, 0.0433136f)),
                          dot(x, float3(0.0690970f, 0.9195400f, 0.0113612f)),
                          dot(x, float3(0.0163916f, 0.0880132f, 0.8955950f)));
    return float4(hdr_pq_encode(bt2020 * 203.0f), v.a);
}

// Ordinary PNG captures are SDR previews, not evidence of HDR screen output.
// Decode PQ, transform the primaries and apply a simple luminance-preserving
// shoulder; never save PQ code values tagged as sRGB by the screenshot path.
fragment float4 fs_hdr_preview(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    float4 v = t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));
    float3 p = pow(clamp(v.rgb, 0.0f, 1.0f), float3(32.0f / 2523.0f));
    float3 nits = 10000.0f * pow(max(p - 3424.0f / 4096.0f, 0.0f) / max(2413.0f / 128.0f - (2392.0f / 128.0f) * p, 1e-6f), float3(16384.0f / 2610.0f));
    float3 x = max(float3(dot(nits, float3(1.660491f, -0.587641f, -0.072850f)),
                         dot(nits, float3(-0.124550f, 1.132900f, -0.008349f)),
                         dot(nits, float3(-0.018151f, -0.100579f, 1.118730f))) / 203.0f, 0.0f);
    x /= 1.0f + max(x.r, max(x.g, x.b));
    float3 srgb = select(1.055f * pow(x, float3(1.0f / 2.4f)) - 0.055f, 12.92f * x, x <= 0.0031308f);
    return float4(srgb, v.a);
}
