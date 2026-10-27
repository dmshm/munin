import AppKit
import SceneKit
import simd

/// Map-style camera: a point on the ground the camera looks at, and the direction and
/// distance it looks from. Dragging moves that point, not the angle.
struct CameraRig {
    var target: SIMD3<Float>
    /// Around the vertical, radians; 0 looks north (SceneKit -z is Valheim north).
    var yaw: Float
    /// Above the horizon, radians.
    var pitch: Float
    var distance: Float

    static let pitchRange: ClosedRange<Float> = Float(4).radians...Float(89).radians
    static let distanceRange: ClosedRange<Float> = 1.5...3000

    var orientation: simd_quatf {
        simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: -pitch, axis: SIMD3(1, 0, 0))
    }

    var position: SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }

    /// Ground-plane directions for keyboard and trackpad movement.
    var forward: SIMD3<Float> { SIMD3(-sin(yaw), 0, -cos(yaw)) }
    var right: SIMD3<Float> { SIMD3(cos(yaw), 0, -sin(yaw)) }

    mutating func clamp() {
        pitch = min(max(pitch, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
        distance = min(max(distance, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
    }
}

extension BuildScene {
    func apply(_ rig: CameraRig, animated: Bool = false) {
        var rig = rig
        rig.clamp()
        self.rig = rig
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.35 : 0
        camera.simdPosition = rig.position
        camera.simdOrientation = rig.orientation
        SCNTransaction.commit()
    }
}

/// SceneKit view with map-style navigation, reporting which piece or prop is under the mouse.
///
/// - drag: move the view — the ground under the cursor follows it
/// - right-drag, ⌥-drag or ⌃-drag: rotate around the view's centre
/// - scroll wheel, pinch: zoom toward the cursor
/// - trackpad two-finger swipe: move; two-finger rotate: turn
/// - double-click: fly to that spot
/// - W A S D / arrows: move · Q E: turn · R F: zoom
final class HoverSCNView: SCNView {
    var onHover: (((isProp: Bool, index: Int)?, CGPoint) -> Void)?
    weak var buildScene: BuildScene?

    private var grab: SIMD3<Float>?
    private var orbiting = false
    private var keys = Set<UInt16>()
    private var keyTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: - hover

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let hit = hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .categoryBitMask: BuildScene.solidMask,
        ]).first
        var node = hit?.node
        while let n = node, !(n.name?.hasPrefix("piece:") ?? false || n.name?.hasPrefix("prop:") ?? false) { node = n.parent }
        let target = node?.name.flatMap { name -> (isProp: Bool, index: Int)? in
            let parts = name.split(separator: ":")
            guard parts.count == 2, let i = Int(parts[1]) else { return nil }
            return (parts[0] == "prop", i)
        }
        // AppKit's y runs up; SwiftUI overlays expect it down.
        onHover?(target, CGPoint(x: point.x, y: bounds.height - point.y))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil, .zero)
    }

    // MARK: - picking

    private func ray(_ point: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let near = SIMD3<Float>(unprojectPoint(SCNVector3(point.x, point.y, 0)))
        let far = SIMD3<Float>(unprojectPoint(SCNVector3(point.x, point.y, 1)))
        return (near, simd_normalize(far - near))
    }

    /// Where a ray from the cursor meets the horizontal plane at `height`.
    private func onPlane(_ point: CGPoint, height: Float) -> SIMD3<Float>? {
        let (o, d) = ray(point)
        guard abs(d.y) > 1e-4 else { return nil }
        let t = (height - o.y) / d.y
        return t > 0 ? o + d * t : nil
    }

    /// The surface under the cursor — a piece, a tree, the ground — or failing that the
    /// plane through the view's centre.
    private func pick(_ point: CGPoint) -> SIMD3<Float>? {
        let hits = hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .categoryBitMask: BuildScene.solidMask | BuildScene.decorationMask,
            .ignoreHiddenNodes: true,
        ])
        if let hit = hits.first { return SIMD3(hit.worldCoordinates) }
        return buildScene.flatMap { onPlane(point, height: $0.rig.target.y) }
    }

    // MARK: - mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        orbiting = !event.modifierFlags.intersection([.option, .control]).isEmpty
        grab = orbiting ? nil : pick(point)
        if event.clickCount == 2, let p = grab, var rig = buildScene?.rig {
            rig.target = p
            rig.distance = max(rig.distance * 0.6, 4)
            buildScene?.apply(rig, animated: true)
        }
        onHover?(nil, .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        if orbiting { orbit(event); return }
        guard let scene = buildScene, let p = grab,
              let q = onPlane(convert(event.locationInWindow, from: nil), height: p.y) else { return }
        // Move the view so the grabbed point is back under the cursor.
        var rig = scene.rig
        rig.target += p - q
        scene.apply(rig)
    }

    override func mouseUp(with event: NSEvent) { grab = nil; orbiting = false }

    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onHover?(nil, .zero) }
    override func rightMouseDragged(with event: NSEvent) { orbit(event) }

    override func otherMouseDown(with event: NSEvent) { grab = pick(convert(event.locationInWindow, from: nil)) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }

    private func orbit(_ event: NSEvent) {
        guard let scene = buildScene else { return }
        var rig = scene.rig
        rig.yaw -= Float(event.deltaX) * 0.006
        rig.pitch += Float(event.deltaY) * 0.006
        scene.apply(rig)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let scene = buildScene else { return }
        var rig = scene.rig
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // Trackpad: two fingers move the view; with ⌥ they turn it.
            if event.modifierFlags.contains(.option) {
                rig.yaw -= Float(event.scrollingDeltaX) * 0.004
                rig.pitch += Float(event.scrollingDeltaY) * 0.004
            } else {
                let scale = rig.distance * 0.0025
                rig.target += (rig.right * -Float(event.scrollingDeltaX) + rig.forward * Float(event.scrollingDeltaY)) * scale
            }
            scene.apply(rig)
        } else {
            let delta = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1)
            zoom(by: exp(-delta), at: convert(event.locationInWindow, from: nil))
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: Float(1 / (1 + event.magnification)), at: convert(event.locationInWindow, from: nil))
    }

    override func rotate(with event: NSEvent) {
        guard let scene = buildScene else { return }
        var rig = scene.rig
        rig.yaw += Float(event.rotation).radians
        scene.apply(rig)
    }

    /// Zoom keeping the point under the cursor where it is on screen.
    private func zoom(by factor: Float, at point: CGPoint) {
        guard let scene = buildScene else { return }
        var rig = scene.rig
        let old = rig.distance
        rig.distance = min(max(old * factor, CameraRig.distanceRange.lowerBound), CameraRig.distanceRange.upperBound)
        let applied = rig.distance / old
        if let p = pick(point) { rig.target = p + (rig.target - p) * applied }
        scene.apply(rig)
    }

    // MARK: - keyboard

    private enum Key {
        static let w: UInt16 = 13, a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
        static let q: UInt16 = 12, e: UInt16 = 14, r: UInt16 = 15, f: UInt16 = 3
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        static let all: Set<UInt16> = [w, a, s, d, q, e, r, f, left, right, down, up]
    }

    override func keyDown(with event: NSEvent) {
        guard Key.all.contains(event.keyCode), event.modifierFlags.intersection([.command, .control]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        keys.insert(event.keyCode)
        if keyTimer == nil {
            var last = CACurrentMediaTime()
            keyTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                let now = CACurrentMediaTime()
                self?.stepKeys(Float(now - last))
                last = now
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        keys.remove(event.keyCode)
        if keys.isEmpty { keyTimer?.invalidate(); keyTimer = nil }
    }

    private func stepKeys(_ dt: Float) {
        guard let scene = buildScene, !keys.isEmpty else { return }
        var rig = scene.rig
        // Speed scales with height, so it feels the same close up and far out.
        let speed = max(rig.distance, 4) * 0.9 * dt
        if keys.contains(Key.w) || keys.contains(Key.up) { rig.target += rig.forward * speed }
        if keys.contains(Key.s) || keys.contains(Key.down) { rig.target -= rig.forward * speed }
        if keys.contains(Key.d) || keys.contains(Key.right) { rig.target += rig.right * speed }
        if keys.contains(Key.a) || keys.contains(Key.left) { rig.target -= rig.right * speed }
        if keys.contains(Key.q) { rig.yaw += 1.6 * dt }
        if keys.contains(Key.e) { rig.yaw -= 1.6 * dt }
        if keys.contains(Key.r) { rig.distance *= 1 - 1.2 * dt }
        if keys.contains(Key.f) { rig.distance *= 1 + 1.2 * dt }
        scene.apply(rig)
    }

    override func resignFirstResponder() -> Bool {
        keys.removeAll()
        keyTimer?.invalidate()
        keyTimer = nil
        return super.resignFirstResponder()
    }
}
