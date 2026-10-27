import Foundation

/// A world to hand to a friend: one zip holding the save (a chunked world folder or a
/// `<world>.db`) and, when there is one, its exported terrain (`<world>.terrain`).
/// Installing one puts both where Munin looks for them.
public enum MapPackage {
    public enum Failure: LocalizedError {
        case noWorld, severalWorlds([String]), tool(String)
        public var errorDescription: String? {
            switch self {
            case .noWorld: return "The zip holds no Valheim world."
            case .severalWorlds(let names): return "The zip holds several worlds (\(names.joined(separator: ", "))); share one at a time."
            case .tool(let message): return message
            }
        }
    }

    /// The world's name: a chunked world's folder, or a single-file save's file.
    public static func name(of world: URL) -> String {
        world.pathExtension.lowercased() == "db" ? world.deletingPathExtension().lastPathComponent : world.lastPathComponent
    }

    /// Zip `world`, and `terrain` if given, into `destination`.
    public static func create(world: URL, terrain: URL?, to destination: URL) throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("munin-map-\(UUID().uuidString)")
        let name = name(of: world)
        let folder = staging.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        // Copies on APFS are clones, so a large terrain costs no time or space here.
        try FileManager.default.copyItem(at: world, to: folder.appendingPathComponent(world.lastPathComponent))
        if let terrain {
            try FileManager.default.copyItem(at: terrain, to: folder.appendingPathComponent(name + ".terrain"))
        }
        // Zip into the temporary folder, then move it into place from this process:
        // ditto is a separate process, and macOS does not extend to it the access the
        // user gave Munin to a folder like Desktop or Downloads by choosing it.
        let zip = staging.appendingPathComponent(name + ".zip")
        // No resource forks or extended attributes: they turn into ._ files in the zip.
        try ditto(["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", folder.path, zip.path])
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: zip, to: destination)
    }

    /// Unpack `zip` into `worlds` and `terrains`, replacing an older copy of the same
    /// world, and return where the world now is.
    public static func install(_ zip: URL, worlds: URL, terrains: URL) throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("munin-map-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        // Copied first, for the same reason as in `create`.
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let copy = staging.appendingPathComponent("package.zip")
        try FileManager.default.copyItem(at: zip, to: copy)
        let unpacked = staging.appendingPathComponent("unpacked")
        try ditto(["-x", "-k", copy.path, unpacked.path])

        var found: [URL] = [], terrain: URL?
        let items = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let item = items?.nextObject() as? URL {
            if item.lastPathComponent == "__MACOSX" { items?.skipDescendants(); continue }
            let ext = item.pathExtension.lowercased()
            if ext == "terrain" {
                terrain = item
            } else if let folder = WorldReader.chunkedDirectory(for: item) {
                if !found.contains(folder) { found.append(folder) }
                items?.skipDescendants()
            } else if ext == "db", !item.lastPathComponent.contains("_backup") {
                found.append(item)
            }
        }
        guard let world = found.first else { throw Failure.noWorld }
        guard found.count == 1 else { throw Failure.severalWorlds(found.map(name(of:))) }

        let fm = FileManager.default
        try fm.createDirectory(at: worlds, withIntermediateDirectories: true)
        let destination = worlds.appendingPathComponent(world.lastPathComponent)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: world, to: destination)
        if let terrain {
            try fm.createDirectory(at: terrains, withIntermediateDirectories: true)
            let target = terrains.appendingPathComponent(name(of: world) + ".terrain")
            try? fm.removeItem(at: target)
            try fm.moveItem(at: terrain, to: target)
        }
        return destination
    }

    private static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.tool("ditto failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
