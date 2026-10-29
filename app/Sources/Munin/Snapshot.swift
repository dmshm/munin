import AppKit
import Metal
import SceneKit
import MuninCore

/// `Munin --snapshot <world|build.json> <out-dir> [build-index | x,z] [radius] [--plan <plan.json>]`
/// renders the chosen build from each preset to PNGs without opening a window —
/// for checking rendering from scripts, and for sharing a build as pictures.
/// `--plan`, anywhere on the line, lays a `munin-plan/1` file over a world first.
enum Snapshot {
    static func runIfRequested() {
        var args = CommandLine.arguments
        // Taken out first, so the positional arguments after --snapshot stay where they were.
        var plan: URL?
        var planMissing = false
        if let p = args.firstIndex(of: "--plan") {
            if args.count > p + 1 {
                plan = URL(fileURLWithPath: args[p + 1])
                args.removeSubrange(p...p + 1)
            } else {
                planMissing = true
                args.remove(at: p)
            }
        }
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 else { return }
        if planMissing {
            FileHandle.standardError.write(Data("snapshot failed: --plan needs a plan file after it\n".utf8))
            exit(1)
        }
        do {
            let pick = args.count > i + 3 ? args[i + 3] : "0"
            let at = pick.split(separator: ",").compactMap { Float($0) }
            try run(input: URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]),
                    index: Int(pick) ?? 0, at: at.count == 2 ? SIMD2(at[0], at[1]) : nil,
                    radius: args.count > i + 4 ? Float(args[i + 4]) ?? 50 : 50, plan: plan)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// `at`: world x, z to centre an area on instead of a build. `plan`: changes to lay
    /// over the world's objects in memory before anything is cut from them.
    static func run(input: URL, out: URL, index: Int, at: SIMD2<Float>? = nil, radius: Float, plan planURL: URL? = nil) throws {
        let catalog = Timing.measure("catalog") { try? PieceCatalog() }
        let scene: BuildScene
        if input.pathExtension.lowercased() == "json" {
            if planURL != nil {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "--plan needs a world, not a build file"])
            }
            scene = BuildScene(build: try BuildFile.load(Data(contentsOf: input)), catalog: catalog)
        } else {
            // A world renders the build with its surroundings, as the app shows it.
            var world = try Timing.measure("read world") { try WorldReader.load(input) }
            if let planURL {
                let plan = try PlanFile.load(Data(contentsOf: planURL))
                let applied = Timing.measure("apply plan") { plan.apply(to: world.objects) }
                world.objects = applied.objects
                print("Plan \"\(plan.name)\": \(applied.added) added, \(applied.removed) removed"
                      + (applied.unmatched > 0 ? ", \(applied.unmatched) unmatched" : ""))
            }
            let builds = Timing.measure("cluster builds") { clusterPieces(world.pieces) }
            let (props, ground) = Timing.measure("classify prefabs") { catalog?.classify(world.objects) ?? ([], []) }
            _ = Timing.measure("render map") { WorldMap.render(world.objects) }
            let region: Region
            var name: String?
            if let at {
                region = Region(center: at, radius: radius)
            } else {
                guard builds.indices.contains(index) else { throw CocoaError(.fileReadUnknown) }
                let build = builds[index]
                region = Region(center: SIMD2(build.origin.x, build.origin.z), radius: max(radius, max(build.size.x, build.size.z) / 2 + 20))
                name = build.name
            }
            let (terrain, note) = Timing.measure("load terrain") { TerrainStore.load(for: input, edits: world.terrainEdits) }
            print(note)
            let content = Timing.measure("cut region") { RegionContent.cut(world.objects, region: region, name: name, terrain: terrain,
                                            isGroundSample: { ground.contains($0) }, includeProp: { props.contains($0) }) }
            scene = Timing.measure("build scene (total)") { BuildScene(build: content.build, catalog: catalog, region: content) }
        }
        scene.apply(level: scene.levels.count - 1, ghosts: true, focus: nil)
        if let hour = ProcessInfo.processInfo.environment["MUNIN_HOUR"].flatMap(Float.init) { scene.setTime(hour) }

        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene.scene
        renderer.pointOfView = scene.camera
        if Timing.enabled {
            // Frame cost, roughly: the first frame compiles shaders, later ones are steady state.
            scene.frame(.iso)
            _ = Timing.measure("first frame") { renderer.snapshot(atTime: 0, with: CGSize(width: 1600, height: 1000), antialiasingMode: .multisampling4X) }
            let start = CACurrentMediaTime()
            for i in 1...20 { _ = renderer.snapshot(atTime: Double(i) / 60, with: CGSize(width: 1600, height: 1000), antialiasingMode: .multisampling4X) }
            Timing.report("20 more frames", since: start)
        }
        for (preset, zoom, suffix) in ViewPreset.allCases.map({ ($0, Float(1), "") }) + [(.iso, 3, "-close"), (.south, 4, "-close"), (.south, 12, "-ground")] {
            scene.frame(preset, zoom: zoom)
            // A couple of seconds in, so flames have risen.
            let image = renderer.snapshot(atTime: 2, with: CGSize(width: 1200, height: 900), antialiasingMode: .multisampling4X)
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let name = preset.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            try png.write(to: out.appendingPathComponent("\(name)\(suffix).png"))
        }
        print("\(scene.build.name): \(scene.build.pieces.count) pieces, \(scene.props.count) props, catalog \(catalog == nil ? "missing" : "loaded") -> \(out.path)")
    }
}
