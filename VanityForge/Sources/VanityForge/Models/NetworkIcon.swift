import AppKit
import SwiftUI

/// Загружает SVG-логотипы сетей (положены как обычные файлы-ресурсы, не через
/// Assets.xcassets — на этой машине нет полного Xcode.app, чтобы actool
/// скомпилировал каталог, а без компиляции `Image(_:bundle:)` их не находит).
/// AppKit на этой версии macOS декодирует SVG нативно через NSImage.
enum NetworkIconLoader {
    private static var cache: [String: NSImage] = [:]

    static func image(for key: String) -> NSImage? {
        if let cached = cache[key] { return cached }
        guard let url = Bundle.module.url(forResource: key, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = image
        return image
    }
}

struct NetworkIcon: View {
    let key: String
    var size: CGFloat = 20

    var body: some View {
        if let nsImage = NetworkIconLoader.image(for: key) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(NetworkVisual.gradient(for: key))
                .frame(width: size, height: size)
        }
    }
}
