import AppKit
import SceneKit
import SwiftUI

/// The 3D view; navigation and hover live in HoverSCNView (Navigation.swift).
struct BuildView: NSViewRepresentable {
    let scene: BuildScene
    /// Render every pixel of a large window instead of capping the count; see HoverSCNView.
    var fullResolution = false
    var onHover: ((isProp: Bool, index: Int)?, CGPoint) -> Void

    func makeNSView(context: Context) -> HoverSCNView {
        let view = HoverSCNView()
        view.allowsCameraControl = false // our own map-style controls instead
        view.rendersContinuously = true    // flames, flicker, wind and water move
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        // MUNIN_STATS=1: the frame rate, shown by the app itself (SceneKit's own
        // statistics bar is pinned bottom left, under the layer bar).
        if FrameCounter.enabled { view.delegate = FrameCounter.shared }
        configure(view)
        return view
    }

    func updateNSView(_ view: HoverSCNView, context: Context) {
        if view.scene !== scene.scene { configure(view) }
        view.pixelBudget = fullResolution ? nil : HoverSCNView.defaultPixelBudget
        view.onHover = onHover
    }

    private func configure(_ view: HoverSCNView) {
        view.scene = scene.scene
        view.pointOfView = scene.camera
        view.buildScene = scene
        scene.frame(.iso)
        view.onHover = onHover
    }
}

/// `MUNIN_STATS=1`: frames per second and the size actually rendered, once a second,
/// in a corner of the 3D view and on stderr — the real rate in the window, which
/// off-screen benchmarks only estimate.
final class FrameCounter: NSObject, SCNSceneRendererDelegate, ObservableObject {
    static let enabled = ProcessInfo.processInfo.environment["MUNIN_STATS"] != nil
    static let shared = FrameCounter()
    @Published private(set) var reading = ""
    private var frames = 0
    private var since = CACurrentMediaTime()

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        frames += 1
        let now = CACurrentMediaTime()
        guard now - since >= 1 else { return }
        let size = renderer.currentViewport.size
        let text = String(format: "%.0f fps · %.0f × %.0f", Double(frames) / (now - since), size.width, size.height)
        FileHandle.standardError.write(Data((text + "\n").utf8))
        // Called on SceneKit's render thread.
        DispatchQueue.main.async { self.reading = text }
        frames = 0
        since = now
    }
}

/// The frame rate readout, for `MUNIN_STATS=1`.
struct FrameRateBadge: View {
    @ObservedObject var counter = FrameCounter.shared

    var body: some View {
        Text(counter.reading.isEmpty ? "measuring…" : counter.reading)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
    }
}

