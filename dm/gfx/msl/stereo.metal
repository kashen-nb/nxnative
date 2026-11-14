// The picture for one eye of a headset, on a screen in front of the player (dm/host/immersive_mac.m), from the present's picture and the depth of its scene (nvn_mtl.m, the stereo tap).
// A depth buffer's value is affine in 1 / distance, so the distance of a pixel from its far plane (w) is proportional to 1 / distance whatever the game's near and far planes are:
// the picture's horizontal parallax, far * (1 - w / conv), needs no constant of the game. Each eye's picture is the source shifted by half its parallax; fs searches the source pixel
// along the row from the nearest parallax to the farthest, so a near surface covers a far one, and what one eye sees behind an edge is filled from the far side.
// A HUD lies over the scene's depth, so it would bend with the scene: with the picture before the game's overlays (base), a pixel where the two differ is the HUD's and is
// drawn whole at the nearest parallax, in front of everything; the scene's pixels come from the base, so no HUD colour is moved with the scene
#include <metal_stdlib>
using namespace metal;
struct U {
    float4x4 mvp;   // the screen's corners (-1..1, -1..1, 0) to clip space
    float4 drect;   // the scene in the depth texture: origin, size (the size's y negative for a bottom-up one)
    float4 par;     // eye (-0.5 left, 0.5 right), far parallax and near limit (fractions of the picture's width), conv (w at the screen's plane; 0: no depth, flat)
    uint4 opt;      // the render target layer, the depth's far plane is 0, the base marks the overlays (HUD)
};
struct V { float4 p [[position]]; float2 uv; uint layer [[render_target_array_index]]; };
vertex V vs(uint id [[vertex_id]], constant U &u [[buffer(0)]]) {
    float2 uv = float2(id & 1, id >> 1);
    V o; o.p = u.mvp * float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1); o.uv = uv; o.layer = u.opt.x; return o;
}
static float near_w(depth2d<float> d, sampler s, float2 uv, constant U &u) {
    float a = d.sample(s, saturate(uv) * u.drect.zw + u.drect.xy);
    return u.opt.y ? a : 1 - a;
}
static bool overlay(texture2d<float> c, texture2d<float> b, sampler s, float2 uv) { return any(abs(c.sample(s, uv) - b.sample(s, uv)) > 1e-4); }
static float parallax(depth2d<float> d, sampler s, float2 uv, constant U &u) { return clamp(u.par.y * (1 - near_w(d, s, uv, u) / u.par.w), -u.par.z, u.par.y); }
fragment float4 fs(V in [[stage_in]], texture2d<float> c [[texture(0)]], depth2d<float> d [[texture(1)]], texture2d<float> b [[texture(2)]], sampler ls [[sampler(0)]], sampler ns [[sampler(1)]],
                   constant U &u [[buffer(0)]]) {
    float2 uv = in.uv;
    if (u.par.w > 0) {
        const int N = 24;
        float lo = -u.par.z, hi = u.par.y, e = u.par.x, ph = lo, pv = parallax(d, ns, uv - float2(e * lo, 0), u), hit = lo;
        if (pv > lo) {
            hit = hi;
            for (int i = 1; i <= N; i++) {
                float h = mix(lo, hi, float(i) / N), v = parallax(d, ns, uv - float2(e * h, 0), u);
                if (v <= h) { float a0 = pv - ph, a1 = v - h; hit = mix(ph, h, saturate(a0 / max(a0 - a1, 1e-6))); break; }
                ph = h; pv = v;
            }
        }
        if (u.opt.z) { float2 h = saturate(uv - float2(e * lo, 0)); if (overlay(c, b, ns, h)) return c.sample(ls, h); }   // the HUD, in front
        uv.x -= e * hit;
        if (u.opt.z) return b.sample(ls, saturate(uv));
    }
    return c.sample(ls, saturate(uv));
}
// The nearest w of each cell of a small grid (4 x 4 taps a cell), and the share of its taps that are overlays, read back to place the screen's plane in the scene and to tell a HUD
// from an effect over the whole picture (immersive_mac.m conv_update)
fragment float2 fs_near(V in [[stage_in]], texture2d<float> c [[texture(0)]], depth2d<float> d [[texture(1)]], texture2d<float> b [[texture(2)]], sampler ns [[sampler(1)]],
                        constant U &u [[buffer(0)]]) {
    float2 cell = float2(dfdx(in.uv.x), dfdy(in.uv.y)); float m = 0, o = 0;
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) { float2 t = in.uv + (float2(x, y) - 1.5) * 0.25 * cell; m = max(m, near_w(d, ns, t, u)); o += overlay(c, b, ns, saturate(t)) ? 1.0 / 16 : 0; }
    return float2(m, o);
}
