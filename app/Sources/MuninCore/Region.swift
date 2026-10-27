import Foundation

/// A circle of the world, picked on the map or around a build.
public struct Region: Hashable {
    /// World x and z (Valheim frame: z is north).
    public var center: SIMD2<Float>
    public var radius: Float

    public init(center: SIMD2<Float>, radius: Float) {
        self.center = center
        self.radius = radius
    }

    public func contains(_ p: SIMD3<Float>) -> Bool {
        let d = SIMD2(p.x, p.z) - center
        return (d * d).sum() <= radius * radius
    }
}

/// What a region shows: its build pieces (as one `Build`, so layers work), the other
/// objects around them, and the ground — exact when the in-game terrain export is
/// available, estimated otherwise. Everything is relative to `build.origin`.
public struct RegionContent {
    public var region: Region
    public var build: Build
    public var props: [Piece]
    public var ground: Heightfield?
    /// Valheim's sea level, relative to the origin.
    public var waterLevel: Float

    public static let seaLevel: Float = 30
    /// Anything above this is inside a dungeon, not on the surface.
    public static let dungeonAltitude: Float = 1000
}

/// Heights on a square grid, relative to the region's origin.
public struct Heightfield {
    /// Corner of the grid (x, z) and spacing, in metres.
    public var minX: Float, minZ: Float, cell: Float
    public var columns: Int, rows: Int
    /// Row-major, `rows × columns`.
    public var heights: [Float]
    /// What covers each vertex, when the heights come from the game's own terrain;
    /// nil for an estimate.
    public var surface: [Terrain.Surface]?

    public var isExact: Bool { surface != nil }

    public func height(column: Int, row: Int) -> Float { heights[row * columns + column] }

    /// Bilinear height at (x, z), clamped to the grid.
    public func height(x: Float, z: Float) -> Float {
        let fx = min(max((x - minX) / cell, 0), Float(columns - 1))
        let fz = min(max((z - minZ) / cell, 0), Float(rows - 1))
        let c0 = Int(fx), r0 = Int(fz)
        let c1 = min(c0 + 1, columns - 1), r1 = min(r0 + 1, rows - 1)
        let tx = fx - Float(c0), tz = fz - Float(r0)
        let top = height(column: c0, row: r0) * (1 - tx) + height(column: c1, row: r0) * tx
        let bottom = height(column: c0, row: r1) * (1 - tx) + height(column: c1, row: r1) * tx
        return top * (1 - tz) + bottom * tz
    }
}

extension RegionContent {
    /// Cut `region` out of a world's objects.
    ///
    /// The save does not hold terrain — Valheim regenerates it from the seed — so the
    /// ground is rebuilt from where things stand: trees, rocks and bushes sit on it.
    /// `isGroundSample` says which prefabs count (not birds, fish, ships…).
    public static func cut(
        _ objects: [Piece],
        region: Region,
        name: String? = nil,
        terrain: Terrain? = nil,
        isGroundSample: (Int32) -> Bool,
        includeProp: (Int32) -> Bool
    ) -> RegionContent {
        var pieces: [Piece] = []
        var props: [Piece] = []
        var samples: [SIMD3<Float>] = []
        // Ground samples come from a margin around the region so the edges are not guessed.
        let sampleRegion = Region(center: region.center, radius: region.radius + 24)
        // Dungeon interiors (crypts, frost caves) sit ~5000 m up, above their entrances.
        for o in objects where o.position.y < RegionContent.dungeonAltitude && sampleRegion.contains(o.position) {
            if o.creator != nil {
                if region.contains(o.position) { pieces.append(o) }
            } else {
                if region.contains(o.position) && includeProp(o.prefab) { props.append(o) }
                if isGroundSample(o.prefab) { samples.append(o.position) }
            }
        }

        let exact = terrain.flatMap { Heightfield.sample($0, region: sampleRegion) }
        let field = exact ?? (samples.count >= 4 ? Heightfield.estimate(samples: samples, region: sampleRegion) : nil)
        let groundAtCenter = field?.height(x: region.center.x, z: region.center.y)
        let lowestPiece = pieces.map(\.position.y).min()
        let originY = groundAtCenter ?? lowestPiece ?? RegionContent.seaLevel
        let origin = SIMD3(region.center.x, originY, region.center.y)

        let build = Build(
            name: name ?? "Area @ \(Int(region.center.x.rounded())), \(Int(region.center.y.rounded()))",
            worldPieces: pieces,
            origin: origin
        )
        let relativeProps = props.map { var p = $0; p.position -= origin; return p }
        let relativeField = field.map { f -> Heightfield in
            var f = f
            f.minX -= origin.x
            f.minZ -= origin.z
            f.heights = f.heights.map { $0 - origin.y }
            return f
        }
        return RegionContent(region: region, build: build, props: relativeProps, ground: relativeField,
                             waterLevel: RegionContent.seaLevel - origin.y)
    }
}

extension Heightfield {
    /// The game's terrain over a region, one vertex per metre (two past 120 m radius).
    /// Nil when the export does not cover the region's centre.
    static func sample(_ terrain: Terrain, region: Region) -> Heightfield? {
        guard terrain.height(x: region.center.x, z: region.center.y) != nil else { return nil }
        let cell: Float = region.radius > 120 ? 2 : 1
        let minX = (region.center.x - region.radius).rounded(.down), minZ = (region.center.y - region.radius).rounded(.down)
        let n = Int((region.radius * 2 / cell).rounded(.up)) + 1
        var heights = [Float](repeating: 0, count: n * n)
        let unknown = Terrain.Surface(biome: .ocean, mask: .zero, paint: .zero, forest: 2)
        var surface = [Terrain.Surface](repeating: unknown, count: n * n)
        var lastKnown = RegionContent.seaLevel - 10
        for r in 0..<n {
            for c in 0..<n {
                let x = minX + Float(c) * cell, z = minZ + Float(r) * cell
                // Outside the export (unexplored) the sea floor stands in.
                if let h = terrain.height(x: x, z: z) { heights[r * n + c] = h; lastKnown = h } else { heights[r * n + c] = lastKnown }
                if let s = terrain.surface(x: x, z: z) { surface[r * n + c] = s }
            }
        }
        return Heightfield(minX: minX, minZ: minZ, cell: cell, columns: n, rows: n, heights: heights, surface: surface)
    }

    /// Lowest sample per cell, holes filled by inverse-distance weighting from nearby
    /// cells, then smoothed. World coordinates in, world coordinates out.
    static func estimate(samples: [SIMD3<Float>], region: Region, cell: Float = 4) -> Heightfield {
        let minX = region.center.x - region.radius, minZ = region.center.y - region.radius
        let n = Int((region.radius * 2 / cell).rounded(.up)) + 1
        var low = [Float](repeating: .infinity, count: n * n)
        for s in samples {
            let c = Int(((s.x - minX) / cell).rounded()), r = Int(((s.z - minZ) / cell).rounded())
            guard c >= 0, c < n, r >= 0, r < n else { continue }
            low[r * n + c] = min(low[r * n + c], s.y)
        }

        // A cell far above its neighbourhood holds something standing tall (a ruin, a
        // tree on a ledge), not ground: forget it and let the neighbours fill it in.
        var filtered = low
        for r in 0..<n {
            for c in 0..<n where low[r * n + c].isFinite {
                var around: [Float] = []
                for dr in -3...3 { for dc in -3...3 where dr != 0 || dc != 0 {
                    let rr = r + dr, cc = c + dc
                    if rr >= 0, rr < n, cc >= 0, cc < n, low[rr * n + cc].isFinite { around.append(low[rr * n + cc]) }
                }}
                guard around.count >= 3 else { continue }
                around.sort()
                if low[r * n + c] > around[around.count / 2] + 6 { filtered[r * n + c] = .infinity }
            }
        }
        low = filtered

        let known = low.indices.filter { low[$0].isFinite }
        var heights = low
        if known.isEmpty {
            heights = [Float](repeating: RegionContent.seaLevel, count: n * n)
        } else {
            for i in heights.indices where !heights[i].isFinite {
                let (r, c) = (i / n, i % n)
                var weight: Float = 0, sum: Float = 0
                // Nearest few known cells; the grid is small enough to scan.
                for k in known {
                    let dr = Float(k / n - r), dc = Float(k % n - c)
                    let d2 = dr * dr + dc * dc
                    if d2 > 100 { continue } // 10 cells = 40 m
                    let w = 1 / (d2 * d2)
                    weight += w
                    sum += w * low[k]
                }
                if weight == 0 {
                    // Far from anything: nearest known cell.
                    let k = known.min { a, b in
                        let da = (a / n - r) * (a / n - r) + (a % n - c) * (a % n - c)
                        let db = (b / n - r) * (b / n - r) + (b % n - c) * (b % n - c)
                        return da < db
                    }!
                    heights[i] = low[k]
                } else {
                    heights[i] = sum / weight
                }
            }
        }

        // Two passes of 3×3 averaging take the edge off single odd samples.
        for _ in 0..<2 {
            var next = heights
            for r in 0..<n {
                for c in 0..<n {
                    var s: Float = 0, k: Float = 0
                    for dr in -1...1 { for dc in -1...1 {
                        let rr = r + dr, cc = c + dc
                        if rr >= 0, rr < n, cc >= 0, cc < n { s += heights[rr * n + cc]; k += 1 }
                    }}
                    next[r * n + c] = s / k
                }
            }
            heights = next
        }
        return Heightfield(minX: minX, minZ: minZ, cell: cell, columns: n, rows: n, heights: heights, surface: nil)
    }
}
