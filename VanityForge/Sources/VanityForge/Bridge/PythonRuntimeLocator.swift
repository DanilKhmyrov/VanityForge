import Foundation

/// Находит python-интерпретатор и bridge.py в двух режимах:
///
/// 1. Упакованное приложение (.app из .dmg) — рантайм лежит внутри бандла
///    в Contents/Resources/PythonRuntime (кладёт туда Scripts/make_app.sh).
/// 2. Локальная сборка из исходников (`swift build` внутри репозитория) —
///    используем #filePath: он подставляет РЕАЛЬНЫЙ путь этого файла на
///    диске ТОГО, кто сейчас компилирует пакет, поэтому корень репозитория
///    вычисляется правильно у любого, кто склонировал репозиторий к себе,
///    а не только на этой машине.
enum PythonRuntimeLocator {
    static var pythonExecutable: URL { resolved().python }
    static var bridgeScript: URL { resolved().script }

    private static func resolved() -> (python: URL, script: URL) {
        // "runtime", не "venv": внутри бандла это не venv поверх системного
        // Python, а самодостаточный standalone-интерпретатор (python-build-
        // standalone) с зависимостями, установленными прямо в его
        // site-packages — у настоящего venv в pyvenv.cfg есть абсолютный
        // путь "home", который ломается при переносе .app на другую машину.
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/PythonRuntime")
        let bundledPython = bundled.appendingPathComponent("runtime/bin/python3")
        let bundledScript = bundled.appendingPathComponent("bridge.py")
        if FileManager.default.fileExists(atPath: bundledPython.path) {
            return (bundledPython, bundledScript)
        }

        // Sources/VanityForge/Bridge/PythonRuntimeLocator.swift
        //   -> Bridge -> VanityForge -> Sources -> VanityForge/ (пакет)
        //   -> address_generator/ (корень репозитория)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return (
            repoRoot.appendingPathComponent("venv/bin/python3"),
            repoRoot.appendingPathComponent("bridge.py")
        )
    }
}
