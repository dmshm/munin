import AppKit
import SceneKit
import SwiftUI
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
    /// The tilt the 2D/3D button returns to, as Google Maps' tilted view.
    static let tilted: Float = Float(45).radians

    var orientation: simd_quatf {
        simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: -pitch, axis: SIMD3(1, 0, 0))
    }

    var position: SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }

    /// Ground-plane directions for keyboard movement.
    var forward: SIMD3<Float> { SIMD3(-sin(yaw), 0, -cos(yaw)) }
    var right: SIMD3<Float> { SIMD3(cos(yaw), 0, -sin(yaw)) }

    var isTopDown: Bool { pitch > Float(80).radians }

    mutating func clamp() {
        pitch = min(max(pitch, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
        distance = min(max(distance, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
    }
}

/// Heading and tilt for the on-screen compass and tilt button. Separate from the app
/// model so a drag, which changes them every frame, redraws only those controls.
final class CameraState: ObservableObject {
    @Published private(set) var yaw: Float = 0
    @Published private(set) var isTopDown = false

    fileprivate func update(_ rig: CameraRig) {
        let apply = { [self] in
            if abs(yaw - rig.yaw) > 0.001 { yaw = rig.yaw }
            if isTopDown != rig.isTopDown { isTopDown = rig.isTopDown }
        }
        // Scenes are first framed while being built in the background.
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }
}

extension BuildScene {
    func apply(_ rig: CameraRig, animated: Bool = false) {
        var rig = rig
        rig.clamp()
        self.rig = rig
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.35 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        camera.simdPosition = rig.position
        camera.simdOrientation = rig.orientation
        SCNTransaction.commit()
        cameraState.update(rig)
    }

    /// Zoom about the middle of the view, as the + and − buttons do.
    func zoom(by factor: Float) {
        var r = rig
        r.distance *= factor
        apply(r, animated: true)
    }

    /// Turn back to north up, keeping the tilt, the short way round.
    func faceNorth() {
        var r = rig
        r.yaw -= remainder(r.yaw, 2 * .pi) // the nearest whole turn
        apply(r, animated: true)
    }

    /// Between looking straight down and Google Maps' tilted view.
    func toggleTilt() {
        var r = rig
        r.pitch = r.isTopDown ? CameraRig.tilted : CameraRig.pitchRange.upperBound
        apply(r, animated: true)
    }
}

/// SceneKit view with Google Maps-style navigation, reporting which piece or prop is
/// under the mouse.
///
/// - drag: move the view, the ground under the cursor following it; let go while
///   moving and it glides to a stop
/// - scroll, mouse wheel or trackpad, and pinch: zoom toward the cursor
/// - double-click: zoom in on that spot
/// - ⌃-drag, ⌥-drag or right-drag: rotate (sideways) and tilt (up and down);
///   two-finger rotate turns too
/// - arrows (or W A S D): move · ⇧-arrows: rotate and tilt · + −: zoom · Q E, R F
final class HoverSCNView: SCNView {
    var onHover: (((isProp: Bool, index: Int)?, CGPoint) -> Void)?
    weak var buildScene: BuildScene?

    private var grab: SIMD3<Float>?
    private var orbiting = false
    private var keys = Set<UInt16>()
    private var keyTimer: Timer?
    /// Where the view's target was over the last moments of a drag, for the glide.
    private var dragSamples: [(time: CFTimeInterval, target: SIMD3<Float>)] = []
    private var glide: Timer?

    override var acceptsFirstResponder: Bool { true }

    /// Most pixels a frame renders; past it the scene renders smaller and macOS scales
    /// it up. Frame cost follows the pixel count, and a full-screen view on a 5K
    /// display is 12 million of them: about 7 million keeps it above 60 fps on an
    /// M1 Pro, and smaller windows and ordinary displays stay at full resolution.
    static let defaultPixelBudget: CGFloat = 7_000_000
    /// nil: always every pixel.
    var pixelBudget: CGFloat? = defaultPixelBudget { didSet { applyRenderScale() } }
    /// Fraction of the display's resolution the scene renders at.
    private(set) var renderScale: CGFloat = 1
    /// Set while the bounds change: AppKit answers that by calling
    /// viewDidChangeBackingProperties, which would come back here without end.
    private var applyingRenderScale = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyRenderScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyRenderScale()
    }

    /// SceneKit sizes its drawable from the bounds, so smaller bounds in the same frame
    /// render fewer pixels, stretched to fill the view. Points from events arrive in
    /// bounds coordinates, so picking keeps working unchanged.
    private func applyRenderScale() {
        guard !applyingRenderScale else { return }
        let backing = window?.backingScaleFactor ?? 2
        let pixels = frame.width * frame.height * backing * backing
        let scale = pixelBudget.map { pixels > $0 ? ($0 / pixels).squareRoot() : 1 } ?? 1
        let size = NSSize(width: frame.width * scale, height: frame.height * scale)
        if abs(bounds.width - size.width) > 0.5 || abs(bounds.height - size.height) > 0.5 {
            applyingRenderScale = true
            setBoundsSize(size)
            applyingRenderScale = false
        }
        // From the bounds AppKit kept, which hover positions are measured in.
        renderScale = frame.width > 0 ? bounds.width / frame.width : 1
    }

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
        // AppKit's y runs up; SwiftUI overlays expect it down, in the view's frame.
        onHover?(target, CGPoint(x: point.x / renderScale, y: (bounds.height - point.y) / renderScale))
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
        stopGlide()
        let point = convert(event.locationInWindow, from: nil)
        // Google Maps rotates and tilts with ⌃-drag; ⌥ does the same here.
        orbiting = !event.modifierFlags.intersection([.option, .control]).isEmpty
        grab = orbiting ? nil : pick(point)
        dragSamples = []
        if event.clickCount == 2, !orbiting {
            // As Google Maps: zoom in on the spot, which stays under the cursor.
            zoom(by: 0.5, at: point, animated: true)
            grab = nil
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
        let now = CACurrentMediaTime()
        dragSamples.append((now, rig.target))
        dragSamples.removeAll { now - $0.time > 0.1 }
    }

    override func mouseUp(with event: NSEvent) {
        if !orbiting { startGlide() }
        grab = nil
        orbiting = false
    }

    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); stopGlide(); onHover?(nil, .zero) }
    override func rightMouseDragged(with event: NSEvent) { orbit(event) }

    override func otherMouseDown(with event: NSEvent) { stopGlide(); grab = pick(convert(event.locationInWindow, from: nil)) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }

    private func orbit(_ event: NSEvent) {
        guard let scene = buildScene else { return }
        var rig = scene.rig
        rig.yaw -= Float(event.deltaX) * 0.006
        rig.pitch += Float(event.deltaY) * 0.006
        scene.apply(rig)
    }

    // MARK: - glide

    /// Keep moving at the speed the drag ended with, slowing to a stop, as a map does.
    private func startGlide() {
        guard let first = dragSamples.first, let last = dragSamples.last, last.time - first.time > 0.01,
              CACurrentMediaTime() - last.time < 0.05 else { return }
        var velocity = (last.target - first.target) / Float(last.time - first.time)
        var previous = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self, let scene = self.buildScene else { timer.invalidate(); return }
            let now = CACurrentMediaTime()
            let dt = Float(now - previous)
            previous = now
            var rig = scene.rig
            rig.target += velocity * dt
            scene.apply(rig)
            velocity *= exp(-5 * dt)
            if simd_length(velocity) < max(rig.distance, 4) * 0.02 { self.stopGlide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glide = timer
    }

    private func stopGlide() {
        glide?.invalidate()
        glide = nil
    }

    // MARK: - zoom

    override func scrollWheel(with event: NSEvent) {
        guard let scene = buildScene else { return }
        stopGlide()
        if !event.modifierFlags.intersection([.option, .control]).isEmpty {
            // ⌥ or ⌃ with two fingers: rotate and tilt, like ⌃-drag.
            var rig = scene.rig
            rig.yaw -= Float(event.scrollingDeltaX) * 0.004
            rig.pitch += Float(event.scrollingDeltaY) * 0.004
            scene.apply(rig)
            return
        }
        // Google Maps: scrolling zooms, toward the cursor, with a mouse wheel or a trackpad.
        let delta = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.005 : event.scrollingDeltaY * 0.12)
        zoom(by: exp(-delta), at: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        stopGlide()
        zoom(by: Float(1 / (1 + event.magnification)), at: convert(event.locationInWindow, from: nil))
    }

    override func rotate(with event: NSEvent) {
        guard let scene = buildScene else { return }
        var rig = scene.rig
        rig.yaw += Float(event.rotation).radians
        scene.apply(rig)
    }

    /// Zoom keeping the point under the cursor where it is on screen.
    private func zoom(by factor: Float, at point: CGPoint, animated: Bool = false) {
        guard let scene = buildScene else { return }
        var rig = scene.rig
        let old = rig.distance
        rig.distance = min(max(old * factor, CameraRig.distanceRange.lowerBound), CameraRig.distanceRange.upperBound)
        let applied = rig.distance / old
        if let p = pick(point) { rig.target = p + (rig.target - p) * applied }
        scene.apply(rig, animated: animated)
    }

    // MARK: - keyboard

    private enum Key {
        static let w: UInt16 = 13, a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
        static let q: UInt16 = 12, e: UInt16 = 14, r: UInt16 = 15, f: UInt16 = 3
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        static let plus: UInt16 = 24, minus: UInt16 = 27, padPlus: UInt16 = 69, padMinus: UInt16 = 78
        static let all: Set<UInt16> = [w, a, s, d, q, e, r, f, left, right, down, up, plus, minus, padPlus, padMinus]
    }

    override func keyDown(with event: NSEvent) {
        guard Key.all.contains(event.keyCode), event.modifierFlags.intersection([.command, .control]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        stopGlide()
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
        func held(_ codes: UInt16...) -> Bool { codes.contains(where: keys.contains) }
        // ⇧ turns the arrows into rotate and tilt, as in Google Maps' 3D view.
        if NSEvent.modifierFlags.contains(.shift) {
            if held(Key.left) { rig.yaw += 1.6 * dt }
            if held(Key.right) { rig.yaw -= 1.6 * dt }
            if held(Key.up) { rig.pitch += 1.2 * dt }
            if held(Key.down) { rig.pitch -= 1.2 * dt }
        } else {
            // Speed scales with height, so it feels the same close up and far out.
            let speed = max(rig.distance, 4) * 0.9 * dt
            if held(Key.w, Key.up) { rig.target += rig.forward * speed }
            if held(Key.s, Key.down) { rig.target -= rig.forward * speed }
            if held(Key.d, Key.right) { rig.target += rig.right * speed }
            if held(Key.a, Key.left) { rig.target -= rig.right * speed }
        }
        if held(Key.q) { rig.yaw += 1.6 * dt }
        if held(Key.e) { rig.yaw -= 1.6 * dt }
        if held(Key.r, Key.plus, Key.padPlus) { rig.distance *= 1 - 1.2 * dt }
        if held(Key.f, Key.minus, Key.padMinus) { rig.distance *= 1 + 1.2 * dt }
        scene.apply(rig)
    }

    override func resignFirstResponder() -> Bool {
        keys.removeAll()
        keyTimer?.invalidate()
        keyTimer = nil
        stopGlide()
        return super.resignFirstResponder()
    }
}

/// Google Maps' corner controls: a compass that points north (click for north up),
/// zoom in and out, and a switch between looking straight down and tilted.
struct CameraControls: View {
    @ObservedObject var camera: CameraState
    let scene: BuildScene

    var body: some View {
        VStack(spacing: 8) {
            Button { scene.faceNorth() } label: {
                Needle()
                    .rotationEffect(.radians(Double(camera.yaw)))
                    .frame(width: 34, height: 34)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("North up")
            .accessibilityLabel("Compass: turn to north up")

            VStack(spacing: 0) {
                Button { scene.zoom(by: 0.6) } label: {
                    Image(systemName: "plus").frame(width: 34, height: 30).contentShape(Rectangle())
                }
                .help("Zoom in")
                .accessibilityLabel("Zoom in")
                Divider().frame(width: 22)
                Button { scene.zoom(by: 1 / 0.6) } label: {
                    Image(systemName: "minus").frame(width: 34, height: 30).contentShape(Rectangle())
                }
                .help("Zoom out")
                .accessibilityLabel("Zoom out")
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            Button { scene.toggleTilt() } label: {
                Text(camera.isTopDown ? "3D" : "2D")
                    .font(.caption.weight(.bold))
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(camera.isTopDown ? "Tilt the view" : "Look straight down")
        }
        .font(.system(size: 13, weight: .semibold))
    }

    /// A compass needle: the north half in ember, the south half grey.
    private struct Needle: View {
        var body: some View {
            VStack(spacing: 0) {
                Triangle().fill(Theme.ember).frame(width: 9, height: 11)
                Triangle().fill(Color.secondary).frame(width: 9, height: 11).rotationEffect(.degrees(180))
            }
        }
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.closeSubpath()
            }
        }
    }
}
