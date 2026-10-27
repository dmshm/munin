import AppKit
import Foundation
import MuninCore

@MainActor
final class AppModel: ObservableObject {
    enum Mode: String, CaseIterable { case map = "Map", scene = "3D" }

    @Published var builds: [Build] = []
    @Published var selected: Build.ID?
    @Published private(set) var scene: BuildScene?
    @Published private(set) var map: WorldMap?
    @Published var mode: Mode = .scene
    @Published var regionRadius: Double = Settings.double("regionRadius") ?? 50 { didSet { Settings.set(regionRadius, "regionRadius") } }
    @Published var level = 0 { didSet { applyState() } }
    @Published var ghosts = true { didSet { applyState() } }
    @Published var surroundings = true { didSet { applyState() } }
    /// Hour of the day, 0–24: sun, sky and how much the fires matter.
    @Published var hour: Double = Settings.double("hour") ?? 12 {
        didSet { scene?.setTime(Float(hour)); Settings.set(hour, "hour") }
    }
    @Published var focus: String? { didSet { applyState() } }
    @Published var hideSmall = Settings.bool("hideSmall") ?? true { didSet { Settings.set(hideSmall, "hideSmall") } }
    /// Render a large 3D view at full resolution, at the cost of frame rate.
    @Published var fullResolution = Settings.bool("fullResolution") ?? false { didSet { Settings.set(fullResolution, "fullResolution") } }
    /// Worlds to offer in one click: opened before, then found on disk.
    @Published private(set) var worlds: [WorldEntry] = []
    /// What is open, and a summary of it for the sidebar.
    @Published private(set) var current: WorldEntry?
    @Published private(set) var info: WorldInfo?
    /// Name of what is being opened, until it is.
    @Published private(set) var opening: String?
    @Published var status = ""
    @Published var statusIsError = false
    @Published var loading = false
    @Published var hovered: (piece: Piece, isProp: Bool, at: CGPoint)?

    let catalog: PieceCatalog?
    let catalogError: String?
    /// Every object of the loaded world; empty for a build file.
    private var objects: [Piece] = []
    /// The game's terrain for this world, when `munin_export` has been run.
    private var terrain: Terrain?
    /// Prefabs shown around a build, and the subset that stands on the ground.
    private var propPrefabs: Set<Int32> = []
    private var groundPrefabs: Set<Int32> = []

    init() {
        do {
            catalog = try PieceCatalog()
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = "No mesh catalog — pieces draw as boxes. Run tools/extract_meshes.py once to pull real shapes from your Valheim install."
        }
        refreshWorlds()
    }

    // MARK: - worlds

    func refreshWorlds() {
        worlds = WorldLibrary.discover(recent: Settings.recentWorlds, folders: WorldLibrary.standardFolders(munin: TerrainStore.root))
    }

    /// At launch: whatever was open last time, if it is still there.
    func openLastWorld() {
        guard scene == nil, !loading, let last = worlds.first(where: { $0.lastOpened != nil }) else { return }
        open(last.url)
    }

    var hasWorld: Bool { !objects.isEmpty }

    /// Builds of fewer than 10 pieces: a lone workbench, a portal, a campfire.
    var smallBuildCount: Int { builds.filter { $0.pieces.count < 10 }.count }

    var visibleBuilds: [Build] {
        builds.filter { !hideSmall || $0.pieces.count >= 10 || $0.id == selected }
    }

    func open(_ url: URL) {
        let entry = WorldLibrary.entry(at: url, source: .other)
        let url = entry?.url ?? url
        loading = true
        statusIsError = false
        opening = entry?.name ?? url.lastPathComponent
        status = "Reading \(opening!)…"
        Task.detached(priority: .userInitiated) {
            do {
                if url.pathExtension.lowercased() == "json" {
                    let build = try BuildFile.load(Data(contentsOf: url))
                    let info = WorldInfo(name: build.name, pieces: build.pieces.count, builds: 1, objects: nil,
                                         terrain: nil, warnings: [])
                    await self.loaded(url, [build], objects: [], terrain: nil, map: nil, info)
                } else {
                    let world = try WorldReader.load(url)
                    let builds = clusterPieces(world.pieces)
                    let map = WorldMap.render(world.objects)
                    TerrainStore.writeZones(world.objects)
                    let (terrain, terrainNote) = TerrainStore.load(for: url, edits: world.terrainEdits)
                    let info = WorldInfo(
                        name: entry?.name ?? url.lastPathComponent,
                        pieces: world.pieces.count, builds: builds.count, objects: world.objectCount,
                        terrain: .init(isExact: terrain != nil,
                                       edited: Set(world.terrainEdits.map(\.zone)).count,
                                       note: terrainNote.prefix(1).uppercased() + terrainNote.dropFirst()),
                        warnings: world.warnings)
                    await self.loaded(url, builds, objects: world.objects, terrain: terrain, map: map, info)
                }
            } catch {
                await self.failed(error.localizedDescription)
            }
        }
    }

    private func loaded(_ url: URL, _ builds: [Build], objects: [Piece], terrain: Terrain?, map: WorldMap?, _ info: WorldInfo) {
        loading = false
        opening = nil
        self.builds = builds
        self.objects = objects
        self.terrain = terrain
        self.map = map
        self.info = info
        classifyPrefabs()
        let empty = builds.isEmpty && objects.isEmpty
        status = empty ? "No player-built pieces found." : ""
        statusIsError = empty
        Settings.remember(url)
        refreshWorlds()
        current = worlds.first { $0.id == url.standardizedFileURL.path }
        mode = .scene
        select(builds.first?.id)
    }

    private func classifyPrefabs() {
        (propPrefabs, groundPrefabs) = catalog?.classify(objects) ?? ([], [])
    }

    private func failed(_ message: String) {
        loading = false
        opening = nil
        status = message
        statusIsError = true
    }

    /// Show a build: with a world loaded, the area around it; otherwise the build alone.
    func select(_ id: Build.ID?) {
        selected = id
        guard let build = builds.first(where: { $0.id == id }) else { scene = nil; return }
        guard hasWorld else { show(BuildScene(build: build, catalog: catalog)); return }
        let radius = max(Float(regionRadius), max(build.size.x, build.size.z) / 2 + 20)
        openRegion(Region(center: SIMD2(build.origin.x, build.origin.z), radius: radius), name: build.name, keepSelection: true)
    }

    func openRegion(at point: SIMD2<Float>) {
        openRegion(Region(center: point, radius: Float(regionRadius)), name: nil, keepSelection: false)
    }

    /// Bumped by every area opened, so a slow one finishing late does not replace a newer one.
    private var regionRequest = 0

    private func openRegion(_ region: Region, name: String?, keepSelection: Bool) {
        if !keepSelection { selected = nil }
        loading = true
        mode = .scene
        regionRequest += 1
        let request = regionRequest
        let objects = objects, props = propPrefabs, ground = groundPrefabs, catalog = catalog, terrain = terrain
        Task.detached(priority: .userInitiated) {
            let content = RegionContent.cut(objects, region: region, name: name, terrain: terrain,
                                            isGroundSample: { ground.contains($0) },
                                            includeProp: { props.contains($0) })
            // Meshes, grass and nodes are built here, off the main thread; the window
            // stays responsive and only the finished scene is handed over.
            let scene = Unchecked(BuildScene(build: content.build, catalog: catalog, region: content))
            await MainActor.run {
                guard request == self.regionRequest else { return }
                self.loading = false
                self.show(scene.value)
            }
        }
    }

    private func show(_ scene: BuildScene) {
        focus = nil
        scene.setTime(Float(hour))
        self.scene = scene
        level = scene.levels.count - 1
    }

    private func applyState() {
        guard let scene else { return }
        scene.apply(level: level, ghosts: ghosts, focus: focus, surroundings: surroundings)
    }

    var layerLabel: String {
        guard let scene else { return "" }
        let n = scene.levels.count
        if scene.build.pieces.isEmpty { return "\(scene.props.count) objects around · no player-built pieces here" }
        if level >= n - 1 { return "All \(n) layers · \(scene.build.pieces.count) pieces" }
        let cut = scene.levels[level]
        let inLayer = scene.levelOf.filter { $0 == cut }.count
        return "Layer \(level + 1)/\(n) · \(String(format: "%.1f", cut)) m up · \(inLayer) pieces"
    }

    func hover(_ target: (isProp: Bool, index: Int)?, at point: CGPoint) {
        guard let target, let scene else { hovered = nil; return }
        let object = target.isProp ? scene.props[target.index] : scene.build.pieces[target.index]
        hovered = (object, target.isProp, point)
    }

    func exportSelected() {
        guard let build = scene?.build, !build.pieces.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = build.name.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression) + ".json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BuildFile.export(build).write(to: url)
            status = "Saved \(url.lastPathComponent)."
            statusIsError = false
        } catch {
            failed(error.localizedDescription)
        }
    }

    func openExample() {
        if let url = Bundle.module.url(forResource: "watchtower", withExtension: "json") { open(url) }
    }

    /// Take a world off the recent list; it still shows if it sits in a save folder.
    func forget(_ world: WorldEntry) {
        Settings.forget(world.url)
        refreshWorlds()
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = current?.url.deletingLastPathComponent()
        panel.message = "Choose a world save — a .db file, or the folder of a chunked world — or a build file (.json)"
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}

/// Hands a value built on one thread to another. Only for values nothing else
/// touches in between, such as a scene finished in the background.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// What the sidebar says about the open world or build file.
struct WorldInfo {
    var name: String
    var pieces: Int
    var builds: Int
    /// Everything in the save; nil for a build file.
    var objects: Int?
    /// Exact or estimated ground; nil for a build file.
    var terrain: TerrainState?
    var warnings: [String]

    struct TerrainState {
        var isExact: Bool
        /// Zones players have levelled, dug or painted.
        var edited: Int
        /// The full explanation, for a tooltip.
        var note: String
    }
}

/// The little the app remembers between launches, in its user defaults.
enum Settings {
    private static let defaults = UserDefaults.standard
    private static let recentKey = "recentWorlds"
    private static let recentLimit = 12

    static func double(_ key: String) -> Double? { defaults.object(forKey: key) as? Double }
    static func bool(_ key: String) -> Bool? { defaults.object(forKey: key) as? Bool }
    static func set(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    private struct Recent: Codable { var path: String; var opened: Date }

    /// Worlds and build files opened before, most recent first.
    static var recentWorlds: [(url: URL, opened: Date)] {
        guard let data = defaults.data(forKey: recentKey),
              let list = try? JSONDecoder().decode([Recent].self, from: data) else { return [] }
        return list.map { (URL(fileURLWithPath: $0.path), $0.opened) }
    }

    static func remember(_ url: URL) {
        let path = url.standardizedFileURL.path
        var list = recentWorlds.map { Recent(path: $0.url.path, opened: $0.opened) }.filter { $0.path != path }
        list.insert(Recent(path: path, opened: Date()), at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(recentLimit))) { defaults.set(data, forKey: recentKey) }
    }

    static func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        let list = recentWorlds.map { Recent(path: $0.url.path, opened: $0.opened) }.filter { $0.path != path }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: recentKey) }
    }
}
