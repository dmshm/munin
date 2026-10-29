import AppKit
import Foundation
import MuninCore
import simd
import UniformTypeIdentifiers

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

    @Published private(set) var catalog: PieceCatalog?
    @Published private(set) var catalogError: String?
    let setup = AssetSetup()
    @Published var showSetup = false
    /// Every object shown: the loaded world, with its plan when that shows; empty for a build file.
    private var objects: [Piece] = []
    /// The open world as saved, and as its plan would leave it, each with its builds and
    /// map worked out once, so showing or hiding the plan is a swap.
    private var saved: ShownWorld?
    private var planned: ShownWorld?
    /// The open world's file, which its plan is remembered against; nil for a build file.
    private var openedWorld: URL?
    /// Changes laid over the open world, kept in memory only; the save is never written.
    @Published private(set) var plan: PlanInfo?
    @Published private(set) var showPlan = true
    /// The plan remembered for this world, when it could not be read this time; kept,
    /// so it comes back once the file is fixed.
    @Published private(set) var planIssue: PlanIssue?
    /// A plan opened while its world was still being read.
    private var pendingPlan: URL?
    /// Bumped by every world or build file opened: work started for an earlier one is
    /// dropped when it finishes. Plans have their own counter, bumped by Clear too.
    private var generation = 0
    private var planRequest = 0
    /// The game's terrain for this world, when `munin_export` has been run.
    private var terrain: Terrain?
    /// Prefabs shown around a build, and the subset that stands on the ground.
    private var propPrefabs: Set<Int32> = []
    private var groundPrefabs: Set<Int32> = []

    init() {
        loadCatalog()
        refreshWorlds()
    }

    // MARK: - game assets

    private func loadCatalog() {
        do {
            catalog = try PieceCatalog()
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = "Game assets aren't set up yet, so pieces draw as plain boxes."
        }
    }

    /// Worlds whose trees, rocks and creatures the setup should extract.
    var worldsForSetup: [URL] { worlds.filter { !$0.isBuildFile }.map(\.url) }

    func runSetup() {
        setup.start(worlds: worldsForSetup) { [weak self] in
            guard let self else { return }
            self.loadCatalog()
            // Names and shapes come from the catalog: read what is open again.
            if let current = self.current { self.open(current.url) }
        }
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
        switch url.pathExtension.lowercased() {
        case "zip": importMap(url)
        case "json": openJSON(url)
        default: load(url, data: nil)
        }
    }

    /// A .json is a build file or a plan: read once, off the main thread, to tell which.
    private func openJSON(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: url)
                let isPlan = PlanFile.declaredFormat(data) == PlanFile.format
                await MainActor.run {
                    if isPlan { self.openPlan(url, data: data) } else { self.load(url, data: data) }
                }
            } catch {
                await self.failed(error.localizedDescription)
            }
        }
    }

    private func load(_ url: URL, data: Data?) {
        let entry = WorldLibrary.entry(at: url, source: .other)
        let url = entry?.url ?? url
        generation += 1
        let generation = generation
        loading = true
        statusIsError = false
        opening = entry?.name ?? url.lastPathComponent
        status = "Reading \(opening!)…"
        Task.detached(priority: .userInitiated) {
            do {
                if url.pathExtension.lowercased() == "json" {
                    let build = try BuildFile.load(data ?? Data(contentsOf: url))
                    let info = WorldInfo(name: build.name, pieces: build.pieces.count, builds: 1, objects: nil,
                                         terrain: nil, warnings: [])
                    await self.loaded(url, generation: generation, saved: nil, builds: [build], plan: nil, planIssue: nil,
                                      terrain: nil, info)
                } else {
                    let world = try WorldReader.load(url)
                    // The plan last laid over this world, if any, goes back on. If it cannot
                    // be read now it stays remembered, to retry once the file is fixed.
                    var laid: LaidPlan?
                    var issue: PlanIssue?
                    if let planURL = Settings.plan(for: url) {
                        do { laid = try LaidPlan(Data(contentsOf: planURL), url: planURL, over: world.objects) } catch {
                            issue = PlanIssue(url: planURL, message: error.localizedDescription)
                        }
                    }
                    let saved = ShownWorld(world.objects)
                    let shown = laid?.shown ?? saved
                    TerrainStore.writeZones(world.objects)
                    let (terrain, terrainNote) = TerrainStore.load(for: url, edits: world.terrainEdits)
                    let info = WorldInfo(
                        name: entry?.name ?? url.lastPathComponent,
                        pieces: shown.pieces, builds: shown.builds.count, objects: world.objectCount,
                        terrain: .init(isExact: terrain != nil,
                                       edited: Set(world.terrainEdits.map(\.zone)).count,
                                       note: terrainNote.prefix(1).uppercased() + terrainNote.dropFirst()),
                        warnings: world.warnings)
                    await self.loaded(url, generation: generation, saved: saved, builds: [], plan: laid, planIssue: issue,
                                      terrain: terrain, info)
                }
            } catch {
                await MainActor.run {
                    guard generation == self.generation else { return }
                    self.failed(error.localizedDescription)
                }
            }
        }
    }

    /// `saved` is the world as read; a build file comes as `builds` alone.
    private func loaded(_ url: URL, generation: Int, saved: ShownWorld?, builds buildFile: [Build], plan laid: LaidPlan?,
                        planIssue: PlanIssue?, terrain: Terrain?, _ info: WorldInfo) {
        // Something opened since: this one is out of date.
        guard generation == self.generation else { return }
        loading = false
        opening = nil
        self.saved = saved
        planned = laid?.shown
        plan = laid?.info
        self.planIssue = planIssue
        showPlan = true
        openedWorld = saved == nil ? nil : url
        shownRegion = nil
        sceneRegion = nil
        let shown = laid?.shown ?? saved
        builds = shown?.builds ?? buildFile
        objects = shown?.objects ?? []
        map = shown?.map
        self.terrain = terrain
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
        if let pending = pendingPlan {
            pendingPlan = nil
            openPlan(pending)
        }
    }

    private func classifyPrefabs() {
        (propPrefabs, groundPrefabs) = catalog?.classify(objects) ?? ([], [])
    }

    private func failed(_ message: String) {
        loading = false
        opening = nil
        pendingPlan = nil
        status = message
        statusIsError = true
    }

    /// Show a build: with a world loaded, the area around it; otherwise the build alone.
    func select(_ id: Build.ID?) {
        selected = id
        guard let build = builds.first(where: { $0.id == id }) else { scene = nil; return }
        guard hasWorld else { sceneRegion = nil; show(BuildScene(build: build, catalog: catalog)); return }
        let radius = max(Float(regionRadius), max(build.size.x, build.size.z) / 2 + 20)
        openRegion(Region(center: SIMD2(build.origin.x, build.origin.z), radius: radius), name: build.name, keepSelection: true)
    }

    func openRegion(at point: SIMD2<Float>) {
        openRegion(Region(center: point, radius: Float(regionRadius)), name: nil, keepSelection: false)
    }

    /// Bumped by every area opened, so a slow one finishing late does not replace a newer one.
    private var regionRequest = 0
    /// The area last opened, to cut again when the plan is shown or hidden.
    private var shownRegion: (region: Region, name: String?)?
    /// The area the scene on screen was cut from.
    private var sceneRegion: Region?

    /// `keepView`: frame the new scene as the one on screen, when that shows the same
    /// area, and keep its layer and focus, so the two can be compared. `keepMode`: stay
    /// on the map if that is showing.
    private func openRegion(_ region: Region, name: String?, keepSelection: Bool, keepView: Bool = false, keepMode: Bool = false) {
        if !keepSelection { selected = nil }
        shownRegion = (region, name)
        loading = true
        if !keepMode { mode = .scene }
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
                let compare = keepView && self.sceneRegion == region
                if compare, let old = self.scene {
                    // Same spot on the ground, even if the new scene's origin moved.
                    var rig = old.rig
                    rig.target += sceneKitPosition(old.build.origin - scene.value.build.origin)
                    scene.value.apply(rig)
                }
                self.show(scene.value, keepState: compare)
                self.sceneRegion = region
            }
        }
    }

    /// `keepState`: the same layer height and focus as the scene it replaces.
    private func show(_ scene: BuildScene, keepState: Bool = false) {
        let old = self.scene
        scene.setTime(Float(hour))
        self.scene = scene
        let top = scene.levels.count - 1
        if keepState, let old, level < old.levels.count - 1 {
            let cut = old.levels[level]
            level = scene.levels.indices.min { abs(scene.levels[$0] - cut) < abs(scene.levels[$1] - cut) } ?? top
            applyState()
        } else if keepState {
            level = top
            applyState()
        } else {
            focus = nil
            level = top
        }
    }

    private func applyState() {
        guard let scene else { return }
        scene.apply(level: level, ghosts: ghosts, focus: focus, surroundings: surroundings)
    }

    // MARK: - plans

    /// Lay a plan over the open world and show the area again with it. It is
    /// remembered for this world and goes back on whenever the world is opened.
    /// At launch, before any world, it goes over the last world opened.
    func openPlan(_ url: URL, data: Data? = nil) {
        if opening != nil { pendingPlan = url; return }
        guard let world = openedWorld, let base = saved else {
            if !loading, let last = worlds.first(where: { $0.lastOpened != nil && !$0.isBuildFile }) {
                pendingPlan = url
                load(last.url, data: nil)
            } else {
                status = "\(url.lastPathComponent) is a plan: changes to a world. Open the world first, then the plan."
                statusIsError = true
            }
            return
        }
        planRequest += 1
        let request = planRequest, generation = generation
        statusIsError = false
        status = "Laying \(url.lastPathComponent) over \(info?.name ?? world.lastPathComponent)…"
        let objects = base.objects
        Task.detached(priority: .userInitiated) {
            let result = Unchecked(Result { try LaidPlan(data ?? Data(contentsOf: url), url: url, over: objects) })
            await MainActor.run {
                // A newer plan, a Clear or another world since: this one is out of date.
                guard request == self.planRequest, generation == self.generation else { return }
                switch result.value {
                case .success(let laid):
                    Settings.setPlan(url, for: world)
                    self.plan = laid.info
                    self.planned = laid.shown
                    self.planIssue = nil
                    self.showPlan = true
                    self.status = ""
                    self.showCurrent()
                case .failure(let error):
                    // Only this plan failed: the world and anything opening stay as they are.
                    self.status = "\(url.lastPathComponent): \(error.localizedDescription)"
                    self.statusIsError = true
                }
            }
        }
    }

    /// Show the open world with its plan or as saved, to compare the two.
    func setPlanShown(_ shown: Bool) {
        guard plan != nil, shown != showPlan else { return }
        showPlan = shown
        showCurrent()
    }

    /// Read the plan file again, after it changed on disk or was fixed.
    func reloadPlan() {
        if let url = plan?.url ?? planIssue?.url { openPlan(url) }
    }

    /// Take the plan off this world, here and for next time.
    func clearPlan() {
        guard plan != nil || planIssue != nil, let world = openedWorld else { return }
        planRequest += 1
        Settings.setPlan(nil, for: world)
        let wasShown = plan != nil && showPlan
        plan = nil
        planned = nil
        planIssue = nil
        if wasShown { showCurrent() }
    }

    /// Swap in the world as it should show now, with or without its plan, and cut the
    /// open area again, looking at it from where the camera was.
    private func showCurrent() {
        guard let shown = (plan != nil && showPlan ? planned : nil) ?? saved else { return }
        // The same build if it is still there, though clustering gave it a new id.
        let previous = builds.first { $0.id == selected }?.origin
        objects = shown.objects
        builds = shown.builds
        map = shown.map
        info?.pieces = shown.pieces
        info?.builds = shown.builds.count
        selected = previous.flatMap { origin in
            shown.builds.min { simd_distance($0.origin, origin) < simd_distance($1.origin, origin) }
                .flatMap { simd_distance($0.origin, origin) < 10 ? $0.id : nil }
        }
        if let area = shownRegion {
            let name = builds.first { $0.id == selected }?.name ?? area.name
            openRegion(area.region, name: name, keepSelection: true, keepView: true, keepMode: true)
        }
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
        if let url = Resource.url("watchtower", "json") { open(url) }
    }

    // MARK: - sharing a map

    /// A map zip from a friend: the world goes into Munin's worlds, its terrain next
    /// to the others, and then it opens.
    func importMap(_ zip: URL) {
        loading = true
        statusIsError = false
        opening = zip.deletingPathExtension().lastPathComponent
        status = "Unpacking \(zip.lastPathComponent)…"
        Task.detached(priority: .userInitiated) {
            do {
                let world = try MapPackage.install(zip, worlds: TerrainStore.root.appendingPathComponent("worlds"),
                                                   terrains: TerrainStore.folder)
                await MainActor.run { self.open(world) }
            } catch {
                await self.failed(error.localizedDescription)
            }
        }
    }

    var canExportMap: Bool { current.map { !$0.isBuildFile } ?? false }

    /// File › Export Map…: the open world and its terrain in one zip, to send to a friend.
    func exportMap() {
        guard let world = current, !world.isBuildFile else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = world.name + ".zip"
        panel.allowedContentTypes = [.zip]
        panel.message = "The world and its terrain, in one file. Whoever gets it drops it on Munin's window."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let terrain = TerrainStore.file(for: world.url)
        loading = true
        status = "Packing \(world.name)…"
        statusIsError = false
        Task.detached(priority: .userInitiated) {
            do {
                try MapPackage.create(world: world.url, terrain: terrain, to: url)
                await MainActor.run {
                    self.loading = false
                    self.status = ""
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await self.failed(error.localizedDescription)
            }
        }
    }

    /// Take a world off the recent list; it still shows if it sits in a save folder.
    func forget(_ world: WorldEntry) {
        Settings.forget(world.url)
        refreshWorlds()
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = current?.url.deletingLastPathComponent()
        panel.message = "Choose a world save (a .db file, or the folder of a chunked world), a shared map (.zip), a build file or a plan (.json)"
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

/// Objects to show, with what is derived from them: the builds and the 2D map.
struct ShownWorld {
    var objects: [Piece]
    var builds: [Build]
    var map: WorldMap?
    var pieces: Int { builds.reduce(0) { $0 + $1.pieces.count } }

    init(_ objects: [Piece]) {
        self.objects = objects
        builds = clusterPieces(objects.filter { $0.creator != nil })
        map = WorldMap.render(objects)
    }
}

/// A plan laid over a world's objects, and what it did to them.
struct LaidPlan {
    var info: PlanInfo
    var shown: ShownWorld

    init(_ data: Data, url: URL, over objects: [Piece]) throws {
        let plan = try PlanFile.load(data)
        let applied = plan.apply(to: objects)
        info = PlanInfo(url: url, name: plan.name, added: applied.added, removed: applied.removed, unmatched: applied.unmatched)
        shown = ShownWorld(applied.objects)
    }
}

/// What the sidebar says about the open world's plan.
struct PlanInfo {
    var url: URL
    var name: String
    var added: Int
    var removed: Int
    /// Removals that found no built piece of their kind where they said.
    var unmatched: Int

    var summary: String { "\(added) added, \(removed) removed" }
}

/// A remembered plan that could not be read when its world opened.
struct PlanIssue {
    var url: URL
    var message: String
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

    private static let plansKey = "plans"

    /// The plan file laid over a world, by the world's path.
    static func plan(for world: URL) -> URL? {
        let plans = defaults.dictionary(forKey: plansKey) as? [String: String]
        return plans?[world.standardizedFileURL.path].map { URL(fileURLWithPath: $0) }
    }

    static func setPlan(_ plan: URL?, for world: URL) {
        var plans = defaults.dictionary(forKey: plansKey) as? [String: String] ?? [:]
        plans[world.standardizedFileURL.path] = plan?.standardizedFileURL.path
        defaults.set(plans, forKey: plansKey)
    }

    static func forget(_ url: URL) {
        setPlan(nil, for: url)
        let path = url.standardizedFileURL.path
        let list = recentWorlds.map { Recent(path: $0.url.path, opened: $0.opened) }.filter { $0.path != path }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: recentKey) }
    }
}
