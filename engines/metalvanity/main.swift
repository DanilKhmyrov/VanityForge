// metalvanity — перебор salt для CREATE2 / CREATE3 на видеокарте Apple Silicon (Metal).
//
// Аргументы и построчный JSON на выходе — те же, что у `ethvanity --create2/--create3`
// (см. ethvanity/src/create2.rs), поэтому create2.py запускает любой из двух движков
// одинаково:
//   {"type":"found","address":"0x...","salt":"0x...","leading_zero_bytes":4,"zero_bytes":5}
//   {"type":"stats","checked":123456}
//   {"type":"error","message":"..."}
//
// Раскладка salt: CREATE2 — [caller 20][случайные 4][счётчик 8];
//                 CREATE3 — [caller 20][0x00][случайные 3][счётчик 8].
// Каждая находка GPU пересчитывается на CPU и сверяется с адресом, который
// вернуло ядро; расхождение — ошибка, а не тихо выданный неверный salt.
//
// --gpu-load 1..100 и --max-speed <попыток/с> ограничивают нагрузку паузами между батчами.
//
// `metalvanity --self-test` гоняет оба режима с порогом «всё подходит» и сверяет
// тысячи адресов GPU с CPU.

import Foundation
import Metal

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - keccak256 на CPU (для перепроверки)

private let roundConstants: [UInt64] = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
private let rho: [UInt64] = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14]

private func rotl(_ x: UInt64, _ n: UInt64) -> UInt64 { n == 0 ? x : (x << n) | (x >> (64 - n)) }

func keccakF(_ s: inout [UInt64]) {
    var b = [UInt64](repeating: 0, count: 25)
    for rc in roundConstants {
        var c = [UInt64](repeating: 0, count: 5)
        for x in 0..<5 { c[x] = s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20] }
        for x in 0..<5 {
            let d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
            for y in 0..<5 { s[x + 5 * y] ^= d }
        }
        for x in 0..<5 {
            for y in 0..<5 { b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(s[x + 5 * y], rho[x + 5 * y]) }
        }
        for y in 0..<5 {
            for x in 0..<5 { s[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y]) }
        }
        s[0] ^= rc
    }
}

/// Дополненный padding'ом блок keccak256 (сообщение короче 136 байт) — 17 слов little-endian.
func paddedLanes(_ message: [UInt8]) -> [UInt64] {
    precondition(message.count < 136)
    var block = message + [UInt8](repeating: 0, count: 136 - message.count)
    block[message.count] ^= 0x01
    block[135] ^= 0x80
    var lanes = [UInt64](repeating: 0, count: 17)
    for i in 0..<136 {
        lanes[i / 8] |= UInt64(block[i]) << UInt64(8 * (i % 8))
    }
    return lanes
}

func keccak256(_ message: [UInt8]) -> [UInt8] {
    var s = paddedLanes(message) + [UInt64](repeating: 0, count: 8)
    keccakF(&s)
    return (0..<32).map { UInt8(truncatingIfNeeded: s[$0 / 8] >> (8 * UInt64($0 % 8))) }
}

// MARK: - Параметры

enum Goal {
    case leading(min: Int), zeros(min: Int), prefix([UInt8]), hook(UInt16)

    var code: UInt32 {
        switch self {
        case .leading: return 0
        case .zeros: return 1
        case .prefix: return 2
        case .hook: return 3
        }
    }
}

struct Config {
    var factory = [UInt8](repeating: 0, count: 20)
    var initCodeHash = [UInt8](repeating: 0, count: 32)
    var caller = [UInt8](repeating: 0, count: 20)
    var goal = Goal.leading(min: 1)
    var create3 = false
    var batchLog2 = 24
    var gpuLoad = 1.0     // доля времени, которую GPU считает (0..1]
    var maxSpeed = 0.0    // попыток в секунду, 0 — без ограничения
}

let createX: [UInt8] = hex("ba5ed099633d3b313e4d5f7bdc1305d3c28ba5ed")!
let create3ProxyHash: [UInt8] = hex("21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f")!
let hookFlagMask: UInt16 = 0x3FFF

func hex(_ raw: String, bytes: Int? = nil) -> [UInt8]? {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
    guard s.count % 2 == 0, bytes == nil || s.count == bytes! * 2 else { return nil }
    var out: [UInt8] = []
    var index = s.startIndex
    while index < s.endIndex {
        let next = s.index(index, offsetBy: 2)
        guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
        out.append(byte)
        index = next
    }
    return out
}

func toHex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

func fail(_ message: String) -> Never {
    print("{\"type\":\"error\",\"message\":\"\(message)\"}")
    exit(2)
}

func parseConfig(_ args: [String]) -> Config {
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    var config = Config()
    config.create3 = args.contains("--create3")
    if config.create3 {
        config.factory = createX
    } else {
        guard let factory = value("--factory").flatMap({ hex($0, bytes: 20) }) else { fail("--factory must be a 20-byte hex address") }
        guard let hash = value("--init-code-hash").flatMap({ hex($0, bytes: 32) }) else { fail("--init-code-hash must be a 32-byte hex hash") }
        config.factory = factory
        config.initCodeHash = hash
    }
    if let raw = value("--caller"), !raw.trimmingCharacters(in: .whitespaces).isEmpty {
        guard let caller = hex(raw, bytes: 20) else { fail("--caller must be a 20-byte hex address") }
        config.caller = caller
    }
    let minBytes = min(max(Int(value("--min") ?? "") ?? 1, 1), 20)
    switch value("--goal") {
    case nil, "leading": config.goal = .leading(min: minBytes)
    case "zeros": config.goal = .zeros(min: minBytes)
    case "prefix":
        var raw = (value("--prefix") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if raw.hasPrefix("0x") { raw.removeFirst(2) }
        let nibbles = raw.compactMap { $0.hexDigitValue.map(UInt8.init) }
        guard !nibbles.isEmpty, nibbles.count == raw.count, nibbles.count <= 40 else { fail("--prefix must be 1..40 hex characters") }
        config.goal = .prefix(nibbles)
    case "hook":
        var raw = (value("--hook-flags") ?? "").trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("0x") { raw.removeFirst(2) }
        guard let flags = UInt16(raw, radix: 16) else { fail("--hook-flags must be a hex number") }
        config.goal = .hook(flags & hookFlagMask)
    default: fail("--goal must be one of: leading, zeros, prefix, hook")
    }
    if let batch = value("--batch-log2").flatMap(Int.init) { config.batchLog2 = min(max(batch, 10), 28) }
    if let load = value("--gpu-load").flatMap(Double.init) { config.gpuLoad = min(max(load, 1), 100) / 100 }
    if let speed = value("--max-speed").flatMap(Double.init) { config.maxSpeed = max(speed, 0) }
    return config
}

// MARK: - Адрес и очки на CPU

/// Префикс salt до счётчика: у CREATE2 — caller + 4 случайных байта,
/// у CREATE3 — caller + 0x00 + 3 случайных байта.
func saltFor(_ config: Config, head: [UInt8], counter: UInt64) -> [UInt8] {
    head + (0..<8).map { UInt8(truncatingIfNeeded: counter >> (56 - 8 * UInt64($0))) }
}

func address(_ config: Config, salt: [UInt8]) -> [UInt8] {
    if !config.create3 {
        return Array(keccak256([0xff] + config.factory + salt + config.initCodeHash)[12...])
    }
    let guardedByCaller = config.caller != [UInt8](repeating: 0, count: 20)
    let guarded = guardedByCaller ? keccak256([UInt8](repeating: 0, count: 12) + config.caller + salt) : keccak256(salt)
    let proxy = Array(keccak256([0xff] + createX + guarded + create3ProxyHash)[12...])
    return Array(keccak256([0xd6, 0x94] + proxy + [0x01])[12...])
}

func leadingZeroBytes(_ a: [UInt8]) -> Int { a.prefix { $0 == 0 }.count }
func zeroBytes(_ a: [UInt8]) -> Int { a.filter { $0 == 0 }.count }

/// Очки находки по тем же правилам, что в Rust; nil — условие не выполнено.
func score(_ goal: Goal, _ a: [UInt8]) -> Int? {
    switch goal {
    case .leading: return a[0] == 0 ? leadingZeroBytes(a) : nil
    case .zeros: return zeroBytes(a)
    case .prefix(let nibbles):
        let ok = nibbles.enumerated().allSatisfy { i, want in
            let byte = a[i / 2]
            return (i % 2 == 0 ? byte >> 4 : byte & 0x0f) == want
        }
        return ok ? zeroBytes(a) + 1 : nil
    case .hook(let flags):
        return (UInt16(a[18]) << 8 | UInt16(a[19])) & hookFlagMask == flags ? zeroBytes(a) + 1 : nil
    }
}

// MARK: - GPU

final class Miner {
    let config: Config
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    let head: [UInt8]
    let lanes: MTLBuffer
    let mode: UInt32
    let capacity: Int

    struct Slot {
        let cfg: MTLBuffer
        let base: MTLBuffer
        let hits: MTLBuffer
        let out: MTLBuffer
        var command: MTLCommandBuffer?
        var batchBase: UInt64 = 0
    }
    var slots: [Slot] = []

    init(config: Config, capacity: Int = 1024) {
        self.config = config
        self.capacity = capacity
        guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
        self.device = device
        guard let queue = device.makeCommandQueue() else { fail("cannot create Metal command queue") }
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let function = library.makeFunction(name: "search") else { fail("kernel not found") }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            fail("Metal shader compile failed: \(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))")
        }

        var random = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        var blocks: [UInt64]
        if config.create3 {
            head = config.caller + [0x00] + random.prefix(3)
            let guardedByCaller = config.caller != [UInt8](repeating: 0, count: 20)
            let zeroCounter = [UInt8](repeating: 0, count: 8)
            let guardMessage = guardedByCaller
                ? [UInt8](repeating: 0, count: 12) + config.caller + head + zeroCounter
                : head + zeroCounter
            blocks = paddedLanes(guardMessage)
            blocks += paddedLanes([0xff] + createX + [UInt8](repeating: 0, count: 32) + create3ProxyHash)
            blocks += paddedLanes([0xd6, 0x94] + [UInt8](repeating: 0, count: 20) + [0x01])
            mode = guardedByCaller ? 1 : 2
        } else {
            head = config.caller + random
            blocks = paddedLanes([0xff] + config.factory + head + [UInt8](repeating: 0, count: 8) + config.initCodeHash)
            mode = 0
        }
        lanes = device.makeBuffer(bytes: blocks, length: blocks.count * 8, options: .storageModeShared)!

        for _ in 0..<2 {
            slots.append(Slot(
                cfg: device.makeBuffer(length: 16 * 4, options: .storageModeShared)!,
                base: device.makeBuffer(length: 8, options: .storageModeShared)!,
                hits: device.makeBuffer(length: 4, options: .storageModeShared)!,
                out: device.makeBuffer(length: capacity * 8 * 4, options: .storageModeShared)!
            ))
        }
    }

    func goalWords(threshold: Int32) -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 16)
        words[0] = UInt32(bitPattern: threshold)
        words[1] = config.goal.code
        words[2] = mode
        words[3] = UInt32(capacity)
        switch config.goal {
        case .hook(let flags): words[4] = UInt32(flags)
        case .prefix(let nibbles):
            var prefix = [UInt8](repeating: 0, count: 20), mask = [UInt8](repeating: 0, count: 20)
            for (i, n) in nibbles.enumerated() {
                let shift: UInt8 = i % 2 == 0 ? 4 : 0
                prefix[i / 2] |= n << shift
                mask[i / 2] |= 0x0f << shift
            }
            for w in 0..<5 {
                for k in 0..<4 {
                    words[5 + w] |= UInt32(prefix[w * 4 + k]) << (8 * k)
                    words[10 + w] |= UInt32(mask[w * 4 + k]) << (8 * k)
                }
            }
        default: break
        }
        return words
    }

    func submit(slot index: Int, base: UInt64, threads: Int, threshold: Int32) {
        let slot = slots[index]
        let words = goalWords(threshold: threshold)
        slot.cfg.contents().copyMemory(from: words, byteCount: words.count * 4)
        slot.base.contents().storeBytes(of: base, as: UInt64.self)
        slot.hits.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        let command = queue.makeCommandBuffer()!
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(lanes, offset: 0, index: 0)
        encoder.setBuffer(slot.cfg, offset: 0, index: 1)
        encoder.setBuffer(slot.base, offset: 0, index: 2)
        encoder.setBuffer(slot.hits, offset: 0, index: 3)
        encoder.setBuffer(slot.out, offset: 0, index: 4)
        let width = pipeline.maxTotalThreadsPerThreadgroup
        encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        slots[index].command = command
        slots[index].batchBase = base
    }

    struct Hit { let counter: UInt64; let address: [UInt8]; let score: Int }

    /// Ждёт батч в слоте и возвращает его находки (не больше capacity).
    func collect(slot index: Int) -> [Hit] {
        let slot = slots[index]
        guard let command = slot.command else { return [] }
        command.waitUntilCompleted()
        if let error = command.error { fail("GPU error: \(error.localizedDescription)") }
        let count = min(Int(slot.hits.contents().load(as: UInt32.self)), capacity)
        let words = slot.out.contents().bindMemory(to: UInt32.self, capacity: capacity * 8)
        return (0..<count).map { i in
            let w = words + i * 8
            let counter = UInt64(w[0]) | UInt64(w[1]) << 32
            let address = (0..<20).map { UInt8(truncatingIfNeeded: w[2 + $0 / 4] >> (8 * UInt32($0 % 4))) }
            return Hit(counter: counter, address: address, score: Int(w[7]))
        }
    }
}

// MARK: - Режимы

func emitFound(address: [UInt8], salt: [UInt8]) {
    print("{\"type\":\"found\",\"address\":\"0x\(toHex(address))\",\"salt\":\"0x\(toHex(salt))\","
          + "\"leading_zero_bytes\":\(leadingZeroBytes(address)),\"zero_bytes\":\(zeroBytes(address))}")
}

func search(_ config: Config) -> Never {
    let miner = Miner(config: config)
    let batch = 1 << config.batchLog2
    var best: Int
    switch config.goal {
    case .leading(let min), .zeros(let min): best = min - 1
    default: best = 0
    }

    var checked: UInt64 = 0
    var lastStats = Date()
    var nextBase = UInt64.random(in: 0...(UInt64.max / 2))

    func process(_ hits: [Miner.Hit]) {
        for hit in hits where hit.score > best {
            let salt = saltFor(config, head: miner.head, counter: hit.counter)
            let cpuAddress = address(config, salt: salt)
            guard cpuAddress == hit.address, let cpuScore = score(config.goal, cpuAddress) else {
                fail("GPU result mismatch for salt 0x\(toHex(salt))")
            }
            if cpuScore > best {
                best = cpuScore
                emitFound(address: cpuAddress, salt: salt)
            }
        }
        checked &+= UInt64(batch)
        if Date().timeIntervalSince(lastStats) >= 1 {
            print("{\"type\":\"stats\",\"checked\":\(checked)}")
            lastStats = Date()
        }
    }

    if config.gpuLoad < 1 || config.maxSpeed > 0 {
        // С ограничением — по одному батчу с паузой: доля работы не выше gpuLoad,
        // средняя скорость не выше maxSpeed.
        while true {
            let started = Date()
            miner.submit(slot: 0, base: nextBase, threads: batch, threshold: Int32(best))
            nextBase &+= UInt64(batch)
            let hits = miner.collect(slot: 0)
            let busy = Date().timeIntervalSince(started)
            process(hits)
            let byLoad = busy * (1 / config.gpuLoad - 1)
            let bySpeed = config.maxSpeed > 0 ? Double(batch) / config.maxSpeed - busy : 0
            let pause = max(byLoad, bySpeed, 0)
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
    }

    miner.submit(slot: 0, base: nextBase, threads: batch, threshold: Int32(best))
    nextBase &+= UInt64(batch)
    var current = 0
    while true {
        // Пока GPU считает текущий батч, следующий уже в очереди — видеокарта не простаивает.
        let other = 1 - current
        miner.submit(slot: other, base: nextBase, threads: batch, threshold: Int32(best))
        nextBase &+= UInt64(batch)
        process(miner.collect(slot: current))
        current = other
    }
}

func selfTest() -> Never {
    precondition(toHex(keccak256([])) == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "CPU keccak broken")
    let caller = hex("0x5B38Da6a701c568545dCfcB03FcB875f56beddC4")!
    var cases: [(String, Config)] = []
    var c2 = Config()
    c2.factory = hex("0000000000ffe8b47b3e2130213b802212439497")!
    c2.initCodeHash = keccak256(Array("hello".utf8))
    c2.caller = caller
    c2.goal = .zeros(min: 1)
    cases.append(("create2", c2))
    var c3 = Config()
    c3.create3 = true
    c3.factory = createX
    c3.caller = caller
    c3.goal = .zeros(min: 1)
    cases.append(("create3 guarded", c3))
    var c3plain = c3
    c3plain.caller = [UInt8](repeating: 0, count: 20)
    cases.append(("create3 plain", c3plain))

    for (name, config) in cases {
        let capacity = 4096
        let miner = Miner(config: config, capacity: capacity)
        let base = UInt64.random(in: 0...(UInt64.max / 2))
        miner.submit(slot: 0, base: base, threads: capacity, threshold: -1)
        let hits = miner.collect(slot: 0)
        guard hits.count == capacity else { fail("\(name): expected \(capacity) hits, got \(hits.count)") }
        for hit in hits {
            let salt = saltFor(config, head: miner.head, counter: hit.counter)
            guard address(config, salt: salt) == hit.address, zeroBytes(hit.address) == hit.score else {
                fail("\(name): mismatch at counter \(hit.counter)")
            }
        }
        print("{\"type\":\"self_test\",\"case\":\"\(name)\",\"checked\":\(hits.count),\"ok\":true}")
    }
    exit(0)
}

let arguments = CommandLine.arguments
if arguments.contains("--self-test") { selfTest() }
search(parseConfig(arguments))
