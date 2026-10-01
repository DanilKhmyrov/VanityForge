import AppKit

// Холст в пикселях при @2x, чтобы фон был чётким на Retina — Finder показывает
// его в half-size точках (660x400), с этим же размером совпадает окно,
// которое настраивает make_dmg.sh через AppleScript.
let pointSize = NSSize(width: 660, height: 400)
let scale: CGFloat = 2
let canvas = NSSize(width: pointSize.width * scale, height: pointSize.height * scale)

let image = NSImage(size: canvas)
image.lockFocus()

let fullRect = NSRect(origin: .zero, size: canvas)

// Тёмная база — тот же тон, что и фон самого приложения (ContentView).
NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.085, alpha: 1.0).setFill()
fullRect.fill()

// Мягкое фиолетово-бирюзовое свечение — те же акцентные цвета, что в
// заголовке сайдбара и на иконке приложения.
func radialGlow(center: NSPoint, radius: CGFloat, color: NSColor) {
    let gradient = NSGradient(colors: [color.withAlphaComponent(0.55), color.withAlphaComponent(0.0)])!
    gradient.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius)
}
radialGlow(center: NSPoint(x: canvas.width * 0.22, y: canvas.height * 0.78),
           radius: canvas.width * 0.42,
           color: NSColor(calibratedRed: 0.55, green: 0.32, blue: 0.98, alpha: 1.0))
radialGlow(center: NSPoint(x: canvas.width * 0.8, y: canvas.height * 0.22),
           radius: canvas.width * 0.42,
           color: NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.72, alpha: 1.0))

// Заголовок.
let titleFont = NSFont.systemFont(ofSize: 30 * scale, weight: .bold)
let title = "VanityForge"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: NSColor.white,
]
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (canvas.width - titleSize.width) / 2, y: canvas.height - titleSize.height - 34 * scale), withAttributes: titleAttrs)

let subtitleFont = NSFont.systemFont(ofSize: 12.5 * scale, weight: .medium)
let subtitle = "Drag the app into Applications to install"
let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: subtitleFont,
    .foregroundColor: NSColor.white.withAlphaComponent(0.55),
]
let subtitleSize = subtitle.size(withAttributes: subtitleAttrs)
subtitle.draw(at: NSPoint(x: (canvas.width - subtitleSize.width) / 2, y: canvas.height - titleSize.height - 34 * scale - subtitleSize.height - 6 * scale), withAttributes: subtitleAttrs)

// Стрелка между будущими позициями иконок (см. make_dmg.sh: app ~x=180pt,
// Applications ~x=480pt, обе на y≈190pt от низа окна).
let arrowY = 190 * scale
let arrowStartX = 250 * scale
let arrowEndX = 410 * scale

let arrowGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.55, green: 0.32, blue: 0.98, alpha: 0.9),
    NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.72, alpha: 0.9),
])!

let shaftPath = NSBezierPath()
shaftPath.lineWidth = 5 * scale
shaftPath.lineCapStyle = .round
shaftPath.move(to: NSPoint(x: arrowStartX, y: arrowY))
shaftPath.line(to: NSPoint(x: arrowEndX - 14 * scale, y: arrowY))

let context = NSGraphicsContext.current
context?.saveGraphicsState()
shaftPath.setClip()
arrowGradient.draw(from: NSPoint(x: arrowStartX, y: arrowY), to: NSPoint(x: arrowEndX, y: arrowY), options: [])
context?.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shaftPath.stroke()
NSGraphicsContext.restoreGraphicsState()

let headPath = NSBezierPath()
headPath.move(to: NSPoint(x: arrowEndX - 22 * scale, y: arrowY + 16 * scale))
headPath.line(to: NSPoint(x: arrowEndX, y: arrowY))
headPath.line(to: NSPoint(x: arrowEndX - 22 * scale, y: arrowY - 16 * scale))
headPath.lineWidth = 5 * scale
headPath.lineCapStyle = .round
headPath.lineJoinStyle = .round
NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.72, alpha: 0.95).setStroke()
headPath.stroke()

image.unlockFocus()

// Flatten to an opaque (no alpha channel) bitmap via Core Graphics — Finder
// can render a DMG background as solid black instead of the picture when
// the PNG carries an alpha channel, even if every pixel is fully opaque
// (NSImage.lockFocus() always backs onto an RGBA store).
guard let tiff = image.tiffRepresentation,
      let sourceRep = NSBitmapImageRep(data: tiff),
      let sourceCGImage = sourceRep.cgImage else {
    FileHandle.standardError.write("failed to rasterize dmg background\n".data(using: .utf8)!)
    exit(1)
}

let pixelsWide = Int(canvas.width)
let pixelsHigh = Int(canvas.height)
guard let flatContext = CGContext(
    data: nil,
    width: pixelsWide,
    height: pixelsHigh,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write("failed to create flat context\n".data(using: .utf8)!)
    exit(1)
}
flatContext.draw(sourceCGImage, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))

guard let flatCGImage = flatContext.makeImage() else {
    FileHandle.standardError.write("failed to flatten image\n".data(using: .utf8)!)
    exit(1)
}
let flatRep = NSBitmapImageRep(cgImage: flatCGImage)
flatRep.size = pointSize // задаёт DPI так, чтобы Finder показал canvas как 660x400 точек

guard let png = flatRep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode png\n".data(using: .utf8)!)
    exit(1)
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg_background.png"
try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
