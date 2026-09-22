// pad-icon.swift — insets a full-bleed app-icon PNG into the standard
// macOS icon grid (content centered at ~80% of the canvas, transparent
// margin around it). Without this margin a full-bleed icon renders too
// large in the Dock on macOS versions that don't auto-mask/inset icons
// (i.e. everything before macOS 26 Tahoe).
//
// Usage: pad-icon <input.png> <output.png> [scale=0.80]

import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: pad-icon <in> <out> [scale]\n".data(using: .utf8)!)
    exit(2)
}
let inPath  = args[1]
let outPath = args[2]
let scale   = args.count >= 4 ? (Double(args[3]) ?? 0.80) : 0.80

guard let src = NSImage(contentsOfFile: inPath),
      let tiff = src.tiffRepresentation,
      let srcRep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write("✗ cannot read \(inPath)\n".data(using: .utf8)!)
    exit(1)
}

let N = srcRep.pixelsWide   // canvas is square (pixelsWide == pixelsHigh)

guard let canvas = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: N, pixelsHigh: N,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    exit(1)
}
canvas.size = NSSize(width: N, height: N)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
NSGraphicsContext.current?.imageInterpolation = .high

let target = Double(N) * scale
let off    = (Double(N) - target) / 2.0
let rect   = NSRect(x: off, y: off, width: target, height: target)
srcRep.draw(in: rect, from: NSRect(x: 0, y: 0, width: srcRep.pixelsWide, height: srcRep.pixelsHigh),
            operation: .sourceOver, fraction: 1.0,
            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

NSGraphicsContext.restoreGraphicsState()

guard let out = canvas.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try out.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write("✗ cannot write \(outPath): \(error)\n".data(using: .utf8)!)
    exit(1)
}
