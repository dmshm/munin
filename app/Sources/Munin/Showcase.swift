import AppKit
import Metal
import SceneKit
import MuninCore

/// `Munin --showcase <out-dir>` renders the README's pictures without anyone's world:
/// the example watchtower on a made-up meadow hill, with a pond, a campfire, a stake
/// wall and the game's own trees, rocks and grass around it.
enum Showcase {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--showcase"), args.count > i + 1 else { return }
        do {
            try run(out: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("showcase failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Where the scene pretends to be: it only shifts the grass's colour variation.
    static let origin = SIMD3<Float>(612, 0, 388)
    static let radius: Float = 46

    static func run(out: URL) throws {
        guard let catalog = try? PieceCatalog() else { throw CocoaError(.fileNoSuchFile) }
        guard let url = Resource.url("watchtower", "json") else { throw CocoaError(.fileNoSuchFile) }
        let tower = try BuildFile.load(Data(contentsOf: url))
        let ground = terrain()
        let content = RegionContent(region: Region(center: SIMD2(origin.x, origin.z), radius: radius),
                                    build: Build(name: "Showcase", worldPieces: pieces(tower, ground), origin: origin),
                                    props: props(ground), ground: ground, waterLevel: -4)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Each shot gets a fresh scene, so time of day, layers and camera never leak between them.
        func shot(_ name: String, hour: Float, size: CGSize, rig: CameraRig, level: ((BuildScene) -> Int)? = nil,
                  depthOfField: Bool = false) throws {
            let scene = BuildScene(build: content.build, catalog: catalog, region: content)
            scene.apply(level: level?(scene) ?? scene.levels.count - 1, ghosts: true, focus: nil)
            scene.setTime(hour)
            scene.apply(rig)
            if depthOfField, let camera = scene.camera.camera {
                camera.wantsDepthOfField = true
                camera.focusDistance = CGFloat(rig.distance)
                camera.fStop = 2.4
                camera.apertureBladeCount = 6
            }
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = scene.scene
            renderer.pointOfView = scene.camera
            // Run three seconds of small frames first: particles only exist once the
            // simulation has stepped through time, so this is what makes the flames rise.
            for frame in 0..<90 { _ = renderer.snapshot(atTime: Double(frame) / 30, with: CGSize(width: 64, height: 32), antialiasingMode: .none) }
            let image = renderer.snapshot(atTime: 3, with: size, antialiasingMode: .multisampling4X)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else { return }
            try jpeg.write(to: out.appendingPathComponent("\(name).jpg"))
            print("wrote \(name).jpg")
        }

        let towerHeight = tower.size.y
        let wide = CGSize(width: 2400, height: 1200), card = CGSize(width: 1500, height: 1000)
        let base = ground.height(x: 0, z: 0)
        try shot("hero", hour: 17.4, size: wide,
                 rig: CameraRig(target: SIMD3(1, base + towerHeight * 0.42, 0), yaw: Float(38).radians, pitch: Float(11).radians, distance: 30),
                 depthOfField: true)
        try shot("night", hour: 22.5, size: card,
                 rig: CameraRig(target: SIMD3(3, base + 2.6, 2.5), yaw: Float(52).radians, pitch: Float(16).radians, distance: 19))
        try shot("layers", hour: 11, size: card,
                 rig: CameraRig(target: SIMD3(0, base + towerHeight * 0.4, 0), yaw: Float(-35).radians, pitch: Float(30).radians, distance: 21),
                 level: { $0.levels.count / 2 })
        try shot("plan", hour: 12.5, size: card,
                 rig: CameraRig(target: SIMD3(-3, base, -2), yaw: 0, pitch: Float(89).radians, distance: 62))
    }

    // MARK: - the scene

    /// Smooth, deterministic bumps: sums of sines rather than random noise.
    private static func hills(_ x: Float, _ z: Float) -> Float {
        sin(x * 0.11 + 1.3) * cos(z * 0.09 - 0.4) * 1.6 + sin((x + z) * 0.05) * 1.4 + cos(x * 0.23 - z * 0.17) * 0.35
    }

    /// A meadow hill, flattened where the tower stands, with a pond to the north-west
    /// that dips below the water line.
    static func terrain() -> Heightfield {
        let n = Int(radius * 2) + 9
        let min = -Float(n / 2)
        var heights: [Float] = [], surface: [Terrain.Surface] = []
        for r in 0..<n {
            for c in 0..<n {
                let x = min + Float(c), z = min + Float(r)
                let d = (x * x + z * z).squareRoot()
                let flat = smooth(d, from: 7, to: 15)
                var h = hills(x, z) * flat + (1 - flat) * hills(0, 0) * 0.3
                // The hill rises away from the clearing.
                h += smooth(d, from: 18, to: 44) * 3.5
                // A pond with an uneven shore, not a perfect circle.
                let pond = SIMD2<Float>(x + 20, z - 15)
                let bearing = atan2(pond.y, pond.x)
                let p = (pond * pond).sum().squareRoot() * (1 + 0.22 * sin(bearing * 3 + 0.7) + 0.12 * sin(bearing * 5 - 1.1))
                h -= (1 - smooth(p, from: 3, to: 12)) * 6
                heights.append(h)
                // Trodden dirt around the tower and the fire.
                let fire = SIMD2<Float>(x - 7, z + 5)
                let dirt = max(1 - smooth(d, from: 3.5, to: 7.5), 1 - smooth((fire * fire).sum().squareRoot(), from: 2, to: 4.5))
                // Forest beyond the clearing, so the game's forest grass grows there.
                let forest: Float = d > 24 ? 0.9 : 1.6
                surface.append(Terrain.Surface(biome: .meadows, mask: .zero, paint: SIMD3(dirt * 0.95, 0, 0), forest: forest))
            }
        }
        return Heightfield(minX: min, minZ: min, cell: 1, columns: n, rows: n, heights: heights, surface: surface)
    }

    private static func smooth(_ v: Float, from a: Float, to b: Float) -> Float {
        let t = Swift.min(Swift.max((v - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The watchtower, a campfire with two benches, a chest, a cart, two torches
    /// and an arc of stake wall behind; positions in the world, standing on the ground.
    static func pieces(_ tower: Build, _ ground: Heightfield) -> [Piece] {
        func at(_ name: String, _ x: Float, _ z: Float, yaw: Float = 0) -> Piece {
            var piece = Piece(prefab: stableHash(name), position: origin + SIMD3(x, ground.height(x: x, z: z), z),
                              rotation: SIMD3(0, yaw, 0), creator: 1)
            piece.fuel = 5 // fires burn only with fuel, as in the save
            return piece
        }
        let base = ground.height(x: 0, z: 0)
        var all = tower.pieces.map { p -> Piece in
            var q = p
            q.position = origin + p.position + SIMD3(0, base, 0)
            q.creator = 1
            return q
        }
        all += [
            at("fire_pit", 7, -5),
            at("piece_logbench01", 9.4, -3.2, yaw: 235),
            at("piece_logbench01", 4.6, -7.4, yaw: 55),
            at("piece_chest_wood", -4.2, -3.6, yaw: 180),
            at("Cart", -9, -8, yaw: 30),
            at("piece_groundtorch_wood", 3.2, -4.2),
            at("piece_groundtorch_wood", -3.2, -4.2),
        ]
        // A palisade arc behind the tower, to the north, facing outwards.
        for i in 0..<16 {
            let a = Float(i) / 15 * Float(150).radians + Float(15).radians
            let x = cos(a) * 16, z = sin(a) * 16
            all.append(at("stake_wall", x, z, yaw: 90 - a * 180 / .pi))
        }
        return all
    }

    /// A wood behind the tower, bushes, stones and stumps fringing the clearing, and
    /// the south left open for the cameras; positions relative to the origin, as a
    /// region's props are. Valheim's trees are big (a beech spreads 18 m), so the wood
    /// keeps its distance.
    static func props(_ ground: Heightfield) -> [Piece] {
        let trees = ["Beech1", "Birch1", "FirTree", "Pinetree_01", "Birch2", "FirTree", "Beech1", "Pinetree_01"]
        let fringe = ["Bush01", "RaspberryBush", "Rock_3", "Beech_small1", "BlueberryBush", "Rock_7", "Beech_Stub", "Bush02_en",
                      "Pickable_StoneRock", "FirTree_small"]
        var rng = SystemRandomNumberGenerator.seeded(7)
        var result: [Piece] = []
        func place(_ name: String, angle degrees: Float, distance d: Float, scale: Float) {
            let a = degrees.radians
            let x = cos(a) * d, z = sin(a) * d
            let pond = SIMD2<Float>(x + 20, z - 15)
            guard (pond * pond).sum() > 12 * 12 else { return } // keep the pond open
            result.append(Piece(prefab: stableHash(name), position: SIMD3(x, ground.height(x: x, z: z), z),
                                rotation: SIMD3(0, rng.next(in: 0...360), 0), scale: SIMD3(repeating: scale)))
        }
        // The wood: north and the flanks (angles from east, anticlockwise; north is 90°).
        for i in 0..<30 {
            let angle = -25 + Float(i) / 29 * 230 + rng.next(in: -3...3)
            place(trees[i % trees.count], angle: angle, distance: rng.next(in: 30...44), scale: rng.next(in: 0.85...1.1))
        }
        // The fringe: all round, but sparse to the south where the cameras stand.
        for i in 0..<40 {
            let angle = Float(i) / 40 * 360 + rng.next(in: -4...4)
            let south = angle > 215 && angle < 325
            if south && i % 3 != 0 { continue }
            place(fringe[i % fringe.count], angle: angle, distance: rng.next(in: south ? 22...26 : 18...24),
                  scale: rng.next(in: 0.85...1.2))
        }
        return result
    }
}

/// The same pictures on every run.
private struct SeededRandom {
    var state: UInt64
    mutating func nextUnit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
    mutating func next(in range: ClosedRange<Float>) -> Float { range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound) }
}

private extension SystemRandomNumberGenerator {
    static func seeded(_ seed: UInt64) -> SeededRandom { SeededRandom(state: seed) }
}
