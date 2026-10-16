// make-icon.swift — renders the fannier .iconset (fan glyph) for iconutil.
// Usage: swift make-icon.swift <output.iconset-dir>
import AppKit

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fannier.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

func png(sizePx: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: sizePx, pixelsHigh: sizePx,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    return rep
}

func draw(at rep: NSBitmapImageRep, px: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let r = px * 0.22

    // background: rounded rect, vertical gradient
    let bg = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    bg.addClip()
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.29, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.14, alpha: 1),
    ])!
    grad.draw(in: bg, angle: 270)

    let c = NSPoint(x: px / 2, y: px / 2)

    // ring
    let ring = NSBezierPath()
    ring.appendArc(withCenter: c, radius: px * 0.42, startAngle: 0, endAngle: 360, clockwise: true)
    ring.lineWidth = px * 0.02
    NSColor(calibratedWhite: 1.0, alpha: 0.18).setStroke()
    ring.stroke()

    // 5 blades (46° sectors, 72° apart)
    let blade = NSBezierPath()
    let outer = px * 0.36
    for i in 0 ..< 5 {
        let a0 = CGFloat(i) * 72
        blade.move(to: c)
        blade.appendArc(withCenter: c, radius: outer,
                        startAngle: a0, endAngle: a0 + 46, clockwise: false)
        blade.close()
    }
    NSColor(calibratedWhite: 0.93, alpha: 0.92).setFill()
    blade.fill()

    // hub
    let hubRadius = px * 0.13
    let hub = NSBezierPath(ovalIn: NSRect(
        x: c.x - hubRadius, y: c.y - hubRadius,
        width: hubRadius * 2, height: hubRadius * 2
    ))
    NSColor(calibratedRed: 0.55, green: 0.72, blue: 1.0, alpha: 1).setFill()
    hub.fill()
}

// iconset layout: icon_16x16.png … icon_16x16@2x.png …
let specs: [(Int, Int)] = [ // (logical size, scale)
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

for (logical, scale) in specs {
    let px = logical * scale
    let rep = png(sizePx: px)
    draw(at: rep, px: CGFloat(px))
    let name = scale == 1 ? "icon_\(logical)x\(logical).png" : "icon_\(logical)x\(logical)@2x.png"
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
    print("wrote \(url.path) (\(px)px)")
}
print("iconset ready at \(dir)")
