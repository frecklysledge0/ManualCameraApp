#include <metal_stdlib>
using namespace metal;

// Every struct here is mirrored in FramePipeline.swift. Keep field order and types identical.

struct OverlayParams {
    uint quarterTurns;     // clockwise quarter turns applied to the buffer to display it
    uint mirrored;         // 1 when the preview is mirrored (front camera)
    float threshold;       // Sobel magnitude where peaking starts
    float stepScale;       // buffer texels per overlay pixel (>= 1)
    float4 color;          // peaking colour, straight alpha
    float2 lumaTexel;      // 1 / luma texture size
    uint peakingEnabled;
    uint zebrasEnabled;
    float zebraThreshold;  // luma (0…1) at and above which zebras are drawn
    float time;            // seconds, animates the zebra stripes
    float flash;           // 0…1 brief peaking boost after a focus snap
    float padding;
};

struct HistogramParams {
    uint width;
    uint height;
};

struct SharpnessParams {
    float2 origin;         // ROI origin in buffer uv
    float2 size;           // ROI size in buffer uv
    uint gridWidth;
    uint gridHeight;
    float2 lumaTexel;
};

struct LoupeParams {
    float2 center;         // display uv of the loupe centre
    float2 windowSize;     // display uv size shown in the loupe
    uint quarterTurns;
    uint mirrored;
    uint nearest;          // 1 = nearest-neighbour (real pixels at 8×)
    float threshold;
    float4 peakColor;
    float2 lumaTexel;
    uint peaking;
    float padding;
};

// Same mapping as RotationMath.bufferPoint(forDisplayPoint:quarterTurns:mirrored:).
inline float2 bufferUV(float2 uv, uint turns, uint mirrored) {
    float u = mirrored != 0 ? 1.0f - uv.x : uv.x;
    float v = uv.y;
    switch (turns & 3u) {
        case 1u: return float2(v, 1.0f - u);
        case 2u: return float2(1.0f - u, 1.0f - v);
        case 3u: return float2(1.0f - v, u);
        default: return float2(u, v);
    }
}

inline float sobelMagnitude(texture2d<float, access::sample> luma, sampler s, float2 b, float2 d) {
    float tl = luma.sample(s, b + float2(-d.x, -d.y)).r;
    float tc = luma.sample(s, b + float2( 0.0f, -d.y)).r;
    float tr = luma.sample(s, b + float2( d.x, -d.y)).r;
    float ml = luma.sample(s, b + float2(-d.x,  0.0f)).r;
    float mr = luma.sample(s, b + float2( d.x,  0.0f)).r;
    float bl = luma.sample(s, b + float2(-d.x,  d.y)).r;
    float bc = luma.sample(s, b + float2( 0.0f,  d.y)).r;
    float br = luma.sample(s, b + float2( d.x,  d.y)).r;
    float gx = (tr + 2.0f * mr + br) - (tl + 2.0f * ml + bl);
    float gy = (bl + 2.0f * bc + br) - (tl + 2.0f * tc + tr);
    return sqrt(gx * gx + gy * gy);
}

// BT.709 full-range YCbCr -> RGB.
inline float3 ycbcrToRGB(float y, float2 cbcr) {
    float2 c = cbcr - 0.5f;
    float3 rgb = float3(y + 1.5748f * c.y,
                        y - 0.1873f * c.x - 0.4681f * c.y,
                        y + 1.8556f * c.x);
    return clamp(rgb, float3(0.0f), float3(1.0f));
}

// Focus peaking and zebras in one pass, written straight into the overlay's drawable (Slice 2 §9).
kernel void overlayKernel(texture2d<float, access::sample> luma [[texture(0)]],
                          texture2d<float, access::write> output [[texture(1)]],
                          constant OverlayParams& p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint width = output.get_width();
    uint height = output.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5f) / float2(width, height);
    float2 b = bufferUV(uv, p.quarterTurns, p.mirrored);

    float4 result = float4(0.0f);

    if (p.zebrasEnabled != 0) {
        float y = luma.sample(s, b).r;
        if (y >= p.zebraThreshold) {
            float phase = fract((float(gid.x) + float(gid.y)) / 14.0f - p.time * 1.5f);
            if (phase < 0.5f) {
                float a = 0.55f;
                result = float4(a, a, a, a);
            }
        }
    }

    if (p.peakingEnabled != 0) {
        float2 d = p.lumaTexel * max(p.stepScale, 1.0f);
        float magnitude = sobelMagnitude(luma, s, b, d);
        float alpha = smoothstep(p.threshold, p.threshold * 1.5f, magnitude) * p.color.a;
        alpha = min(1.0f, alpha * (1.0f + p.flash));
        float3 rgb = mix(p.color.rgb, float3(1.0f), p.flash * 0.5f);
        // Peaking over zebras (premultiplied "over").
        result = float4(rgb * alpha, alpha) + result * (1.0f - alpha);
    }

    output.write(result, gid);
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
    float2 uv = (float2(gid) + 0.5f) / float2(p.width, p.height);
    float y = luma.sample(s, uv).r;
    float3 rgb = ycbcrToRGB(y, chroma.sample(s, uv).rg);
    uint3 index = uint3(rgb * 255.0f + 0.5f);
    uint lumaIndex = uint(clamp(y, 0.0f, 1.0f) * 255.0f + 0.5f);
    atomic_fetch_add_explicit(&bins[index.r], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[256u + index.g], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[512u + index.b], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[768u + lumaIndex], 1u, memory_order_relaxed);
}

// Edge energy inside the focus ROI at native resolution (focus snap, Slice 2 §8).
kernel void sharpnessKernel(texture2d<float, access::sample> luma [[texture(0)]],
                            device atomic_uint* energy [[buffer(0)]],
                            constant SharpnessParams& p [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.gridWidth || gid.y >= p.gridHeight) {
        return;
    }
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 uv = p.origin + (float2(gid) + 0.5f) / float2(p.gridWidth, p.gridHeight) * p.size;
    float magnitude = sobelMagnitude(luma, s, uv, p.lumaTexel);
    uint scaled = uint(magnitude * magnitude * 4096.0f);
    atomic_fetch_add_explicit(&energy[0], scaled, memory_order_relaxed);
}

// Magnified view of the native-resolution frame around the focus point (loupe, Slice 2 §8).
kernel void loupeKernel(texture2d<float, access::sample> luma [[texture(0)]],
                        texture2d<float, access::sample> chroma [[texture(1)]],
                        texture2d<float, access::write> output [[texture(2)]],
                        constant LoupeParams& p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint width = output.get_width();
    uint height = output.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 local = (float2(gid) + 0.5f) / float2(width, height);
    float2 display = p.center + (local - 0.5f) * p.windowSize;
    float2 b = bufferUV(display, p.quarterTurns, p.mirrored);

    float y;
    float2 cbcr;
    if (p.nearest != 0) {
        y = luma.sample(nearestSampler, b).r;
        cbcr = chroma.sample(nearestSampler, b).rg;
    } else {
        y = luma.sample(linearSampler, b).r;
        cbcr = chroma.sample(linearSampler, b).rg;
    }
    float3 rgb = ycbcrToRGB(y, cbcr);

    if (p.peaking != 0) {
        float magnitude = sobelMagnitude(luma, linearSampler, b, p.lumaTexel);
        float alpha = smoothstep(p.threshold, p.threshold * 1.5f, magnitude) * p.peakColor.a;
        rgb = mix(rgb, p.peakColor.rgb, alpha);
    }
    output.write(float4(rgb, 1.0f), gid);
}
