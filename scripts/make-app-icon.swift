// Draws the Liv Vitals app icon at 1024×1024 and writes it as PNG.
// Usage: swift scripts/make-app-icon.swift <output.png>
// Original artwork: a sparkle inside a ring on the Smart Care gradient, on the standard macOS icon grid.
import AppKit

let canvas: CGFloat = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png")

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("Could not create bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt body centered on a 1024 canvas, ~185pt corner radius.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow under the body.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor.black.setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()

// Gradient body (same colors as the Smart Care module).
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.36, green: 0.30, blue: 0.95, alpha: 1),
    NSColor(srgbRed: 0.75, green: 0.25, blue: 0.85, alpha: 1),
    NSColor(srgbRed: 0.95, green: 0.38, blue: 0.62, alpha: 1),
])!
gradient.draw(in: bodyPath, angle: -50)

// Soft top highlight.
NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
highlight.draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
NSGraphicsContext.restoreGraphicsState()

let center = NSPoint(x: 512, y: 512)

// Ring, echoing the round Scan button.
let ringRadius: CGFloat = 268
let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
ring.lineWidth = 44
NSColor.white.withAlphaComponent(0.92).setStroke()
ring.stroke()

/// Four-point sparkle with concave sides: each side curves toward the center.
func sparkle(at point: NSPoint, radius: CGFloat, pinch: CGFloat = 0.18) -> NSBezierPath {
    let tips = [
        NSPoint(x: point.x, y: point.y + radius),
        NSPoint(x: point.x + radius, y: point.y),
        NSPoint(x: point.x, y: point.y - radius),
        NSPoint(x: point.x - radius, y: point.y),
    ]
    let path = NSBezierPath()
    path.move(to: tips[0])
    for index in 0..<4 {
        let next = tips[(index + 1) % 4]
        let control = NSPoint(
            x: point.x + (tips[index].x + next.x - 2 * point.x) * pinch,
            y: point.y + (tips[index].y + next.y - 2 * point.y) * pinch
        )
        path.curve(to: next, controlPoint1: control, controlPoint2: control)
    }
    path.close()
    return path
}

NSColor.white.setFill()
sparkle(at: NSPoint(x: center.x - 10, y: center.y - 14), radius: 172).fill()
sparkle(at: NSPoint(x: center.x + 118, y: center.y + 122), radius: 62).fill()
sparkle(at: NSPoint(x: center.x - 120, y: center.y + 120), radius: 34).fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("Could not encode PNG") }
try png.write(to: output)
print("Wrote \(output.path)")
