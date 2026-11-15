// The stereo tap (nvn_mtl.m, mtl_stereo.h) and the headset's pass (dm/host/immersive_mac.m, msl/stereo.metal), without a headset: a frame whose scene has a far third, a middle
// and a small near patch is tapped as a game's would be, and each eye's picture must show the far marker behind the screen, the middle one on it and the near one in front.
// Then a HUD is drawn over a window texture through the replay (st_overlay): it must stand in front of the scene, whole, and leave no copy of itself where the scene moves
#include "../nvn/nvn_mtl.m"
#include "../../host/immersive_mac.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
void dm_immersive_scene_open(void) {}
static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)
enum { W = 1024, H = 576 };
static id<MTLCommandQueue> g_tq;
static void fill(id<MTLTexture> t, const void *bytes, NSUInteger bpp) {
    id<MTLBuffer> b = [g_dev newBufferWithBytes:bytes length:t.width * t.height * bpp options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_tq commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:t.width * bpp sourceBytesPerImage:t.width * t.height * bpp sourceSize:MTLSizeMake(t.width, t.height, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
static id<MTLTexture> make(MTLPixelFormat pf, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; res_add(t); return t;
}
// A frame as the replay sees it: a pass over colour and depth with n depth-writing draws, then the present
static uint64_t frame_scene(id<MTLTexture> color, id<MTLTexture> depth, int n, int func, id<MTLTexture> decoy, id<MTLTexture> scene) {
    MTL4RenderPassDescriptor *pd = [MTL4RenderPassDescriptor new];
    S.ds.dt = S.ds.dw = 1; S.ds.df = func; S.has_vp = 1; S.vp[0][0] = S.vp[0][1] = 0;
    if (decoy) { pd.colorAttachments[0].texture = color; pd.depthAttachment.texture = decoy; S.vp[0][2] = decoy.width; S.vp[0][3] = decoy.height; st_pass(pd); for (int i = 0; i < n / 2; i++) st_draw(); }
    if (depth) { pd.colorAttachments[0].texture = scene; pd.depthAttachment.texture = depth; S.vp[0][2] = W; S.vp[0][3] = H; st_pass(pd); for (int i = 0; i < n; i++) st_draw(); }
    pd.colorAttachments[0].texture = nil; pd.depthAttachment.texture = decoy ?: depth; st_pass(pd); for (int i = 0; i < 4 * n; i++) st_draw();   // a shadow map's pass: no colour, never the scene
    res_commit();
    uint64_t seq0 = g_st_pub.seq;
    tex_t none = {0}; g_st_tag = st_take_depth(&none); uint64_t tag = g_st_tag;
    st_present(color, NULL);
    for (int i = 0; i < 400 && g_st_pub.seq == seq0; i++) usleep(5000);
    CHECK(g_st_pub.seq != seq0, "a present's picture is published within 2 s");
    return tag;
}
static uint64_t frame(id<MTLTexture> color, id<MTLTexture> depth, int n, int func, id<MTLTexture> decoy) {
    return frame_scene(color, depth, n, func, decoy, color);
}
// The centre column of one channel's brightness in columns x0..x1 of a row of an eye's picture
static double column_in(const uint8_t *px, int eye, int row, int ch, int x0, int x1) {
    const uint8_t *r = px + ((size_t)eye * H + (size_t)row) * W * 4; double sum = 0, n = 0;
    for (int x = x0; x < x1; x++) { double v = r[x * 4 + ch]; sum += v * x; n += v; }
    return n > 0 ? sum / n : -1;
}
static double column(const uint8_t *px, int eye, int row, int ch) { return column_in(px, eye, row, ch, 0, W); }
int main(void) { @autoreleasepool {
    mtl_init(); g_tq = [g_dev newCommandQueue];
    mtl_stereo_enable(1);
    mtl_stereo_frame f;
    CHECK(!mtl_stereo_acquire(&f), "no frame before the first present");
    // Colour (RGBA): a red line in the far third, a blue one in the middle, a green one in the near patch. Depth: 1 (far), 0.8, 0.2
    uint8_t *c = calloc(W * H, 4); float *z = malloc(W * H * sizeof *z), *zr = malloc(W * H * sizeof *zr);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        int band = y / (H / 3), near = band == 2 && x >= 448 && x < 576;
        z[y * W + x] = band == 0 ? 1 : near ? 0.2f : 0.8f; zr[y * W + x] = 1 - z[y * W + x];
        if (band == 0 && x >= 198 && x < 203) c[(y * W + x) * 4] = 255;
        if (band == 1 && x >= 798 && x < 803) c[(y * W + x) * 4 + 2] = 255;
        if (near && x >= 510 && x < 515) c[(y * W + x) * 4 + 1] = 255;
    }
    id<MTLTexture> color = make(MTLPixelFormatRGBA8Unorm, W, H), depth = make(MTLPixelFormatDepth32Float, W, H), rdepth = make(MTLPixelFormatDepth32Float, W, H), decoy = make(MTLPixelFormatDepth32Float, 64, 64);
    fill(color, c, 4); fill(depth, z, 4); fill(rdepth, zr, 4);
    for (int pass = 0; pass < 2; pass++) {   // a far plane of 1, then of 0 (GREATER)
        const char *nm = pass ? "far plane 0" : "far plane 1";
        uint64_t tag = frame(color, pass ? rdepth : depth, 40, pass ? NVN_DEPTH_FUNC_GEQUAL : NVN_DEPTH_FUNC_LEQUAL, decoy);
        CHECK(tag != 0, "%s: the frame's scene depth is copied", nm);
        for (int i = 0; i < 400 && !(mtl_stereo_acquire(&f) && f.depth); i++) { if (f.c >= 0) mtl_stereo_release(&f); usleep(5000); }
        CHECK(f.color && f.depth, "%s: the frame comes with its depth", nm);
        if (!f.depth) return 1;
        id<MTLTexture> fc = (__bridge id<MTLTexture>)f.color, fz = (__bridge id<MTLTexture>)f.depth;
        CHECK(fc.width == W && fc.height == H && fc.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB, "%s: the picture is %lux%lu format %lu", nm, (unsigned long)fc.width, (unsigned long)fc.height, (unsigned long)fc.pixelFormat);
        CHECK(fz.width == W && fz.height == H, "%s: the depth with the most draws in a pass with colour is taken, not the decoy or the shadow map (%lux%lu)", nm, (unsigned long)fz.width, (unsigned long)fz.height);
        CHECK(f.depth_rect[0] == 0 && f.depth_rect[1] == 0 && f.depth_rect[2] == 1 && f.depth_rect[3] == 1, "%s: the scene covers the depth", nm);
        CHECK(f.depth_rev == pass, "%s: the far plane's side comes from the draws' compare (%d)", nm, f.depth_rev);
        NSUInteger w, h; id<MTLBuffer> px = dm_immersive_eyes(&f, 1, &w, &h);
        CHECK(px && w == W && h == H, "%s: both eyes are drawn", nm);
        if (!px) return 1;
        const uint8_t *p = px.contents;   // BGRA
        double far = 0.012 * W, fl = column(p, 0, 90, 2), fr = column(p, 1, 90, 2), ml = column(p, 0, 280, 0), mr = column(p, 1, 280, 0), nl = column(p, 0, 480, 1), nr = column(p, 1, 480, 1);
        CHECK(fabs(fl - (200 - far / 2)) < 1.5 && fabs(fr - (200 + far / 2)) < 1.5, "%s: the far marker lies behind the screen (left %.2f, right %.2f, want %.2f and %.2f)", nm, fl, fr, 200 - far / 2, 200 + far / 2);
        CHECK(fabs(ml - 800) < 1 && fabs(mr - 800) < 1, "%s: the middle is the screen's plane (left %.2f, right %.2f, want 800)", nm, ml, mr);
        CHECK(fabs(nl - (512 + far / 4)) < 1.5 && fabs(nr - (512 - far / 4)) < 1.5, "%s: the near marker lies in front, by the limit (left %.2f, right %.2f, want %.2f and %.2f)", nm, nl, nr, 512 + far / 4, 512 - far / 4);
        // The held frame stays as it is while later frames are tapped
        int hc = f.c, hd = f.d;
        for (int i = 0; i < 8; i++) frame(color, pass ? rdepth : depth, 40, pass ? NVN_DEPTH_FUNC_GEQUAL : NVN_DEPTH_FUNC_LEQUAL, nil);
        mtl_stereo_frame g; CHECK(mtl_stereo_acquire(&g) && g.c != hc && (g.d < 0 || g.d != hd), "%s: later frames leave a pinned frame's slots alone (colour %d then %d, depth %d then %d)", nm, hc, g.c, hd, g.d);
        mtl_stereo_release(&g); mtl_stereo_release(&f);
    }
    // The scene and its depth are rendered upside down, then postprocessing flips
    // only the colour into the window. The tap must carry enough information to
    // align depth with that final colour, without changing the window origin.
    {
        id<MTLTexture> picture = make(MTLPixelFormatRGBA8Unorm, W, H);
        id<MTLTexture> scene = make(MTLPixelFormatRGBA8Unorm, W, H), flipped = make(MTLPixelFormatDepth32Float, W, H);
        uint8_t *rc = malloc(W * H * 4); float *rz = malloc(W * H * sizeof *rz);
        // An asymmetric scene with detail at the reference grid's scale.
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            uint8_t *p = rc + (y * W + x) * 4;
            p[0] = 20 + y * 120 / H; p[1] = 20 + (x / 32 % 2) * 20; p[2] = 10; p[3] = 255;
        }
        fill(picture, rc, 4);
        uint8_t row[W * 4];
        for (int y = 0; y < H / 2; y++) {
            memcpy(row, rc + y * W * 4, W * 4);
            memcpy(rc + y * W * 4, rc + (H - 1 - y) * W * 4, W * 4);
            memcpy(rc + (H - 1 - y) * W * 4, row, W * 4);
        }
        fill(scene, rc, 4);
        for (int reverse = 0; reverse < 2; reverse++) {
            const float *source = reverse ? zr : z;
            for (int y = 0; y < H; y++) memcpy(rz + y * W, source + (H - 1 - y) * W, W * sizeof *rz);
            fill(flipped, rz, 4);
            int func = reverse ? NVN_DEPTH_FUNC_GEQUAL : NVN_DEPTH_FUNC_LEQUAL;
            frame(picture, reverse ? rdepth : depth, 40, func, nil);
            CHECK(mtl_stereo_acquire(&f) && f.reference, "alignment: upright scene has a reference (reverse %d)", reverse);
            NSUInteger ew, eh, aw, ah;
            id<MTLBuffer> expected = dm_immersive_eyes(&f, 1, &ew, &eh);
            mtl_stereo_release(&f);
            frame_scene(picture, flipped, 40, func, nil, scene);
            CHECK(mtl_stereo_acquire(&f) && f.reference && !f.depth_flip, "alignment: inverted scene has its own reference, despite an upper-left window (reverse %d)", reverse);
            id<MTLBuffer> actual = dm_immersive_eyes(&f, 1, &aw, &ah);
            CHECK(expected && actual && ew == aw && eh == ah && !memcmp(expected.contents, actual.contents, ew * eh * 8),
                  "alignment: both eyes match the upright scene after an offscreen Y flip (reverse %d)", reverse);
            // A constant scene cannot distinguish the mappings: retain the declared
            // orientation. This also checks that a previous frame's decision is not reused.
            float blank[32 * 18] = {0}; id<MTLTexture> ref = make(MTLPixelFormatR32Float, 32, 18); fill(ref, blank, 4);
            f.reference = (__bridge void *)ref; f.depth_flip = 1;
            actual = dm_immersive_eyes(&f, 0, &aw, &ah);
            CHECK(expected && actual && !memcmp(expected.contents, actual.contents, ew * eh * 8), "alignment: ambiguous reference uses this frame's declared origin (reverse %d)", reverse);
            f.reference = NULL;
            actual = dm_immersive_eyes(&f, 0, &aw, &ah);
            CHECK(expected && actual && !memcmp(expected.contents, actual.contents, ew * eh * 8), "alignment: absent reference uses this frame's declared origin (reverse %d)", reverse);
            mtl_stereo_release(&f);
        }
        free(rc); free(rz);
    }
    // A frame without a scene (a 2D game): the picture alone, drawn flat
    uint64_t tag = frame(color, nil, 0, NVN_DEPTH_FUNC_LEQUAL, nil);
    CHECK(tag == 0, "a frame without depth-writing draws has no depth copy");
    CHECK(mtl_stereo_acquire(&f) && !f.depth, "its frame comes without a depth");
    NSUInteger w, h; id<MTLBuffer> px = dm_immersive_eyes(&f, 1, &w, &h);
    if (px) { const uint8_t *p = px.contents; double l = column(p, 0, 90, 2), r = column(p, 1, 90, 2); CHECK(fabs(l - 200) < 0.6 && fabs(r - 200) < 0.6, "and both eyes get the same picture (%.2f, %.2f)", l, r); }
    mtl_stereo_release(&f);
    // A HUD: the scene composited into a window texture by one draw, then a white bar drawn over its far band by a second, without the depth test
    {
        tex_t wt = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 99701};
        wt.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = W, .height = H, .depth = 1, .levels = 1, .samples = 1};
        MTLTextureDescriptor *td = tex_desc(&wt, 0); td.usage |= MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
        id<MTLTexture> win = [g_dev newTextureWithDescriptor:td];
        res_add(win); mtl_tex_init(&wt); serial_put(wt.serial, win); mtl_xv_window_tex(wt.serial);
        fill(win, c, 4);
        uint8_t bar[16 * 100 * 4]; memset(bar, 255, sizeof bar);
        id<MTLBuffer> bb = [g_dev newBufferWithBytes:bar length:sizeof bar options:MTLResourceStorageModeShared]; res_add(bb); res_commit();
        state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
        R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &wt; S.ds.dt = 0;
        st_overlay(1);   // the composite: the picture is laid down
        st_overlay(1);   // the HUD's first draw: the window texture is copied before it
        enc_b_copy_buffer_texture(blit_open(), bb, 0, 16 * 4, sizeof bar, MTLSizeMake(16, 100, 1), win, 0, 0, MTLOriginMake(600, 40, 0));   // the bar, at columns 600..615 of the far band
        st_overlay(1);   // its second draw: copied once
        mtl_sub_commit(); mtl_drain();
        MTL4RenderPassDescriptor *pd = [MTL4RenderPassDescriptor new]; pd.colorAttachments[0].texture = color; pd.depthAttachment.texture = depth;
        S.ds.dt = S.ds.dw = 1; S.ds.df = NVN_DEPTH_FUNC_LEQUAL; S.has_vp = 1; S.vp[0][0] = S.vp[0][1] = 0; S.vp[0][2] = W; S.vp[0][3] = H;
        st_pass(pd); for (int i = 0; i < 40; i++) st_draw();
        res_commit();
        uint64_t seq0 = g_st_pub.seq;
        g_st_tag = st_take_depth(&wt); CHECK(g_st_tag != 0, "HUD: the frame's depth is copied");
        st_present(win, NULL);
        for (int i = 0; i < 400 && g_st_pub.seq == seq0; i++) usleep(5000);
        CHECK(mtl_stereo_acquire(&f) && f.base && f.depth, "HUD: the frame comes with the picture before its overlays");
        if (f.base) {
            NSUInteger w2, h2; id<MTLBuffer> px2 = dm_immersive_eyes(&f, 1, &w2, &h2);
            CHECK(px2 != nil, "HUD: both eyes are drawn");
            if (px2) {
                const uint8_t *q = px2.contents; double far = 0.012 * W, lo = far / 2;
                double hl = column_in(q, 0, 90, 1, 560, 660), hr = column_in(q, 1, 90, 1, 560, 660), fl = column_in(q, 0, 90, 2, 150, 250), fr = column_in(q, 1, 90, 2, 150, 250);
                CHECK(fabs(hl - (607.5 + lo / 2)) < 1.5 && fabs(hr - (607.5 - lo / 2)) < 1.5, "HUD: the bar stands in front of the scene (left %.2f, right %.2f, want %.2f and %.2f)", hl, hr, 607.5 + lo / 2, 607.5 - lo / 2);
                CHECK(fabs(fl - (200 - far / 2)) < 1.5 && fabs(fr - (200 + far / 2)) < 1.5, "HUD: the far marker beside it keeps its depth (left %.2f, right %.2f)", fl, fr);
                int ghost = 0; for (int x = 590; x < 600; x++) ghost |= q[((size_t)0 * H + 90) * W * 4 + (size_t)x * 4 + 1] > 8;
                CHECK(!ghost, "HUD: no copy of the bar where the far band moves (left eye, columns 590..599)");
            }
            mtl_stereo_release(&f);
        }
    }
    // Alpha in the game's opaque present is not visible. An alpha-only triangle must not
    // split the scene into HUD and scene depths along its diagonal.
    {
        id<MTLTexture> alpha = make(MTLPixelFormatRGBA8Unorm, W, H);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
            c[(y * W + x) * 4 + 3] = x < y * 2 ? 255 : 0;
        fill(alpha, c, 4);
        mtl_stereo_frame plain = {.color = (__bridge void *)color, .depth = (__bridge void *)depth,
                                 .depth_rect = {0, 0, 1, 1}, .seq = UINT64_MAX - 1};
        NSUInteger w0, h0, w1, h1;
        id<MTLBuffer> expected = dm_immersive_eyes(&plain, 1, &w0, &h0);
        plain.color = (__bridge void *)alpha; plain.base = (__bridge void *)color; plain.seq++;
        id<MTLBuffer> actual = dm_immersive_eyes(&plain, 1, &w1, &h1);
        CHECK(expected && actual && w0 == w1 && h0 == h1, "alpha-only triangle: both eyes are drawn");
        if (expected && actual && w0 == w1 && h0 == h1) {
            const uint8_t *a = actual.contents, *b = expected.contents; size_t changed = 0;
            for (NSUInteger i = 0; i < 2 * w0 * h0; i++)
                if (a[4 * i] != b[4 * i] || a[4 * i + 1] != b[4 * i + 1] || a[4 * i + 2] != b[4 * i + 2]) changed++;
            CHECK(changed == 0, "alpha-only triangle: invisible alpha leaves scene geometry unchanged (%zu RGB pixels changed)", changed);
        }
    }
    mtl_drain();
    CHECK(!mtl_last_commit_error(), "no GPU error");
    printf("t_stereo: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
