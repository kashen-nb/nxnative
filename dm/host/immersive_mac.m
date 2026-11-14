// The game on a Vision Pro (immersive_mac.h). The Metal backend's stereo tap (dm/gfx/nvn/mtl_stereo.h) gives each present's picture and the depth of its scene; this file draws the
// picture on a screen in the player's room once for each eye (dm/gfx/msl/stereo.metal), at the headset's rate, on a queue of its own, whatever rate the game presents at.
// - The screen: DM_IMMERSIVE_SCREEN=<width m>,<distance m> (3.2 m wide, 2.5 m away), placed in front of the player at the first pose of each connection. Hold the Digital Crown to recenter.
// - The depth: DM_IMMERSIVE_3D=<strength> (1; 0 = a flat picture). The farthest point lies 1.2 % of the picture's width behind the screen for each unit, the nearest at most half that
//   in front of it. The screen's plane follows the nearest things in the scene (conv_update), so the scene opens behind the screen like a window.
// - DM_IMMERSIVE_SHOT=<present>:<path.png>: without a headset, both eyes' pictures of that present side by side (left | right) as a PNG, through the same pass (a check of the tap and the shader)
// - A HUD: drawn over the scene without its depth, it is told from the scene by the picture before the game's overlays (the tap's base) and drawn in front of the scene. When
//   overlays cover more than HUD_MAX of the picture, it is an effect over the whole picture (a fade, a vignette) or a menu: nothing is drawn apart.
// Open: a HUD the game draws into the scene's own target before the composite stays with the scene; a Vulkan or GL game has no depth and stays flat; the game is paced by the Mac's display, whose
// window must stay visible
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <simd/simd.h>
#include <pthread.h>
#include <stdatomic.h>
#include "immersive_mac.h"
#include "dm.h"
#include "../gfx/nvn/mtl_stereo.h"
#include "../gfx/nvn/host_msl.h"

#define ILOG(...) dm_log("[dm] [immersive] " __VA_ARGS__)
void *mtl_device(void); uint64_t mtl_present_count(void);

typedef struct { simd_float4x4 mvp; simd_float4 drect, par; simd_uint4 opt; } st_u;   // stereo.metal U
#define NEAR_W 32
#define HUD_MAX 0.6f
#define NEAR_H 18
static id<MTLDevice> g_dev; static id<MTLCommandQueue> g_q; static id<MTLLibrary> g_lib;
static id<MTLSamplerState> g_ls, g_ns; static id<MTLDepthStencilState> g_dss; static id<MTLTexture> g_nodepth, g_near_tex; static id<MTLRenderPipelineState> g_near_pso;
static float g_screen_w = 3.2f, g_screen_d = 2.5f, g_strength = 1;
static _Atomic int g_recenter = 1;
static pthread_mutex_t g_conv_mu = PTHREAD_MUTEX_INITIALIZER; static float g_conv, g_hud = 1; static double g_conv_t; static uint64_t g_conv_seq;   // the screen's plane (w), smoothed; the share of the picture overlays cover; the frame they were last measured on

static int st_setup(void) {
    if (g_q) return 1;
    g_dev = (__bridge id<MTLDevice>)mtl_device(); NSError *e = nil;
    g_lib = host_msl_lib(g_dev, nil, "stereo", &e);
    if (!g_lib) { ILOG("[RED] no stereo shader library: %s", e.localizedDescription.UTF8String ?: "?"); return 0; }
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; g_ls = [g_dev newSamplerStateWithDescriptor:sd];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest; g_ns = [g_dev newSamplerStateWithDescriptor:sd];
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES; g_dss = [g_dev newDepthStencilStateWithDescriptor:dd];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate; g_nodepth = [g_dev newTextureWithDescriptor:td];
    td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float width:NEAR_W height:NEAR_H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate; g_near_tex = [g_dev newTextureWithDescriptor:td];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [g_lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [g_lib newFunctionWithName:@"fs_near"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG32Float; pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    g_near_pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!g_near_pso) { ILOG("[RED] no pipeline for the depth grid: %s", e.localizedDescription.UTF8String); return 0; }
    g_q = [g_dev newCommandQueue];
    const char *s = getenv("DM_IMMERSIVE_SCREEN"); float w, d;
    if (s && sscanf(s, "%f,%f", &w, &d) == 2 && w >= 0.3f && w <= 30 && d >= 0.3f && d <= 30) { g_screen_w = w; g_screen_d = d; } else if (s) ILOG("[RED] DM_IMMERSIVE_SCREEN=%s is not <width m>,<distance m> (0.3 to 30)", s);
    s = getenv("DM_IMMERSIVE_3D"); if (s) g_strength = fminf(fmaxf((float)atof(s), 0), 3);
    ILOG("screen %.2f m wide, %.2f m away; depth strength %.2f (DM_IMMERSIVE_SCREEN, DM_IMMERSIVE_3D)", g_screen_w, g_screen_d, g_strength);
    return 1;
}
static id<MTLRenderPipelineState> st_pipeline(MTLPixelFormat cf, MTLPixelFormat df) {
    static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *made; if (!made) made = [NSMutableDictionary dictionary];
    NSNumber *key = @((uint64_t)cf << 32 | (uint64_t)df); id<MTLRenderPipelineState> p = made[key]; if (p) return p;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; NSError *e = nil;
    pd.vertexFunction = [g_lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [g_lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = cf; pd.depthAttachmentPixelFormat = df; pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    p = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!p) { ILOG("[RED] no pipeline for a headset layer of colour format %lu, depth format %lu: %s", (unsigned long)cf, (unsigned long)df, e.localizedDescription.UTF8String); return nil; }
    return made[key] = p;
}
// The constants of one eye's draw. eye: -1 left, 1 right, 0 none (a flat picture)
static st_u st_uniforms(const mtl_stereo_frame *f, simd_float4x4 mvp, int eye, unsigned layer, float conv, int hud) {
    st_u u = {mvp};
    if (f->depth) { const float *r = f->depth_rect; u.drect = f->depth_flip ? simd_make_float4(r[0], r[1] + r[3], r[2], -r[3]) : simd_make_float4(r[0], r[1], r[2], r[3]); }
    // the far parallax stays under the distance between the eyes on the screen, so the eyes never have to turn outwards
    float far = fminf(0.012f * g_strength, 0.055f / g_screen_w);
    u.par = simd_make_float4(0.5f * eye, far, far * 0.5f, f->depth && eye && far > 0 ? conv : 0);
    u.opt = simd_make_uint4(layer, f->depth_rev != 0, f->base && hud, 0);
    return u;
}
static void st_draw(id<MTLRenderCommandEncoder> en, const mtl_stereo_frame *f, const st_u *u) {
    [en setVertexBytes:u length:sizeof *u atIndex:0]; [en setFragmentBytes:u length:sizeof *u atIndex:0];
    [en setFragmentTexture:(__bridge id<MTLTexture>)f->color atIndex:0]; [en setFragmentTexture:f->depth ? (__bridge id<MTLTexture>)f->depth : g_nodepth atIndex:1];
    [en setFragmentTexture:(__bridge id<MTLTexture>)(f->base ?: f->color) atIndex:2];
    [en setFragmentSamplerState:g_ls atIndex:0]; [en setFragmentSamplerState:g_ns atIndex:1];
    [en drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}
// Where the screen's plane lies in a frame's scene: the 90th percentile of the grid's nearest w, so what is nearest the camera (the ground at the player's feet) lies at the screen or
// a little in front of it and everything else behind. 0 when under a twentieth of the grid holds anything (a menu over a cleared depth): flat
static float conv_of(const float *g) {   // g: the grid's (nearest w, overlay share) pairs
    float v[NEAR_W * NEAR_H]; int n = 0;
    for (int i = 0; i < NEAR_W * NEAR_H; i++) if (g[2 * i] > 1e-7f && g[2 * i] <= 1) { float x = g[2 * i]; int j = n++; while (j > 0 && v[j - 1] > x) { v[j] = v[j - 1]; j--; } v[j] = x; }
    return n < NEAR_W * NEAR_H / 20 ? 0 : v[(n - 1) * 9 / 10];
}
// A new frame's depth grid, encoded into cb; its completion moves the plane towards the frame's (half the way in 0.25 s: a cut does not jump, a walk does not swim). wait: the plane
// is set to the frame's at once and the call returns when it is (DM_IMMERSIVE_SHOT)
static void conv_update(id<MTLCommandBuffer> cb, const mtl_stereo_frame *f, int wait) {
    pthread_mutex_lock(&g_conv_mu); int seen = g_conv_seq == f->seq; g_conv_seq = f->seq; pthread_mutex_unlock(&g_conv_mu);
    if (seen || !f->depth) { if (!f->depth && !seen) { pthread_mutex_lock(&g_conv_mu); g_conv = 0; g_hud = 1; pthread_mutex_unlock(&g_conv_mu); } return; }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
    rp.colorAttachments[0].texture = g_near_tex; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.renderTargetArrayLength = 1;   // the vertex shader names a layer
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    st_u u = st_uniforms(f, matrix_identity_float4x4, 0, 0, 0, 1);
    [en setRenderPipelineState:g_near_pso]; [en setVertexBytes:&u length:sizeof u atIndex:0]; [en setFragmentBytes:&u length:sizeof u atIndex:0];
    [en setFragmentTexture:(__bridge id<MTLTexture>)f->color atIndex:0]; [en setFragmentTexture:(__bridge id<MTLTexture>)f->depth atIndex:1];
    [en setFragmentTexture:(__bridge id<MTLTexture>)(f->base ?: f->color) atIndex:2]; [en setFragmentSamplerState:g_ns atIndex:1];
    [en drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [en endEncoding];
    id<MTLBuffer> out = [g_dev newBufferWithLength:NEAR_W * NEAR_H * 8 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:g_near_tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(NEAR_W, NEAR_H, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:NEAR_W * 8 destinationBytesPerImage:NEAR_W * NEAR_H * 8];
    [b endEncoding];
    void (^done)(void) = ^{
        const float *g = out.contents; float c = conv_of(g), hud = 0; double now = CACurrentMediaTime();
        for (int i = 0; i < NEAR_W * NEAR_H; i++) hud += g[2 * i + 1] / (NEAR_W * NEAR_H);
        pthread_mutex_lock(&g_conv_mu);
        g_hud = hud;
        if (wait || g_conv <= 0 || c <= 0) g_conv = c; else g_conv += (c - g_conv) * (float)(1 - exp2(-(now - g_conv_t) / 0.25));
        g_conv_t = now;
        pthread_mutex_unlock(&g_conv_mu);
    };
    if (!wait) { [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { if (!c.error) done(); }]; return; }
    id<MTLCommandBuffer> own = cb; [own commit]; [own waitUntilCompleted]; done();
}
static float conv_now(void) { pthread_mutex_lock(&g_conv_mu); float c = g_conv; pthread_mutex_unlock(&g_conv_mu); return c; }
static float hud_now(void) { pthread_mutex_lock(&g_conv_mu); float h = g_hud; pthread_mutex_unlock(&g_conv_mu); return h; }   // the share of the picture overlays cover

// ---------- DM_IMMERSIVE_SHOT ----------
// Both eyes' pictures of a frame through the headset's pass (a target of two layers, no lens map, the screen filling it): BGRA bytes, the left eye's rows then the right's.
// measure: place the screen's plane from this frame first. Also what dm/gfx/tests/t_stereo.m checks
id<MTLBuffer> dm_immersive_eyes(const mtl_stereo_frame *f, int measure, NSUInteger *pw, NSUInteger *ph) {
    if (!st_setup()) return nil;
    id<MTLTexture> c = (__bridge id<MTLTexture>)f->color; NSUInteger w = *pw = c.width, h = *ph = c.height;
    if (measure) conv_update([g_q commandBuffer], f, 1);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:w height:h mipmapped:NO];
    td.textureType = MTLTextureType2DArray; td.arrayLength = 2; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float; id<MTLTexture> zt = [g_dev newTextureWithDescriptor:td];
    id<MTLRenderPipelineState> pso = st_pipeline(MTLPixelFormatBGRA8Unorm_sRGB, MTLPixelFormatDepth32Float);
    id<MTLBuffer> px = [g_dev newBufferWithLength:w * h * 8 options:MTLResourceStorageModeShared];
    if (!out || !zt || !pso || !px) { ILOG("[RED] both eyes' pictures: no texture, pipeline or buffer"); return nil; }
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
    rp.colorAttachments[0].texture = out; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.depthAttachment.texture = zt; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionDontCare; rp.renderTargetArrayLength = 2;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso]; [en setDepthStencilState:g_dss];
    float conv = conv_now(); int hud = hud_now() <= HUD_MAX;
    for (int i = 0; i < 2; i++) { st_u u = st_uniforms(f, matrix_identity_float4x4, i ? 1 : -1, (unsigned)i, conv, hud); st_draw(en, f, &u); }
    [en endEncoding];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    for (int i = 0; i < 2; i++) [b copyFromTexture:out sourceSlice:(NSUInteger)i sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:px destinationOffset:(NSUInteger)i * w * h * 4 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) { ILOG("[RED] both eyes' pictures: %s", cb.error.localizedDescription.UTF8String); return nil; }
    return px;
}
static void shot_thread(const char *path, uint64_t at) { @autoreleasepool {
    while (mtl_present_count() < at) usleep(20000);
    mtl_stereo_frame f; int tries = 0; while (!mtl_stereo_acquire(&f)) { if (++tries > 500) { ILOG("[RED] DM_IMMERSIVE_SHOT: no frame from the stereo tap within 10 s"); return; } usleep(20000); }
    NSUInteger w, h; id<MTLBuffer> px = dm_immersive_eyes(&f, 1, &w, &h);
    if (!px) { mtl_stereo_release(&f); return; }
    // side by side: left | right
    NSMutableData *img = [NSMutableData dataWithLength:w * 2 * h * 4]; const uint8_t *p = px.contents; uint8_t *q = img.mutableBytes;
    for (NSUInteger y = 0; y < h; y++) for (int i = 0; i < 2; i++) memcpy(q + (y * 2 * w + (NSUInteger)i * w) * 4, p + ((NSUInteger)i * h + y) * w * 4, w * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)img);
    CGImageRef im = CGImageCreate(w * 2, h, 8, 32, w * 2 * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, dp, NULL, false, kCGRenderingIntentDefault);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)], (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    int ok = 0; if (dst && im) { CGImageDestinationAddImage(dst, im, NULL); ok = CGImageDestinationFinalize(dst); }
    if (dst) CFRelease(dst); if (im) CGImageRelease(im); CGDataProviderRelease(dp); CGColorSpaceRelease(cs);
    id<MTLTexture> z = (__bridge id<MTLTexture>)f.depth; float conv = conv_now(), hud = hud_now();
    ILOG("%sDM_IMMERSIVE_SHOT: present %llu, picture %lux%lu, %s, screen plane w %.6g%s, %s: %s", ok ? "" : "[RED] ", (unsigned long long)at, (unsigned long)w, (unsigned long)h,
         z ? [NSString stringWithFormat:@"depth %lux%lu format %lu (scene at %.3f,%.3f %.3fx%.3f, far plane %d%s)", (unsigned long)z.width, (unsigned long)z.height,
              (unsigned long)z.pixelFormat, f.depth_rect[0], f.depth_rect[1], f.depth_rect[2], f.depth_rect[3], !f.depth_rev, f.depth_flip ? ", bottom-up" : ""].UTF8String : "no depth",
         conv, conv > 0 ? "" : " (flat)",
         !f.base ? "no overlays" : [NSString stringWithFormat:@"overlays over %.1f %% of the picture%s", hud * 100, hud <= HUD_MAX ? ", in front" : ", over the whole picture: not drawn apart"].UTF8String, ok ? path : "could not write the file");
    mtl_stereo_release(&f);
} }

// ---------- The headset ----------
static simd_float4x4 screen_model(simd_float4x4 head, float aspect) {   // in front of the head, upright, facing it: the head's position and heading only
    simd_float3 pos = head.columns[3].xyz, fwd = -head.columns[2].xyz; fwd.y = 0;
    fwd = simd_length(fwd) > 1e-3f ? simd_normalize(fwd) : simd_make_float3(0, 0, -1);
    simd_float3 up = {0, 1, 0}, right = simd_cross(fwd, up), c = pos + fwd * g_screen_d;
    float hw = g_screen_w / 2, hh = hw / aspect;
    return (simd_float4x4){{simd_make_float4(right * hw, 0), simd_make_float4(up * hh, 0), simd_make_float4(-fwd, 0), simd_make_float4(c, 1)}};
}
static void render_drawable(cp_drawable_t dr, ar_world_tracking_provider_t wt, const mtl_stereo_frame *f, int have) {
    static simd_float4x4 model, at; static int placed; static float aspect;   // at: the head's pose the screen was placed for
    cp_frame_timing_t tm = cp_drawable_get_frame_timing(dr);
    ar_device_anchor_t anchor = ar_device_anchor_create();
    int tracked = ar_world_tracking_provider_query_device_anchor_at_timestamp(wt, cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(tm)), anchor) == ar_device_anchor_query_status_success;
    simd_float4x4 head = tracked ? ar_anchor_get_origin_from_anchor_transform(anchor) : matrix_identity_float4x4;
    if (tracked) cp_drawable_set_device_anchor(dr, anchor);
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    if (have) {
        id<MTLTexture> c = (__bridge id<MTLTexture>)f->color; float a = (float)c.width / c.height;
        if (tracked && (atomic_exchange(&g_recenter, 0) || !placed)) { at = head; placed = 1; aspect = 0; }
        if (placed && fabsf(a - aspect) > 1e-3f) { model = screen_model(at, a); aspect = a; }   // a picture of another shape keeps the screen's place and width
        conv_update(cb, f, 0);
    }
    size_t nv = cp_drawable_get_view_count(dr), nt = cp_drawable_get_texture_count(dr), nr = cp_drawable_get_rasterization_rate_map_count(dr);
    float conv = conv_now(); int hud = hud_now() <= HUD_MAX;
    for (size_t t = 0; t < nt; t++) {   // one pass a texture: a layered layout has one of two layers, a dedicated one two, a shared one one that both eyes' viewports lie in
        id<MTLTexture> ct = cp_drawable_get_color_texture(dr, t), zt = cp_drawable_get_depth_texture(dr, t);
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
        rp.colorAttachments[0].texture = ct; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rp.depthAttachment.texture = zt; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore; rp.depthAttachment.clearDepth = 0;   // reverse Z: 0 is the far plane
        rp.renderTargetArrayLength = ct.textureType == MTLTextureType2DArray ? ct.arrayLength : 1;   // the vertex shader names a layer: Metal refuses its draws at 0
        if (t < nr) rp.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(dr, t);
        id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
        id<MTLRenderPipelineState> pso = have && placed ? st_pipeline(ct.pixelFormat, zt.pixelFormat) : nil;
        if (pso) {
            [en setRenderPipelineState:pso]; [en setDepthStencilState:g_dss]; [en setCullMode:MTLCullModeNone];
            for (size_t i = 0; i < nv; i++) {
                cp_view_t v = cp_drawable_get_view(dr, i); cp_view_texture_map_t map = cp_view_get_view_texture_map(v);
                if (cp_view_texture_map_get_texture_index(map) != t) continue;
                simd_float4x4 eye = simd_mul(head, cp_view_get_transform(v));
                simd_float4x4 mvp = simd_mul(cp_drawable_compute_projection(dr, cp_axis_direction_convention_right_up_back, i), simd_mul(simd_inverse(eye), model));
                // which eye a view is: its place to the left or right of the head (one view: a flat picture)
                int side = nv < 2 ? 0 : cp_view_get_transform(v).columns[3].x < 0 ? -1 : 1;
                st_u u = st_uniforms(f, mvp, side, (unsigned)cp_view_texture_map_get_slice_index(map), conv, hud);
                [en setViewport:cp_view_texture_map_get_viewport(map)];
                st_draw(en, f, &u);
            }
        }
        [en endEncoding];
    }
    cp_drawable_encode_present(dr, cb);
    [cb commit];
}
static void *render_thread(void *arg) { @autoreleasepool {
    pthread_setname_np("dm-immersive");
    void **a = arg; cp_layer_renderer_t lr = (__bridge_transfer cp_layer_renderer_t)a[0]; ar_device_t dev = (__bridge_transfer ar_device_t)a[1]; free(a);
    if (cp_layer_renderer_get_device(lr) != g_dev) ILOG("[RED] the headset's layer is on another Metal device (%s) than the game's (%s)", cp_layer_renderer_get_device(lr).name.UTF8String, g_dev.name.UTF8String);
    ar_session_t session = ar_session_create_with_device(dev);
    ar_world_tracking_configuration_t wc = ar_world_tracking_configuration_create(); ar_world_tracking_provider_t wt = ar_world_tracking_provider_create(wc);
    ar_data_providers_t ps = ar_data_providers_create(); ar_data_providers_add_data_provider(ps, wt);
    ar_session_run(session, ps);
    atomic_store(&g_recenter, 1);
    ILOG("headset connected: drawing the game for it");
    mtl_stereo_frame held = {0}; int have = 0; uint64_t frames = 0;
    for (;;) @autoreleasepool {
        cp_layer_renderer_state st = cp_layer_renderer_get_state(lr);
        if (st == cp_layer_renderer_state_invalidated) break;
        if (st == cp_layer_renderer_state_paused) { cp_layer_renderer_wait_until_running(lr); continue; }
        cp_frame_t fr = cp_layer_renderer_query_next_frame(lr); if (!fr) continue;
        cp_frame_timing_t tm = cp_frame_predict_timing(fr); if (!tm) continue;
        cp_frame_start_update(fr);
        cp_frame_end_update(fr);
        cp_time_wait_until(cp_frame_timing_get_optimal_input_time(tm));
        cp_frame_start_submission(fr);
        cp_drawable_array_t ds = cp_frame_query_drawables(fr); size_t nd = cp_drawable_array_get_count(ds);
        if (nd) {   // the newest picture, held until the queue has run the frames drawn from it
            mtl_stereo_frame nf;
            if (mtl_stereo_acquire(&nf)) {
                if (have) { mtl_stereo_frame old = held; id<MTLCommandBuffer> cb = [g_q commandBuffer]; [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; mtl_stereo_release(&old); }]; [cb commit]; }
                held = nf; have = 1;
            }
        }
        for (size_t i = 0; i < nd; i++) render_drawable(cp_drawable_array_get_drawable(ds, i), wt, &held, have);
        cp_frame_end_submission(fr);
        if (!frames++) ILOG("first frame for the headset%s", have ? "" : " (no picture from the game yet)");
    }
    if (have) { id<MTLCommandBuffer> cb = [g_q commandBuffer]; [cb commit]; [cb waitUntilCompleted]; mtl_stereo_release(&held); }
    ar_session_stop(session);
    ILOG("headset disconnected after %llu frames", (unsigned long long)frames);
    return NULL;
} }
void dm_immersive_render(cp_layer_renderer_t layer, ar_device_t device) {
    if (!st_setup()) return;
    void **a = malloc(2 * sizeof *a); a[0] = (__bridge_retained void *)layer; a[1] = (__bridge_retained void *)device;
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 1u << 20); pthread_attr_set_qos_class_np(&at, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_t th; if (pthread_create(&th, &at, render_thread, a)) { ILOG("[RED] no render thread for the headset"); CFRelease(a[0]); CFRelease(a[1]); free(a); return; }
    pthread_detach(th);
}
void dm_immersive_note(const char *what) { ILOG("%s", what); }
int dm_immersive_wanted(void) { const char *e = getenv("DM_IMMERSIVE"); return e && atoi(e); }
void dm_immersive_start(void) {
    const char *shot = getenv("DM_IMMERSIVE_SHOT"), *colon = shot ? strchr(shot, ':') : NULL;
    if (shot && !(colon && atoll(shot) > 0 && colon[1])) { ILOG("[RED] DM_IMMERSIVE_SHOT=%s is not <present>:<path.png>", shot); colon = NULL; }
    if (!dm_immersive_wanted() && !colon) return;
    if (!st_setup()) return;
    mtl_stereo_enable(1);
    if (colon) { uint64_t at = (uint64_t)atoll(shot); const char *path = strdup(colon + 1); dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ shot_thread(path, at); }); }
    if (dm_immersive_wanted()) dispatch_async(dispatch_get_main_queue(), ^{ dm_immersive_scene_open(); });
}
