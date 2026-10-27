import AppKit
import Metal
import SceneKit
import MuninCore

/// `Munin --snapshot <world|build.json> <out-dir> [build-index | x,z] [radius]`
/// renders the chosen build from each preset to PNGs without opening a window —
/// for checking rendering from scripts, and for sharing a build as pictures.
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 else { return }
        do {
            let pick = args.count > i + 3 ? args[i + 3] : "0"
            let at = pick.split(separator: ",").compactMap { Float($0) }
            try run(input: URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]),
                    index: Int(pick) ?? 0, at: at.count == 2 ? SIMD2(at[0], at[1]) : nil,
                    radius: args.count > i + 4 ? Float(args[i + 4]) ?? 50 : 50)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// `at`: world x, z to centre an area on instead of a build.
    static func run(input: URL, out: URL, index: Int, at: SIMD2<Float>? = nil, radius: Float) throws {
        let catalog = try? PieceCatalog()
        let scene: BuildScene
        if input.pathExtension.lowercased() == "json" {
            scene = BuildScene(build: try BuildFile.load(Data(contentsOf: input)), catalog: catalog)
        } else {
            // A world renders the build with its surroundings, as the app shows it.
            let world = try WorldReader.load(input)
            let builds = clusterPieces(world.pieces)
            let (props, ground) = catalog?.classify(world.objects) ?? ([], [])
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
            let (terrain, note) = TerrainStore.load(for: input, edits: world.terrainEdits)
            print(note)
            let content = RegionContent.cut(world.objects, region: region, name: name, terrain: terrain,
                                            isGroundSample: { ground.contains($0) }, includeProp: { props.contains($0) })
            scene = BuildScene(build: content.build, catalog: catalog, region: content)
        }
        scene.apply(level: scene.levels.count - 1, ghosts: true, focus: nil)
        if let hour = ProcessInfo.processInfo.environment["MUNIN_HOUR"].flatMap(Float.init) { scene.setTime(hour) }

        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene.scene
        renderer.pointOfView = scene.camera
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
