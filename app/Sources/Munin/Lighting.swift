import AppKit
import SceneKit
import simd
import MuninCore

/// Time of day, and the game's own light sources: every torch, fire, brazier and
/// lantern carries a Light (colour, range, intensity) and a LightFlicker in its prefab,
/// extracted by tools/extract_meshes.py. Fires burn only while they have fuel, which the
/// save records per fire.
extension BuildScene {
    /// How the sky and sun look at one hour; hours in between are blended.
    struct Palette {
        var zenith, upper, horizon, haze, below: SIMD3<Float>
        var sunColor: SIMD3<Float>
        var sun: Float, ambient: Float, environment: Float, exposure: Float

        static func mix(_ a: Palette, _ b: Palette, _ t: Float) -> Palette {
            func m(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> { x + (y - x) * t }
            func f(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
            return Palette(zenith: m(a.zenith, b.zenith), upper: m(a.upper, b.upper), horizon: m(a.horizon, b.horizon),
                           haze: m(a.haze, b.haze), below: m(a.below, b.below), sunColor: m(a.sunColor, b.sunColor),
                           sun: f(a.sun, b.sun), ambient: f(a.ambient, b.ambient),
                           environment: f(a.environment, b.environment), exposure: f(a.exposure, b.exposure))
        }

        static let night = Palette(zenith: [0.02, 0.03, 0.07], upper: [0.04, 0.06, 0.12], horizon: [0.09, 0.11, 0.18],
                                   haze: [0.06, 0.07, 0.11], below: [0.04, 0.05, 0.08], sunColor: [0.55, 0.65, 0.95],
                                   sun: 140, ambient: 35, environment: 0.1, exposure: 0.7)
        static let dawn = Palette(zenith: [0.20, 0.28, 0.46], upper: [0.55, 0.52, 0.58], horizon: [0.96, 0.66, 0.46],
                                  haze: [0.72, 0.62, 0.56], below: [0.42, 0.40, 0.40], sunColor: [1, 0.72, 0.48],
                                  sun: 800, ambient: 140, environment: 0.45, exposure: 0)
        static let day = Palette(zenith: [0.23, 0.38, 0.58], upper: [0.52, 0.66, 0.80], horizon: [0.72, 0.78, 0.82],
                                 haze: [0.62, 0.68, 0.72], below: [0.46, 0.52, 0.56], sunColor: [1, 0.95, 0.86],
                                 sun: 1600, ambient: 250, environment: 0.8, exposure: -0.3)
        static let dusk = Palette(zenith: [0.16, 0.20, 0.38], upper: [0.50, 0.42, 0.52], horizon: [0.98, 0.52, 0.32],
                                  haze: [0.66, 0.50, 0.46], below: [0.36, 0.32, 0.34], sunColor: [1, 0.56, 0.34],
                                  sun: 650, ambient: 110, environment: 0.38, exposure: 0.1)

        /// Keyframes through the day: night until dawn, day from mid-morning, dusk at evening.
        static func at(hour: Float) -> Palette {
            let keys: [(Float, Palette)] = [(0, night), (5, night), (6.5, dawn), (9, day), (16, day), (18.5, dusk), (20, night), (24, night)]
            let h = hour.truncatingRemainder(dividingBy: 24)
            for i in 0..<(keys.count - 1) where h >= keys[i].0 && h <= keys[i + 1].0 {
                let t = (h - keys[i].0) / max(keys[i + 1].0 - keys[i].0, 0.001)
                return mix(keys[i].1, keys[i + 1].1, t * t * (3 - 2 * t))
            }
            return night
        }
    }

    func setUpSun() {
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        scene.rootNode.addChildNode(ambient)

        let light = SCNLight()
        light.type = .directional
        light.castsShadow = true
        light.shadowMode = .deferred
        light.shadowSampleCount = 8
        light.shadowRadius = 2
        light.shadowMapSize = CGSize(width: 4096, height: 4096)
        light.shadowColor = NSColor(white: 0, alpha: 0.55)
        light.automaticallyAdjustsShadowProjection = true
        light.maximumShadowDistance = CGFloat(extent * 3)
        sun.light = light
        scene.rootNode.addChildNode(sun)
    }

    /// Sun (or moon) position, sky, ambient light and exposure for an hour of the day.
    func setTime(_ hour: Float) {
        let p = Palette.at(hour: hour)
        // The sun rises in the east, stands in the south at noon, sets in the west;
        // at night the moon takes the opposite arc. SceneKit +x is east, +z south.
        let day = hour >= 6 && hour < 18
        let a = (day ? hour - 6 : (hour + 6).truncatingRemainder(dividingBy: 24)) / 12 * .pi
        let elevation = max(sin(a), 0.08) * 1.0
        let toSun = simd_normalize(SIMD3<Float>(cos(a), elevation, 0.45))
        sun.simdPosition = toSun * 200
        sun.simdLook(at: .zero, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        sun.light?.intensity = CGFloat(p.sun)
        sun.light?.color = NSColor(srgbRed: CGFloat(p.sunColor.x), green: CGFloat(p.sunColor.y), blue: CGFloat(p.sunColor.z), alpha: 1)
        ambient.light?.intensity = CGFloat(p.ambient)
        ambient.light?.color = NSColor(srgbRed: CGFloat(p.upper.x * 0.5 + 0.5), green: CGFloat(p.upper.y * 0.5 + 0.5),
                                       blue: CGFloat(p.upper.z * 0.5 + 0.5), alpha: 1)

        let sky = skyImage(p)
        scene.background.contents = sky
        scene.lightingEnvironment.contents = sky
        scene.lightingEnvironment.intensity = CGFloat(p.environment)
        if region != nil {
            scene.fogColor = color(p.haze)
            scene.fogStartDistance = CGFloat(extent * 6)
            scene.fogEndDistance = CGFloat(extent * 16)
        }
        camera.camera?.exposureOffset = CGFloat(p.exposure)
        // A fire hardly shows in full sun; at night it is everything.
        fireScale.value = CGFloat(1 - (p.sun - Palette.night.sun) / (Palette.day.sun - Palette.night.sun) * 0.6)
    }

    private func color(_ c: SIMD3<Float>) -> NSColor {
        NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }

    /// A vertical gradient: backdrop and image-based ambient light at once.
    private func skyImage(_ p: Palette) -> NSImage {
        let image = NSImage(size: NSSize(width: 512, height: 256))
        image.lockFocus()
        NSGradient(colorsAndLocations:
            (color(p.zenith), 0.0), (color(p.upper), 0.38), (color(p.horizon), 0.5),
            // Below the horizon: haze, so an area's edge fades out rather than floats.
            (color(p.haze), 0.6), (color(p.below), 1.0)
        )!.draw(in: NSRect(x: 0, y: 0, width: 512, height: 256), angle: -90) // first colour at the top: the zenith
        image.unlockFocus()
        return image
    }

    // MARK: - fire

    /// Lights, flicker and flames for every burning light source among `objects`.
    /// Point lights are costly, so only the `limit` nearest the centre get one;
    /// every fire still gets its flames.
    func addFires(_ objects: [(node: SCNNode, object: Piece)], catalog: PieceCatalog, limit: Int = 48) {
        /// Light, whether it has flames, distance for picking which get a light, and the
        /// height its flames start at when not at the light (ground fires).
        var candidates: [(SCNNode, PieceCatalog.LightDef, Bool, Float, Float?)] = []
        for (node, object) in objects {
            guard let name = object.name, let entry = catalog.manifest.pieces[name], let lights = entry.lights else { continue }
            if let fire = entry.fire {
                // Burning while there is fuel; a fire the save has no fuel for keeps its starting fuel.
                guard fire.infiniteFuel || (object.fuel ?? fire.startFuel) > 0 else { continue }
            }
            let flames = entry.fire != nil || name.lowercased().contains("candle")
            // A fire pit's light hangs above it; its flames belong among the stones.
            let low = entry.bounds.count == 2 && entry.bounds[1][1] - entry.bounds[0][1] < 0.6
            let flameHeight: Float? = flames && low ? entry.bounds[0][1] + 0.1 : nil
            for l in lights {
                // Smelters and kilns glow only with fuel loaded; a forge's light means someone
                // is crafting at it, which a save cannot say, so it stays dark.
                if entry.fire == nil, l.switched == true, (object.fuel ?? 0) <= 0 { continue }
                candidates.append((node, l, flames, simd_length(object.position), flameHeight))
            }
        }
        let lit = Set(candidates.indices.sorted { candidates[$0].3 < candidates[$1].3 }.prefix(limit))
        for (i, (node, def, flames, _, flameHeight)) in candidates.enumerated() {
            let at = SIMD3(def.position[0], def.position[1], def.position[2])
            let holder = SCNNode()
            holder.simdPosition = sceneKitPosition(at)
            node.addChildNode(holder)
            if lit.contains(i) { holder.light = pointLight(def, on: holder) }
            guard flames else { continue }
            let size = min(max(def.range / 12, 0.4), 2.2)
            if let flameHeight {
                let base = SCNNode()
                base.simdPosition = sceneKitPosition(SIMD3(at.x, flameHeight, at.z))
                node.addChildNode(base)
                // A campfire burns bigger than the flame on a torch.
                base.addParticleSystem(flame(size: size * 2))
            } else {
                holder.addParticleSystem(flame(size: size))
            }
        }
    }

    private func pointLight(_ def: PieceCatalog.LightDef, on node: SCNNode) -> SCNLight {
        let light = SCNLight()
        light.type = .omni
        light.color = NSColor(srgbRed: CGFloat(def.color[0]), green: CGFloat(def.color[1]), blue: CGFloat(def.color[2]), alpha: 1)
        // Unity's intensity is relative; this scale reads like the game against the
        // physically based sun above. Fires stand close together and their light adds
        // up, so a single one stays well below the sun's level.
        // Stations go up to 5 over a few metres, which here would burn nearby surfaces white.
        let base = CGFloat(min(def.intensity, 1.5) * 130)
        light.intensity = base * fireScale.value
        light.attenuationStartDistance = 0
        light.attenuationEndDistance = CGFloat(def.range)
        // Close to the game's falloff: bright near the flame, little left at the range's edge.
        light.attenuationFalloffExponent = 2.2
        light.castsShadow = false
        // As the game's LightFlicker: a noisy wobble of brightness at its own speed,
        // scaled down in daylight (see setTime).
        let phase = Float.random(in: 0...100), speed = def.flicker?.speed ?? 0, amount = def.flicker?.intensity ?? 0
        let scale = fireScale
        node.runAction(.repeatForever(.customAction(duration: 60) { _, t in
            let x = Float(t) * speed * 0.35 + phase
            let wobble = sin(x) * 0.55 + sin(x * 2.3 + 1.7) * 0.3 + sin(x * 5.1 + 0.4) * 0.15
            light.intensity = base * scale.value * CGFloat(1 + amount * 0.8 * wobble)
        }))
        return light
    }

    private static let flameImage: NSImage = {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSGradient(colors: [.white, NSColor(white: 1, alpha: 0)])!
            .draw(fromCenter: NSPoint(x: 32, y: 32), radius: 0, toCenter: NSPoint(x: 32, y: 32), radius: 32, options: [])
        image.unlockFocus()
        return image
    }()

    /// Flames: additive sparks rising and fading from yellow to red, about `size` m tall.
    private func flame(size: Float) -> SCNParticleSystem {
        let p = SCNParticleSystem()
        p.particleImage = Self.flameImage
        p.birthRate = CGFloat(40 * size)
        p.particleLifeSpan = 0.55
        p.particleLifeSpanVariation = 0.2
        p.emitterShape = SCNSphere(radius: CGFloat(0.06 * size))
        p.particleVelocity = CGFloat(0.5 * size)
        p.particleVelocityVariation = CGFloat(0.2 * size)
        p.emittingDirection = SCNVector3(0, 1, 0)
        p.spreadingAngle = 12
        p.acceleration = SCNVector3(0, CGFloat(0.6 * size), 0)
        p.particleSize = CGFloat(0.22 * size)
        p.particleSizeVariation = CGFloat(0.08 * size)
        p.blendMode = .additive
        p.isLightingEnabled = false
        p.sortingMode = .none
        let colors = CAKeyframeAnimation()
        colors.values = [NSColor(srgbRed: 1, green: 0.85, blue: 0.45, alpha: 1), NSColor(srgbRed: 1, green: 0.45, blue: 0.12, alpha: 0.85),
                         NSColor(srgbRed: 0.6, green: 0.12, blue: 0.04, alpha: 0)]
        colors.keyTimes = [0, 0.45, 1]
        p.propertyControllers = [.color: SCNParticlePropertyController(animation: colors)]
        let shrink = CAKeyframeAnimation()
        shrink.values = [1.0, 0.7, 0.2]
        shrink.keyTimes = [0, 0.5, 1]
        p.propertyControllers?[.size] = SCNParticlePropertyController(animation: shrink)
        return p
    }
}

/// Shared brightness factor for fire lights, read by their flicker every frame.
final class FireScale {
    var value: CGFloat = 1
}
