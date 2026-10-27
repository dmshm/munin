import AppKit
import SceneKit
import SwiftUI

/// The 3D view; navigation and hover live in HoverSCNView (Navigation.swift).
struct BuildView: NSViewRepresentable {
    let scene: BuildScene
    var onHover: ((isProp: Bool, index: Int)?, CGPoint) -> Void

    func makeNSView(context: Context) -> HoverSCNView {
        let view = HoverSCNView()
        view.allowsCameraControl = false // our own map-style controls instead
        view.rendersContinuously = true    // flames, flicker, wind and water move
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        configure(view)
        return view
    }

    func updateNSView(_ view: HoverSCNView, context: Context) {
        if view.scene !== scene.scene { configure(view) }
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
