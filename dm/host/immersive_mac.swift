// The scene of the game on a Vision Pro (immersive_mac.h): a RemoteImmersiveSpace is a SwiftUI scene, so this file adds it to the AppKit app (NSHostingSceneRepresentation) and
// hands its layer and the headset to immersive_mac.m, which draws. Built into gen/swift/immersive_mac.o by the host's Makefile
import ARKit
import CompositorServices
import SwiftUI

private let spaceID = "game"

private struct LayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        // layered: one texture of two layers, each eye's part of the lens map with it (immersive_mac.m draws any of the three)
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.layered) ? .layered : layouts.contains(.dedicated) ? .dedicated : .shared
        configuration.isFoveationEnabled = capabilities.supportsFoveation
        configuration.depthFormat = .depth32Float
        if capabilities.supportedColorFormats(options: []).contains(.bgra8Unorm_srgb) { configuration.colorFormat = .bgra8Unorm_srgb }
    }
}

private struct GameContent: CompositorContent {
    @Environment(\.remoteDeviceIdentifier) private var device

    var body: some CompositorContent {
        CompositorLayer(configuration: LayerConfiguration()) { @MainActor layer in
            guard let device else { dm_immersive_note("[RED] the space opened without a headset to track"); return }
            dm_immersive_render(layer, device.cDevice)
        }
    }
}

@MainActor private var scene: AnyObject?

@_cdecl("dm_immersive_scene_open")
public func dm_immersive_scene_open() {
    MainActor.assumeIsolated {
        guard scene == nil else { return }
        let representation = NSHostingSceneRepresentation {
            RemoteImmersiveSpace(id: spaceID) { GameContent() }
                .immersionStyle(selection: .constant(.full), in: .full)
        }
        NSApplication.shared.addSceneRepresentation(representation)
        scene = representation
        guard representation.environment.supportsRemoteScenes else {
            dm_immersive_note("[RED] this Mac does not support remote scenes: the game stays on the Mac")
            return
        }
        let open = representation.environment.openImmersiveSpace
        Task { @MainActor in
            switch await open(id: spaceID) {
            case .opened: dm_immersive_note("space opened on the headset")
            case .userCancelled: dm_immersive_note("the player declined the connection: the game stays on the Mac")
            case .error: dm_immersive_note("[RED] the space could not be opened: the game stays on the Mac")
            @unknown default: dm_immersive_note("[RED] the space did not open: the game stays on the Mac")
            }
        }
    }
}
