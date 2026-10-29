import Foundation

/// Proposed changes to a world (`munin-plan/1`): built pieces to take away and pieces
/// to add, all in world coordinates. A plan is laid over the objects in memory to see
/// a change before making it in game; the save itself is never touched.
public struct Plan {
    public struct Removal: Sendable, Equatable {
        public var prefab: Int32
        public var position: SIMD3<Float>
    }

    public var name: String
    public var remove: [Removal]
    /// Built pieces, in world coordinates, carrying `Plan.creator`.
    public var add: [Piece]

    /// What added pieces carry as their builder, so clustering and the counts treat
    /// them as built.
    public static let creator: Int64 = -0x4D756E696E // "Munin"
    /// How far from its `pos` a removed piece may stand, in metres.
    public static let tolerance: Float = 0.1

    public struct Applied {
        /// The world's objects with the plan applied: removals gone, additions at the end.
        public var objects: [Piece]
        public var added: Int
        public var removed: Int
        /// Removals with no built piece of that prefab within the tolerance.
        public var unmatched: Int
    }

    /// Each removal takes a built piece of its prefab within `tolerance` of its position,
    /// each piece only once, pairing as many as can be paired and preferring the
    /// closest. Unmatched removals are counted, not fatal.
    public func apply(to objects: [Piece], tolerance: Float = Plan.tolerance) -> Applied {
        // Built pieces of the prefabs a removal names, out of half a million objects,
        // by prefab and a cell the size of the tolerance: a removal looks only in the
        // 27 cells around its own.
        struct Cell: Hashable { var prefab: Int32, x, y, z: Int32 }
        func cell(_ prefab: Int32, _ p: SIMD3<Float>) -> Cell {
            let c = (p / tolerance).rounded(.down)
            return Cell(prefab: prefab, x: Int32(c.x), y: Int32(c.y), z: Int32(c.z))
        }
        let wanted = Set(remove.map(\.prefab))
        var grid: [Cell: [Int]] = [:]
        if !wanted.isEmpty {
            for (i, o) in objects.enumerated() where o.creator != nil && wanted.contains(o.prefab) {
                grid[cell(o.prefab, o.position), default: []].append(i)
            }
        }
        let limit = tolerance * tolerance
        let reach: [[Int]] = remove.map { r in
            let c = cell(r.prefab, r.position)
            var found: [(index: Int, d2: Float)] = []
            for dx: Int32 in -1...1 { for dy: Int32 in -1...1 { for dz: Int32 in -1...1 {
                for i in grid[Cell(prefab: r.prefab, x: c.x + dx, y: c.y + dy, z: c.z + dz)] ?? [] {
                    let d = objects[i].position - r.position
                    let d2 = (d * d).sum()
                    if d2 <= limit { found.append((i, d2)) }
                }
            } } }
            return found.sorted { $0.d2 < $1.d2 }.map(\.index)
        }

        // Pair removals with pieces by augmenting paths, nearest pieces tried first, so a
        // removal never takes the only piece a later one could reach while it had another.
        var owner: [Int: Int] = [:]   // piece index -> removal
        func assign(_ r: Int, _ seen: inout Set<Int>) -> Bool {
            for i in reach[r] where seen.insert(i).inserted {
                if let other = owner[i], !assign(other, &seen) { continue }
                owner[i] = r
                return true
            }
            return false
        }
        var unmatched = 0
        for r in remove.indices {
            var seen = Set<Int>()
            if !assign(r, &seen) { unmatched += 1 }
        }

        var result: [Piece]
        if owner.isEmpty {
            result = objects
        } else {
            var kept = [Bool](repeating: true, count: objects.count)
            for i in owner.keys { kept[i] = false }
            result = []
            result.reserveCapacity(objects.count - owner.count + add.count)
            for (i, o) in objects.enumerated() where kept[i] { result.append(o) }
        }
        result.append(contentsOf: add)
        return Applied(objects: result, added: add.count, removed: owner.count, unmatched: unmatched)
    }
}

/// Reads plan files. Entries are those of a build file: prefabs by name or raw hash.
public enum PlanFile {
    public static let format = "munin-plan/1"

    struct File: Decodable {
        var format: String
        var name: String?
        var remove: [BuildFile.Entry]?
        var add: [BuildFile.Entry]?
    }

    /// The `format` a JSON file declares, if any: tells a plan from a build file.
    public static func declaredFormat(_ data: Data) -> String? {
        struct Header: Decodable { var format: String? }
        return (try? JSONDecoder().decode(Header.self, from: data))?.format
    }

    public static func load(_ data: Data) throws -> Plan {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.format == format else { throw BuildFile.corrupt("Not a \(format) file (format: \(file.format))") }
        var names: [String] = []
        func position(_ e: BuildFile.Entry, _ list: String, _ i: Int) throws -> (Int32, SIMD3<Float>) {
            let prefab = e.prefab.resolved
            if let name = prefab.name { names.append(name) }
            guard e.pos.count == 3, e.pos.allSatisfy(\.isFinite) else {
                throw BuildFile.corrupt("\(list)[\(i)]: pos needs three numbers")
            }
            return (prefab.hash, BuildFile.vec(e.pos))
        }
        // A removal goes by prefab and place only; its rot, if any, is not looked at.
        let remove = try (file.remove ?? []).enumerated().map { i, e in
            let (hash, pos) = try position(e, "remove", i)
            return Plan.Removal(prefab: hash, position: pos)
        }
        let add = try (file.add ?? []).enumerated().map { i, e in
            let (hash, pos) = try position(e, "add", i)
            let rot = e.rot ?? [0, 0, 0]
            guard rot.count == 3, rot.allSatisfy(\.isFinite) else {
                throw BuildFile.corrupt("add[\(i)]: rot needs three numbers")
            }
            return Piece(prefab: hash, position: pos, rotation: BuildFile.vec(rot), creator: Plan.creator)
        }
        PrefabNames.shared.add(names)
        return Plan(name: file.name ?? "Untitled plan", remove: remove, add: add)
    }
}
