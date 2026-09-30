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
//!                   [--threads N] [--batch B] [--reseed-secs S]
//!                   [--gpu-load 1..100] [--max-speed адресов/с]
//!
//! --gpu-load и --max-speed ограничивают нагрузку паузами между запусками: GPU
//! считает пачку (~0,1 с), потом ждёт столько, чтобы доля работы не превышала
//! gpu-load %, а средняя скорость — max-speed.
//!
//! Цель — «начало:конец» в hex (любая часть может быть пустой); адрес подходит,
//! если совпал хотя бы с одной целью. Итоговую проверку условия делает bridge.py.
//!   metalvanity-evm --self-test
//!
//! Вывод — построчный JSON, как у ethvanity:
//!   {"type":"found","address":"0x...","private_key":"..."}
//!   {"type":"stats","checked":123456}

use metal::{CompileOptions, Device, MTLResourceOptions, MTLSize};
use secp256k1::rand::rngs::OsRng;
use secp256k1::{PublicKey, Scalar, Secp256k1, SecretKey};
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

struct Hit {
    thread: u32,
    run: u64,
    j: u32, // смещение в окне 0..2B
    address: [u8; 20],
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
    fn new(threads: u32, batch: u32, capacity: u32, start: &[PublicKey], patterns: &[Pattern]) -> Gpu {
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
            .map(|w| Hit { thread: w[0], run, j: w[1], address: unpack(&w[2..7]) })
            .collect()
    }
}

struct Keys {
    starts: Vec<SecretKey>,
    batch: u32,
}

impl Keys {
    fn random(threads: u32, batch: u32) -> Keys {
        Keys { starts: (0..threads).map(|_| SecretKey::new(&mut OsRng)).collect(), batch }
    }

    fn window(&self) -> u128 {
        2 * self.batch as u128 + 1
    }

    /// k_t + run·(2B+1) + смещение в окне.
    fn key(&self, hit: &Hit) -> SecretKey {
        let offset = hit.run as u128 * self.window() + hit.j as u128;
        self.starts[hit.thread as usize].add_tweak(&scalar_u128(offset)).unwrap()
    }

    /// Центры первых окон: (k_t + B)·G.
    fn points(&self) -> Vec<PublicKey> {
        let secp = Secp256k1::new();
        let shift = scalar_u128(self.batch as u128);
        self.starts
            .iter()
            .map(|k| PublicKey::from_secret_key(&secp, &k.add_tweak(&shift).unwrap()))
            .collect()
    }
}

fn verify(secp: &Secp256k1<secp256k1::All>, keys: &Keys, hit: &Hit, patterns: &[Pattern]) -> SecretKey {
    let key = keys.key(hit);
    let address = eth_address(&PublicKey::from_secret_key(secp, &key));
    let matches = patterns.iter().any(|(value, mask)| (0..20).all(|i| address[i] & mask[i] == value[i]));
    if address != hit.address || !matches {
        fail(&format!("GPU result mismatch: thread {} run {} j {}", hit.thread, hit.run, hit.j));
    }
    key
}

fn self_test() -> ! {
    let (threads, batch) = (512u32, 64u32);
    let capacity = threads * (2 * batch + 1);
    let keys = Keys::random(threads, batch);
    let patterns = [([0u8; 20], [0u8; 20])];
    let gpu = Gpu::new(threads, batch, capacity, &keys.points(), &patterns);
    let secp = Secp256k1::new();
    for run in 0..3u64 {
        let command = gpu.submit(0);
        let hits = gpu.collect(0, &command, run);
        if hits.len() != capacity as usize {
            fail(&format!("run {run}: expected {capacity} hits, got {}", hits.len()));
        }
        for hit in &hits {
            verify(&secp, &keys, hit, &patterns);
        }
        println!("{{\"type\":\"self_test\",\"run\":{run},\"checked\":{},\"ok\":true}}", hits.len());
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
    if patterns.is_empty() {
        eprintln!("usage: metalvanity-evm --target <prefix>:<suffix> [...] [--threads N] [--batch B]");
        std::process::exit(1);
    }
    if patterns.len() > MAX_PATTERNS {
        fail("too many targets");
    }
    let threads = value_of("--threads").and_then(|v| v.parse().ok()).unwrap_or(16384u32).max(1);
    let batch = value_of("--batch").and_then(|v| v.parse().ok()).unwrap_or(256u32).clamp(1, 4096);
    let reseed_secs = value_of("--reseed-secs").and_then(|v| v.parse().ok()).unwrap_or(RESEED_SECS).max(1);
    let throttle = Throttle {
        load: value_of("--gpu-load").and_then(|v| v.parse::<f64>().ok()).unwrap_or(100.0).clamp(1.0, 100.0) / 100.0,
        max_speed: value_of("--max-speed").and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0).max(0.0),
    };

    let mut keys = Keys::random(threads, batch);
    let gpu = Gpu::new(threads, batch, 1024, &keys.points(), &patterns);
    let secp = Secp256k1::new();
    let per_run = threads as u64 * (2 * batch as u64 + 1);

    // Новые случайные старты готовятся в фоне, пока GPU считает старые.
    let (reseed_tx, reseed_rx) = mpsc::sync_channel::<(Keys, Vec<PublicKey>)>(1);
    thread::spawn(move || loop {
        thread::sleep(Duration::from_secs(reseed_secs));
        let fresh = Keys::random(threads, batch);
        let points = fresh.points();
        if reseed_tx.send((fresh, points)).is_err() {
            return;
        }
    });

    let report = |hits: Vec<Hit>, keys: &Keys| {
        for hit in hits {
            let key = verify(&secp, keys, &hit, &patterns);
            println!(
                "{{\"type\":\"found\",\"address\":\"0x{}\",\"private_key\":\"{}\"}}",
                to_hex(&hit.address),
                to_hex(&key.secret_bytes())
            );
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
