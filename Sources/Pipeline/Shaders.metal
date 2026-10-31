#include <metal_stdlib>
using namespace metal;

// Shared with FramePipeline.swift. Field order and types must match `OverlayParams` there.
struct OverlayParams {
    uint quarterTurns;     // clockwise quarter turns applied to the buffer to display it
    uint mirrored;         // 1 when the preview is mirrored (front camera)
    float threshold;       // Sobel magnitude where peaking starts
    float stepScale;       // buffer texels per overlay pixel (>= 1)
    float4 color;          // peaking colour, straight alpha
    float2 lumaTexel;      // 1 / luma texture size
    float2 padding;
};

struct HistogramParams {
    uint width;
    uint height;
};

// Same mapping as RotationMath.bufferPoint(forDisplayPoint:quarterTurns:mirrored:).
inline float2 bufferUV(float2 uv, uint turns, uint mirrored) {
    float u = mirrored != 0 ? 1.0f - uv.x : uv.x;
    float v = uv.y;
    switch (turns & 3u) {
        case 1u: return float2(v, 1.0 - u);
        case 2u: return float2(1.0 - u, 1.0 - v);
        case 3u: return float2(1.0 - v, u);
        default: return float2(u, v);
    }
}

inline float sobelMagnitude(texture2d<float, access::sample> luma, sampler s, float2 b, float2 d) {
    float tl = luma.sample(s, b + float2(-d.x, -d.y)).r;
    float tc = luma.sample(s, b + float2( 0.0, -d.y)).r;
    float tr = luma.sample(s, b + float2( d.x, -d.y)).r;
    float ml = luma.sample(s, b + float2(-d.x,  0.0)).r;
    float mr = luma.sample(s, b + float2( d.x,  0.0)).r;
    float bl = luma.sample(s, b + float2(-d.x,  d.y)).r;
    float bc = luma.sample(s, b + float2( 0.0,  d.y)).r;
    float br = luma.sample(s, b + float2( d.x,  d.y)).r;
    float gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
    float gy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);
    return sqrt(gx * gx + gy * gy);
}

// Focus peaking: Sobel on the luma plane, written straight into the overlay's drawable.
kernel void peakingKernel(texture2d<float, access::sample> luma [[texture(0)]],
                          texture2d<float, access::write> output [[texture(1)]],
                          constant OverlayParams& p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint width = output.get_width();
    uint height = output.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(width, height);
    float2 b = bufferUV(uv, p.quarterTurns, p.mirrored);
    float2 d = p.lumaTexel * max(p.stepScale, 1.0f);
    float magnitude = sobelMagnitude(luma, s, b, d);
    float alpha = smoothstep(p.threshold, p.threshold * 1.5f, magnitude) * p.color.a;
    output.write(float4(p.color.rgb * alpha, alpha), gid);
}

// 256-bin R, G, B and luma histograms over a downsampled grid of the frame.
// bins layout: [0,256) red, [256,512) green, [512,768) blue, [768,1024) luma.
kernel void histogramKernel(texture2d<float, access::sample> luma [[texture(0)]],
                            texture2d<float, access::sample> chroma [[texture(1)]],
                            device atomic_uint* bins [[buffer(0)]],
                            constant HistogramParams& p [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) {
        return;
    }
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(p.width, p.height);
    float y = luma.sample(s, uv).r;
    float2 c = chroma.sample(s, uv).rg - 0.5f;
    // BT.709 full-range YCbCr -> RGB.
    float3 rgb = float3(y + 1.5748 * c.y,
                        y - 0.1873 * c.x - 0.4681 * c.y,
                        y + 1.8556 * c.x);
    rgb = clamp(rgb, float3(0.0f), float3(1.0f));
    uint3 index = uint3(rgb * 255.0f + 0.5f);
    uint lumaIndex = uint(clamp(y, 0.0f, 1.0f) * 255.0f + 0.5f);
    atomic_fetch_add_explicit(&bins[index.r], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[256u + index.g], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[512u + index.b], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[768u + lumaIndex], 1u, memory_order_relaxed);
}
