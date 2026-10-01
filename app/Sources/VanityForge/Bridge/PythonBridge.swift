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
    /// он не source-ится из .zshrc/.zprofile, поэтому установленные через
    /// Homebrew инструменты там не видны. Дополняем PATH стандартными местами
    /// установки Homebrew.
    private static func subprocessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var merged: [String] = []
        for path in extra + existing {
            if !merged.contains(path) { merged.append(path) }
        }
        env["PATH"] = merged.joined(separator: ":")
        env[ResultsLocation.environmentKey] = ResultsLocation.directory.path
        return env
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start(networks: [String], preset: String, fakeFoundInterval: Double? = nil, workerCount: Int? = nil,
               customPattern: (text: String, mode: CustomPatternMode, caseSensitive: Bool)? = nil,
               language: AppLanguage = .ru, words: [String]? = nil, splitKey: String? = nil,
               useGPU: Bool = true, gpuLoad: Int = 100) -> AsyncStream<BridgeEvent> {
        var arguments = [networks.joined(separator: ","), preset, "--lang", language.rawValue,
                         "--engine", useGPU ? "auto" : "cpu"]
        if gpuLoad < 100 { arguments += ["--gpu-load", String(gpuLoad)] }
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
        if let splitKey {
            arguments += ["--split-key", splitKey]
        }
        return run(arguments: arguments, language: language)
    }

    /// Режим CREATE2: тот же протокол событий, другие аргументы (см. create2.py).
    func startCreate2(kind: ContractKind, factory: String, initCodeHash: String, caller: String, goal: Create2Goal,
                      minBytes: Int, prefix: String, hookFlags: UInt16, useGPU: Bool, gpuLoad: Int, workerCount: Int?,
                      language: AppLanguage) -> AsyncStream<BridgeEvent> {
        var arguments = [
            "--create2", "--kind", kind.rawValue, "--lang", language.rawValue,
            "--factory", factory, "--init-code-hash", initCodeHash,
            "--goal", goal.rawValue, "--min", String(minBytes),
            "--prefix", prefix, "--hook-flags", String(hookFlags, radix: 16),
            "--engine", useGPU ? "auto" : "cpu",
        ]
        if gpuLoad < 100 { arguments += ["--gpu-load", String(gpuLoad)] }
        if !caller.isEmpty { arguments += ["--caller", caller] }
        if let workerCount { arguments += ["--workers", String(workerCount)] }
        return run(arguments: arguments, language: language)
    }

    private func run(arguments: [String], language: AppLanguage) -> AsyncStream<BridgeEvent> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = pythonPath
            process.arguments = [scriptPath.path] + arguments
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

    /// Баланс EVM-адреса по всем сетям (`bridge.py --balance`). Адрес уходит в
    /// публичные RPC-узлы, поэтому только по кнопке на карточке.
    static func fetchBalance(address: String) async -> [String: Double]? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = venvPython
            process.arguments = [bridgeScript.path, "--balance", address]
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
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            for line in output.split(separator: "\n") {
                if case .balance(let event)? = BridgeEvent.parse(line: String(line)) {
                    return event.balances
                }
            }
            return nil
        }.value
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
