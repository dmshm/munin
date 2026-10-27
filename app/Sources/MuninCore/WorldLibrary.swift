import Foundation

/// A world Munin can open in one click: found where Valheim or Munin keeps saves,
/// or opened before.
public struct WorldEntry: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable {
        /// Downloaded from a dedicated server (tools/fetch_world.sh).
        case server = "Server copy"
        /// The game's own save folder.
        case game = "Single player"
        /// Opened from anywhere else, by hand.
        case other = "Opened before"
    }

    public var url: URL
    public var name: String
    public var source: Source
    /// When the save last changed on disk.
    public var modified: Date?
    /// When Munin last opened it; nil if never.
    public var lastOpened: Date?

    public var id: String { url.standardizedFileURL.path }
    public var isBuildFile: Bool { url.pathExtension.lowercased() == "json" }
}

public enum WorldLibrary {
    /// Folders where saves turn up on a Mac, and what each one means.
    public static func standardFolders(munin: URL) -> [(URL, WorldEntry.Source)] {
        let valheim = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IronGate/Valheim")
        return [
            (munin.appendingPathComponent("worlds"), .server),
            (valheim.appendingPathComponent("worlds_local"), .game),
            (valheim.appendingPathComponent("worlds"), .game),
        ]
    }

    /// The world at `url`, if there is one: a chunked world folder (or a file inside
    /// one), a single-file `<world>.db`, or a saved build `.json`.
    public static func entry(at url: URL, source: WorldEntry.Source) -> WorldEntry? {
        if let folder = WorldReader.chunkedDirectory(for: url) {
            return WorldEntry(url: folder, name: folder.lastPathComponent, source: source, modified: newest(in: folder))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let ext = url.pathExtension.lowercased()
        guard ext == "db" || ext == "json" else { return nil }
        return WorldEntry(url: url, name: url.deletingPathExtension().lastPathComponent, source: source, modified: modified(url))
    }

    /// Worlds directly inside `folder`. Valheim's automatic backups are left out.
    public static func worlds(in folder: URL, source: WorldEntry.Source) -> [WorldEntry] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { !$0.lastPathComponent.contains("_backup") && $0.pathExtension.lowercased() != "json" }
            .compactMap { entry(at: $0, source: source) }
    }

    /// Everything to offer: the worlds opened before, most recent first, then the
    /// others found in `folders`, newest first. Each world appears once; ones that
    /// are gone from disk are dropped.
    public static func discover(recent: [(url: URL, opened: Date)], folders: [(URL, WorldEntry.Source)]) -> [WorldEntry] {
        var found: [String: WorldEntry] = [:]
        for (folder, source) in folders {
            for world in worlds(in: folder, source: source) where found[world.id] == nil { found[world.id] = world }
        }
        var result: [WorldEntry] = []
        var seen = Set<String>()
        for (url, opened) in recent.sorted(by: { $0.opened > $1.opened }) {
            guard var world = entry(at: url, source: .other) else { continue }
            if let known = found[world.id] { world.source = known.source }
            guard seen.insert(world.id).inserted else { continue }
            world.lastOpened = opened
            result.append(world)
        }
        result += found.values
            .filter { !seen.contains($0.id) }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return result
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// A chunked world changes file by file, so its newest file says when it was saved.
    private static func newest(in folder: URL) -> Date? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap(modified).max()
    }
}
