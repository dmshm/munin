import Foundation
import Testing
@testable import MuninCore

@Test func stableHashMatchesGame() {
    // Values from the game's own Utils.GetStableHashCode.
    #expect(stableHash("wefijfewijfjewi") == -957_960_349)
    #expect(stableHash("ownerName") == 1_227_488_406)
}

/// A minimal world in the v34 layout: one terrain-ish object without fields, one
/// player-built wall with the usual mix of fields around its "creator".
private func syntheticWorld() -> Data {
    var d = Data()
    func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func put(_ v: Float) { put(v.bitPattern) }
    func put(_ v: Double) { put(v.bitPattern) }

    put(Int32(34)); put(Double(1234.5)); put(Int64(42)); put(UInt32(3)); put(Int32(2))

    // object 1: no data, no rotation
    put(UInt16(0)); put(Int16(0)); put(Int16(0)); put(Float(1)); put(Float(2)); put(Float(3)); put(stableHash("_ZoneCtrl"))

    // object 2: rotation + floats + longs + strings + byte arrays
    let flags: UInt16 = 2 | 32 | 64 | 128 | 4096
    put(flags); put(Int16(1)); put(Int16(-1))
    put(Float(100.5)); put(Float(30)); put(Float(-64))
    put(stableHash("woodwall"))
    put(Float(0)); put(Float(90)); put(Float(0))
    d.append(1); put(stableHash("health")); put(Float(400))
    d.append(1); put(stableHash("creator")); put(Int64(-123_456_789))
    d.append(1); put(stableHash("text")); d.append(5); d.append(contentsOf: Array("hello".utf8))
    d.append(1); put(stableHash("blob")); put(Int32(3)); d.append(contentsOf: [1, 2, 3])
    return d
}

@Test func readsPlayerBuiltPieces() throws {
    let world = try WorldReader.read(syntheticWorld())
    #expect(world.version == 34)
    #expect(world.objectCount == 2)
    #expect(world.pieces.count == 1)
    let wall = try #require(world.pieces.first)
    #expect(wall.prefab == stableHash("woodwall"))
    #expect(wall.position == SIMD3(100.5, 30, -64))
    #expect(wall.rotation == SIMD3(0, 90, 0))
    #expect(wall.creator == -123_456_789)
}

@Test func rejectsTruncatedSave() {
    let cut = syntheticWorld().dropLast(4)
    #expect(throws: WorldReader.Failure.self) { try WorldReader.read(Data(cut)) }
}

@Test func clustersByDistanceAndRoundTripsFiles() throws {
    let wall = stableHash("woodwall")
    let near = (0..<5).map { Piece(prefab: wall, position: SIMD3(Float($0) * 2, 0, 0), rotation: .zero) }
    let far = [Piece(prefab: wall, position: SIMD3(500, 10, 500), rotation: .zero)]
    let builds = clusterPieces(near + far)
    #expect(builds.map(\.pieces.count) == [5, 1])
    #expect(builds[0].origin == SIMD3(4, 0, 0))

    PrefabNames.shared.add(["woodwall"])
    let reloaded = try BuildFile.load(BuildFile.export(builds[0]))
    #expect(reloaded.pieces.map(\.position) == builds[0].pieces.map(\.position))
    #expect(reloaded.pieces.first?.name == "woodwall")
}

@Test func unpacksRotations() throws {
    func rot(_ bytes: [UInt8]) throws -> SIMD3<Float> {
        try Data(bytes).withUnsafeBytes { raw in
            var r = ByteReader(raw)
            return try WorldReader.readPackedRotation(&r)
        }
    }
    // Yaw only: 0x8000 | half-degrees. 180 → 90°.
    #expect(try rot([0xb4, 0x80]) == SIMD3(0, 90, 0))
    // Tilted: second | first << 16 = x | y << 10 | z << 20, half-degrees.
    let v: UInt32 = 10 | 300 << 10 | 714 << 20
    let first = UInt16(v >> 16), second = UInt16(v & 0xffff)
    #expect(try rot([UInt8(first & 0xff), UInt8(first >> 8), UInt8(second & 0xff), UInt8(second >> 8)]) == SIMD3(5, 150, 357))
}

@Test func readsChunkedWorld() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("munin-chunked-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func chunk(_ wallX: Float) -> Data {
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put(_ v: Float) { put(v.bitPattern) }
        put(UInt16(42)); put(Int32(2))
        // zone anchor: compact position, no data
        put(UInt16(0x2100)); put(Int16(1024)); put(Int16(-5120)); put(stableHash("_ZoneCtrl"))
        // wall: full position, yaw-only rotation, creator
        put(UInt16(0x1000 | 0x100 | 32)); put(wallX); put(Float(32)); put(Float(-5150)); put(stableHash("woodwall"))
        put(UInt16(0x8000 | 180))
        d.append(1); put(stableHash("creator")); put(Int64(7))
        return d
    }
    try chunk(1).write(to: dir.appendingPathComponent("10_20__1_3.chunk"))
    try chunk(2).write(to: dir.appendingPathComponent("10_20__1_7.chunk")) // newer revision wins
    let world = try WorldReader.load(dir.appendingPathComponent("10_20__1_7.chunk"))
    #expect(world.version == 42)
    #expect(world.objectCount == 2)
    #expect(world.objects[0].position == SIMD3(1024, 0, -5120))
    let wall = try #require(world.pieces.first)
    #expect(wall.position.x == 2)
    #expect(wall.rotation == SIMD3(0, 90, 0))
}

/// Against a real save, when one is around: MUNIN_TEST_WORLD=/path/to/world.db swift test
@Test(.enabled(if: ProcessInfo.processInfo.environment["MUNIN_TEST_WORLD"] != nil))
func readsRealWorld() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUNIN_TEST_WORLD"]!)
    let world = try WorldReader.load(url)
    #expect(world.objectCount > 0)
    print("real world: v\(world.version), \(world.objectCount) objects, \(world.pieces.count) pieces, "
          + "\(world.terrainEdits.count) edited zones, \(world.terrainEdits.map(\.heightDeltas.count).reduce(0, +)) edited vertices")
}

@Test func cutsRegionAndEstimatesGround() {
    let tree = stableHash("Beech1"), ruin = stableHash("StoneTower"), wall = stableHash("woodwall")
    var objects: [Piece] = []
    // Gently sloping ground traced by trees: y = 40 + x / 10.
    for x in stride(from: -60, through: 60, by: 6) {
        for z in stride(from: -60, through: 60, by: 6) {
            objects.append(Piece(prefab: tree, position: SIMD3(Float(x), 40 + Float(x) / 10, Float(z)), rotation: .zero))
        }
    }
    objects.append(Piece(prefab: ruin, position: SIMD3(12, 70, 12), rotation: .zero))           // stands tall
    objects.append(Piece(prefab: tree, position: SIMD3(0, 5000, 0), rotation: .zero))           // dungeon interior
    objects.append(Piece(prefab: wall, position: SIMD3(2, 41, 0), rotation: .zero, creator: 1)) // player-built
    objects.append(Piece(prefab: wall, position: SIMD3(300, 41, 0), rotation: .zero, creator: 1)) // outside

    let content = RegionContent.cut(objects, region: Region(center: .zero, radius: 30), name: nil,
                                    isGroundSample: { $0 == tree || $0 == ruin }, includeProp: { _ in true })
    #expect(content.build.pieces.count == 1)
    #expect(!content.props.contains { $0.position.y > 1000 })
    let ground = try! #require(content.ground)
    // Origin is the ground at the centre, so the field is ~0 there and follows the slope.
    #expect(abs(ground.height(x: 0, z: 0)) < 0.5)
    #expect(abs(ground.height(x: 20, z: 0) - 2) < 0.6)
    // The ruin's 70 m sample was rejected as standing tall, not taken as ground.
    #expect(ground.height(x: 12, z: 12) < 3)
    #expect(abs(content.waterLevel - (30 - 40)) < 0.5)
}

/// A one-zone export as the in-game plugin writes it (format 2).
private func exportedTerrain(height: (Int, Int) -> Float, biome: UInt16) -> Data {
    var d = Data()
    func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func put(_ v: Float) { put(v.bitPattern) }
    d.append(contentsOf: Array("MUNT".utf8))
    put(Int32(2)); put(Int32(64)); put(Int32(65)); put(Int32(1))
    put(Int16(0)); put(Int16(0))
    for r in 0..<65 { for c in 0..<65 { put(height(c, r)) } }
    for _ in 0..<(65 * 65) { put(biome) }
    d.append(contentsOf: [UInt8](repeating: 0, count: 65 * 65 * 4))
    for _ in 0..<(65 * 65) { put(Float(1.5)) }
    return d
}

@Test func readsTerrainExportAndAppliesEdits() throws {
    // Zone (0,0) spans -32…32; heights rise 0.1 m per metre east.
    let terrain = try Terrain.load(exportedTerrain(height: { c, _ in 40 + Float(c) * 0.1 }, biome: Biome.meadows.rawValue))
    #expect(abs(terrain.height(x: 0, z: 0)! - 43.2) < 0.001)
    #expect(abs(terrain.height(x: 10.5, z: 3)! - 44.25) < 0.001)
    #expect(terrain.height(x: 100, z: 0) == nil)

    // Vertex (32, 32) — the zone centre — dug 2 m and paved.
    let centre = 32 * 65 + 32
    terrain.apply([TerrainEdit(zone: SIMD2(0, 0), heightDeltas: [(centre, -2)], paint: [(centre, SIMD3(0, 0, 1))])])
    #expect(abs(terrain.height(x: 0, z: 0)! - 41.2) < 0.001)
    #expect(terrain.surface(x: 0, z: 0)?.paint.z == 1)
    #expect(terrain.surface(x: 0, z: 0)?.biome == .meadows)
}

@Test func decodesSavedTerrainEdits() throws {
    // TCData: version, operations, last op (vec3 + radius), 2 heights, 2 paints — gzipped.
    var raw = Data()
    func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { raw.append(contentsOf: $0) } }
    func put(_ v: Float) { put(v.bitPattern) }
    put(Int32(1)); put(Int32(3)); for _ in 0..<4 { put(Float(0)) }
    put(Int32(2)); raw.append(0); raw.append(1); put(Float(-0.5)); put(Float(0.25))
    put(Int32(2)); raw.append(1); put(Float(1)); put(Float(0)); put(Float(0)); put(Float(1)); raw.append(0)
    let gz = try gzip(raw)
    let edit = try TerrainEdit.decode(zoneCenter: SIMD3(128, 0, -64), gzipped: gz)
    #expect(edit.zone == SIMD2(2, -1))
    #expect(edit.heightDeltas.count == 1 && edit.heightDeltas[0].0 == 1 && edit.heightDeltas[0].1 == -0.25)
    #expect(edit.paint.count == 1 && edit.paint[0].0 == 0 && edit.paint[0].1 == SIMD3(1, 0, 0))
}

/// gzip via the system tool, so the test does not reuse the code under test.
private func gzip(_ data: Data) throws -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    p.arguments = ["-c", "-n"]
    let input = Pipe(), output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    try p.run()
    input.fileHandleForWriting.write(data)
    try input.fileHandleForWriting.close()
    let out = output.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return out
}

@Test func scattersGrassByTheGamesRules() throws {
    let terrain = try Terrain.load(exportedTerrain(height: { _, _ in 40 }, biome: Biome.meadows.rawValue))
    // Pave the western half: grass must not grow there.
    var paint: [(Int, SIMD3<Float>)] = []
    for r in 0..<65 { for c in 0..<32 { paint.append((r * 65 + c, SIMD3(0, 0, 1))) } }
    terrain.apply([TerrainEdit(zone: SIMD2(0, 0), heightDeltas: [], paint: paint)])

    let content = RegionContent.cut([], region: Region(center: .zero, radius: 24), terrain: terrain,
                                    isGroundSample: { _ in false }, includeProp: { _ in false })
    let field = try #require(content.ground)
    #expect(field.isExact)
    let rules = [
        ClutterRule(name: "grass", prefab: "g", biome: Biome.meadows.rawValue, amount: 50, scaleMin: 1, scaleMax: 1,
                    minTilt: 0, maxTilt: 25, minAlt: 0.5, maxAlt: 1000, onUncleared: 1, onCleared: 0, inForest: 0,
                    forestTresholdMin: 0, forestTresholdMax: 1, fractalScale: 0, fractalOffset: 0,
                    fractalTresholdMin: 0, fractalTresholdMax: 1, snapToWater: 0),
        ClutterRule(name: "swampgrass", prefab: "s", biome: Biome.swamp.rawValue, amount: 50, scaleMin: 1, scaleMax: 1,
                    minTilt: 0, maxTilt: 25, minAlt: 0, maxAlt: 1000, onUncleared: 1, onCleared: 0, inForest: 0,
                    forestTresholdMin: 0, forestTresholdMax: 1, fractalScale: 0, fractalOffset: 0,
                    fractalTresholdMin: 0, fractalTresholdMax: 1, snapToWater: 0),
    ]
    let grass = field.scatter(ClutterSettings(patchSize: 8, waterLevel: 30, rules: rules),
                              origin: content.build.origin, waterLevel: content.waterLevel, radius: 24)
    #expect(!grass.isEmpty)
    #expect(grass.allSatisfy { $0.rule == 0 })                          // meadows only
    #expect(grass.allSatisfy { $0.position.x + content.build.origin.x > -0.5 }) // not on the paved half
    // Same region, same grass.
    let again = field.scatter(ClutterSettings(patchSize: 8, waterLevel: 30, rules: rules),
                              origin: content.build.origin, waterLevel: content.waterLevel, radius: 24)
    #expect(again.map(\.position) == grass.map(\.position))
}
