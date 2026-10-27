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
    @Published var regionRadius: Double = 50
    @Published var level = 0 { didSet { applyState() } }
    @Published var ghosts = true { didSet { applyState() } }
    @Published var surroundings = true { didSet { applyState() } }
    /// Hour of the day, 0–24: sun, sky and how much the fires matter.
    @Published var hour: Double = 12 { didSet { scene?.setTime(Float(hour)) } }
    @Published var focus: String? { didSet { applyState() } }
    @Published var hideSmall = true
    @Published var status = "Open a world save (a .db, or a chunked world folder) or a build file (.json)."
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
    }

    var hasWorld: Bool { !objects.isEmpty }

    var visibleBuilds: [Build] {
        builds.filter { !hideSmall || $0.pieces.count >= 10 || $0.id == selected }
    }

    func open(_ url: URL) {
        loading = true
        statusIsError = false
        status = "Reading \(url.lastPathComponent)…"
        Task.detached(priority: .userInitiated) {
            let started = Date()
            do {
                if url.pathExtension.lowercased() == "json" {
                    let build = try BuildFile.load(Data(contentsOf: url))
                    await self.loaded([build], objects: [], terrain: nil, map: nil, "\(url.lastPathComponent): \(build.pieces.count) pieces.")
                } else {
                    let world = try WorldReader.load(url)
                    let builds = clusterPieces(world.pieces)
                    let map = WorldMap.render(world.objects)
                    TerrainStore.writeZones(world.objects)
                    let (terrain, terrainNote) = TerrainStore.load(for: url, edits: world.terrainEdits)
                    let secs = String(format: "%.1f", Date().timeIntervalSince(started))
                    var text = "\(url.lastPathComponent): world v\(world.version), \(world.objectCount.formatted()) objects, "
                        + "\(world.pieces.count.formatted()) player-built pieces in \(builds.count) builds (\(secs)s)."
                    text += "\n" + terrainNote.prefix(1).uppercased() + terrainNote.dropFirst() + "."
                    if !world.warnings.isEmpty { text += "\n" + world.warnings.joined(separator: "\n") }
                    await self.loaded(builds, objects: world.objects, terrain: terrain, map: map, text)
                }
            } catch {
                await self.failed(error.localizedDescription)
            }
        }
    }

    private func loaded(_ builds: [Build], objects: [Piece], terrain: Terrain?, map: WorldMap?, _ text: String) {
        loading = false
        self.builds = builds
        self.objects = objects
        self.terrain = terrain
        self.map = map
        classifyPrefabs()
        status = builds.isEmpty && objects.isEmpty ? "No player-built pieces found." : text
        statusIsError = builds.isEmpty && objects.isEmpty
        mode = .scene
        select(builds.first?.id)
    }

    private func classifyPrefabs() {
        (propPrefabs, groundPrefabs) = catalog?.classify(objects) ?? ([], [])
    }

    private func failed(_ message: String) {
        loading = false
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

    private func openRegion(_ region: Region, name: String?, keepSelection: Bool) {
        if !keepSelection { selected = nil }
        loading = true
        mode = .scene
        let objects = objects, props = propPrefabs, ground = groundPrefabs, catalog = catalog, terrain = terrain
        Task.detached(priority: .userInitiated) {
            let content = RegionContent.cut(objects, region: region, name: name, terrain: terrain,
                                            isGroundSample: { ground.contains($0) },
                                            includeProp: { props.contains($0) })
            await MainActor.run {
                let scene = BuildScene(build: content.build, catalog: catalog, region: content)
                self.loading = false
                self.show(scene)
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

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose a world save — a .db file, or the folder of a chunked world — or a build file (.json)"
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}
