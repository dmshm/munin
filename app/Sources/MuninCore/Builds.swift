import Foundation

/// One placed object — a build piece when it has a `creator`, otherwise a tree, rock,
/// creature… — in Valheim's own frame (Unity: left-handed, y up, z north).
/// `rotation` is Euler degrees, applied Z, then X, then Y.
public struct Piece: Hashable {
    public var prefab: Int32
    public var position: SIMD3<Float>
    public var rotation: SIMD3<Float>
    public var scale: SIMD3<Float>
    public var creator: Int64?
    /// Fuel left in a fire, torch or brazier, when the save records it; empty fires are out.
    public var fuel: Float?

    public init(prefab: Int32, position: SIMD3<Float>, rotation: SIMD3<Float>, scale: SIMD3<Float> = .one, creator: Int64? = nil) {
        self.prefab = prefab
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.creator = creator
    }

    public var name: String? { PrefabNames.shared.name(for: prefab) }
    /// Name when known, otherwise the raw hash — what a list shows.
    public var label: String { name ?? "#\(prefab)" }
}

/// Saves only store prefab hashes; names come from whatever has been seen —
/// the extracted mesh catalog, imported build files.
public final class PrefabNames: @unchecked Sendable {
    public static let shared = PrefabNames()
    private var names: [Int32: String] = [:]
    private let lock = NSLock()

    public func add<S: Sequence>(_ list: S) where S.Element == String {
        lock.lock(); defer { lock.unlock() }
        for n in list { names[stableHash(n)] = n }
    }

    public func name(for hash: Int32) -> String? {
        lock.lock(); defer { lock.unlock() }
        return names[hash]
    }
}

/// A cluster of pieces — a base, a tower, a lone portal. Piece positions are
/// relative to `origin`: the horizontal centre of the build at its lowest piece.
public struct Build: Identifiable, Hashable {
    public let id = UUID()
    public var name: String
    public var origin: SIMD3<Float>
    public var size: SIMD3<Float>
    public var pieces: [Piece]

    /// `origin` defaults to the horizontal centre of the pieces at the lowest one.
    public init(name: String?, worldPieces: [Piece], origin explicitOrigin: SIMD3<Float>? = nil) {
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        for p in worldPieces {
            lo = pointwiseMin(lo, p.position)
            hi = pointwiseMax(hi, p.position)
        }
        if worldPieces.isEmpty { lo = .zero; hi = .zero }
        let origin = explicitOrigin ?? SIMD3((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2)
        self.origin = origin
        self.size = hi - lo
        self.pieces = worldPieces.map { var p = $0; p.position -= origin; return p }
        self.name = name ?? Build.describe(pieces.count, origin)
    }

    static func describe(_ count: Int, _ origin: SIMD3<Float>) -> String {
        "\(count) pieces @ \(Int(origin.x.rounded())), \(Int(origin.z.rounded()))"
    }

    /// Piece counts by label, most first — roughly the bill of materials.
    public var counts: [(label: String, count: Int)] {
        Dictionary(grouping: pieces, by: \.label)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }
}

/// Group pieces whose centres are within `link` metres of each other, largest first.
public func clusterPieces(_ pieces: [Piece], link: Float = 6) -> [Build] {
    var parent = Array(pieces.indices)
    func find(_ i: Int) -> Int {
        var i = i
        while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
        return i
    }

    struct Cell: Hashable { var x, y, z: Int32 }
    func cell(_ p: SIMD3<Float>) -> Cell {
        Cell(x: Int32((p.x / link).rounded(.down)), y: Int32((p.y / link).rounded(.down)), z: Int32((p.z / link).rounded(.down)))
    }
    var cells: [Cell: [Int]] = [:]
    for (i, p) in pieces.enumerated() { cells[cell(p.position), default: []].append(i) }

    let link2 = link * link
    for (i, p) in pieces.enumerated() {
        let c = cell(p.position)
        for dx: Int32 in -1...1 { for dy: Int32 in -1...1 { for dz: Int32 in -1...1 {
            for j in cells[Cell(x: c.x + dx, y: c.y + dy, z: c.z + dz)] ?? [] where j > i {
                let d = pieces[j].position - p.position
                if (d * d).sum() <= link2 { parent[find(i)] = find(j) }
            }
        }}}
    }

    return Dictionary(grouping: pieces.indices, by: find)
        .values
        .map { Build(name: nil, worldPieces: $0.map { pieces[$0] }) }
        .sorted { $0.pieces.count > $1.pieces.count }
}

// MARK: - Build files

/// A single build as JSON (`munin-build/1`), small enough to keep with notes —
/// or to type by hand. Unknown prefabs are kept by hash, so nothing is lost.
public enum BuildFile {
    public static let format = "munin-build/1"

    struct File: Codable {
        var format: String
        var name: String
        var origin: [Float]?
        var pieces: [Entry]
    }

    struct Entry: Codable {
        var prefab: Prefab
        var pos: [Float]
        var rot: [Float]?
    }

    enum Prefab: Codable {
        case name(String), hash(Int32)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .name(s) } else { self = .hash(try c.decode(Int32.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .name(let s): try c.encode(s)
            case .hash(let h): try c.encode(h)
            }
        }
    }

    public static func export(_ build: Build) throws -> Data {
        func round(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z].map { ($0 * 1000).rounded() / 1000 } }
        let file = File(
            format: format,
            name: build.name,
            origin: round(build.origin),
            pieces: build.pieces.map {
                Entry(prefab: $0.name.map(Prefab.name) ?? .hash($0.prefab), pos: round($0.position), rot: round($0.rotation))
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    public static func load(_ data: Data) throws -> Build {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.format == format else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Not a \(format) file (format: \(file.format))"])
        }
        let origin = vec(file.origin ?? [0, 0, 0])
        var names: [String] = []
        let pieces = file.pieces.map { e -> Piece in
            let hash: Int32
            switch e.prefab {
            case .name(let n): hash = stableHash(n); names.append(n)
            case .hash(let h): hash = h
            }
            return Piece(prefab: hash, position: vec(e.pos) + origin, rotation: vec(e.rot ?? [0, 0, 0]))
        }
        PrefabNames.shared.add(names)
        return Build(name: file.name, worldPieces: pieces)
    }

    static func vec(_ a: [Float]) -> SIMD3<Float> {
        SIMD3(a.count > 0 ? a[0] : 0, a.count > 1 ? a[1] : 0, a.count > 2 ? a[2] : 0)
    }
}
