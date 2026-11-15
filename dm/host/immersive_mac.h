// The game on a Vision Pro, drawn by this Mac (immersive_mac.m, immersive_mac.swift): a screen in front of the player in a RemoteImmersiveSpace, with a picture for each eye made from
// the game's depth (dm/gfx/msl/stereo.metal). On with DM_IMMERSIVE=1 and a window; the Mac's window goes on showing the game
#pragma once
#ifdef __OBJC__
#import <CompositorServices/CompositorServices.h>
#import <ARKit/ARKit.h>
// From the scene (main thread): the layer the system made for the space, and the headset to take the head's pose from. Starts the render thread, which ends when the layer is invalidated
void dm_immersive_render(cp_layer_renderer_t layer, ar_device_t device);
#import <Metal/Metal.h>
#include "../gfx/nvn/mtl_stereo.h"
id<MTLBuffer> dm_immersive_eyes(const mtl_stereo_frame *f, int measure, NSUInteger *w, NSUInteger *h);   // see immersive_mac.m
#endif
// The scene (immersive_mac.swift): adds the space to the app and asks the system to open it on a Vision Pro. Main thread, once the app runs
void dm_immersive_scene_open(void);
// The scene's reports: why the space did not open, or that it closed (main thread)
void dm_immersive_note(const char *what);
// front_mac.m: start (DM_IMMERSIVE, DM_IMMERSIVE_SHOT) once the window is up; whether DM_IMMERSIVE asked for the headset
void dm_immersive_start(void);
int dm_immersive_wanted(void);
