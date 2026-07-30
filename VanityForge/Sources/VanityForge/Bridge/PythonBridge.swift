import Foundation

/// Запускает `bridge.py` как дочерний процесс и превращает его stdout (JSON Lines)
/// в асинхронный поток событий. Остановка идёт через stdin-команду
/// `{"cmd":"stop"}` (даёт python-стороне корректно завершить воркеры и
/// сохранить статистику); SIGTERM/SIGKILL — только как страховка на случай
/// зависшего процесса.
final class PythonBridge {
    static var venvPython: URL { PythonRuntimeLocator.pythonExecutable }
    static var bridgeScript: URL { PythonRuntimeLocator.bridgeScript }

    private let pythonPath: URL
    private let scriptPath: URL

    private var process: Process?
    private var stdinHandle: FileHandle?

    init(pythonPath: URL = PythonBridge.venvPython, scriptPath: URL = PythonBridge.bridgeScript) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
    }

    /// Приложения, запущенные обычным способом (Dock/Finder), получают от
    /// LaunchServices урезанный PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) —
    /// он не source-ится из .zshrc/.zprofile, поэтому Homebrew-инструменты
    /// вроде `keyhunt` там не видны и bridge.py тихо откатывается на CPU.
    /// Дополняем PATH стандартными местами установки Homebrew.
    private static func subprocessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var merged: [String] = []
        for path in extra + existing {
            if !merged.contains(path) { merged.append(path) }
        }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start(networks: [String], preset: String, fakeFoundInterval: Double? = nil, workerCount: Int? = nil,
               customPattern: (text: String, mode: CustomPatternMode, caseSensitive: Bool)? = nil,
               language: AppLanguage = .ru, words: [String]? = nil) -> AsyncStream<BridgeEvent> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = pythonPath
            var arguments = [scriptPath.path, networks.joined(separator: ","), preset, "--lang", language.rawValue]
            if let interval = fakeFoundInterval {
                arguments += ["--fake-found", String(interval)]
            }
            if let workerCount {
                arguments += ["--workers", String(workerCount)]
            }
            if let customPattern {
                arguments += ["--custom", "\(customPattern.mode.rawValue):\(customPattern.text)"]
                if customPattern.caseSensitive {
                    arguments += ["--custom-case"]
                }
            }
            if let words, !words.isEmpty {
                arguments += ["--words", words.joined(separator: ",")]
            }
            process.arguments = arguments
            process.currentDirectoryURL = scriptPath.deletingLastPathComponent()
            process.environment = Self.subprocessEnvironment()

            let stdoutPipe = Pipe()
            let stdinPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardInput = stdinPipe
            process.standardError = Pipe()

            self.process = process
            self.stdinHandle = stdinPipe.fileHandleForWriting

            var buffer = Data()
            let newline = UInt8(ascii: "\n")

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)
                while let idx = buffer.firstIndex(of: newline) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<idx)
                    buffer.removeSubrange(buffer.startIndex...idx)
                    guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
                    if let event = BridgeEvent.parse(line: line) {
                        continuation.yield(event)
                    }
                }
            }

            process.terminationHandler = { [weak self] _ in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                self?.stdinHandle = nil
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.yield(.error(ErrorEvent(message: L.processLaunchFailed.s(language) + error.localizedDescription, fatal: true)))
                continuation.finish()
            }
        }
    }

    /// Мягкая остановка: команда через stdin, затем SIGTERM/SIGKILL как страховка.
    func stop() {
        guard let process, process.isRunning else { return }

        if let handle = stdinHandle, let data = "{\"cmd\": \"stop\"}\n".data(using: .utf8) {
            try? handle.write(contentsOf: data)
            try? handle.close()
            stdinHandle = nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak process] in
            guard let process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Однократный опрос `bridge.py --list-presets`: сети/пресеты берём из
    /// Python (patterns.py/networks.py), а не дублируем их вручную в Swift —
    /// так UI не может разойтись с тем, что реально валидируется на бэкенде.
    static func loadCatalog(lang: AppLanguage = .ru) async -> PresetsEvent? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = venvPython
            process.arguments = [bridgeScript.path, "--list-presets", "--lang", lang.rawValue]
            process.currentDirectoryURL = bridgeScript.deletingLastPathComponent()
            process.environment = subprocessEnvironment()

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return nil
            }

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8),
                  let firstLine = output.split(separator: "\n").first,
                  case .presets(let event)? = BridgeEvent.parse(line: String(firstLine)) else {
                return nil
            }
            return event
        }.value
    }
}
