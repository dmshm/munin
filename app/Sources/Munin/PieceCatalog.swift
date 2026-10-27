import AppKit
import SceneKit
import MuninCore

/// Real meshes for build pieces and props (trees, rocks…), as extracted from the
/// local game install by `tools/extract_meshes.py` into Application Support. The app
/// ships without any game assets; without a catalog every piece draws as a plain box.
final class PieceCatalog {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Munin/catalog")

    struct Manifest: Decodable {
        var version: Int
        var pieces: [String: Entry]
        /// The terrain material's texture layers (catalog version 3+).
        var terrain: TerrainLayers?
        /// The game's grass and ground-cover rules (catalog version 3+).
        var clutter: ClutterSettings?
    }

    struct TerrainLayers: Decodable {
        /// Texture repeats per metre.
        var uvScale: Float
        var diffuse: [String]
        var normal: [String]
    }

    struct Entry: Decodable {
        var parts: [Part]
        var bounds: [[Float]]
        /// "piece", "prop", "creature" or "item"; absent in catalogs from before props were extracted.
        var kind: String?
        /// The prefab's light sources, relative to its pivot (Valheim frame).
        var lights: [LightDef]?
        /// Present for things that burn fuel: fires, torches, braziers.
        var fire: FireDef?
    }

    struct LightDef: Decodable {
        var position: [Float]
        var color: [Float]
        var intensity: Float
        var range: Float
        var shadows: Bool?
        var flicker: Flicker?
        /// In a subtree the game turns on only while the thing burns or works.
        var switched: Bool?

        struct Flicker: Decodable {
            var intensity: Float
            var speed: Float
            var movement: Float?
        }
    }

    struct FireDef: Decodable {
        var startFuel: Float
        var maxFuel: Float
        var infiniteFuel: Bool
    }

    struct Part: Decodable {
        var count: Int
        var indices: Int
        var color: [Float]
        var texture: String?
        var positions: Int
        var normals: Int?
        var uvs: Int
        var indexOffset: Int
        var normalMap: String?
        /// Alpha below this is a hole (thatch edges, leaves). Nil: the texture is opaque.
        var cutoff: Float?
        /// The game samples this texture without filtering — its crisp, pixelated look.
        var point: Bool?
        /// World-space colour map that tints this part (grass), and its scale per metre.
        var terrainColor: String?
        var terrainColorScale: Float?
    }

    let directory: URL
    let manifest: Manifest
    private let blob: Data
    private var geometries: [String: SCNGeometry] = [:]
    private var textures: [String: NSImage] = [:]
    /// Scenes are built off the main thread; the caches below are shared between them.
    private let lock = NSRecursiveLock()

    init(directory: URL = PieceCatalog.defaultDirectory) throws {
        self.directory = directory
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("catalog.json")))
        blob = try Data(contentsOf: directory.appendingPathComponent("catalog.bin"), options: .mappedIfSafe)
        PrefabNames.shared.add(manifest.pieces.keys)
    }

    var count: Int { manifest.pieces.count }

    func kind(of name: String?) -> String? { name.flatMap { manifest.pieces[$0]?.kind } }

    /// Which of a world's prefabs to draw around a build (props and creatures with real
    /// meshes; never dropped items), and which trace the ground — scenery that does not
    /// fly or swim.
    func classify(_ objects: [Piece]) -> (props: Set<Int32>, ground: Set<Int32>) {
        let airborne = ["crow", "bat", "seagal", "gull", "bird", "deathsquito", "wraith", "drake", "hatchling", "ghost",
                        "odin", "fish", "serpent", "leviathan", "ship", "karve", "raft", "trailership", "bonemaw", "volture"]
        var props = Set<Int32>(), ground = Set<Int32>()
        for prefab in Set(objects.lazy.filter { $0.creator == nil }.map(\.prefab)) {
            let name = PrefabNames.shared.name(for: prefab)
            let kind = kind(of: name)
            guard kind == "prop" || kind == "creature", let lower = name?.lowercased() else { continue }
            props.insert(prefab)
            // Trees, bushes and rocks stand on the terrain; ruins and the like stand tall.
            if kind == "prop" && WorldMap.kind(of: name) != .other && !airborne.contains(where: lower.contains) {
                ground.insert(prefab)
            }
        }
        return (props, ground)
    }

    /// Geometry in SceneKit's frame, shared by every node showing this piece.
    func geometry(for name: String?) -> SCNGeometry? {
        guard let name, let entry = manifest.pieces[name] else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = geometries[name] { return cached }
        let parts = entry.parts.map(makeGeometry)
        let geometry = parts.count == 1 ? parts[0] : merge(parts)
        geometries[name] = geometry
        return geometry
    }

    private func floats(at offset: Int, count: Int) -> [Float] {
        blob.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: offset + $0 * 4, as: Float.self) }
        }
    }

    private func uints(at offset: Int, count: Int) -> [UInt32] {
        blob.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: offset + $0 * 4, as: UInt32.self) }
        }
    }

    /// A part's arrays in SceneKit's frame. Unity is left-handed, SceneKit right-handed;
    /// mirroring z converts between them, which also reverses triangle winding. Unity's
    /// v runs bottom-up, Metal's top-down.
    struct PartData {
        var positions: [Float]
        var uvs: [Float]
        var normals: [Float]?
        var indices: [UInt32]
        var material: SCNMaterial
        var terrainColor: (map: ColorMap, scale: Float)?
        var cutoff: Float?
    }

    func partData(for name: String) -> [PartData] {
        guard let entry = manifest.pieces[name] else { return [] }
        lock.lock(); defer { lock.unlock() }
        return entry.parts.map(partData)
    }

    private func partData(_ part: Part) -> PartData {
        var pos = floats(at: part.positions, count: part.count * 3)
        for i in stride(from: 2, to: pos.count, by: 3) { pos[i] = -pos[i] }
        var uv = floats(at: part.uvs, count: part.count * 2)
        for i in stride(from: 1, to: uv.count, by: 2) { uv[i] = 1 - uv[i] }
        var idx = uints(at: part.indexOffset, count: part.indices)
        for t in stride(from: 0, to: idx.count - 2, by: 3) { idx.swapAt(t + 1, t + 2) }
        var nrm: [Float]?
        if let offset = part.normals {
            nrm = floats(at: offset, count: part.count * 3)
            for i in stride(from: 2, to: nrm!.count, by: 3) { nrm![i] = -nrm![i] }
        }
        let tint = part.terrainColor.flatMap { colorMap($0) }.map { ($0, part.terrainColorScale ?? 0.01) }
        return PartData(positions: pos, uvs: uv, normals: nrm, indices: idx, material: material(part), terrainColor: tint,
                        cutoff: part.cutoff)
    }

    private var colorMaps: [String: ColorMap] = [:]

    private func colorMap(_ name: String) -> ColorMap? {
        if let cached = colorMaps[name] { return cached }
        guard let image = texture(name), let map = ColorMap(image) else { return nil }
        colorMaps[name] = map
        return map
    }

    func image(named name: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return texture(name)
    }

    private func makeGeometry(_ part: Part) -> SCNGeometry {
        let data = partData(part)
        let idx = data.indices
        var sources = [
            source(data.positions, .vertex, components: 3),
            source(data.uvs, .texcoord, components: 2),
        ]
        if let nrm = data.normals {
            sources.append(source(nrm, .normal, components: 3))
        }
        let element = SCNGeometryElement(
            data: idx.withUnsafeBufferPointer { Data(buffer: $0) },
            primitiveType: .triangles,
            primitiveCount: idx.count / 3,
            bytesPerIndex: 4
        )
        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = [data.material]
        return geometry
    }

    func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
        SCNGeometrySource(
            data: values.withUnsafeBufferPointer { Data(buffer: $0) },
            semantic: semantic,
            vectorCount: values.count / components,
            usesFloatComponents: true,
            componentsPerVector: components,
            bytesPerComponent: 4,
            dataOffset: 0,
            dataStride: components * 4
        )
    }

    private func material(_ part: Part) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.roughness.contents = NSNumber(value: 0.88)
        m.metalness.contents = NSNumber(value: 0)
        m.isDoubleSided = true // plenty of Valheim's thatch, trim and leaves are single planes
        let color = NSColor(srgbRed: CGFloat(part.color[0]), green: CGFloat(part.color[1]), blue: CGFloat(part.color[2]), alpha: 1)
        if let name = part.texture, let image = texture(name) {
            m.diffuse.contents = image
            configure(m.diffuse, point: part.point ?? false)
        } else {
            m.diffuse.contents = color
        }
        if let name = part.normalMap, let image = texture(name) {
            m.normal.contents = image
            configure(m.normal, point: false)
        }
        if let cutoff = part.cutoff {
            // Alpha test, as the game does: cut the holes, keep the rest opaque so
            // nothing needs depth sorting.
            // The cutoff is an argument, not text, so every cut-out shares one shader.
            m.shaderModifiers = [.fragment: Self.cutoutModifier]
            m.setValue(NSNumber(value: cutoff), forKey: "alphaCutoff")
            m.blendMode = .replace
        }
        return m
    }

    static let cutoutModifier = """
        #pragma arguments
        float alphaCutoff;
        #pragma body
        if (_output.color.a < alphaCutoff) { discard_fragment(); }
        _output.color.a = 1.0;
        """

    private func configure(_ property: SCNMaterialProperty, point: Bool) {
        property.wrapS = .repeat
        property.wrapT = .repeat
        property.magnificationFilter = point ? .nearest : .linear
        property.minificationFilter = .linear
        property.mipFilter = .linear
        property.maxAnisotropy = 16
    }

    private func texture(_ name: String) -> NSImage? {
        if let cached = textures[name] { return cached }
        let image = NSImage(contentsOf: directory.appendingPathComponent("textures").appendingPathComponent(name))
        textures[name] = image
        return image
    }

    /// Several single-element geometries into one, so a piece is one node.
    private func merge(_ parts: [SCNGeometry]) -> SCNGeometry {
        // SceneKit pairs element i with material i, but all elements index into one
        // set of sources — so concatenate the sources and rebase the indices.
        var pos: [Float] = [], nrm: [Float] = [], uv: [Float] = []
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        var hasNormals = true
        for g in parts {
            let base = UInt32(pos.count / 3)
            pos += read(g, .vertex)
            uv += read(g, .texcoord)
            let n = read(g, .normal)
            if n.isEmpty { hasNormals = false } else { nrm += n }
            let e = g.elements[0]
            var idx = [UInt32](repeating: 0, count: e.primitiveCount * 3)
            _ = idx.withUnsafeMutableBytes { e.data.copyBytes(to: $0) }
            for i in idx.indices { idx[i] += base }
            elements.append(SCNGeometryElement(
                data: idx.withUnsafeBufferPointer { Data(buffer: $0) },
                primitiveType: .triangles, primitiveCount: e.primitiveCount, bytesPerIndex: 4))
            materials.append(g.materials[0])
        }
        var sources = [source(pos, .vertex, components: 3), source(uv, .texcoord, components: 2)]
        if hasNormals { sources.append(source(nrm, .normal, components: 3)) }
        let merged = SCNGeometry(sources: sources, elements: elements)
        merged.materials = materials
        return merged
    }

    private func read(_ g: SCNGeometry, _ semantic: SCNGeometrySource.Semantic) -> [Float] {
        guard let s = g.sources(for: semantic).first else { return [] }
        var out = [Float](repeating: 0, count: s.vectorCount * s.componentsPerVector)
        _ = out.withUnsafeMutableBytes { s.data.copyBytes(to: $0) }
        return out
    }
}

/// Stand-in for pieces the catalog does not have (usually modded ones): a box,
/// loud enough to notice.
func placeholderGeometry() -> SCNGeometry {
    let box = SCNBox(width: 0.8, height: 0.8, length: 0.8, chamferRadius: 0.05)
    let m = SCNMaterial()
    m.diffuse.contents = NSColor(srgbRed: 0.75, green: 0.3, blue: 0.65, alpha: 1)
    m.lightingModel = .lambert
    box.materials = [m]
    return box
}

/// A texture's pixels on the CPU, for colouring vertices from it.
struct ColorMap {
    let width: Int, height: Int
    private let pixels: [UInt8]

    init?(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        width = cg.width
        height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = data
    }

    /// Wrapped lookup at texture coordinates (Unity's: v up), as sRGB 0…1.
    func color(u: Float, v: Float) -> SIMD3<Float> {
        let x = ((Int((u - u.rounded(.down)) * Float(width)) % width) + width) % width
        let y = height - 1 - ((Int((v - v.rounded(.down)) * Float(height)) % height) + height) % height
        let i = (y * width + x) * 4
        return SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
    }
}
