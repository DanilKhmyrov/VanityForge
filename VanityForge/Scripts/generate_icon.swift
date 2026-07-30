import AppKit

let canvas: CGFloat = 1024

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: canvas, height: canvas)
let path = NSBezierPath(roundedRect: rect, xRadius: canvas * 0.225, yRadius: canvas * 0.225)
path.addClip()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.07, blue: 0.20, alpha: 1.0),
    NSColor(calibratedRed: 0.45, green: 0.24, blue: 0.92, alpha: 1.0),
    NSColor(calibratedRed: 0.06, green: 0.85, blue: 0.62, alpha: 1.0),
])!
gradient.draw(in: rect, angle: -50)

let sizeConfig = NSImage.SymbolConfiguration(pointSize: canvas * 0.46, weight: .heavy)
let colorConfig = NSImage.SymbolConfiguration(paletteColors: [.white])
let config = sizeConfig.applying(colorConfig)

if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let boltSize = bolt.size
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = canvas * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.01)
    shadow.set()
    let boltRect = NSRect(
        x: (canvas - boltSize.width) / 2,
        y: (canvas - boltSize.height) / 2,
        width: boltSize.width,
        height: boltSize.height
    )
    bolt.draw(in: boltRect)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render icon\n".data(using: .utf8)!)
    exit(1)
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
