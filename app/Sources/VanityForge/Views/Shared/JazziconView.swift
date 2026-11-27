import SwiftUI

/// Круглая иконка MetaMask (см. Jazzicon) — фон и три повёрнутых квадрата.
struct JazziconView: View {
    let icon: Jazzicon
    var size: CGFloat = 24

    init(seed: UInt32, size: CGFloat = 24) {
        icon = Jazzicon(seed: seed)
        self.size = size
    }

    init?(address: String, size: CGFloat = 24) {
        guard let icon = Jazzicon(address: address) else { return nil }
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Canvas { context, canvas in
            let d = canvas.width
            context.clip(to: Path(ellipseIn: CGRect(origin: .zero, size: canvas)))
            context.fill(Path(CGRect(origin: .zero, size: canvas)), with: .color(icon.background.color))
            for shape in icon.shapes {
                var ctx = context
                // SVG: translate(tx ty) rotate(r cx cy) — сначала поворот вокруг центра, потом сдвиг.
                ctx.translateBy(x: shape.tx * d, y: shape.ty * d)
                ctx.translateBy(x: d / 2, y: d / 2)
                ctx.rotate(by: .degrees(shape.rotation))
                ctx.translateBy(x: -d / 2, y: -d / 2)
                ctx.fill(Path(CGRect(x: 0, y: 0, width: d, height: d)), with: .color(shape.color.color))
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}

extension Jazzicon.RGB {
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
}

/// Обе иконки адреса EVM рядом: Etherscan (blockies) и MetaMask (jazzicon).
struct AddressIcons: View {
    let address: String
    var size: CGFloat = 24
    var emphasizeJazzicon = false
    var emphasizeBlockie = false

    var body: some View {
        HStack(spacing: 4) {
            BlockieView(address: address, size: emphasizeBlockie ? size * 1.7 : size)
                .help("Etherscan · blockies")
            if let jazz = JazziconView(address: address, size: emphasizeJazzicon ? size * 1.7 : size) {
                jazz.help("MetaMask · jazzicon")
            }
        }
    }
}
