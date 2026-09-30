//! Режим `--create2`: подбор salt для адреса смарт-контракта.
//!
//! Адрес контракта, развёрнутого через CREATE2, считается как
//!   keccak256(0xff ++ factory ++ salt ++ keccak256(init_code))[12..]
//! Фабрика и хеш кода фиксированы заказчиком, перебирается только salt —
//! ни ключей, ни эллиптической кривой, одна keccak-перестановка на попытку
//! (85 байт входа влезают в один блок keccak, rate = 136 байт).
//!
//! Раскладка salt: [caller: 20 байт][поток: 1 байт][случайные: 3 байта][счётчик: 8 байт].
//! Первые 20 байт — адрес заказчика: фабрики вроде ImmutableCreate2Factory
//! требуют, чтобы они совпадали с msg.sender (или были нулями), иначе
//! найденный salt мог бы использовать кто угодно, подсмотрев его в мемпуле.
//!
//! Режим `--create3` (через фабрику CreateX): адрес не зависит от кода вообще.
//! CreateX сначала «охраняет» salt — keccak256(msg.sender ++ salt), если первые
//! 20 байт salt равны вызывающему, а 21-й байт 0x00 (один адрес во всех сетях),
//! — затем кладёт крошечный прокси по CREATE2, а прокси разворачивает контракт
//! своим первым CREATE. Итоговый адрес = keccak256(0xd694 ++ proxy ++ 0x01)[12..].
//! Три keccak на попытку. Раскладка salt: [caller 20][0x00][поток 1][случайные 2][счётчик 8].
//!
//! Вывод — тот же построчный JSON, что и в основном режиме:
//!   {"type":"found","address":"0x...","salt":"0x...","leading_zero_bytes":4,"zero_bytes":5}
//!   {"type":"stats","checked":123456}

use secp256k1::rand::rngs::OsRng;
use secp256k1::rand::RngCore;
use std::env;
use std::io::Write;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;
use tiny_keccak::{Hasher, Keccak};

#[derive(Clone)]
enum Goal {
    /// Нулевые байты в начале адреса; выдаём только новые рекорды не ниже `min`.
    LeadingZeros { min: u32 },
    /// Нулевые байты где угодно в адресе (каждый дешевле в calldata); тоже рекорды.
    ZeroBytes { min: u32 },
    /// Hex-префикс адреса (по полубайтам). Совпадений может быть сотни в
    /// секунду, поэтому выдаём первое, а дальше — только те, где нулевых
    /// байт больше (такой адрес ещё и дешевле в вызовах).
    Prefix(Vec<u8>),
    /// Uniswap v4 hook: младшие 14 бит адреса должны точно совпасть с флагами.
    /// Выдача — как у префикса.
    HookFlags(u16),
}

struct Config {
    factory: [u8; 20],
    init_code_hash: [u8; 32],
    caller: [u8; 20],
    goal: Goal,
    threads: usize,
    create3: bool,
}

const HOOK_FLAG_MASK: u16 = 0x3FFF;

/// CreateX — одинаковый адрес во всех EVM-сетях.
const CREATEX: [u8; 20] = [
    0xba, 0x5e, 0xd0, 0x99, 0x63, 0x3d, 0x3b, 0x31, 0x3e, 0x4d, 0x5f, 0x7b, 0xdc, 0x13, 0x05, 0xd3, 0xc2, 0x8b, 0xa5, 0xed,
];
/// keccak256 кода прокси, через который CreateX делает CREATE3.
const CREATE3_PROXY_HASH: [u8; 32] = [
    0x21, 0xc3, 0x5d, 0xbe, 0x1b, 0x34, 0x4a, 0x24, 0x88, 0xcf, 0x33, 0x21, 0xd6, 0xce, 0x54, 0x2f, 0x8e, 0x9f, 0x30, 0x55,
    0x44, 0xff, 0x09, 0xe4, 0x99, 0x3a, 0x62, 0x31, 0x9a, 0x49, 0x7c, 0x1f,
];

fn parse_hex<const N: usize>(raw: &str) -> Option<[u8; N]> {
    let s = raw.trim().trim_start_matches("0x").trim_start_matches("0X");
    if s.len() != N * 2 {
        return None;
    }
    let mut out = [0u8; N];
    for (i, chunk) in s.as_bytes().chunks(2).enumerate() {
        let pair = std::str::from_utf8(chunk).ok()?;
        out[i] = u8::from_str_radix(pair, 16).ok()?;
    }
    Some(out)
}

fn fail(message: &str) -> ! {
    println!("{{\"type\":\"error\",\"message\":\"{message}\"}}");
    let _ = std::io::stdout().flush();
    std::process::exit(2);
}

fn parse_config() -> Config {
    let args: Vec<String> = env::args().collect();
    let value = |flag: &str| -> Option<String> {
        args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned()
    };

    let create3 = args.iter().any(|a| a == "--create3");
    let factory = if create3 {
        CREATEX
    } else {
        value("--factory")
            .and_then(|v| parse_hex::<20>(&v))
            .unwrap_or_else(|| fail("--factory must be a 20-byte hex address"))
    };
    let init_code_hash = if create3 {
        [0u8; 32]
    } else {
        value("--init-code-hash")
            .and_then(|v| parse_hex::<32>(&v))
            .unwrap_or_else(|| fail("--init-code-hash must be a 32-byte hex hash"))
    };
    let caller = match value("--caller") {
        Some(v) if !v.trim().is_empty() => {
            parse_hex::<20>(&v).unwrap_or_else(|| fail("--caller must be a 20-byte hex address"))
        }
        _ => [0u8; 20],
    };

    let min = value("--min").and_then(|v| v.parse::<u32>().ok()).unwrap_or(1).clamp(1, 20);
    let goal = match value("--goal").as_deref() {
        Some("leading") | None => Goal::LeadingZeros { min },
        Some("zeros") => Goal::ZeroBytes { min },
        Some("prefix") => {
            let raw = value("--prefix").unwrap_or_default();
            let nibbles: Option<Vec<u8>> = raw
                .trim()
                .trim_start_matches("0x")
                .chars()
                .map(|c| c.to_digit(16).map(|d| d as u8))
                .collect();
            match nibbles {
                Some(n) if !n.is_empty() && n.len() <= 40 => Goal::Prefix(n),
                _ => fail("--prefix must be 1..40 hex characters"),
            }
        }
        Some("hook") => {
            let raw = value("--hook-flags").unwrap_or_default();
            let flags = u16::from_str_radix(raw.trim().trim_start_matches("0x"), 16)
                .unwrap_or_else(|_| fail("--hook-flags must be a hex number"));
            Goal::HookFlags(flags & HOOK_FLAG_MASK)
        }
        Some(_) => fail("--goal must be one of: leading, zeros, prefix, hook"),
    };

    let threads = value("--threads")
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or_else(|| thread::available_parallelism().map(|n| n.get()).unwrap_or(4))
        .max(1);

    Config { factory, init_code_hash, caller, goal, threads, create3 }
}

#[inline]
fn leading_zero_bytes(addr: &[u8]) -> u32 {
    addr.iter().take_while(|&&b| b == 0).count() as u32
}

#[inline]
fn zero_bytes(addr: &[u8]) -> u32 {
    addr.iter().filter(|&&b| b == 0).count() as u32
}

#[inline]
fn matches_prefix(addr: &[u8], prefix: &[u8]) -> bool {
    prefix.iter().enumerate().all(|(i, &want)| {
        let byte = addr[i / 2];
        let nibble = if i % 2 == 0 { byte >> 4 } else { byte & 0x0f };
        nibble == want
    })
}

/// Поднимает общий рекорд, если `score` его побил. true — мы новый рекордсмен.
fn claim_record(best: &AtomicU32, score: u32) -> bool {
    let mut current = best.load(Ordering::Relaxed);
    while score > current {
        match best.compare_exchange_weak(current, score, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return true,
            Err(actual) => current = actual,
        }
    }
    false
}

fn to_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        s.push(HEX[(b >> 4) as usize] as char);
        s.push(HEX[(b & 0x0f) as usize] as char);
    }
    s
}

pub fn run() {
    let config = Arc::new(parse_config());
    let checked = Arc::new(AtomicU64::new(0));
    // Рекорд стартует с min-1: первым выдаётся результат, дотянувший до минимума.
    let floor = match config.goal {
        Goal::LeadingZeros { min } | Goal::ZeroBytes { min } => min - 1,
        _ => 0,
    };
    let best = Arc::new(AtomicU32::new(floor));
    let (tx, rx) = mpsc::channel::<([u8; 20], [u8; 32])>();

    for index in 0..config.threads {
        let config = Arc::clone(&config);
        let checked = Arc::clone(&checked);
        let best = Arc::clone(&best);
        let tx = tx.clone();
        if config.create3 {
            thread::spawn(move || worker_create3(index as u8, &config, &checked, &best, tx));
        } else {
            thread::spawn(move || worker(index as u8, &config, &checked, &best, tx));
        }
    }
    drop(tx);

    {
        let checked = Arc::clone(&checked);
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(1));
            let now = checked.load(Ordering::Relaxed);
            println!("{{\"type\":\"stats\",\"checked\":{now}}}");
            let _ = std::io::stdout().flush();
        });
    }

    for (addr, salt) in rx {
        println!(
            "{{\"type\":\"found\",\"address\":\"0x{}\",\"salt\":\"0x{}\",\"leading_zero_bytes\":{},\"zero_bytes\":{}}}",
            to_hex(&addr),
            to_hex(&salt),
            leading_zero_bytes(&addr),
            zero_bytes(&addr)
        );
        let _ = std::io::stdout().flush();
    }
}

#[inline]
fn is_hit(goal: &Goal, addr: &[u8], best: &AtomicU32) -> bool {
    match goal {
        Goal::LeadingZeros { .. } => addr[0] == 0 && claim_record(best, leading_zero_bytes(addr)),
        Goal::ZeroBytes { .. } => {
            let score = zero_bytes(addr);
            score > best.load(Ordering::Relaxed) && claim_record(best, score)
        }
        Goal::Prefix(prefix) => matches_prefix(addr, prefix) && claim_record(best, zero_bytes(addr) + 1),
        Goal::HookFlags(flags) => {
            (u16::from_be_bytes([addr[18], addr[19]]) & HOOK_FLAG_MASK) == *flags
                && claim_record(best, zero_bytes(addr) + 1)
        }
    }
}

#[inline]
fn keccak(data: &[u8], out: &mut [u8; 32]) {
    let mut hasher = Keccak::v256();
    hasher.update(data);
    hasher.finalize(out);
}

fn worker_create3(index: u8, config: &Config, checked: &AtomicU64, best: &AtomicU32, tx: mpsc::Sender<([u8; 20], [u8; 32])>) {
    // Вход «охраны» CreateX: salt, перед которым 32-байтный msg.sender (если
    // salt разрешённый) — либо просто сам salt (keccak256(abi.encode(salt))).
    let guarded_by_caller = config.caller != [0u8; 20];
    let mut guard_input = [0u8; 64];
    guard_input[12..32].copy_from_slice(&config.caller);
    guard_input[32..52].copy_from_slice(&config.caller);
    guard_input[52] = 0x00;
    guard_input[53] = index;
    let mut entropy = [0u8; 2];
    OsRng.fill_bytes(&mut entropy);
    guard_input[54..56].copy_from_slice(&entropy);

    let mut proxy_preimage = [0u8; 85];
    proxy_preimage[0] = 0xff;
    proxy_preimage[1..21].copy_from_slice(&config.factory);
    proxy_preimage[53..85].copy_from_slice(&CREATE3_PROXY_HASH);

    let mut rlp = [0u8; 23];
    rlp[0] = 0xd6;
    rlp[1] = 0x94;
    rlp[22] = 0x01;

    const REPORT_EVERY: u64 = 16_384;
    let (mut local, mut counter) = (0u64, 0u64);
    let mut hash = [0u8; 32];

    loop {
        guard_input[56..64].copy_from_slice(&counter.to_be_bytes());
        let guard_slice: &[u8] = if guarded_by_caller { &guard_input } else { &guard_input[32..64] };
        keccak(guard_slice, &mut hash);
        proxy_preimage[21..53].copy_from_slice(&hash);
        keccak(&proxy_preimage, &mut hash);
        rlp[2..22].copy_from_slice(&hash[12..32]);
        keccak(&rlp, &mut hash);
        let addr = &hash[12..32];

        if is_hit(&config.goal, addr, best) {
            let mut found_addr = [0u8; 20];
            found_addr.copy_from_slice(addr);
            let mut salt = [0u8; 32];
            salt.copy_from_slice(&guard_input[32..64]);
            if tx.send((found_addr, salt)).is_err() {
                return;
            }
        }

        counter = counter.wrapping_add(1);
        local += 1;
        if local >= REPORT_EVERY {
            checked.fetch_add(local, Ordering::Relaxed);
            local = 0;
        }
    }
}

fn worker(index: u8, config: &Config, checked: &AtomicU64, best: &AtomicU32, tx: mpsc::Sender<([u8; 20], [u8; 32])>) {
    // 0xff ++ factory ++ salt ++ init_code_hash — собирается один раз, дальше
    // в цикле переписываются только последние 8 байт salt (счётчик).
    let mut preimage = [0u8; 85];
    preimage[0] = 0xff;
    preimage[1..21].copy_from_slice(&config.factory);
    preimage[21..41].copy_from_slice(&config.caller);
    preimage[41] = index;
    let mut entropy = [0u8; 3];
    OsRng.fill_bytes(&mut entropy);
    preimage[42..45].copy_from_slice(&entropy);
    preimage[53..85].copy_from_slice(&config.init_code_hash);

    const REPORT_EVERY: u64 = 16_384;
    let mut local = 0u64;
    let mut counter = 0u64;
    let mut hash = [0u8; 32];

    loop {
        preimage[45..53].copy_from_slice(&counter.to_be_bytes());
        let mut hasher = Keccak::v256();
        hasher.update(&preimage);
        hasher.finalize(&mut hash);
        let addr = &hash[12..32];

        if is_hit(&config.goal, addr, best) {
            let mut found_addr = [0u8; 20];
            found_addr.copy_from_slice(addr);
            let mut salt = [0u8; 32];
            salt.copy_from_slice(&preimage[21..53]);
            if tx.send((found_addr, salt)).is_err() {
                return;
            }
        }

        counter = counter.wrapping_add(1);
        local += 1;
        if local >= REPORT_EVERY {
            checked.fetch_add(local, Ordering::Relaxed);
            local = 0;
        }
    }
}
