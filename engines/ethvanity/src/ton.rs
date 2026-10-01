//! Режим `--ton-subwallet <публичный ключ ed25519>`: красивый TON-адрес без нового ключа.
//!
//! Адрес кошелька v4r2 = хеш StateInit(код, данные), а в данных кроме ключа лежит
//! 32-битный номер подкошелька (wallet_id). Один ключ — 2^32 разных адресов;
//! перебираем номер, ключ и сид-фраза владельца не меняются.
//!
//! Хеш ячейки TON = sha256(дескрипторы ++ данные ++ глубины ссылок ++ хеши ссылок):
//!   данные  = sha256(00 51 ++ seqno(0) ++ wallet_id ++ pubkey ++ 40)
//!   StateInit = sha256(02 01 34 ++ глубина_кода ++ 0000 ++ хеш_кода ++ хеш_данных)
//! Адрес для людей: base64url(флаг ++ workchain ++ хеш ++ crc16) — 48 символов.
//! Всё сверено с tonsdk (WalletV4ContractR2) на случайных ключах и номерах.
//!
//! Пространство конечное: поток t проверяет номера t, t+T, t+2T, … до 2^32,
//! в конце печатается {"type":"done"}.

use sha2::{Digest, Sha256};
use std::env;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;

const CODE_HASH: [u8; 32] = [
    0xfe, 0xb5, 0xff, 0x68, 0x20, 0xe2, 0xff, 0x0d, 0x94, 0x83, 0xe7, 0xe0, 0xd6, 0x2c, 0x81, 0x7d, 0x84, 0x67, 0x89, 0xfb,
    0x4a, 0xe5, 0x80, 0xc8, 0x78, 0x86, 0x6d, 0x95, 0x9d, 0xab, 0xd5, 0xc0,
];
const CODE_DEPTH: u16 = 7;
const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Prefix,
    Suffix,
    Contains,
}

struct Config {
    pubkey: [u8; 32],
    pattern: Vec<u8>,
    mode: Mode,
    case_sensitive: bool,
    bounceable: bool,
    threads: u64,
}

fn fail(message: &str) -> ! {
    println!("{{\"type\":\"error\",\"message\":\"{message}\"}}");
    let _ = std::io::stdout().flush();
    std::process::exit(2);
}

fn parse() -> Config {
    let args: Vec<String> = env::args().collect();
    let value = |flag: &str| args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned();
    let raw = value("--ton-subwallet").unwrap_or_default();
    let hex = raw.trim().trim_start_matches("0x");
    if hex.len() != 64 {
        fail("--ton-subwallet must be a 32-byte ed25519 public key in hex");
    }
    let mut pubkey = [0u8; 32];
    for i in 0..32 {
        pubkey[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap_or_else(|_| fail("public key is not hex"));
    }
    let case_sensitive = args.iter().any(|a| a == "--case");
    let pattern = value("--pattern").unwrap_or_default();
    if pattern.is_empty() || !pattern.bytes().all(|b| B64.contains(&b)) {
        fail("--pattern must use base64url characters: A-Z a-z 0-9 - _");
    }
    let pattern = if case_sensitive { pattern.into_bytes() } else { pattern.to_ascii_lowercase().into_bytes() };
    let mode = match value("--mode").as_deref() {
        Some("suffix") => Mode::Suffix,
        Some("contains") => Mode::Contains,
        _ => Mode::Prefix,
    };
    let threads = value("--threads")
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or_else(|| thread::available_parallelism().map(|n| n.get() as u64).unwrap_or(4))
        .max(1);
    Config { pubkey, pattern, mode, case_sensitive, bounceable: args.iter().any(|a| a == "--bounceable"), threads }
}

fn crc16(data: &[u8]) -> u16 {
    let mut crc: u16 = 0;
    for &byte in data {
        crc ^= (byte as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 { (crc << 1) ^ 0x1021 } else { crc << 1 };
        }
    }
    crc
}

fn friendly(state_hash: &[u8; 32], bounceable: bool, out: &mut [u8; 48]) {
    let mut raw = [0u8; 36];
    raw[0] = if bounceable { 0x11 } else { 0x51 };
    raw[1] = 0x00;
    raw[2..34].copy_from_slice(state_hash);
    let crc = crc16(&raw[..34]);
    raw[34..36].copy_from_slice(&crc.to_be_bytes());
    for (i, chunk) in raw.chunks(3).enumerate() {
        let n = (chunk[0] as u32) << 16 | (chunk[1] as u32) << 8 | chunk[2] as u32;
        out[i * 4] = B64[(n >> 18) as usize & 63];
        out[i * 4 + 1] = B64[(n >> 12) as usize & 63];
        out[i * 4 + 2] = B64[(n >> 6) as usize & 63];
        out[i * 4 + 3] = B64[n as usize & 63];
    }
}

fn matches(address: &[u8; 48], config: &Config) -> bool {
    let body = &address[2..];
    let lowered;
    let body: &[u8] = if config.case_sensitive {
        body
    } else {
        lowered = body.to_ascii_lowercase();
        &lowered
    };
    let p = &config.pattern;
    match config.mode {
        Mode::Prefix => body.starts_with(p),
        Mode::Suffix => body.ends_with(p),
        Mode::Contains => body.windows(p.len()).any(|w| w == p.as_slice()),
    }
}

pub fn run() {
    let config = Arc::new(parse());
    let checked = Arc::new(AtomicU64::new(0));
    let (tx, rx) = mpsc::channel::<(String, u32)>();
    let mut handles = Vec::new();

    for t in 0..config.threads {
        let config = Arc::clone(&config);
        let checked = Arc::clone(&checked);
        let tx = tx.clone();
        handles.push(thread::spawn(move || {
            let mut data = [0u8; 43];
            data[0] = 0x00;
            data[1] = 0x51;
            data[10..42].copy_from_slice(&config.pubkey);
            data[42] = 0x40;
            let mut state = [0u8; 71];
            state[0] = 0x02;
            state[1] = 0x01;
            state[2] = 0x34;
            state[3..5].copy_from_slice(&CODE_DEPTH.to_be_bytes());
            state[7..39].copy_from_slice(&CODE_HASH);
            let mut address = [0u8; 48];
            let mut local = 0u64;
            let mut id = t;
            while id <= u32::MAX as u64 {
                data[6..10].copy_from_slice(&(id as u32).to_be_bytes());
                let data_hash = Sha256::digest(data);
                state[39..71].copy_from_slice(&data_hash);
                let state_hash: [u8; 32] = Sha256::digest(state).into();
                friendly(&state_hash, config.bounceable, &mut address);
                if matches(&address, &config) {
                    let text = String::from_utf8_lossy(&address).into_owned();
                    if tx.send((text, id as u32)).is_err() {
                        return;
                    }
                }
                local += 1;
                if local == 16_384 {
                    checked.fetch_add(local, Ordering::Relaxed);
                    local = 0;
                }
                id += config.threads;
            }
            checked.fetch_add(local, Ordering::Relaxed);
        }));
    }
    drop(tx);

    {
        let checked = Arc::clone(&checked);
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(1));
            println!("{{\"type\":\"stats\",\"checked\":{}}}", checked.load(Ordering::Relaxed));
            let _ = std::io::stdout().flush();
        });
    }

    for (address, wallet_id) in rx {
        println!("{{\"type\":\"found\",\"address\":\"{address}\",\"wallet_id\":{wallet_id}}}");
        let _ = std::io::stdout().flush();
    }
    for h in handles {
        let _ = h.join();
    }
    println!("{{\"type\":\"stats\",\"checked\":{}}}", checked.load(Ordering::Relaxed));
    println!("{{\"type\":\"done\"}}");
    let _ = std::io::stdout().flush();
}
