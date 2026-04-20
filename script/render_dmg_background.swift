import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: render_dmg_background.swift /path/to/output.png\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let canvasSize = NSSize(width: 720, height: 420)

let image = NSImage(size: canvasSize)
image.lockFocus()

let bounds = NSRect(origin: .zero, size: canvasSize)
let backgroundGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.95, green: 0.97, blue: 1.0, alpha: 1.0),
    NSColor(calibratedRed: 0.90, green: 0.94, blue: 0.99, alpha: 1.0)
])!
backgroundGradient.draw(in: bounds, angle: -90)

let cardRect = bounds.insetBy(dx: 28, dy: 26)
NSColor.white.withAlphaComponent(0.78).setFill()
NSBezierPath(roundedRect: cardRect, xRadius: 28, yRadius: 28).fill()

let leftHalo = NSBezierPath(ovalIn: NSRect(x: 106, y: 154, width: 132, height: 132))
NSColor(calibratedRed: 0.21, green: 0.51, blue: 0.98, alpha: 0.08).setFill()
leftHalo.fill()

let rightHalo = NSBezierPath(ovalIn: NSRect(x: 482, y: 154, width: 132, height: 132))
NSColor(calibratedRed: 0.21, green: 0.51, blue: 0.98, alpha: 0.08).setFill()
rightHalo.fill()

let arrowPath = NSBezierPath()
arrowPath.lineWidth = 10
arrowPath.lineCapStyle = .round
arrowPath.move(to: NSPoint(x: 278, y: 221))
arrowPath.curve(
    to: NSPoint(x: 450, y: 221),
    controlPoint1: NSPoint(x: 332, y: 221),
    controlPoint2: NSPoint(x: 398, y: 221)
)
NSColor(calibratedRed: 0.21, green: 0.51, blue: 0.98, alpha: 0.88).setStroke()
arrowPath.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 450, y: 221))
arrowHead.line(to: NSPoint(x: 424, y: 238))
arrowHead.line(to: NSPoint(x: 424, y: 204))
arrowHead.close()
NSColor(calibratedRed: 0.21, green: 0.51, blue: 0.98, alpha: 0.88).setFill()
arrowHead.fill()

image.unlockFocus()

guard
    let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
else {
    fputs("failed to render background image\n", stderr)
    exit(1)
}

try pngData.write(to: outputURL, options: .atomic)
