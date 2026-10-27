import AppKit
import SceneKit
import simd
import MuninCore

/// The game's ground: the exact terrain mesh, textured from the terrain material's
/// own layers, and the grass and ground cover the game would scatter on it.
///
/// Which layer belongs to which biome is not written anywhere outside the game's
/// compiled terrain shader; the mapping below was made by eye from the layers.
enum Ground {
    /// Layers of `terrain_d_array`, by index.
    enum Layer: Int, CaseIterable {
        case meadows = 0, forest = 1, dirt = 3, rock = 4, mountainRock = 5, ash = 7, plains = 8,
             sand = 9, swamp = 10, paved = 12, mistlands = 13, mistlandsRock = 14, snow = 15

        var uniform: String { "vbL\(rawValue)" }
    }

    // Per-vertex weights travel in the colour (4) and texture coordinates 1–4 (2 each):
    // meadows, forest, swamp, plains | snow, mistlands | ash, sand | dirt, cultivated | paved, –
    static let geometryModifier = """
        #pragma varyings
        float4 vbW0;
        float4 vbW1;
        float4 vbW2;
        float3 vbN;
        float2 vbXZ;
        #pragma body
        out.vbW0 = _geometry.color;
        out.vbW1 = float4(_geometry.texcoords[1], _geometry.texcoords[2]);
        out.vbW2 = float4(_geometry.texcoords[3], _geometry.texcoords[4]);
        out.vbN = _geometry.normal;
        out.vbXZ = _geometry.position.xz;
        """

    static func surfaceModifier(uvScale: Float) -> String {
        let args = Layer.allCases.map { "texture2d<float> \($0.uniform);" }.joined(separator: "\n")
        return """
        #pragma arguments
        \(args)
        #pragma body
        constexpr sampler s(filter::linear, mip_filter::linear, address::repeat);
        float2 uv = in.vbXZ * \(uvScale);
        float4 w0 = in.vbW0, w1 = in.vbW1, w2 = in.vbW2;
        float3 c = vbL0.sample(s, uv).rgb * w0.x
                 + vbL1.sample(s, uv).rgb * w0.y
                 + vbL10.sample(s, uv).rgb * w0.z
                 + vbL8.sample(s, uv).rgb * w0.w
                 + (float3(0.82, 0.86, 0.92) + (dot(vbL15.sample(s, uv * 0.25).rgb, float3(0.33)) - 0.5) * 0.12) * w1.x
                 + vbL13.sample(s, uv).rgb * w1.y
                 + vbL7.sample(s, uv).rgb * w1.z
                 + vbL9.sample(s, uv).rgb * w1.w
                 + vbL3.sample(s, uv).rgb * w2.x
                 + vbL3.sample(s, uv).rgb * 0.55 * w2.y
                 + vbL12.sample(s, uv).rgb * w2.z;
        float total = dot(w0, float4(1)) + dot(w1, float4(1)) + w2.x + w2.y + w2.z;
        c /= max(total, 0.001);
        // Steep ground turns to rock, of the kind the biome has.
        float steep = smoothstep(0.62, 0.48, normalize(in.vbN).y);
        float3 rock = vbL4.sample(s, uv * 0.5).rgb;
        rock = mix(rock, vbL5.sample(s, uv * 0.5).rgb, saturate(w1.x * 2));
        rock = mix(rock, vbL14.sample(s, uv * 0.5).rgb, saturate(w1.y * 2));
        rock = mix(rock, vbL7.sample(s, uv * 0.5).rgb, saturate(w1.z * 2));
        c = mix(c, rock, steep * (1 - saturate(w2.z * 2)));
        _surface.diffuse = float4(c, 1);
        """
    }

    /// Weights for one vertex: biome, beach near the waterline, then paint on top.
    static func weights(_ s: Terrain.Surface, heightAboveWater h: Float) -> [Float] {
        var w = [Float](repeating: 0, count: 12)
        let b = s.biome
        if b.contains(.meadows) { w[0] = 1 }
        if b.contains(.blackForest) { w[1] = 1 }
        if b.contains(.swamp) { w[2] = 1 }
        if b.contains(.plains) { w[3] = 1 }
        if b.contains(.mountain) || b.contains(.deepNorth) { w[4] = 1 }
        if b.contains(.mistlands) { w[5] = 1 }
        if b.contains(.ashLands) { w[6] = 1 }
        if b.contains(.ocean) || w[0..<7].allSatisfy({ $0 == 0 }) { w[7] = 1 }
        // Beaches: sand where the ground meets the sea (swamps stay muddy).
        if !b.contains(.swamp) {
            let beach = min(max((1.8 - h) / 1.8, 0), 1)
            for i in 0..<7 { w[i] *= 1 - beach }
            w[7] = max(w[7], beach)
        }
        let paint = min(s.paint.x + s.paint.y + s.paint.z, 1)
        if paint > 0 {
            for i in 0..<8 { w[i] *= 1 - paint }
            w[8] = s.paint.x; w[9] = s.paint.y; w[10] = s.paint.z
        }
        return w
    }

    static func node(_ field: Heightfield, waterLevel: Float, radius: Float, catalog: PieceCatalog) -> SCNNode? {
        guard let surface = field.surface, let layers = catalog.manifest.terrain else { return nil }
        var positions: [SCNVector3] = []
        var colors: [Float] = []
        var t = [[Float]](repeating: [], count: 5)
        for r in 0..<field.rows {
            for c in 0..<field.columns {
                let x = field.minX + Float(c) * field.cell, z = field.minZ + Float(r) * field.cell
                let h = field.height(column: c, row: r)
                positions.append(SCNVector3(sceneKitPosition(SIMD3(x, h, z))))
                let w = weights(surface[r * field.columns + c], heightAboveWater: h - waterLevel)
                colors += w[0..<4]
                t[0] += [x, z]
                t[1] += w[4..<6]; t[2] += w[6..<8]; t[3] += w[8..<10]; t[4] += w[10..<12]
            }
        }
        var indices: [UInt32] = []
        let cols = UInt32(field.columns)
        func inside(_ i: UInt32) -> Bool {
            let p = positions[Int(i)]
            return Float(p.x * p.x + p.z * p.z) <= radius * radius
        }
        for r in 0..<UInt32(field.rows - 1) {
            for c in 0..<(cols - 1) {
                let a = r * cols + c, b = a + 1, d = a + cols, e = d + 1
                guard inside(a) || inside(b) || inside(d) || inside(e) else { continue }
                indices += [a, b, d, b, e, d]
            }
        }
        // Round edge: pull the outer ring onto the circle.
        for i in positions.indices {
            let d = Float(positions[i].x * positions[i].x + positions[i].z * positions[i].z).squareRoot()
            if d > radius { positions[i].x *= CGFloat(radius / d); positions[i].z *= CGFloat(radius / d) }
        }
        let normals = BuildScene.normals(positions, indices)
        var sources = [
            SCNGeometrySource(vertices: positions),
            SCNGeometrySource(normals: normals),
            catalog.source(colors, .color, components: 4),
        ]
        for set in t { sources.append(catalog.source(set, .texcoord, components: 2)) }
        let geometry = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])

        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.roughness.contents = NSNumber(value: 0.95)
        m.metalness.contents = NSNumber(value: 0)
        m.diffuse.contents = NSColor.white
        for layer in Layer.allCases where layer.rawValue < layers.diffuse.count {
            if let image = catalog.image(named: layers.diffuse[layer.rawValue]) {
                m.setValue(SCNMaterialProperty(contents: image), forKey: layer.uniform)
            }
        }
        m.shaderModifiers = [.geometry: geometryModifier, .surface: surfaceModifier(uvScale: layers.uvScale)]
        geometry.materials = [m]
        let node = SCNNode(geometry: geometry)
        node.name = "ground"
        node.categoryBitMask = BuildScene.decorationMask
        return node
    }

    /// Grass and ground cover, merged into one geometry per kind so tens of thousands
    /// of tufts cost a handful of draw calls.
    static func clutterNode(_ field: Heightfield, origin: SIMD3<Float>, waterLevel: Float, radius: Float,
                            catalog: PieceCatalog) -> SCNNode? {
        guard let settings = catalog.manifest.clutter else { return nil }
        let instances = field.scatter(settings, origin: origin, waterLevel: waterLevel, radius: radius)
        if ProcessInfo.processInfo.environment["MUNIN_DEBUG"] != nil {
            let counts = Dictionary(grouping: instances, by: \.rule).map { (settings.rules[$0.key].name, $0.value.count) }
            print("clutter:", counts.sorted { $0.1 > $1.1 })
        }
        let node = SCNNode()
        node.name = "grass"
        node.categoryBitMask = BuildScene.decorationMask
        for (index, rule) in settings.rules.enumerated() {
            let mine = instances.filter { $0.rule == index }
            guard !mine.isEmpty else { continue }
            for part in catalog.partData(for: rule.prefab) {
                guard let geometry = merged(part, mine, origin: origin) else { continue }
                let child = SCNNode(geometry: geometry)
                child.castsShadow = false
                child.categoryBitMask = BuildScene.decorationMask
                node.addChildNode(child)
            }
        }
        return node
    }

    private static func merged(_ part: PieceCatalog.PartData, _ instances: [ClutterInstance], origin: SIMD3<Float>) -> SCNGeometry? {
        let n = part.positions.count / 3
        guard n > 0 else { return nil }
        var pos = [Float](), nrm = [Float](), uv = [Float](), idx = [UInt32](), colors = [Float]()
        // Sway weight per vertex: 0 at the root, 1 at the tip.
        let ys = stride(from: 1, to: part.positions.count, by: 3).map { part.positions[$0] }
        let low = ys.min() ?? 0, span = max((ys.max() ?? 1) - low, 0.01)
        let sway: [Float] = ys.flatMap { y -> [Float] in [(y - low) / span, 0] }
        var swayAll = [Float]()
        pos.reserveCapacity(n * 3 * instances.count)
        uv.reserveCapacity(n * 2 * instances.count)
        idx.reserveCapacity(part.indices.count * instances.count)
        for inst in instances {
            let base = UInt32(pos.count / 3)
            let q = sceneKitOrientation(SIMD3(0, inst.yaw, 0))
            let at = sceneKitPosition(inst.position)
            for v in 0..<n {
                let p = q.act(SIMD3(part.positions[v * 3], part.positions[v * 3 + 1], part.positions[v * 3 + 2]) * inst.scale) + at
                pos.append(p.x); pos.append(p.y); pos.append(p.z)
                if part.cutoff != nil {
                    // Like the game's grass shader: blades lit as the ground under them,
                    // not by their own crossed quads (half of which face away from the sun).
                    nrm.append(0); nrm.append(1); nrm.append(0)
                } else if let normals = part.normals {
                    let nn = q.act(SIMD3(normals[v * 3], normals[v * 3 + 1], normals[v * 3 + 2]))
                    nrm.append(nn.x); nrm.append(nn.y); nrm.append(nn.z)
                }
            }
            uv.append(contentsOf: part.uvs)
            swayAll.append(contentsOf: sway)
            idx.append(contentsOf: part.indices.lazy.map { $0 + base })
            if let (map, scale) = part.terrainColor {
                // As the game's grass shader: colour from the map at the tuft's world position.
                // SceneKit takes vertex colours as sRGB, like the map itself.
                let c = map.color(u: (inst.position.x + origin.x) * scale, v: (inst.position.z + origin.z) * scale)
                for _ in 0..<n { colors.append(c.x); colors.append(c.y); colors.append(c.z); colors.append(1) }
            }
        }
        let source = { (values: [Float], semantic: SCNGeometrySource.Semantic, k: Int) in
            SCNGeometrySource(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: semantic,
                              vectorCount: values.count / k, usesFloatComponents: true, componentsPerVector: k,
                              bytesPerComponent: 4, dataOffset: 0, dataStride: k * 4)
        }
        var sources = [source(pos, .vertex, 3), source(uv, .texcoord, 2), source(swayAll, .texcoord, 2)]
        if nrm.count == pos.count { sources.append(source(nrm, .normal, 3)) }
        if colors.count == pos.count / 3 * 4 { sources.append(source(colors, .color, 4)) }
        let element = SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) },
                                         primitiveType: .triangles, primitiveCount: idx.count / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        // Blades are thin alpha cut-outs: mipmapping averages their alpha away, while no
        // mipmaps shimmer. Keep the mipmaps and lower the cutoff with distance instead.
        part.material.shaderModifiers = [.geometry: Wind.grass]
        if let cutoff = part.cutoff {
            part.material.shaderModifiers?[.fragment] = """
                #pragma arguments
                float alphaCutoff;
                #pragma body
                float near = saturate(1.0 - length(_surface.position) / 70.0);
                if (_output.color.a < alphaCutoff * (0.3 + 0.7 * near)) { discard_fragment(); }
                _output.color.a = 1.0;
                """
            part.material.setValue(NSNumber(value: cutoff), forKey: "alphaCutoff")
        }
        geometry.materials = [part.material]
        return geometry
    }
}

/// Wind and water as vertex and surface shaders, animated by SceneKit's frame time.
enum Wind {
    /// Grass and ground cover: tips move, roots stay (texture coordinate 1 is the
    /// height within the tuft); a slow gust rolls over the field.
    static let grass = """
        #pragma body
        float w = _geometry.texcoords[1].x;
        float t = scn_frame.time;
        float3 p = _geometry.position.xyz;
        float gust = sin(t * 0.6 + p.x * 0.05 + p.z * 0.03) * 0.5 + 0.5;
        _geometry.position.x += (sin(t * 2.1 + p.x * 0.6 + p.z * 0.4) * 0.06 + 0.06 * gust) * w;
        _geometry.position.z += cos(t * 1.7 + p.z * 0.5 + p.x * 0.3) * 0.05 * w;
        """

    /// Trees and bushes: sway grows with height, each tree out of step with the next.
    static let tree = """
        #pragma body
        float t = scn_frame.time;
        float4 at = scn_node.modelTransform * float4(0.0, 0.0, 0.0, 1.0);
        float h = max(_geometry.position.y, 0.0);
        float k = h * h * 0.0015;
        float phase = at.x * 0.13 + at.z * 0.11;
        _geometry.position.x += (sin(t * 1.1 + phase) * 0.6 + sin(t * 2.9 + phase * 1.7 + h) * 0.2) * k;
        _geometry.position.z += cos(t * 0.9 + phase) * 0.4 * k;
        """

    static let waterGeometry = """
        #pragma varyings
        float2 vbW;
        #pragma body
        out.vbW = _geometry.position.xz;
        """

    /// Ripples: the surface normal wobbles with a few travelling waves.
    static let waterSurface = """
        #pragma body
        float t = scn_frame.time;
        float2 p = in.vbW;
        float3 n = normalize(float3(sin(p.x * 0.9 + t * 1.3) * 0.08 + sin(p.y * 1.7 - t * 0.8) * 0.05,
                                    1.0,
                                    cos(p.y * 1.1 + t * 1.1) * 0.08 + sin((p.x + p.y) * 0.6 + t * 0.7) * 0.05));
        _surface.normal = normalize((scn_node.normalTransform * float4(n, 0.0)).xyz);
        """
}
