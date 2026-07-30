//! ethvanity — быстрый многопоточный поиск ETH vanity-адресов по hex-префиксу.
//!
//! Ключевая оптимизация: вместо полного скалярного умножения k*G для КАЖДОГО
//! кандидата (как это делает "наивная" генерация), мы считаем его один раз
//! для случайного стартового ключа, а дальше двигаемся по кривой сложением
//! точек — P(k+1) = P(k) + G — через безопасный, аудированный API крейта
//! `secp256k1` (обёртка над libsecp256k1 из Bitcoin Core). Сложение точки
//! ощутимо дешевле полного умножения, поэтому это и даёт основной прирост
//! скорости — без единой строчки написанной вручную эллиптической математики.
//!
//! Вторая оптимизация — сравнение префикса идёт по "сырым" полубайтам адреса,
//! без форматирования каждого кандидата в hex-строку (это было главным
//! узким местом в первой версии: `format!` на каждый из миллионов адресов
//! в секунду). В hex превращается только реальная находка — событие редкое.
//!
//! Вывод — построчный JSON в stdout, без ANSI и терминальных хитростей:
//!   {"type":"found","address":"0x...","private_key":"..."}
//!   {"type":"stats","checked":123456}
//!
//! Останавливается по SIGTERM/SIGKILL от родителя (как обычный unix-процесс),
//! отдельного протокола остановки не требует.

use secp256k1::rand::rngs::OsRng;
use secp256k1::{PublicKey, Scalar, Secp256k1, SecretKey};
use std::env;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;
use tiny_keccak::{Hasher, Keccak};

struct Args {
    prefixes: Vec<Vec<u8>>, // каждый префикс — последовательность полубайтов (0..=15)
    threads: usize,
}

fn hex_nibble(c: char) -> Option<u8> {
    c.to_digit(16).map(|d| d as u8)
}

fn parse_args() -> Args {
    let args: Vec<String> = env::args().collect();
    let mut prefixes = Vec::new();
    let mut threads = thread::available_parallelism().map(|n| n.get()).unwrap_or(4);

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--prefix" => {
                if let Some(v) = args.get(i + 1) {
                    let nibbles: Option<Vec<u8>> = v.chars().map(hex_nibble).collect();
                    if let Some(nibbles) = nibbles {
                        if !nibbles.is_empty() {
                            prefixes.push(nibbles);
                        }
                    }
                    i += 1;
                }
            }
            "--threads" => {
                if let Some(v) = args.get(i + 1) {
                    if let Ok(n) = v.parse::<usize>() {
                        threads = n.max(1);
                    }
                    i += 1;
                }
            }
            _ => {}
        }
        i += 1;
    }

    Args { prefixes, threads }
}

#[inline]
fn eth_address_bytes(pubkey: &PublicKey) -> [u8; 20] {
    // Адрес Ethereum = последние 20 байт keccak256(X || Y), где X,Y — не
    // сжатое представление точки без ведущего байта 0x04.
    let uncompressed = pubkey.serialize_uncompressed();
    let mut hasher = Keccak::v256();
    let mut hash = [0u8; 32];
    hasher.update(&uncompressed[1..]);
    hasher.finalize(&mut hash);
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&hash[12..32]);
    addr
}

#[inline]
fn nibble_at(addr: &[u8; 20], index: usize) -> u8 {
    let byte = addr[index / 2];
    if index % 2 == 0 { byte >> 4 } else { byte & 0x0f }
}

#[inline]
fn matches_prefix(addr: &[u8; 20], prefix: &[u8]) -> bool {
    for (i, &want) in prefix.iter().enumerate() {
        if nibble_at(addr, i) != want {
            return false;
        }
    }
    true
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

fn main() {
    let args = parse_args();
    if args.prefixes.is_empty() {
        eprintln!("usage: ethvanity --prefix <hex> [--prefix <hex> ...] [--threads N]");
        std::process::exit(1);
    }

    let checked = Arc::new(AtomicU64::new(0));
    let (tx, rx) = mpsc::channel::<(String, String)>();

    let mut handles = Vec::with_capacity(args.threads);
    for _ in 0..args.threads {
        let prefixes = args.prefixes.clone();
        let checked = Arc::clone(&checked);
        let tx = tx.clone();
        handles.push(thread::spawn(move || worker_loop(&prefixes, &checked, tx)));
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

    for (address, private_key) in rx {
        println!("{{\"type\":\"found\",\"address\":\"0x{address}\",\"private_key\":\"{private_key}\"}}");
        let _ = std::io::stdout().flush();
    }

    for h in handles {
        let _ = h.join();
    }
}

fn worker_loop(prefixes: &[Vec<u8>], checked: &AtomicU64, tx: mpsc::Sender<(String, String)>) {
    let secp = Secp256k1::new();
    let mut rng = OsRng;

    // Публичный ключ приватного ключа "1" — это сам генератор G. Дальше он
    // используется только для сложения точек, скалярное умножение с ним не
    // выполняется ни разу после этой инициализации.
    let one = SecretKey::from_slice(&Scalar::ONE.to_be_bytes()).expect("scalar one is a valid secret key");
    let g_pub = PublicKey::from_secret_key(&secp, &one);

    // Каждые BATCH шагов уходим на новый случайный старт — чтобы потоки не
    // шли по одной и той же последовательности и чтобы не накапливать смещение
    // от исходного случайного ключа бесконечно.
    const BATCH: u64 = 200_000;
    const REPORT_EVERY: u64 = 4_096;

    loop {
        let mut secret = SecretKey::new(&mut rng);
        let mut pubkey = PublicKey::from_secret_key(&secp, &secret);
        let mut local = 0u64;

        for step in 0..BATCH {
            let addr = eth_address_bytes(&pubkey);

            if prefixes.iter().any(|p| matches_prefix(&addr, p)) {
                let addr_hex = to_hex(&addr);
                let sk_hex = to_hex(&secret.secret_bytes());
                if tx.send((addr_hex, sk_hex)).is_err() {
                    return; // приёмник закрыт — процесс останавливается
                }
            }

            local += 1;
            if local >= REPORT_EVERY {
                checked.fetch_add(local, Ordering::Relaxed);
                local = 0;
            }

            if step + 1 < BATCH {
                match pubkey.combine(&g_pub) {
                    Ok(next) => pubkey = next,
                    Err(_) => break, // точка на бесконечности — практически невозможно, но на всякий случай
                }
                secret = secret
                    .add_tweak(&Scalar::ONE)
                    .expect("adding 1 to a valid secret key stays in range for all practical batch sizes");
            }
        }

        if local > 0 {
            checked.fetch_add(local, Ordering::Relaxed);
        }
    }
}
