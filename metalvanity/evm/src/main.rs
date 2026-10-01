//! Прототип: перебор EVM-адресов на видеокарте Apple Silicon.
//!
//! Хост раздаёт каждому потоку GPU свой случайный ключ k_t, ядро (kernel.metal)
//! проверяет окна по 2B+1 ключей подряд (k_t + запуск·(2B+1) + 0..2B, центр
//! окна — точка ядра) и сообщает совпадения как (поток, запуск, смещение в окне).
//! Ключ совпадения — k_t + запуск·(2B+1) + смещение; хост
//! пересчитывает его адрес через libsecp256k1 и сверяет с адресом из ядра,
//! прежде чем что-то выдать.
//!
//! Ключи внутри цепочки одного потока отличаются на небольшое число: зная один
//! найденный ключ, соседние по цепочке можно найти перебором разницы. Поэтому
//! старты независимы у каждого потока и раз в RESEED_SECS заменяются новыми
//! случайными — цепочка не бывает длиннее нескольких миллионов шагов, а ключи
//! из разных цепочек между собой никак не связаны.
//!
//!   metalvanity-evm --target dead:beef [--target :0000 ...] [--prefix dead] [--suffix beef]
//!                   [--tron-target TXyz:abc ...] [--split-key <публичный ключ заказчика>]
//!                   [--threads N] [--batch B] [--reseed-secs S]
//!                   [--gpu-load 1..100] [--max-speed адресов/с]
//!
//! --gpu-load и --max-speed ограничивают нагрузку паузами между запусками: GPU
//! считает пачку (~0,1 с), потом ждёт столько, чтобы доля работы не превышала
//! gpu-load %, а средняя скорость — max-speed.
//!
//! Цель — «начало:конец» в hex (любая часть может быть пустой); адрес подходит,
//! если совпал хотя бы с одной целью. Итоговую проверку условия делает bridge.py.
//!
//! --tron-target — то же для TRON, в base58 («начало» включает ведущую T, конец —
//! до 10 символов). У TRON и EVM из одного ключа одинаковые 20 байт адреса, так что
//! обе сети проверяются на одном и том же кандидате.
//!
//! --split-key: точки — P_заказчика + k·G, в находке вместо приватного ключа
//! добавка k (как у ethvanity --split-key); ключ адреса знает только заказчик.
//!   metalvanity-evm --self-test
//!
//! Вывод — построчный JSON, как у ethvanity:
//!   {"type":"found","network":"eth","address":"0x...","private_key":"..."}
//!   {"type":"stats","checked":123456}

use metal::{CompileOptions, Device, MTLResourceOptions, MTLSize};
use secp256k1::rand::rngs::OsRng;
use secp256k1::{PublicKey, Scalar, Secp256k1, SecretKey};
use sha2::{Digest, Sha256};
use std::env;
use std::ffi::c_void;
use std::io::Write;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};
use tiny_keccak::{Hasher, Keccak};

const KERNEL: &str = include_str!("kernel.metal");
const RESEED_SECS: u64 = 30;

fn fail(message: &str) -> ! {
    println!("{{\"type\":\"error\",\"message\":\"{}\"}}", message.replace('"', "'"));
    let _ = std::io::stdout().flush();
    std::process::exit(2);
}

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn eth_address(pk: &PublicKey) -> [u8; 20] {
    let raw = pk.serialize_uncompressed();
    let mut hash = [0u8; 32];
    let mut k = Keccak::v256();
    k.update(&raw[1..]);
    k.finalize(&mut hash);
    let mut out = [0u8; 20];
    out.copy_from_slice(&hash[12..]);
    out
}

/// Точка в формате ядра: x и y по 8 слов little-endian.
fn point_words(pk: &PublicKey) -> [u32; 16] {
    let raw = pk.serialize_uncompressed();
    let mut w = [0u32; 16];
    for (half, bytes) in [&raw[1..33], &raw[33..65]].iter().enumerate() {
        for i in 0..8 {
            let at = 32 - 4 * (i + 1);
            w[half * 8 + i] = u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap());
        }
    }
    w
}

fn scalar_u128(value: u128) -> Scalar {
    let mut b = [0u8; 32];
    b[16..].copy_from_slice(&value.to_be_bytes());
    Scalar::from_be_bytes(b).unwrap()
}

type Pattern = ([u8; 20], [u8; 20]);
const MAX_PATTERNS: usize = 256;

/// Шаблон адреса по полубайтам: префикс с начала, суффикс с конца.
/// Возвращает (значения, маска) — 20 байт каждая.
fn pattern(prefix: &str, suffix: &str) -> Pattern {
    let parse = |s: &str| -> Vec<u8> {
        let s = s.trim().trim_start_matches("0x");
        s.chars()
            .map(|c| c.to_digit(16).map(|d| d as u8).unwrap_or_else(|| fail("pattern must be hex")))
            .collect()
    };
    let (pre, suf) = (parse(prefix), parse(suffix));
    if pre.is_empty() && suf.is_empty() {
        fail("empty target");
    }
    if pre.len() + suf.len() > 40 {
        fail("pattern longer than an address");
    }
    let (mut value, mut mask) = ([0u8; 20], [0u8; 20]);
    let mut put = |pos: usize, nibble: u8| {
        let shift = if pos % 2 == 0 { 4 } else { 0 };
        value[pos / 2] |= nibble << shift;
        mask[pos / 2] |= 0x0f << shift;
    };
    for (i, &n) in pre.iter().enumerate() {
        put(i, n);
    }
    for (i, &n) in suf.iter().enumerate() {
        put(40 - suf.len() + i, n);
    }
    (value, mask)
}

fn pack(bytes: &[u8; 20]) -> [u32; 5] {
    let mut w = [0u32; 5];
    for (i, &b) in bytes.iter().enumerate() {
        w[i / 4] |= (b as u32) << (8 * (i % 4));
    }
    w
}

fn unpack(words: &[u32]) -> [u8; 20] {
    let mut out = [0u8; 20];
    for i in 0..20 {
        out[i] = (words[i / 4] >> (8 * (i % 4))) as u8;
    }
    out
}

// ---- TRON: base58check(0x41 ++ адрес ++ первые 4 байта sha256(sha256(...))) ----

const B58: &[u8; 58] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const TRON_LEN: usize = 34;
const MAX_TRON_SUFFIX: usize = 10;

fn b58_digit(c: char) -> Option<u32> {
    B58.iter().position(|&b| b as char == c).map(|d| d as u32)
}

fn b58_encode(bytes: &[u8]) -> String {
    let mut digits: Vec<u8> = Vec::new();
    for &byte in bytes {
        let mut carry = byte as u32;
        for d in digits.iter_mut() {
            carry += (*d as u32) << 8;
            *d = (carry % 58) as u8;
            carry /= 58;
        }
        while carry > 0 {
            digits.push((carry % 58) as u8);
            carry /= 58;
        }
    }
    let zeros = bytes.iter().take_while(|&&b| b == 0).count();
    std::iter::repeat('1')
        .take(zeros)
        .chain(digits.iter().rev().map(|&d| B58[d as usize] as char))
        .collect()
}

fn tron_address(addr: &[u8; 20]) -> String {
    let mut payload = vec![0x41u8];
    payload.extend_from_slice(addr);
    let checksum = Sha256::digest(Sha256::digest(&payload));
    payload.extend_from_slice(&checksum[..4]);
    b58_encode(&payload)
}

/// Значение base58-строки как 25-байтное число big-endian; None — не влезло.
fn b58_value(s: &str) -> Option<[u8; 25]> {
    let mut n = [0u8; 26];
    for c in s.chars() {
        let mut carry = b58_digit(c)?;
        for byte in n.iter_mut().rev() {
            carry += (*byte as u32) * 58;
            *byte = (carry & 0xff) as u8;
            carry >>= 8;
        }
        if carry != 0 {
            return None;
        }
    }
    if n[0] != 0 {
        return None;
    }
    let mut out = [0u8; 25];
    out.copy_from_slice(&n[1..]);
    Some(out)
}

/// Старшие 21 байт (0x41 ++ адрес) как 6 слов big-endian, как в ядре.
fn top21_words(n: &[u8; 25]) -> [u32; 6] {
    let mut w = [0u32; 6];
    w[0] = n[0] as u32;
    for i in 0..5 {
        w[1 + i] = u32::from_be_bytes(n[1 + 4 * i..5 + 4 * i].try_into().unwrap());
    }
    w
}

struct TronTarget {
    prefix: String,
    suffix: String,
}

impl TronTarget {
    fn parse(raw: &str) -> TronTarget {
        let (prefix, suffix) = raw.split_once(':').unwrap_or((raw, ""));
        let valid = |s: &str| s.chars().all(|c| b58_digit(c).is_some());
        if !valid(prefix) || !valid(suffix) {
            fail("tron target must be base58");
        }
        if prefix.len() > TRON_LEN || suffix.len() > MAX_TRON_SUFFIX {
            fail("tron target too long (prefix ≤ 34, suffix ≤ 10)");
        }
        TronTarget { prefix: prefix.to_string(), suffix: suffix.to_string() }
    }

    fn matches(&self, address: &str) -> bool {
        address.starts_with(&self.prefix) && address.ends_with(&self.suffix)
    }

    /// 20 слов для ядра (раскладка — в комментарии к check() в kernel.metal).
    fn words(&self) -> [u32; 20] {
        let mut w = [0u32; 20];
        if !self.prefix.is_empty() {
            w[0] |= 1;
            let fill = TRON_LEN - self.prefix.len();
            let lo = b58_value(&(self.prefix.clone() + &"1".repeat(fill)));
            let hi = b58_value(&(self.prefix.clone() + &"z".repeat(fill)));
            // Верх, не влезший в 25 байт, — до максимума; низ — цель невозможна.
            let (lo, hi) = match lo {
                Some(lo) => (top21_words(&lo), top21_words(&hi.unwrap_or([0xff; 25]))),
                None => ([u32::MAX; 6], [0u32; 6]),
            };
            w[2..8].copy_from_slice(&lo);
            w[8..14].copy_from_slice(&hi);
        }
        if !self.suffix.is_empty() {
            w[0] |= 2;
            let k = self.suffix.len() as u32;
            let value = self.suffix.chars().fold(0u64, |acc, c| acc * 58 + b58_digit(c).unwrap() as u64);
            let m29 = 29u64.pow(k);
            let r29 = value % m29;
            w[1] = k;
            w[14] = (value & ((1u64 << k) - 1)) as u32;
            w[15] = r29 as u32;
            w[16] = (r29 >> 32) as u32;
            w[17] = m29 as u32;
            w[18] = (m29 >> 32) as u32;
        }
        w
    }
}

struct Hit {
    thread: u32,
    run: u64,
    j: u32, // смещение в окне 0..2B
    address: [u8; 20],
    network: u32, // 0 — EVM, 1 — TRON
}

struct Gpu {
    queue: metal::CommandQueue,
    pipeline: metal::ComputePipelineState,
    points: metal::Buffer,
    table: metal::Buffer,
    scratch: metal::Buffer,
    cfg: metal::Buffer,
    slots: Vec<(metal::Buffer, metal::Buffer)>, // (hits, out)
    threads: u32,
    capacity: u32,
}

impl Gpu {
    fn new(threads: u32, batch: u32, capacity: u32, start: &[PublicKey], patterns: &[Pattern], tron: &[TronTarget]) -> Gpu {
        let device = Device::system_default().unwrap_or_else(|| fail("no Metal device"));
        let library = device
            .new_library_with_source(KERNEL, &CompileOptions::new())
            .unwrap_or_else(|e| fail(&format!("kernel compile failed: {e}")));
        let function = library.get_function("step", None).unwrap_or_else(|e| fail(&e));
        let pipeline = device
            .new_compute_pipeline_state_with_function(&function)
            .unwrap_or_else(|e| fail(&e));
        let shared = MTLResourceOptions::StorageModeShared;
        let buffer = |data: &[u32]| {
            device.new_buffer_with_data(data.as_ptr() as *const c_void, (data.len() * 4) as u64, shared)
        };

        let points: Vec<u32> = start.iter().flat_map(point_words).collect();
        let secp = Secp256k1::new();
        // j·G для j = 1..B и (2B+1)·G — сдвиг окна.
        let table: Vec<u32> = (1..=batch as u128)
            .chain(std::iter::once(2 * batch as u128 + 1))
            .flat_map(|j| {
                let key = SecretKey::from_slice(&scalar_u128(j).to_be_bytes()).unwrap();
                point_words(&PublicKey::from_secret_key(&secp, &key))
            })
            .collect();
        let mut cfg = vec![threads, batch, capacity, patterns.len() as u32];
        for (value, mask) in patterns {
            cfg.extend(pack(value));
            cfg.extend(pack(mask));
        }
        cfg.push(tron.len() as u32);
        for target in tron {
            cfg.extend(target.words());
        }

        let slots = (0..2)
            .map(|_| (device.new_buffer(4, shared), device.new_buffer(capacity as u64 * 32, shared)))
            .collect();
        Gpu {
            queue: device.new_command_queue(),
            points: buffer(&points),
            table: buffer(&table),
            scratch: device.new_buffer(threads as u64 * batch as u64 * 32, MTLResourceOptions::StorageModePrivate),
            cfg: buffer(&cfg),
            slots,
            pipeline,
            threads,
            capacity,
        }
    }

    /// Новые стартовые точки. Только когда на GPU ничего не выполняется.
    fn upload(&self, start: &[PublicKey]) {
        let words: Vec<u32> = start.iter().flat_map(point_words).collect();
        unsafe {
            std::ptr::copy_nonoverlapping(words.as_ptr(), self.points.contents() as *mut u32, words.len());
        }
    }

    fn submit(&self, slot: usize) -> metal::CommandBuffer {
        let (hits, out) = &self.slots[slot];
        unsafe { *(hits.contents() as *mut u32) = 0 };
        let command = self.queue.new_command_buffer().to_owned();
        let encoder = command.new_compute_command_encoder();
        encoder.set_compute_pipeline_state(&self.pipeline);
        for (i, b) in [&self.points, &self.table, &self.scratch, &self.cfg, hits, out].iter().enumerate() {
            encoder.set_buffer(i as u64, Some(b), 0);
        }
        let width = self.pipeline.max_total_threads_per_threadgroup().min(256);
        encoder.dispatch_threads(MTLSize::new(self.threads as u64, 1, 1), MTLSize::new(width, 1, 1));
        encoder.end_encoding();
        command.commit();
        command
    }

    fn collect(&self, slot: usize, command: &metal::CommandBuffer, run: u64) -> Vec<Hit> {
        command.wait_until_completed();
        let (hits, out) = &self.slots[slot];
        let count = unsafe { *(hits.contents() as *const u32) }.min(self.capacity) as usize;
        let words = unsafe { std::slice::from_raw_parts(out.contents() as *const u32, count * 8) };
        words
            .chunks(8)
            .map(|w| Hit { thread: w[0], run, j: w[1], address: unpack(&w[2..7]), network: w[7] })
            .collect()
    }
}

struct Keys {
    starts: Vec<SecretKey>,
    batch: u32,
    /// Split-key: публичный ключ заказчика P; точки — P + k·G, находка — k.
    base: Option<PublicKey>,
}

impl Keys {
    fn random(threads: u32, batch: u32, base: Option<PublicKey>) -> Keys {
        Keys { starts: (0..threads).map(|_| SecretKey::new(&mut OsRng)).collect(), batch, base }
    }

    fn window(&self) -> u128 {
        2 * self.batch as u128 + 1
    }

    /// k_t + run·(2B+1) + смещение в окне (в split-key — добавка к ключу заказчика).
    fn key(&self, hit: &Hit) -> SecretKey {
        let offset = hit.run as u128 * self.window() + hit.j as u128;
        self.starts[hit.thread as usize].add_tweak(&scalar_u128(offset)).unwrap()
    }

    fn public(&self, secp: &Secp256k1<secp256k1::All>, key: &SecretKey) -> PublicKey {
        let own = PublicKey::from_secret_key(secp, key);
        match self.base {
            Some(base) => base.combine(&own).unwrap_or_else(|_| fail("split-key point at infinity")),
            None => own,
        }
    }

    /// Центры первых окон: (k_t + B)·G (+ P в split-key).
    fn points(&self) -> Vec<PublicKey> {
        let secp = Secp256k1::new();
        let shift = scalar_u128(self.batch as u128);
        self.starts.iter().map(|k| self.public(&secp, &k.add_tweak(&shift).unwrap())).collect()
    }
}

/// Пересчитывает находку на CPU. Расхождение адреса — ошибка GPU; для TRON
/// диапазон начала на GPU чуть шире точного условия, такие «почти» тихо отсеиваются.
fn verify(
    secp: &Secp256k1<secp256k1::All>,
    keys: &Keys,
    hit: &Hit,
    patterns: &[Pattern],
    tron: &[TronTarget],
) -> Option<(SecretKey, String)> {
    let key = keys.key(hit);
    let address = eth_address(&keys.public(secp, &key));
    if address != hit.address {
        fail(&format!("GPU result mismatch: thread {} run {} j {}", hit.thread, hit.run, hit.j));
    }
    if hit.network == 1 {
        let text = tron_address(&address);
        return tron.iter().any(|t| t.matches(&text)).then_some((key, text));
    }
    if !patterns.iter().any(|(value, mask)| (0..20).all(|i| address[i] & mask[i] == value[i])) {
        fail(&format!("GPU pattern mismatch: thread {} run {} j {}", hit.thread, hit.run, hit.j));
    }
    Some((key, format!("0x{}", to_hex(&address))))
}

fn self_test() -> ! {
    let (threads, batch) = (512u32, 64u32);
    let window = 2 * batch + 1;
    let capacity = threads * window * 2;
    let secp = Secp256k1::new();
    let everything = [([0u8; 20], [0u8; 20])];

    // EVM: каждый кандидат — совпадение; обычный режим и split-key.
    let client = PublicKey::from_secret_key(&secp, &SecretKey::new(&mut OsRng));
    for (name, base) in [("evm", None), ("evm split-key", Some(client))] {
        let keys = Keys::random(threads, batch, base);
        let gpu = Gpu::new(threads, batch, capacity, &keys.points(), &everything, &[]);
        for run in 0..3u64 {
            let command = gpu.submit(0);
            let hits = gpu.collect(0, &command, run);
            if hits.len() != (threads * window) as usize {
                fail(&format!("{name} run {run}: expected {} hits, got {}", threads * window, hits.len()));
            }
            for hit in &hits {
                verify(&secp, &keys, hit, &everything, &[]);
            }
            println!("{{\"type\":\"self_test\",\"case\":\"{name}\",\"run\":{run},\"checked\":{},\"ok\":true}}", hits.len());
        }
    }

    // TRON: GPU должен найти ровно то, что находит CPU перебором всех кандидатов.
    let tron = [TronTarget::parse("TX:"), TronTarget::parse(":a"), TronTarget::parse("TR:z")];
    let keys = Keys::random(threads, batch, None);
    let gpu = Gpu::new(threads, batch, capacity, &keys.points(), &[], &tron);
    for run in 0..2u64 {
        let command = gpu.submit(0);
        let mut found: Vec<String> = gpu
            .collect(0, &command, run)
            .iter()
            .filter_map(|hit| verify(&secp, &keys, hit, &[], &tron).map(|(_, a)| a))
            .collect();
        let mut expected: Vec<String> = Vec::new();
        for t in 0..threads {
            for j in 0..window {
                let hit = Hit { thread: t, run, j, address: [0; 20], network: 1 };
                let text = tron_address(&eth_address(&keys.public(&secp, &keys.key(&hit))));
                if tron.iter().any(|target| target.matches(&text)) {
                    expected.push(text);
                }
            }
        }
        found.sort();
        expected.sort();
        if found != expected {
            fail(&format!("tron run {run}: GPU found {}, CPU expected {}", found.len(), expected.len()));
        }
        println!("{{\"type\":\"self_test\",\"case\":\"tron\",\"run\":{run},\"matched\":{},\"ok\":true}}", found.len());
    }
    std::process::exit(0);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.iter().any(|a| a == "--self-test") {
        self_test();
    }
    let value_of = |flag: &str| args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned();
    let mut patterns: Vec<Pattern> = args
        .windows(2)
        .filter(|w| w[0] == "--target")
        .map(|w| {
            let (pre, suf) = w[1].split_once(':').unwrap_or((w[1].as_str(), ""));
            pattern(pre, suf)
        })
        .collect();
    let prefix = value_of("--prefix").unwrap_or_default();
    let suffix = value_of("--suffix").unwrap_or_default();
    if !prefix.is_empty() || !suffix.is_empty() {
        patterns.push(pattern(&prefix, &suffix));
    }
    let tron: Vec<TronTarget> = args
        .windows(2)
        .filter(|w| w[0] == "--tron-target")
        .map(|w| TronTarget::parse(&w[1]))
        .collect();
    let split_base = value_of("--split-key").map(|raw| {
        let hex = raw.trim().trim_start_matches("0x");
        let bytes: Option<Vec<u8>> = (0..hex.len() / 2).map(|i| u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).ok()).collect();
        bytes
            .and_then(|b| PublicKey::from_slice(&b).ok())
            .unwrap_or_else(|| fail("--split-key must be a secp256k1 public key (33 or 65 bytes hex)"))
    });
    if patterns.is_empty() && tron.is_empty() {
        eprintln!("usage: metalvanity-evm --target <prefix>:<suffix> [--tron-target <prefix>:<suffix>] [...]");
        std::process::exit(1);
    }
    if patterns.len() > MAX_PATTERNS || tron.len() > MAX_PATTERNS {
        fail("too many targets");
    }
    let threads = value_of("--threads").and_then(|v| v.parse().ok()).unwrap_or(16384u32).max(1);
    let batch = value_of("--batch").and_then(|v| v.parse().ok()).unwrap_or(256u32).clamp(1, 4096);
    let reseed_secs = value_of("--reseed-secs").and_then(|v| v.parse().ok()).unwrap_or(RESEED_SECS).max(1);
    let throttle = Throttle {
        load: value_of("--gpu-load").and_then(|v| v.parse::<f64>().ok()).unwrap_or(100.0).clamp(1.0, 100.0) / 100.0,
        max_speed: value_of("--max-speed").and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0).max(0.0),
    };

    let mut keys = Keys::random(threads, batch, split_base);
    let gpu = Gpu::new(threads, batch, 1024, &keys.points(), &patterns, &tron);
    let secp = Secp256k1::new();
    let per_run = threads as u64 * (2 * batch as u64 + 1);

    // Новые случайные старты готовятся в фоне, пока GPU считает старые.
    let (reseed_tx, reseed_rx) = mpsc::sync_channel::<(Keys, Vec<PublicKey>)>(1);
    thread::spawn(move || loop {
        thread::sleep(Duration::from_secs(reseed_secs));
        let fresh = Keys::random(threads, batch, split_base);
        let points = fresh.points();
        if reseed_tx.send((fresh, points)).is_err() {
            return;
        }
    });

    let report = |hits: Vec<Hit>, keys: &Keys| {
        for hit in hits {
            if let Some((key, address)) = verify(&secp, keys, &hit, &patterns, &tron) {
                let network = if hit.network == 1 { "trx" } else { "eth" };
                println!(
                    "{{\"type\":\"found\",\"network\":\"{network}\",\"address\":\"{address}\",\"private_key\":\"{}\"}}",
                    to_hex(&key.secret_bytes())
                );
            }
        }
    };

    let mut checked = 0u64;
    let mut last_stats = Instant::now();
    let mut run = 0u64;
    let mut print_stats = |checked: u64| {
        if last_stats.elapsed().as_secs_f64() >= 1.0 {
            println!("{{\"type\":\"stats\",\"checked\":{checked}}}");
            let _ = std::io::stdout().flush();
            last_stats = Instant::now();
        }
    };

    if throttle.active() {
        // С ограничением — по одному запуску с паузой после каждого.
        loop {
            objc::rc::autoreleasepool(|| {
                if let Ok((fresh, points)) = reseed_rx.try_recv() {
                    keys = fresh;
                    gpu.upload(&points);
                    run = 0;
                }
                let started = Instant::now();
                let command = gpu.submit(0);
                let hits = gpu.collect(0, &command, run);
                let busy = started.elapsed();
                report(hits, &keys);
                checked += per_run;
                run += 1;
                print_stats(checked);
                thread::sleep(throttle.pause(busy, per_run));
            });
        }
    }

    let mut pending = (0usize, gpu.submit(0), run);
    loop {
        objc::rc::autoreleasepool(|| {
            if let Ok((fresh, points)) = reseed_rx.try_recv() {
                // Дожидаемся текущего запуска со старыми ключами, потом меняем точки.
                let (slot, command, done_run) = &pending;
                report(gpu.collect(*slot, command, *done_run), &keys);
                checked += per_run;
                keys = fresh;
                gpu.upload(&points);
                run = 0;
                pending = (0, gpu.submit(0), run);
                return;
            }
            // Следующий запуск ставится в очередь до того, как ждём текущий: GPU
            // выполняет их по порядку, точки продолжаются без пауз.
            run += 1;
            let next = (1 - pending.0, gpu.submit(1 - pending.0), run);
            let (slot, command, done_run) = std::mem::replace(&mut pending, next);
            report(gpu.collect(slot, &command, done_run), &keys);
            checked += per_run;
        });
        print_stats(checked);
    }
}

struct Throttle {
    load: f64,      // доля времени, которую GPU считает (0..1]
    max_speed: f64, // адресов в секунду, 0 — без ограничения
}

impl Throttle {
    fn active(&self) -> bool {
        self.load < 1.0 || self.max_speed > 0.0
    }

    /// Пауза после запуска, который занял `busy` и проверил `per_run` адресов.
    fn pause(&self, busy: Duration, per_run: u64) -> Duration {
        let busy = busy.as_secs_f64();
        let by_load = busy * (1.0 / self.load - 1.0);
        let by_speed = if self.max_speed > 0.0 { per_run as f64 / self.max_speed - busy } else { 0.0 };
        Duration::from_secs_f64(by_load.max(by_speed).max(0.0))
    }
}
