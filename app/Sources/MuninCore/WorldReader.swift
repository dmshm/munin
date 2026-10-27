import Foundation

/// Reader for Valheim world saves. Two layouts exist:
///
/// **Single file** (`<world>.db`, world version 33–41), little-endian:
///   int32 worldVersion, double netTime,
///   int64 sessionId, uint32 nextUid, int32 objectCount, objectCount × ZDO, …zones, events
///
/// **Chunked** (a `<world>/` directory, world version 42+): `_main.<n>.db2` keeps
/// zones and events, `_main.<n>.chunks` indexes the chunks, and each
/// `<a>_<b>__<kind>_<revision>.chunk` holds the objects of one 512 m square:
///   uint16 version, int32 objectCount, objectCount × compact ZDO
///
/// ZDOs ("Zone Data Objects", one per networked thing in the world) carry no length
/// prefix, so each has to be walked field by field. The compact ZDO differs from the
/// old one in three places, all worked out from real saves (see the README):
///   - no sector before the position;
///   - flag 0x2000: position stored as int16 x, z (metres, y = 0) — zone anchors;
///   - rotation packed into 2 bytes (yaw only) or 4 (yaw and tilt), half-degree steps.
public enum WorldReader {
    public static let minimumVersion: Int32 = 33
    public static let chunkedVersion: Int32 = 42
    public static let testedVersions: Set<Int32> = [34, 42]

    public struct Result {
        public var version: Int32
        /// Every object in the world: vegetation, rocks, creatures, build pieces…
        public var objects: [Piece]
        public var warnings: [String]
        /// Player edits to the terrain, one per edited zone.
        public var terrainEdits: [TerrainEdit] = []

        public var objectCount: Int { objects.count }
        /// The player-built ones.
        public var pieces: [Piece] { objects.filter { $0.creator != nil } }
    }

    public enum Failure: LocalizedError {
        case tooOld(Int32)
        case notAWorld(String)
        case truncated

        public var errorDescription: String? {
            switch self {
            case .tooOld(let v):
                return "World version \(v) predates the compact save format (needs \(WorldReader.minimumVersion)+). Load and save the world in a current Valheim first."
            case .notAWorld(let why): return "Not a Valheim world save: \(why)"
            case .truncated: return "The save ends in the middle of an object — truncated, or a layout this reader does not know."
            }
        }
    }

    enum Flag {
        static let connections: UInt16 = 1
        static let floats: UInt16 = 2
        static let vec3s: UInt16 = 4
        static let quats: UInt16 = 8
        static let ints: UInt16 = 16
        static let longs: UInt16 = 32
        static let strings: UInt16 = 64
        static let byteArrays: UInt16 = 128
        static let rotation: UInt16 = 4096
        static let compactPosition: UInt16 = 8192
    }

    /// Every player-placed piece stores who built it under "creator".
    static let creatorKey = stableHash("creator")
    static let scaleKey = stableHash("scale")
    static let scaleScalarKey = stableHash("scaleScalar")
    static let fuelKey = stableHash("fuel")

    // MARK: - entry points

    /// Open whatever the user picked: a `.db`, a chunked world directory, or any file inside one.
    public static func load(_ url: URL) throws -> Result {
        if let directory = chunkedDirectory(for: url) { return try readChunked(directory) }
        return try read(Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func chunkedDirectory(for url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let directory = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { $0.hasSuffix(".chunk") } ? directory : nil
    }

    /// Single-file `.db` save.
    public static func read(_ data: Data) throws -> Result {
        try data.withUnsafeBytes { raw in
            var r = ByteReader(raw)
            var warnings: [String] = []

            let version: Int32 = try r.read()
            if version < minimumVersion { throw Failure.tooOld(version) }
            if version >= chunkedVersion { throw Failure.notAWorld("version \(version) saves are a directory of .chunk files — open the folder instead") }
            if !testedVersions.contains(version) {
                warnings.append("World version \(version) has not been tested; results are sanity-checked but may be off.")
            }
            let _: Double = try r.read() // netTime
            let _: Int64 = try r.read() // sessionId
            let _: UInt32 = try r.read() // nextUid
            let count: Int32 = try r.read()
            guard count >= 0 && count < 50_000_000 else { throw Failure.notAWorld("implausible object count \(count)") }

            var objects: [Piece] = []
            var edits: [TerrainEdit] = []
            objects.reserveCapacity(Int(count))
            for index in 0..<Int(count) {
                let (object, edit) = try readObject(&r, compact: false, index: index)
                objects.append(object)
                if let edit { edits.append(edit) }
            }
            return Result(version: version, objects: objects, warnings: warnings, terrainEdits: edits)
        }
    }

    /// Chunked world directory. Each chunk is kept once, at its highest revision.
    public static func readChunked(_ directory: URL) throws -> Result {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".chunk") }
        var latest: [String: (revision: Int, name: String)] = [:]
        for name in names {
            // "1e_20__1_273.chunk": chunk "1e_20", kind 1, revision 273.
            let stem = name.dropLast(".chunk".count)
            let parts = stem.components(separatedBy: "__")
            guard parts.count == 2, let revision = Int(parts[1].split(separator: "_").last ?? "") else { continue }
            if (latest[parts[0]]?.revision ?? -1) < revision { latest[parts[0]] = (revision, name) }
        }
        guard !latest.isEmpty else { throw Failure.notAWorld("no .chunk files in \(directory.lastPathComponent)") }

        var objects: [Piece] = []
        var edits: [TerrainEdit] = []
        var versions = Set<Int32>()
        for (_, entry) in latest.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.name), options: .mappedIfSafe)
            try data.withUnsafeBytes { raw in
                var r = ByteReader(raw)
                let version: UInt16 = try r.read()
                versions.insert(Int32(version))
                let count: Int32 = try r.read()
                guard count >= 0 && count < 10_000_000 else { throw Failure.notAWorld("\(entry.name): implausible object count \(count)") }
                for index in 0..<Int(count) {
                    let (object, edit) = try readObject(&r, compact: true, index: index)
                    objects.append(object)
                    if let edit { edits.append(edit) }
                }
                guard r.offset == raw.count else {
                    throw Failure.notAWorld("\(entry.name): \(raw.count - r.offset) bytes left after the last object")
                }
            }
        }
        let version = versions.max() ?? chunkedVersion
        var warnings: [String] = []
        if versions.contains(where: { !testedVersions.contains($0) }) {
            warnings.append("Chunk version \(versions.sorted()) has not been tested; every chunk parsed to its last byte, so it is probably fine.")
        }
        return Result(version: version, objects: objects, warnings: warnings, terrainEdits: edits)
    }

    // MARK: - one object

    /// One object, plus its terrain edits when it is a zone's `_TerrainCompiler`.
    static func readObject(_ r: inout ByteReader, compact: Bool, index: Int) throws -> (Piece, TerrainEdit?) {
        let flags: UInt16 = try r.read()
        if !compact { try r.skip(4) } // sector, derivable from position

        var pos: SIMD3<Float>
        if compact && flags & Flag.compactPosition != 0 {
            let x: Int16 = try r.read()
            let z: Int16 = try r.read()
            pos = SIMD3(Float(x), 0, Float(z))
        } else {
            pos = SIMD3(try r.read(), try r.read(), try r.read())
        }
        let prefab: Int32 = try r.read()

        var rot = SIMD3<Float>(0, 0, 0)
        if flags & Flag.rotation != 0 {
            rot = compact ? try readPackedRotation(&r) : SIMD3(try r.read(), try r.read(), try r.read())
        }

        var creator: Int64?
        var scale = SIMD3<Float>(1, 1, 1)
        var fuel: Float?
        var terrainData: Data?
        if flags & 0xff != 0 {
            if flags & Flag.connections != 0 { try r.skip(1 + 4) } // type + target hash
            if flags & Flag.floats != 0 {
                for _ in 0..<(try r.numItems()) {
                    let key: Int32 = try r.read()
                    let value: Float = try r.read()
                    if key == scaleScalarKey { scale = SIMD3(repeating: value) }
                    if key == fuelKey { fuel = value }
                }
            }
            if flags & Flag.vec3s != 0 {
                for _ in 0..<(try r.numItems()) {
                    let key: Int32 = try r.read()
                    let value = SIMD3<Float>(try r.read(), try r.read(), try r.read())
                    if key == scaleKey { scale = value }
                }
            }
            if flags & Flag.quats != 0 { try r.skipItems(4 + 16) }
            if flags & Flag.ints != 0 { try r.skipItems(4 + 4) }
            if flags & Flag.longs != 0 {
                for _ in 0..<(try r.numItems()) {
                    let key: Int32 = try r.read()
                    let value: Int64 = try r.read()
                    if key == creatorKey { creator = value }
                }
            }
            if flags & Flag.strings != 0 {
                for _ in 0..<(try r.numItems()) { try r.skip(4); try r.skipString() }
            }
            if flags & Flag.byteArrays != 0 {
                for _ in 0..<(try r.numItems()) {
                    let key: Int32 = try r.read()
                    let length: Int32 = try r.read()
                    if prefab == TerrainEdit.prefab && key == TerrainEdit.dataKey, length > 0, r.offset + Int(length) <= r.raw.count {
                        terrainData = Data(r.raw[r.offset..<(r.offset + Int(length))])
                    }
                    try r.skip(Int(length))
                }
            }
        }

        // Real objects sit within ±10500 m; a few bookkeeping ones park at 1e6.
        guard pos.x.isFinite, pos.y.isFinite, pos.z.isFinite, abs(pos.x) < 2e6, abs(pos.z) < 2e6 else {
            throw Failure.notAWorld("object \(index) has position \(pos) — the layout is not what this reader expects")
        }
        var object = Piece(prefab: prefab, position: pos, rotation: rot, scale: scale, creator: creator)
        object.fuel = fuel
        // An unreadable edit loses that zone's edits, not the world.
        let edit = terrainData.flatMap { try? TerrainEdit.decode(zoneCenter: pos, gzipped: $0) }
        return (object, edit)
    }

    /// Euler angles in half-degree steps (0…719). The first uint16 has its top bit set
    /// when only yaw follows in its low bits; otherwise a second uint16 follows and
    /// `second | first << 16` packs x | y << 10 | z << 20.
    static func readPackedRotation(_ r: inout ByteReader) throws -> SIMD3<Float> {
        let first: UInt16 = try r.read()
        if first & 0x8000 != 0 {
            return SIMD3(0, Float(first & 0x7fff) / 2, 0)
        }
        let second: UInt16 = try r.read()
        let v = UInt32(second) | UInt32(first) << 16
        return SIMD3(Float(v & 0x3ff), Float((v >> 10) & 0x3ff), Float((v >> 20) & 0x3ff)) / 2
    }
}

struct ByteReader {
    let raw: UnsafeRawBufferPointer
    var offset = 0

    init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }

    mutating func read<T: FixedWidthInteger>() throws -> T {
        guard offset + MemoryLayout<T>.size <= raw.count else { throw WorldReader.Failure.truncated }
        let v = raw.loadUnaligned(fromByteOffset: offset, as: T.self)
        offset += MemoryLayout<T>.size
        return T(littleEndian: v)
    }

    mutating func read() throws -> Float {
        Float(bitPattern: try read() as UInt32)
    }

    mutating func read() throws -> Double {
        Double(bitPattern: try read() as UInt64)
    }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, offset + n <= raw.count else { throw WorldReader.Failure.truncated }
        offset += n
    }

    /// `ZPackage.ReadNumItems`: one byte, or two when the high bit is set.
    mutating func numItems() throws -> Int {
        let first: UInt8 = try read()
        if first & 0x80 == 0 { return Int(first) }
        let second: UInt8 = try read()
        return Int(first & 0x7f) << 8 | Int(second)
    }

    mutating func skipItems(_ size: Int) throws {
        try skip(try numItems() * size)
    }

    /// .NET `BinaryWriter` string: 7-bit varint byte length, then UTF-8.
    mutating func skipString() throws {
        var length = 0
        var shift = 0
        while true {
            let b: UInt8 = try read()
            length |= Int(b & 0x7f) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        try skip(length)
    }
}
