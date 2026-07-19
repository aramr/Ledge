#!/usr/bin/env swift

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Usage: generate_ledge_icon.swift <output.png>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let size = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create the Ledge icon canvas.\n", stderr)
    exit(1)
}

let previousContext = NSGraphicsContext.current
NSGraphicsContext.current = graphicsContext
defer {
    graphicsContext.flushGraphics()
    NSGraphicsContext.current = previousContext
}

NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let tileRect = NSRect(x: 64, y: 64, width: 896, height: 896)
let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: 210, yRadius: 210)

NSGraphicsContext.current?.saveGraphicsState()
NSShadow().apply {
    $0.shadowColor = NSColor.black.withAlphaComponent(0.28)
    $0.shadowBlurRadius = 44
    $0.shadowOffset = NSSize(width: 0, height: -22)
}
NSColor.black.setFill()
tilePath.fill()
NSGraphicsContext.current?.restoreGraphicsState()

let background = NSGradient(colors: [
    NSColor(red: 0.09, green: 0.58, blue: 1.0, alpha: 1),
    NSColor(red: 0.34, green: 0.25, blue: 0.91, alpha: 1),
    NSColor(red: 0.46, green: 0.16, blue: 0.72, alpha: 1)
])!
background.draw(in: tilePath, angle: -48)

let glowPath = NSBezierPath(ovalIn: NSRect(x: 175, y: 370, width: 670, height: 430))
let glow = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.17),
    NSColor.white.withAlphaComponent(0)
])!
glow.draw(in: glowPath, relativeCenterPosition: NSPoint(x: 0, y: 0))

let ledgePath = NSBezierPath()
ledgePath.move(to: NSPoint(x: 340, y: 960))
ledgePath.line(to: NSPoint(x: 684, y: 960))
ledgePath.line(to: NSPoint(x: 684, y: 720))
ledgePath.curve(
    to: NSPoint(x: 764, y: 640),
    controlPoint1: NSPoint(x: 684, y: 676),
    controlPoint2: NSPoint(x: 720, y: 640)
)
ledgePath.line(to: NSPoint(x: 832, y: 640))
ledgePath.curve(
    to: NSPoint(x: 896, y: 576),
    controlPoint1: NSPoint(x: 867, y: 640),
    controlPoint2: NSPoint(x: 896, y: 611)
)
ledgePath.line(to: NSPoint(x: 896, y: 528))
ledgePath.curve(
    to: NSPoint(x: 824, y: 456),
    controlPoint1: NSPoint(x: 896, y: 488),
    controlPoint2: NSPoint(x: 864, y: 456)
)
ledgePath.line(to: NSPoint(x: 200, y: 456))
ledgePath.curve(
    to: NSPoint(x: 128, y: 528),
    controlPoint1: NSPoint(x: 160, y: 456),
    controlPoint2: NSPoint(x: 128, y: 488)
)
ledgePath.line(to: NSPoint(x: 128, y: 576))
ledgePath.curve(
    to: NSPoint(x: 192, y: 640),
    controlPoint1: NSPoint(x: 128, y: 611),
    controlPoint2: NSPoint(x: 157, y: 640)
)
ledgePath.line(to: NSPoint(x: 260, y: 640))
ledgePath.curve(
    to: NSPoint(x: 340, y: 720),
    controlPoint1: NSPoint(x: 304, y: 640),
    controlPoint2: NSPoint(x: 340, y: 676)
)
ledgePath.close()

NSGraphicsContext.current?.saveGraphicsState()
NSShadow().apply {
    $0.shadowColor = NSColor.black.withAlphaComponent(0.32)
    $0.shadowBlurRadius = 30
    $0.shadowOffset = NSSize(width: 0, height: -12)
}
NSColor(deviceWhite: 0.015, alpha: 1).setFill()
ledgePath.fill()
NSGraphicsContext.current?.restoreGraphicsState()

let highlight = NSBezierPath()
highlight.move(to: NSPoint(x: 210, y: 640))
highlight.line(to: NSPoint(x: 260, y: 640))
highlight.curve(
    to: NSPoint(x: 340, y: 720),
    controlPoint1: NSPoint(x: 304, y: 640),
    controlPoint2: NSPoint(x: 340, y: 676)
)
highlight.lineWidth = 9
highlight.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.42).setStroke()
highlight.stroke()

let rightHighlight = NSBezierPath()
rightHighlight.move(to: NSPoint(x: 684, y: 720))
rightHighlight.curve(
    to: NSPoint(x: 764, y: 640),
    controlPoint1: NSPoint(x: 684, y: 676),
    controlPoint2: NSPoint(x: 720, y: 640)
)
rightHighlight.line(to: NSPoint(x: 814, y: 640))
rightHighlight.lineWidth = 9
rightHighlight.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.24).setStroke()
rightHighlight.stroke()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to render the Ledge icon.\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try pngData.write(to: outputURL, options: .atomic)

private extension NSShadow {
    func apply(_ configure: (NSShadow) -> Void) {
        configure(self)
        set()
    }
}
