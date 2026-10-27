import AppKit
import SceneKit
import simd
import MuninCore

enum ViewPreset: String, CaseIterable, Identifiable {
    case iso = "3D", north = "From N", east = "From E", south = "From S", west = "From W", top = "Top"
    var id: String { rawValue }
}

/// The SceneKit scene for one build — optionally with its surroundings (ground,
/// water, trees and rocks) — and the per-piece state the controls drive: a height
/// cut, ghosts above it, and dimming of whatever is not in focus.
final class BuildScene {
    static let solidMask = 1
    static let ghostMask = 2
    /// Grid, ground, water and compass: drawn, but never answer hover.
    static let decorationMask = 4

    let scene = SCNScene()
    let build: Build
    /// Objects around the build that are not player-built; empty for a build file.
    let props: [Piece]
    let region: RegionContent?
    let camera = SCNNode()
    let sun = SCNNode()
    let ambient = SCNNode()
    let fireScale = FireScale()
    /// Heading and tilt, for the compass and the 2D/3D button.
    let cameraState = CameraState()
    private(set) var nodes: [SCNNode] = []
    private let surroundings = SCNNode()
    /// Height of each piece rounded to half a metre; distinct values are the layers.
    let levelOf: [Float]
    let levels: [Float]
    /// Shapes per prefab, by hash: a name can appear while the scene is shown, when the
    /// game assets finish setting up.
    private var geometries: [Int32: (normal: SCNGeometry, dim: SCNGeometry)] = [:]
    private(set) var propNodes: [(node: SCNNode, object: Piece)] = []

    init(build: Build, catalog: PieceCatalog?, region: RegionContent? = nil) {
        self.build = build
        self.region = region
        props = region?.props ?? []
        levelOf = build.pieces.map { ($0.position.y * 2).rounded() / 2 }
        levels = Array(Set(levelOf)).sorted().nilIfEmpty ?? [0]

        setUpSun()
        scene.rootNode.addChildNode(surroundings)
        if let region {
            if let ground = region.ground {
                let radius = region.region.radius + 8
                if ground.isExact, let catalog,
                   let exact = Timing.measure("  ground mesh", { Ground.node(ground, waterLevel: region.waterLevel, radius: radius, catalog: catalog) }) {
                    surroundings.addChildNode(exact)
                    if let grass = Timing.measure("  grass", { Ground.clutterNode(ground, origin: build.origin, waterLevel: region.waterLevel,
                                                      radius: region.region.radius, catalog: catalog) }) {
                        surroundings.addChildNode(grass)
                    }
                } else {
                    surroundings.addChildNode(groundNode(ground, water: region.waterLevel, radius: radius))
                }
            }
            // Only where the sea reaches the area; otherwise inland bases look like islands.
            let lowest = region.ground?.heights.min() ?? region.waterLevel
            if region.waterLevel > lowest - 1 { surroundings.addChildNode(waterNode(region)) }
            let propsStart = CACurrentMediaTime()
            for (i, prop) in props.enumerated() {
                guard let geometry = catalog?.geometry(for: prop.name) else { continue }
                if WorldMap.kind(of: prop.name) == .tree { Self.addWind(geometry) }
                let node = SCNNode(geometry: geometry)
                node.name = "prop:\(i)"
                place(node, prop)
                node.categoryBitMask = Self.solidMask
                surroundings.addChildNode(node)
                propNodes.append((node, prop))
            }
            Timing.report("  props (\(props.count))", since: propsStart)
        } else {
            scene.rootNode.addChildNode(grid())
        }
        scene.rootNode.addChildNode(compass())

        let piecesStart = CACurrentMediaTime()
        for (i, piece) in build.pieces.enumerated() {
            let node = SCNNode(geometry: geometries(for: piece, catalog).normal)
            node.name = "piece:\(i)"
            place(node, piece)
            scene.rootNode.addChildNode(node)
            nodes.append(node)
        }
        Timing.report("  pieces (\(build.pieces.count))", since: piecesStart)

        if let catalog {
            addFires(Array(zip(nodes, build.pieces)).map { ($0.0, $0.1) } + propNodes, catalog: catalog)
        }

        let cam = SCNCamera()
        cam.fieldOfView = 40
        cam.zNear = 0.1
        cam.zFar = 3000
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = false // it chases the bright sky and greys everything out
        // No screen-space ambient occlusion: at 5K it cost 40% of the frame rate and
        // streaked stone walls with dark bands; the sun's shadows give the depth.
        cam.bloomIntensity = 0.15
        camera.camera = cam
        scene.rootNode.addChildNode(camera)
        setTime(12)
        frame(.iso)
    }

    /// Half the size of what the camera frames.
    var extent: Float {
        let buildRadius = simd_length(build.size) / 2
        if let region { return max(buildRadius, region.region.radius * 0.75) }
        return max(buildRadius, 4)
    }

    var center: SIMD3<Float> {
        if build.pieces.isEmpty, let ground = region?.ground { return SIMD3(0, ground.height(x: 0, z: 0) + 4, 0) }
        return SIMD3(0, build.size.y / 2, 0)
    }

    // MARK: - state

    func apply(level: Int, ghosts: Bool, focus: String?, surroundings show: Bool = true) {
        surroundings.isHidden = !show
        guard !build.pieces.isEmpty else { return }
        let cut = levels[min(level, levels.count - 1)]
        let cutting = level < levels.count - 1
        for (i, node) in nodes.enumerated() {
            let piece = build.pieces[i]
            let visible = levelOf[i] <= cut
            let focused = focus.map { piece.label == $0 } ?? (!cutting || levelOf[i] == cut)
            let pair = geometries[piece.prefab]!
            node.geometry = visible && !focused ? pair.dim : pair.normal
            node.isHidden = !visible && !ghosts
            node.opacity = visible ? 1 : 0.12
            node.categoryBitMask = visible ? Self.solidMask : Self.ghostMask
        }
    }

    // MARK: - camera

    /// Where the camera is, map-style (see Navigation.swift).
    var rig = CameraRig(target: .zero, yaw: 0, pitch: 0.6, distance: 30)

    func frame(_ preset: ViewPreset, zoom: Float = 1) {
        let distance = extent / sin(Float(20).radians) * 1.2 / zoom
        let direction: SIMD3<Float>
        switch preset {
        case .iso: direction = SIMD3(1, 0.8, 1.2)
        case .north: direction = SIMD3(0, 0.15, -1) // SceneKit -z is Valheim north
        case .south: direction = SIMD3(0, 0.15, 1)
        case .east: direction = SIMD3(1, 0.15, 0)
        case .west: direction = SIMD3(-1, 0.15, 0)
        case .top: direction = SIMD3(0, 1, 0.001)
        }
        let d = simd_normalize(direction)
        apply(CameraRig(target: center, yaw: atan2(d.x, d.z), pitch: asin(d.y), distance: distance))
    }

    // MARK: - building blocks

    private func place(_ node: SCNNode, _ object: Piece) {
        node.simdPosition = sceneKitPosition(object.position)
        node.simdOrientation = sceneKitOrientation(object.rotation)
        node.simdScale = object.scale
    }

    private func geometries(for piece: Piece, _ catalog: PieceCatalog?) -> (normal: SCNGeometry, dim: SCNGeometry) {
        if let pair = geometries[piece.prefab] { return pair }
        let normal = catalog?.geometry(for: piece.name) ?? placeholderGeometry()
        let dim = normal.copy() as! SCNGeometry
        dim.materials = normal.materials.map {
            let m = $0.copy() as! SCNMaterial
            m.multiply.contents = NSColor(white: 0.3, alpha: 1)
            return m
        }
        geometries[piece.prefab] = (normal, dim)
        return (normal, dim)
    }

    /// The estimated ground as a mesh, tinted by height above the sea: sand at the
    /// shore, grass above, rock high up.
    private func groundNode(_ field: Heightfield, water: Float, radius: Float) -> SCNNode {
        var positions: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []
        for r in 0..<field.rows {
            for c in 0..<field.columns {
                let x = field.minX + Float(c) * field.cell
                let z = field.minZ + Float(r) * field.cell
                let h = field.height(column: c, row: r)
                positions.append(SCNVector3(sceneKitPosition(SIMD3(x, h, z))))
                colors.append(Self.groundColor(heightAboveWater: h - water))
            }
        }
        var indices: [UInt32] = []
        let cols = UInt32(field.columns)
        // Only the cells inside the circle, so the area ends in a round patch, not a slab.
        func inside(_ i: UInt32) -> Bool {
            let p = positions[Int(i)]
            return Float(p.x * p.x + p.z * p.z) <= radius * radius
        }
        for r in 0..<UInt32(field.rows - 1) {
            for c in 0..<(cols - 1) {
                let a = r * cols + c, b = a + 1, d = a + cols, e = d + 1
                guard inside(a) || inside(b) || inside(d) || inside(e) else { continue }
                // z is mirrored into SceneKit, so this winding faces up.
                indices += [a, b, d, b, e, d]
            }
        }
        // Pull the outer ring of vertices onto the circle: a round edge instead of steps.
        for i in positions.indices {
            let d = Float(positions[i].x * positions[i].x + positions[i].z * positions[i].z).squareRoot()
            if d > radius {
                positions[i].x *= CGFloat(radius / d)
                positions[i].z *= CGFloat(radius / d)
            }
        }
        let normals = Self.normals(positions, indices)
        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: positions),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(data: colors.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color,
                                  vectorCount: colors.count, usesFloatComponents: true, componentsPerVector: 4,
                                  bytesPerComponent: 4, dataOffset: 0, dataStride: 16),
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor.white
        m.roughness.contents = NSNumber(value: 0.95)
        m.isDoubleSided = true
        geometry.materials = [m]
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = Self.decorationMask
        return node
    }

    static func groundColor(heightAboveWater h: Float) -> SIMD4<Float> {
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * min(max(t, 0), 1) }
        // Linear-light albedos: these read as Valheim's muted meadow greens on screen.
        let sand = SIMD3<Float>(0.36, 0.30, 0.18), grass = SIMD3<Float>(0.09, 0.15, 0.04)
        let forest = SIMD3<Float>(0.05, 0.09, 0.03), rock = SIMD3<Float>(0.18, 0.17, 0.15)
        let c: SIMD3<Float>
        switch h {
        case ..<1.5: c = sand
        case ..<4: c = mix(sand, grass, (h - 1.5) / 2.5)
        case ..<40: c = mix(grass, forest, (h - 4) / 36)
        default: c = mix(forest, rock, (h - 40) / 40)
        }
        return SIMD4(c, 1)
    }

    static func normals(_ positions: [SCNVector3], _ indices: [UInt32]) -> [SCNVector3] {
        var acc = [SIMD3<Float>](repeating: .zero, count: positions.count)
        let p = positions.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let n = simd_cross(p[b] - p[a], p[c] - p[a])
            acc[a] += n; acc[b] += n; acc[c] += n
        }
        return acc.map { n in
            let u = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0)
            return SCNVector3(u.y < 0 ? -u : u)
        }
    }

    /// Trees sway; geometry is shared by every tree of a kind, so this happens once.
    private static func addWind(_ geometry: SCNGeometry) {
        for m in geometry.materials where m.shaderModifiers?[.geometry] == nil {
            var modifiers = m.shaderModifiers ?? [:]
            modifiers[.geometry] = Wind.tree
            m.shaderModifiers = modifiers
        }
    }

    private func waterNode(_ region: RegionContent) -> SCNNode {
        let plane = SCNCylinder(radius: CGFloat(region.region.radius + 10), height: 0.01)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(srgbRed: 0.10, green: 0.27, blue: 0.36, alpha: 0.78)
        m.roughness.contents = NSNumber(value: 0.15)
        m.metalness.contents = NSNumber(value: 0.1)
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.geometry: Wind.waterGeometry, .surface: Wind.waterSurface]
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.simdPosition = SIMD3(0, region.waterLevel, 0)
        node.categoryBitMask = Self.decorationMask
        node.renderingOrder = 10
        return node
    }

    /// 1 m ground grid so pieces can be counted against it; every 2 m (one wall) brighter.
    private func grid() -> SCNNode {
        let half = Int((max(build.size.x, build.size.z) / 2).rounded(.up)) + 4
        var fine: [SCNVector3] = []
        var coarse: [SCNVector3] = []
        for i in -half...half {
            let f = CGFloat(i), h = CGFloat(half)
            let lines = [SCNVector3(f, 0, -h), SCNVector3(f, 0, h), SCNVector3(-h, 0, f), SCNVector3(h, 0, f)]
            if i % 2 == 0 { coarse += lines } else { fine += lines }
        }
        let node = SCNNode()
        node.addChildNode(lineNode(fine, NSColor(white: 0.2, alpha: 1)))
        node.addChildNode(lineNode(coarse, NSColor(white: 0.3, alpha: 1)))
        node.position.y = -0.01
        node.categoryBitMask = Self.decorationMask
        return node
    }

    private func lineNode(_ points: [SCNVector3], _ color: NSColor) -> SCNNode {
        let source = SCNGeometrySource(vertices: points)
        let indices = (0..<UInt32(points.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let g = SCNGeometry(sources: [source], elements: [element])
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        g.materials = [m]
        let node = SCNNode(geometry: g)
        node.categoryBitMask = Self.decorationMask
        return node
    }

    private func compass() -> SCNNode {
        let text = SCNText(string: "N", extrusionDepth: 0)
        text.font = NSFont.boldSystemFont(ofSize: region == nil ? 1.4 : 4)
        text.flatness = 0.05
        let m = SCNMaterial()
        m.diffuse.contents = NSColor(srgbRed: 0.88, green: 0.64, blue: 0.29, alpha: 1)
        m.lightingModel = .constant
        text.materials = [m]
        let node = SCNNode(geometry: text)
        let (lo, hi) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0)
        let r = region.map { $0.region.radius + 4 } ?? max(build.size.x, build.size.z) / 2 + 3
        let y = region?.ground.map { $0.height(x: 0, z: r) + 6 } ?? 0.8
        node.simdPosition = SIMD3(0, y, -r)
        node.constraints = [SCNBillboardConstraint()]
        node.categoryBitMask = Self.decorationMask
        return node
    }
}

// MARK: - frames

/// Valheim (Unity) is left-handed with z north; SceneKit right-handed. Mirroring z
/// converts positions; rotations about x and y change sign, z keeps its own.
func sceneKitPosition(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, p.y, -p.z) }

/// Unity applies Euler angles Z, then X, then Y: q = qy · qx · qz.
func sceneKitOrientation(_ euler: SIMD3<Float>) -> simd_quatf {
    let qx = simd_quatf(angle: -euler.x.radians, axis: SIMD3(1, 0, 0))
    let qy = simd_quatf(angle: -euler.y.radians, axis: SIMD3(0, 1, 0))
    let qz = simd_quatf(angle: euler.z.radians, axis: SIMD3(0, 0, 1))
    return qy * qx * qz
}

extension Float {
    var radians: Float { self * .pi / 180 }
}

extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
