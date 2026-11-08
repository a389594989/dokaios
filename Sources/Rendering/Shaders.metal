#include <metal_stdlib>
using namespace metal;

// 与 Swift 端 FilmParams 布局一致 (5 个 float)。
struct FilmParams {
    float intensity;
    float grain;
    float vignette;
    float time;
    float lutEnabled;
};

struct VOut {
    float4 position [[position]];
    float2 uv;      // 采样相机帧 (已做 aspect-fill 裁切)
    float2 screen;  // 0..1 屏幕坐标, 用于颗粒/暗角
};

// 全屏三角形。scale = aspect-fill 时可见区域占整帧的比例。
vertex VOut previewVertex(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    float2 uv = float2(p.x, 1.0 - p.y);
    o.screen = uv;
    o.uv = (uv - 0.5) * scale + 0.5;
    return o;
}

fragment float4 previewFragment(VOut in [[stage_in]],
                                texture2d<float> frame [[texture(0)]],
                                texture3d<float> lut [[texture(1)]],
                                constant FilmParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = frame.sample(s, in.uv).rgb;

    if (p.lutEnabled > 0.5) {
        // 64^3 LUT: 把 [0,1] 映射到纹素中心, 避免边缘偏移
        float3 coord = c * (63.0 / 64.0) + (0.5 / 64.0);
        float3 graded = lut.sample(s, coord).rgb;
        c = mix(c, graded, p.intensity);
    }

    // 胶片颗粒
    float n = fract(sin(dot(in.screen * 1000.0 + p.time, float2(12.9898, 78.233))) * 43758.5453);
    c += (n - 0.5) * p.grain;

    // 暗角
    float d = distance(in.screen, float2(0.5));
    c *= 1.0 - p.vignette * smoothstep(0.35, 0.85, d);

    return float4(saturate(c), 1.0);
}
