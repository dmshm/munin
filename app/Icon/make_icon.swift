// Draws the app icon: a runestone at night, carved with ᛘ (maðr, the M of Munin).
//
//   swift app/Icon/make_icon.swift app/Icon/Munin.png && app/Icon/make_icns.sh
//
// Drawn in code rather than kept as a design file, so it can be tweaked in a diff.
import AppKit

let size: CGFloat = 1024
let ember = CGColor(red: 1.0, green: 0.55, blue: 0.24, alpha: 1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: an 824 pt rounded square centred on the 1024 canvas, with a drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x000000, 0.45))
ctx.addPath(tilePath); ctx.setFillColor(color(0x0B1420)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()

// Night sky.
linear(ctx, [color(0x2B4560), color(0x152434), color(0x0A121C)], from: CGPoint(x: 0, y: 924), to: CGPoint(x: 0, y: 100))

// Moon, with a soft halo.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: color(0xCFE0F0, 0.55))
ctx.setFillColor(color(0xEDE9DC))
ctx.fillEllipse(in: CGRect(x: 676, y: 676, width: 128, height: 128))
ctx.restoreGState()

// A few stars.
for (x, y, r) in [(220.0, 800.0, 5.0), (300, 700, 3.5), (420, 845, 4), (560, 760, 3), (250, 600, 3), (820, 590, 3.5), (610, 870, 3)] {
    ctx.setFillColor(color(0xFFFFFF, 0.75))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// Hills.
ctx.setFillColor(color(0x101C27))
ctx.move(to: CGPoint(x: 100, y: 330))
ctx.addCurve(to: CGPoint(x: 560, y: 300), control1: CGPoint(x: 260, y: 400), control2: CGPoint(x: 420, y: 360))
ctx.addCurve(to: CGPoint(x: 924, y: 360), control1: CGPoint(x: 700, y: 250), control2: CGPoint(x: 820, y: 300))
ctx.addLine(to: CGPoint(x: 924, y: 100)); ctx.addLine(to: CGPoint(x: 100, y: 100)); ctx.fillPath()
ctx.setFillColor(color(0x070D13))
ctx.move(to: CGPoint(x: 100, y: 240))
ctx.addCurve(to: CGPoint(x: 924, y: 230), control1: CGPoint(x: 380, y: 300), control2: CGPoint(x: 640, y: 180))
ctx.addLine(to: CGPoint(x: 924, y: 100)); ctx.addLine(to: CGPoint(x: 100, y: 100)); ctx.fillPath()

// The runestone: an uneven, rough-hewn slab, smoothed through the midpoints of its outline.
let outline: [CGPoint] = [
    CGPoint(x: 312, y: 200), CGPoint(x: 296, y: 400), CGPoint(x: 328, y: 590), CGPoint(x: 372, y: 712),
    CGPoint(x: 452, y: 792), CGPoint(x: 560, y: 800), CGPoint(x: 646, y: 726), CGPoint(x: 700, y: 572),
    CGPoint(x: 712, y: 380), CGPoint(x: 728, y: 200),
]
let stone = CGMutablePath()
stone.move(to: outline[0])
for i in 1..<outline.count - 1 {
    let mid = CGPoint(x: (outline[i].x + outline[i + 1].x) / 2, y: (outline[i].y + outline[i + 1].y) / 2)
    stone.addQuadCurve(to: i == outline.count - 2 ? outline[i + 1] : mid, control: outline[i])
}
stone.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 30, color: color(0x000000, 0.6))
ctx.addPath(stone); ctx.setFillColor(color(0x5E656C)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(stone); ctx.clip()
linear(ctx, [color(0x979A98), color(0x6C706F), color(0x434847)], from: CGPoint(x: 0, y: 800), to: CGPoint(x: 0, y: 200))
// Moonlight from the upper right: the left side falls into shadow.
linear(ctx, [color(0x000000, 0.38), color(0x000000, 0.08), color(0xFFFFFF, 0.06)], from: CGPoint(x: 300, y: 0), to: CGPoint(x: 720, y: 0))
// Weathering.
for (x, y, w, h) in [(560.0, 300.0, 60.0, 18.0), (400, 460, 44, 14), (610, 520, 30, 40), (380, 260, 70, 12)] {
    ctx.setFillColor(color(0x000000, 0.08))
    ctx.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
}
ctx.restoreGState()

// ᛘ: a stave with two arms rising from it.
let rune = CGMutablePath()
rune.move(to: CGPoint(x: 512, y: 290)); rune.addLine(to: CGPoint(x: 512, y: 700))
rune.move(to: CGPoint(x: 512, y: 520)); rune.addLine(to: CGPoint(x: 420, y: 650))
rune.move(to: CGPoint(x: 512, y: 520)); rune.addLine(to: CGPoint(x: 604, y: 650))

func stroke(_ path: CGPath, width: CGFloat, color c: CGColor, glow: CGFloat = 0, offset: CGSize = .zero) {
    ctx.saveGState()
    if glow > 0 { ctx.setShadow(offset: .zero, blur: glow, color: c) }
    ctx.translateBy(x: offset.width, y: offset.height)
    ctx.addPath(path)
    ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(c); ctx.strokePath()
    ctx.restoreGState()
}
// Carved groove, then the glow inside it.
stroke(rune, width: 50, color: color(0x1E1A17, 0.85))
stroke(rune, width: 50, color: color(0xFFFFFF, 0.18), offset: CGSize(width: 3, height: -4))
stroke(rune, width: 46, color: color(0x241D18))
stroke(rune, width: 30, color: ember, glow: 48)
stroke(rune, width: 12, color: color(0xFFE2B8), glow: 12)

// The ground the stone is set into.
ctx.setFillColor(color(0x070D13))
ctx.move(to: CGPoint(x: 100, y: 250))
ctx.addCurve(to: CGPoint(x: 924, y: 235), control1: CGPoint(x: 360, y: 270), control2: CGPoint(x: 640, y: 210))
ctx.addLine(to: CGPoint(x: 924, y: 100)); ctx.addLine(to: CGPoint(x: 100, y: 100)); ctx.fillPath()

ctx.restoreGState()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Munin.png")
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
