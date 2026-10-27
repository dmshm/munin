import AppKit
import SwiftUI
import MuninCore

/// A top-down picture of the explored world, rasterised once per loaded save:
/// generated zones as land, trees green, rocks grey, player builds orange.
struct WorldMap {
    let image: CGImage
    /// World bounds the image covers (Valheim x and z; z is north, image top).
    let minX: Float, maxZ: Float
    let metresPerPixel: Float

    var width: Int { image.width }
    var height: Int { image.height }

    func worldPoint(pixel: CGPoint) -> SIMD2<Float> {
        SIMD2(minX + Float(pixel.x) * metresPerPixel, maxZ - Float(pixel.y) * metresPerPixel)
    }

    func pixel(world p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: CGFloat((p.x - minX) / metresPerPixel), y: CGFloat((maxZ - p.y) / metresPerPixel))
    }

    enum Kind { case tree, rock, other }

    static func kind(of name: String?) -> Kind {
        guard let n = name?.lowercased() else { return .other }
        let trees = ["tree", "beech", "birch", "oak", "pine", "fir", "bush", "shrub", "swamp", "ygga", "sapling", "stub", "log", "vines"]
        let rocks = ["rock", "stone", "cliff", "boulder", "marble", "minerock", "obsidian", "ore"]
        if trees.contains(where: n.contains) { return .tree }
        if rocks.contains(where: n.contains) { return .rock }
        return .other
    }

    static func render(_ objects: [Piece], maxPixels: Int = 2048) -> WorldMap? {
        let zoneHash = stableHash("_ZoneCtrl")
        // Generated zones are the explored world; each is 64 m square.
        let zones = objects.filter { $0.prefab == zoneHash && abs($0.position.x) < 20000 }
        guard !zones.isEmpty else { return nil }
        let xs = zones.map(\.position.x), zs = zones.map(\.position.z)
        let minX = xs.min()! - 64, maxX = xs.max()! + 64
        let minZ = zs.min()! - 64, maxZ = zs.max()! + 64
        let mpp = max((maxX - minX) / Float(maxPixels), (maxZ - minZ) / Float(maxPixels), 1)
        let w = Int(((maxX - minX) / mpp).rounded(.up)), h = Int(((maxZ - minZ) / mpp).rounded(.up))

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CoreGraphics' origin is bottom-left; flip so image row 0 is the north edge.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        func rect(_ x: Float, _ z: Float, _ size: Float) -> CGRect {
            let px = CGFloat((x - minX) / mpp), py = CGFloat((maxZ - z) / mpp), s = CGFloat(size / mpp)
            return CGRect(x: px - s / 2, y: py - s / 2, width: max(s, 1), height: max(s, 1))
        }

        ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.08, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.15, green: 0.17, blue: 0.15, alpha: 1))
        for z in zones { ctx.fill(rect(z.position.x, z.position.z, 64)) }

        var kinds: [Int32: Kind] = [:]
        let tree = CGColor(srgbRed: 0.30, green: 0.52, blue: 0.24, alpha: 0.55)
        let rock = CGColor(srgbRed: 0.55, green: 0.55, blue: 0.52, alpha: 0.6)
        let other = CGColor(srgbRed: 0.45, green: 0.42, blue: 0.30, alpha: 0.35)
        for o in objects where o.creator == nil && o.prefab != zoneHash && o.position.y < RegionContent.dungeonAltitude {
            let k = kinds[o.prefab] ?? { let k = kind(of: o.name); kinds[o.prefab] = k; return k }()
            ctx.setFillColor(k == .tree ? tree : k == .rock ? rock : other)
            ctx.fill(rect(o.position.x, o.position.z, k == .tree ? 3 : 2))
        }
        ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.55, blue: 0.24, alpha: 1)) // Theme.ember
        for o in objects where o.creator != nil {
            ctx.fill(rect(o.position.x, o.position.z, 3))
        }
        guard let image = ctx.makeImage() else { return nil }
        return WorldMap(image: image, minX: minX, maxZ: maxZ, metresPerPixel: mpp)
    }
}

/// Pan with a drag, zoom with a pinch or the buttons, click to open that area in 3D.
struct MapView: View {
    let map: WorldMap
    let builds: [Build]
    @Binding var radius: Double
    var onPick: (SIMD2<Float>) -> Void
    var onPickBuild: (Build) -> Void

    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGSize = .zero
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let fit = min(geo.size.width / CGFloat(map.width), geo.size.height / CGFloat(map.height))
            let scale = fit * zoom * pinch
            let center = CGPoint(x: geo.size.width / 2 + offset.width + drag.width,
                                 y: geo.size.height / 2 + offset.height + drag.height)
            let toView = { (p: CGPoint) in
                CGPoint(x: center.x + (p.x - CGFloat(map.width) / 2) * scale,
                        y: center.y + (p.y - CGFloat(map.height) / 2) * scale)
            }
            let toPixel = { (v: CGPoint) in
                CGPoint(x: (v.x - center.x) / scale + CGFloat(map.width) / 2,
                        y: (v.y - center.y) / scale + CGFloat(map.height) / 2)
            }

            ZStack(alignment: .topLeading) {
                Color(nsColor: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.09, alpha: 1))
                Image(decorative: map.image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
                    .position(center)

                ForEach(builds.prefix(40)) { build in
                    let p = toView(map.pixel(world: SIMD2(build.origin.x, build.origin.z)))
                    Circle()
                        .stroke(Theme.ember, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                        .position(p)
                        .help("\(build.name) — click to open")
                        .onTapGesture { onPickBuild(build) }
                }

                if let hover {
                    let world = map.worldPoint(pixel: toPixel(hover))
                    let r = CGFloat(radius) / CGFloat(map.metresPerPixel) * scale
                    Circle()
                        .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .frame(width: r * 2, height: r * 2)
                        .position(hover)
                        .allowsHitTesting(false)
                    Text("\(Int(world.x)), \(Int(world.y))")
                        .font(.caption.monospacedDigit())
                        .padding(4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .position(x: hover.x, y: hover.y - r - 14)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p } else { hover = nil }
            }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation }
                .onEnded { offset.width += $0.translation.width; offset.height += $0.translation.height; drag = .zero })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { zoom = min(max(zoom * $0.magnification, 0.5), 60); pinch = 1 })
            .onTapGesture(coordinateSpace: .local) { location in
                onPick(map.worldPoint(pixel: toPixel(location)))
            }
            .overlay(alignment: .bottomLeading) { controls }
            .clipped()
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { zoom = min(zoom * 1.5, 60) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { zoom = max(zoom / 1.5, 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
            Button("Fit") { zoom = 1; offset = .zero }
            Divider().frame(height: 16)
            Text("Area radius")
            Slider(value: $radius, in: 20...200, step: 5).frame(width: 160)
            Text("\(Int(radius)) m").monospacedDigit().frame(width: 50, alignment: .leading)
            Text("Click the map to open that area in 3D").foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }
}
