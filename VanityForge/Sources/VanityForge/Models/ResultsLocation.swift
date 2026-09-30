import Foundation

/// Где лежат файлы находок (адрес + приватный ключ / salt).
///
/// Раньше упакованное приложение писало их внутрь себя — в
/// Contents/Resources/PythonRuntime/results, — а пересборка .app стирает
/// бандл целиком вместе с ключами. Теперь для .app это постоянная папка
/// ~/Library/Application Support/VanityForge/results (путь передаётся
/// Python-стороне через VANITYFORGE_RESULTS_DIR), а при запуске из исходников —
/// results/ в корне репозитория, как и у консольных скриптов.
enum ResultsLocation {
    static let environmentKey = "VANITYFORGE_RESULTS_DIR"

    private static var legacyBundleDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PythonRuntime/results")
    }

    private static var isBundled: Bool {
        PythonRuntimeLocator.bridgeScript.path.hasPrefix(Bundle.main.bundleURL.path + "/Contents/")
    }

    static var directory: URL {
        if isBundled {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            return support.appendingPathComponent("VanityForge/results", isDirectory: true)
        }
        return PythonRuntimeLocator.bridgeScript.deletingLastPathComponent().appendingPathComponent("results", isDirectory: true)
    }

    /// Путь из события found: новые — абсолютные, старые — относительно bridge.py.
    static func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return PythonRuntimeLocator.bridgeScript.deletingLastPathComponent().appendingPathComponent(path)
    }

    /// Переносит находки, оставшиеся внутри бандла от старых версий, в
    /// постоянную папку. Существующие файлы не перезаписываются; из бандла
    /// переносимые файлы удаляются только после успешного копирования.
    static func migrateLegacyResults() {
        let fm = FileManager.default
        let source = legacyBundleDirectory
        guard isBundled, fm.fileExists(atPath: source.path) else { return }
        let target = directory
        guard let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let file as URL in files {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = file.path.dropFirst(source.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let destination = target.appendingPathComponent(relative)
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: destination.path) {
                    try fm.copyItem(at: file, to: destination)
                }
                try fm.removeItem(at: file)
            } catch {
                continue
            }
        }
    }
}
