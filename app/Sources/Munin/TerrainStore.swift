import Foundation
import MuninCore

/// Where the in-game exporter (mod/) and the app meet: the app lists the world's
/// explored zones for `munin_export`, and reads back the terrain it writes.
enum TerrainStore {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Munin")

    /// A chunked world's folder is named after the world; a single-file save after its file.
    static func worldName(for url: URL) -> String {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { return url.lastPathComponent }
        if url.pathExtension == "db" { return url.deletingPathExtension().lastPathComponent }
        return url.deletingLastPathComponent().lastPathComponent
    }

    /// The exported terrain for this world, with the save's edits applied; nil when
    /// `munin_export` has not been run for it yet.
    static func load(for url: URL, edits: [TerrainEdit]) -> (terrain: Terrain?, note: String) {
        guard let file = file(for: url) else { return (nil, "ground estimated — run munin_export in game for the exact terrain") }
        do {
            let terrain = try Terrain.load(Data(contentsOf: file, options: .alwaysMapped))
            terrain.apply(edits)
            return (terrain, "exact terrain: \(terrain.zoneCount) zones, \(edits.count) edited by players")
        } catch {
            return (nil, "terrain export unreadable (\(error.localizedDescription)); ground estimated")
        }
    }

    static var folder: URL { root.appendingPathComponent("terrain") }

    /// The world's `.terrain`, if `munin_export` has written one.
    static func file(for url: URL) -> URL? {
        let file = folder.appendingPathComponent(worldName(for: url) + ".terrain")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        // The exporter names the file after the server's world, which may differ.
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".terrain") }
        return all.count == 1 ? folder.appendingPathComponent(all[0]) : nil
    }

    /// Zones the world has generated, for `munin_export` to export.
    static func writeZones(_ objects: [Piece]) {
        let zoneHash = stableHash("_ZoneCtrl")
        let zones = Set(objects.lazy.filter { $0.prefab == zoneHash && abs($0.position.x) < 20000 }
            .map { "\(Int(($0.position.x / 64).rounded())) \(Int(($0.position.z / 64).rounded()))" })
        guard !zones.isEmpty else { return }
        let folder = root.appendingPathComponent("export")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? (zones.sorted().joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("zones.txt"), atomically: true, encoding: .utf8)
    }
}
