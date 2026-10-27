import Compression
import Foundation

/// Valheim's biomes, as the game's `Heightmap.Biome` flags.
public struct Biome: OptionSet, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let meadows = Biome(rawValue: 1)
    public static let swamp = Biome(rawValue: 2)
    public static let mountain = Biome(rawValue: 4)
    public static let blackForest = Biome(rawValue: 8)
    public static let plains = Biome(rawValue: 16)
    public static let ashLands = Biome(rawValue: 32)
    public static let deepNorth = Biome(rawValue: 64)
    public static let ocean = Biome(rawValue: 256)
    public static let mistlands = Biome(rawValue: 512)
}

/// The ground as the game builds it: heights and biomes from the world generator
/// (exported in game by the `munin_export` plugin, see mod/), plus the player's edits
/// to it stored in the save (levelling, digging, paths, farmland).
///
/// An export covers every explored zone — thousands, hundreds of MB — while an area
/// needs a handful, so zones are decoded, and their edits applied, on first use.
public final class Terrain: @unchecked Sendable {
    public static let zoneSize = 64
    public static let side = 65
    static let vertices = side * side
    /// int16 x, z; then per vertex float height, uint16 biome, RGBA8 mask, float forest.
    static let zoneBytes = 4 + vertices * (4 + 2 + 4 + 4)

    /// One zone's 65 × 65 vertices, 1 m apart, from its south-west corner; rows run
    /// south to north. Heights already include the edits.
    public struct Zone {
        public var heights: [Float]
        public var biomes: [UInt16]
        /// Generator mask per vertex (RGBA, 0…255) — what the game's terrain shader blends on.
        public var masks: [SIMD4<UInt8>]
        /// Paint per vertex: x dirt, y cultivated, z paved (0…1); zero where unpainted.
        public var paint: [SIMD3<Float>]
        /// The generator's forest factor per vertex; below 1.15 counts as forest for clutter.
        public var forest: [Float]
    }

    /// The export, usually memory-mapped, and where each zone's record starts in it.
    private let data: Data
    private let offsets: [SIMD2<Int32>: Int]
    private var edits: [SIMD2<Int32>: [TerrainEdit]] = [:]
    private var decoded: [SIMD2<Int32>: Zone] = [:]
    private let lock = NSLock()

    private init(data: Data, offsets: [SIMD2<Int32>: Int]) {
        self.data = data
        self.offsets = offsets
    }

    public var zoneCount: Int { offsets.count }
    public var isEmpty: Bool { offsets.isEmpty }

    // MARK: - export file

    public enum Failure: LocalizedError {
        case notAnExport(String)
        public var errorDescription: String? {
            if case .notAnExport(let why) = self { return "Not a munin_export terrain file: \(why)" }
            return nil
        }
    }

    /// Read a `.terrain` written by the in-game exporter. Only the header and zone
    /// coordinates are read here; pass memory-mapped data to keep the rest on disk.
    public static func load(_ data: Data) throws -> Terrain {
        var offsets: [SIMD2<Int32>: Int] = [:]
        try data.withUnsafeBytes { raw in
            var r = ByteReader(raw)
            let magic: UInt32 = try r.read()
            guard magic == 0x544E_554D else { throw Failure.notAnExport("bad magic") } // "MUNT"
            let version: Int32 = try r.read()
            let zoneSize: Int32 = try r.read()
            let side: Int32 = try r.read()
            let count: Int32 = try r.read()
            guard version == 2, zoneSize == Int32(Terrain.zoneSize), side == Int32(Terrain.side) else {
                throw Failure.notAnExport("version \(version), zone \(zoneSize), side \(side)")
            }
            guard count >= 0, raw.count == r.offset + Int(count) * zoneBytes else {
                throw Failure.notAnExport("\(raw.count) bytes do not hold \(count) zones")
            }
            offsets.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                let start = 20 + i * zoneBytes
                r.offset = start
                let x: Int16 = try r.read()
                let z: Int16 = try r.read()
                offsets[SIMD2(Int32(x), Int32(z))] = start + 4
            }
        }
        return Terrain(data: data, offsets: offsets)
    }

    // MARK: - edits from the save

    /// Apply a world's terrain edits (`_TerrainCompiler` objects' `TCData`) to the
    /// zones they belong to, as each zone is decoded.
    public func apply(_ edits: [TerrainEdit]) {
        lock.lock(); defer { lock.unlock() }
        for edit in edits where offsets[edit.zone] != nil {
            self.edits[edit.zone, default: []].append(edit)
            decoded[edit.zone] = nil
        }
    }

    /// A zone with its edits applied, decoded the first time it is asked for.
    public func zone(_ key: SIMD2<Int32>) -> Zone? {
        lock.lock(); defer { lock.unlock() }
        if let zone = decoded[key] { return zone }
        guard let start = offsets[key] else { return nil }
        let n = Terrain.vertices
        func copy<T>(_ type: T.Type, at offset: Int) -> [T] {
            [T](unsafeUninitializedCapacity: n) { buffer, count in
                data.withUnsafeBytes { raw in
                    _ = memcpy(buffer.baseAddress!, raw.baseAddress! + offset, n * MemoryLayout<T>.stride)
                }
                count = n
            }
        }
        // Little-endian on disk and in memory on every Mac this runs on.
        var zone = Zone(heights: copy(Float.self, at: start),
                        biomes: copy(UInt16.self, at: start + n * 4),
                        masks: copy(SIMD4<UInt8>.self, at: start + n * 6),
                        paint: Array(repeating: .zero, count: n),
                        forest: copy(Float.self, at: start + n * 10))
        for edit in edits[key] ?? [] {
            for (i, delta) in edit.heightDeltas { zone.heights[i] += delta }
            for (i, color) in edit.paint { zone.paint[i] = color }
        }
        decoded[key] = zone
        return zone
    }

    // MARK: - sampling

    /// Zone holding world point (x, z) and the vertex coordinates inside it.
    private func locate(_ x: Float, _ z: Float) -> (Zone, Float, Float)? {
        let size = Float(Terrain.zoneSize)
        let zx = Int32((x / size).rounded()), zz = Int32((z / size).rounded())
        guard let zone = zone(SIMD2(zx, zz)) else { return nil }
        let fx = x - (Float(zx) * size - size / 2), fz = z - (Float(zz) * size - size / 2)
        return (zone, min(max(fx, 0), size), min(max(fz, 0), size))
    }

    /// Ground height at world (x, z), bilinear between vertices; nil outside the export.
    public func height(x: Float, z: Float) -> Float? {
        guard let (zone, fx, fz) = locate(x, z) else { return nil }
        let s = Terrain.side
        let c0 = min(Int(fx), s - 2), r0 = min(Int(fz), s - 2)
        let tx = fx - Float(c0), tz = fz - Float(r0)
        let h = zone.heights
        let top = h[r0 * s + c0] * (1 - tx) + h[r0 * s + c0 + 1] * tx
        let bottom = h[(r0 + 1) * s + c0] * (1 - tx) + h[(r0 + 1) * s + c0 + 1] * tx
        return top * (1 - tz) + bottom * tz
    }

    public struct Surface {
        public var biome: Biome
        public var mask: SIMD4<UInt8>
        public var paint: SIMD3<Float>
        public var forest: Float

        public init(biome: Biome, mask: SIMD4<UInt8>, paint: SIMD3<Float>, forest: Float) {
            self.biome = biome
            self.mask = mask
            self.paint = paint
            self.forest = forest
        }
    }

    /// What covers the ground at the vertex nearest world (x, z).
    public func surface(x: Float, z: Float) -> Surface? {
        guard let (zone, fx, fz) = locate(x, z) else { return nil }
        let i = Int(fz.rounded()) * Terrain.side + Int(fx.rounded())
        return Surface(biome: Biome(rawValue: zone.biomes[i]), mask: zone.masks[i], paint: zone.paint[i], forest: zone.forest[i])
    }
}

/// One zone's player edits, as `TerrainComp` saves them: per vertex of the 65 × 65
/// grid, an optional height change (level + smooth delta) and an optional paint.
public struct TerrainEdit {
    public var zone: SIMD2<Int32>
    public var heightDeltas: [(Int, Float)]
    public var paint: [(Int, SIMD3<Float>)]

    static let dataKey = stableHash("TCData")
    static let prefab = stableHash("_TerrainCompiler")

    /// `TCData` is gzip around: int32 version, int32 operations, vec3 + float last
    /// operation, int32 n, n × (bool modified [, float level, float smooth]),
    /// int32 n, n × (bool painted [, RGBA floats]).
    public static func decode(zoneCenter: SIMD3<Float>, gzipped: Data) throws -> TerrainEdit {
        let data = try gunzip(gzipped)
        let size = Float(Terrain.zoneSize)
        var edit = TerrainEdit(zone: SIMD2(Int32((zoneCenter.x / size).rounded()), Int32((zoneCenter.z / size).rounded())),
                               heightDeltas: [], paint: [])
        try data.withUnsafeBytes { raw in
            var r = ByteReader(raw)
            let _: Int32 = try r.read() // version
            let _: Int32 = try r.read() // operations
            try r.skip(16)              // last operation point and radius
            let heights: Int32 = try r.read()
            for i in 0..<Int(heights) {
                let modified: UInt8 = try r.read()
                if modified != 0 {
                    let level: Float = try r.read()
                    let smooth: Float = try r.read()
                    edit.heightDeltas.append((i, level + smooth))
                }
            }
            let paints: Int32 = try r.read()
            for i in 0..<Int(paints) {
                let painted: UInt8 = try r.read()
                if painted != 0 {
                    let c = SIMD4<Float>(try r.read(), try r.read(), try r.read(), try r.read())
                    edit.paint.append((i, SIMD3(c.x, c.y, c.z)))
                }
            }
            guard r.offset == raw.count else { throw WorldReader.Failure.notAWorld("terrain edit has \(raw.count - r.offset) stray bytes") }
        }
        return edit
    }
}

/// Unwrap a gzip member (as .NET's GZipStream writes it) with the Compression
/// framework, which speaks raw DEFLATE.
func gunzip(_ data: Data) throws -> Data {
    guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else {
        throw WorldReader.Failure.notAWorld("not gzip")
    }
    var start = 10
    let flags = data[data.startIndex + 3]
    if flags & 4 != 0 { start += 2 + Int(data[data.startIndex + 10]) | Int(data[data.startIndex + 11]) << 8 }
    if flags & 8 != 0 { while data[data.startIndex + start] != 0 { start += 1 }; start += 1 }
    if flags & 16 != 0 { while data[data.startIndex + start] != 0 { start += 1 }; start += 1 }
    if flags & 2 != 0 { start += 2 }
    // The trailer's last 4 bytes hold the uncompressed size (mod 2^32).
    let size = data.suffix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
    var out = Data(count: max(size, 1))
    let written = out.withUnsafeMutableBytes { dst in
        data.dropFirst(start).withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                      src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
    }
    guard written == size else { throw WorldReader.Failure.notAWorld("gzip body did not inflate to \(size) bytes") }
    return out
}
