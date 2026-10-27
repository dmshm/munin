import Foundation

/// One of the game's grass and ground-cover rules (its `ClutterSystem`), as extracted
/// by tools/extract_meshes.py. The game scatters these at runtime, nothing is saved,
/// so they are scattered again here by the same rules.
public struct ClutterRule: Decodable {
    public var name: String
    /// Catalog entry with the mesh.
    public var prefab: String
    public var biome: UInt16
    /// Instances per patch (8 × 8 m in the game).
    public var amount: Int
    public var scaleMin: Float, scaleMax: Float
    public var minTilt: Float, maxTilt: Float
    /// Height above sea level, metres.
    public var minAlt: Float, maxAlt: Float
    public var onUncleared: Int, onCleared: Int
    public var inForest: Int
    public var forestTresholdMin: Float, forestTresholdMax: Float
    public var fractalScale: Float, fractalOffset: Float
    public var fractalTresholdMin: Float, fractalTresholdMax: Float
    public var snapToWater: Int
}

public struct ClutterSettings: Decodable {
    public var patchSize: Float
    public var waterLevel: Float
    public var rules: [ClutterRule]
}

public struct ClutterInstance {
    public var rule: Int
    /// Relative to the region origin, Valheim frame.
    public var position: SIMD3<Float>
    public var yaw: Float
    public var scale: Float
}

extension Heightfield {
    /// Where the clutter goes, on exact terrain only (an estimate has no biomes).
    /// Deterministic: the same region always grows the same grass.
    ///
    /// At the game's density; past `budget` instances, thinned evenly.
    public func scatter(_ settings: ClutterSettings, origin: SIMD3<Float>, waterLevel: Float,
                        radius: Float, budget: Int = 150_000) -> [ClutterInstance] {
        guard let surface else { return [] }
        let patch = settings.patchSize

        var out: [ClutterInstance] = []
        let lo = -radius, hi = radius
        var pz = (lo / patch).rounded(.down) * patch
        while pz < hi {
            var px = (lo / patch).rounded(.down) * patch
            while px < hi {
                for (index, rule) in settings.rules.enumerated() {
                    var rng = SplitMix(seed: UInt64(bitPattern: Int64(Int32(px + origin.x) &* 73_856_093 ^ Int32(pz + origin.z) &* 19_349_663))
                                       ^ UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15)
                    for _ in 0..<rule.amount {
                        let x = px + rng.unit() * patch, z = pz + rng.unit() * patch
                        let yaw = rng.unit() * 360
                        let scale = rule.scaleMin + rng.unit() * (rule.scaleMax - rule.scaleMin)
                        guard x * x + z * z <= radius * radius,
                              let p = place(rule, x: x, z: z, origin: origin, waterLevel: waterLevel, surface: surface)
                        else { continue }
                        out.append(ClutterInstance(rule: index, position: p, yaw: yaw, scale: scale))
                    }
                }
                px += patch
            }
            pz += patch
        }
        guard out.count > budget else { return out }
        let step = Double(out.count) / Double(budget)
        return (0..<budget).map { out[Int(Double($0) * step)] }
    }

    private func place(_ rule: ClutterRule, x: Float, z: Float, origin: SIMD3<Float>, waterLevel: Float,
                       surface: [Terrain.Surface]) -> SIMD3<Float>? {
        let c = Int(((x - minX) / cell).rounded()), r = Int(((z - minZ) / cell).rounded())
        guard c > 0, r > 0, c < columns - 1, r < rows - 1 else { return nil }
        let s = surface[r * columns + c]
        guard s.biome.rawValue & rule.biome != 0 else { return nil }

        // Cleared ground is anything painted: dirt, cultivated, paved.
        let cleared = max(s.paint.x, s.paint.y, s.paint.z) > 0.5
        if cleared && rule.onCleared == 0 { return nil }
        if !cleared && rule.onUncleared == 0 { return nil }

        let y = height(x: x, z: z)
        let altitude = y - waterLevel
        guard altitude >= rule.minAlt, altitude <= rule.maxAlt else { return nil }

        // Slope from the neighbouring vertices.
        let dx = (height(column: c + 1, row: r) - height(column: c - 1, row: r)) / (2 * cell)
        let dz = (height(column: c, row: r + 1) - height(column: c, row: r - 1)) / (2 * cell)
        let tilt = atan(sqrt(dx * dx + dz * dz)) * 180 / .pi
        guard tilt >= rule.minTilt, tilt <= rule.maxTilt else { return nil }

        if rule.inForest != 0, !(s.forest >= rule.forestTresholdMin && s.forest <= rule.forestTresholdMax) { return nil }

        if rule.fractalScale > 0 {
            // The game's noise is internal; a three-octave value noise at the same
            // scale gives the same kind of patchiness.
            let wx = (x + origin.x) * 0.01 * rule.fractalScale + rule.fractalOffset
            let wz = (z + origin.z) * 0.01 * rule.fractalScale
            let f = fbm(wx, wz) * 2
            guard f >= rule.fractalTresholdMin, f <= rule.fractalTresholdMax else { return nil }
        }

        return SIMD3(x, rule.snapToWater != 0 ? waterLevel : y, z)
    }
}

/// Small, fast, seedable random numbers; placement must not change between runs.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

/// Value noise, 0…1.
func noise(_ x: Float, _ z: Float) -> Float {
    func hash(_ i: Int32, _ j: Int32) -> Float {
        var h = UInt32(bitPattern: i &* 374_761_393 &+ j &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Float(h ^ (h >> 16)) / Float(UInt32.max)
    }
    let i = Int32(x.rounded(.down)), j = Int32(z.rounded(.down))
    let fx = x - Float(i), fz = z - Float(j)
    let sx = fx * fx * (3 - 2 * fx), sz = fz * fz * (3 - 2 * fz)
    let a = hash(i, j), b = hash(i + 1, j), c = hash(i, j + 1), d = hash(i + 1, j + 1)
    return (a * (1 - sx) + b * sx) * (1 - sz) + (c * (1 - sx) + d * sx) * sz
}

/// Three octaves of value noise, 0…1.
func fbm(_ x: Float, _ z: Float) -> Float {
    var sum: Float = 0, amp: Float = 0.5, freq: Float = 1, norm: Float = 0
    for _ in 0..<3 {
        sum += noise(x * freq, z * freq) * amp
        norm += amp
        amp *= 0.5
        freq *= 2
    }
    return sum / norm
}
