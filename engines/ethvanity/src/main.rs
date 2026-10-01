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
//!
//! `--split-key <публичный ключ заказчика>`: вместо своих ключей перебираются
//! точки P_заказчика + k·G. Находка — не приватный ключ, а добавка k: заказчик
//! сам складывает её со своим секретом, и итоговый ключ не знает никто, кроме него.
//! В JSON поле "private_key" в этом режиме содержит k.

use secp256k1::rand::rngs::OsRng;
use secp256k1::{PublicKey, Scalar, Secp256k1, SecretKey};
use std::env;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;
use k256::{FieldBytes, FieldElement};
use tiny_keccak::{Hasher, Keccak};

mod create2;
mod ton;

type Target = (Vec<u8>, Vec<u8>);

struct Args {
    /// Цели: (начало, конец) полубайтами (0..=15); любая часть может быть пустой.
    prefixes: Vec<Target>,
    threads: usize,
    split_key: Option<PublicKey>,
}

fn hex_nibble(c: char) -> Option<u8> {
    c.to_digit(16).map(|d| d as u8)
}

fn parse_args() -> Args {
    let args: Vec<String> = env::args().collect();
    let mut prefixes = Vec::new();
    let mut threads = thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let mut split_key = None;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--prefix" => {
                if let Some(v) = args.get(i + 1) {
                    let nibbles: Option<Vec<u8>> = v.chars().map(hex_nibble).collect();
                    if let Some(nibbles) = nibbles {
                        if !nibbles.is_empty() {
                            prefixes.push((nibbles, Vec::new()));
                        }
                    }
                    i += 1;
                }
            }
            // "начало:конец" в hex — как у metalvanity-evm, чтобы условия на
            // конец адреса работали и без видеокарты.
            "--target" => {
                if let Some(v) = args.get(i + 1) {
                    let (pre, suf) = v.split_once(':').unwrap_or((v.as_str(), ""));
                    let pre: Option<Vec<u8>> = pre.chars().map(hex_nibble).collect();
                    let suf: Option<Vec<u8>> = suf.chars().map(hex_nibble).collect();
                    if let (Some(pre), Some(suf)) = (pre, suf) {
                        if !(pre.is_empty() && suf.is_empty()) && pre.len() + suf.len() <= 40 {
                            prefixes.push((pre, suf));
                        }
                    }
                    i += 1;
                }
            }
            "--split-key" => {
                if let Some(v) = args.get(i + 1) {
                    let bytes: Option<Vec<u8>> = (0..v.trim_start_matches("0x").len() / 2)
                        .map(|j| u8::from_str_radix(&v.trim_start_matches("0x")[j * 2..j * 2 + 2], 16).ok())
                        .collect();
                    match bytes.and_then(|b| PublicKey::from_slice(&b).ok()) {
                        Some(key) => split_key = Some(key),
                        None => {
                            eprintln!("--split-key must be a secp256k1 public key (33 or 65 bytes hex)");
                            std::process::exit(1);
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

    Args { prefixes, threads, split_key }
}

#[inline]
fn nibble_at(addr: &[u8; 20], index: usize) -> u8 {
    let byte = addr[index / 2];
    if index % 2 == 0 { byte >> 4 } else { byte & 0x0f }
}

#[inline]
fn matches_target(addr: &[u8; 20], (prefix, suffix): &Target) -> bool {
    prefix.iter().enumerate().all(|(i, &want)| nibble_at(addr, i) == want)
        && suffix.iter().enumerate().all(|(i, &want)| nibble_at(addr, 40 - suffix.len() + i) == want)
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
    if env::args().any(|a| a == "--ton-subwallet") {
        ton::run();
        return;
    }
    if env::args().any(|a| a == "--create2" || a == "--create3") {
        create2::run();
        return;
    }

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
        let split_key = args.split_key;
        handles.push(thread::spawn(move || worker_loop(&prefixes, &checked, tx, split_key)));
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

/// Точки j·G для j = 1..B и (2B+1)·G — сдвиг окна, в виде (x, y) поля k256.
fn window_table(batch: usize) -> Vec<(FieldElement, FieldElement)> {
    let secp = Secp256k1::new();
    (1..=batch as u64)
        .chain(std::iter::once(2 * batch as u64 + 1))
        .map(|j| {
            let mut bytes = [0u8; 32];
            bytes[24..].copy_from_slice(&j.to_be_bytes());
            let key = SecretKey::from_slice(&bytes).expect("small scalar is a valid key");
            point_fields(&PublicKey::from_secret_key(&secp, &key))
        })
        .collect()
}

fn point_fields(pk: &PublicKey) -> (FieldElement, FieldElement) {
    let raw = pk.serialize_uncompressed();
    let x = FieldElement::from_bytes(FieldBytes::from_slice(&raw[1..33])).unwrap();
    let y = FieldElement::from_bytes(FieldBytes::from_slice(&raw[33..65])).unwrap();
    (x, y)
}

#[inline]
fn address_of(x: &FieldElement, y: &FieldElement) -> [u8; 20] {
    let mut hasher = Keccak::v256();
    hasher.update(&x.to_bytes());
    hasher.update(&y.to_bytes());
    let mut hash = [0u8; 32];
    hasher.finalize(&mut hash);
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&hash[12..32]);
    addr
}

/// Перебор окнами, как в GPU-ядре: центр Q и точки Q ± j·G (j = 1..B). У Q + j·G
/// и Q − j·G общий знаменатель (x_j − x_Q), а все знаменатели окна обращаются
/// одной инверсией (Монтгомери) — вместо инверсии на каждый адрес, как при
/// PublicKey::combine. Ключ точки — старт + номер окна·(2B+1) + B ± j.
///
/// У k256 ленивая нормализация: перед вычитанием сумма должна быть приведена
/// normalize_weak (отрицание считает аргумент величиной 1).
fn worker_loop(prefixes: &[Target], checked: &AtomicU64, tx: mpsc::Sender<(String, String)>, split_key: Option<PublicKey>) {
    const B: usize = 512;
    const WINDOW: u64 = 2 * B as u64 + 1;
    // Новый случайный старт примерно каждые 200 тыс. ключей.
    const WINDOWS_PER_START: u64 = 200_000 / WINDOW + 1;

    let secp = Secp256k1::new();
    let mut rng = OsRng;
    let table = window_table(B);
    let mut acc = vec![FieldElement::ONE; B + 1];

    let report = |key: &SecretKey, offset: u64, addr: &[u8; 20]| -> bool {
        let found = key.add_tweak(&Scalar::from_be_bytes({
            let mut b = [0u8; 32];
            b[24..].copy_from_slice(&offset.to_be_bytes());
            b
        }).expect("small scalar")).expect("offset keeps the key in range");
        tx.send((to_hex(addr), to_hex(&found.secret_bytes()))).is_ok()
    };

    loop {
        let start = SecretKey::new(&mut rng);
        let mut center_key = [0u8; 32];
        center_key[24..].copy_from_slice(&(B as u64).to_be_bytes());
        let center = start.add_tweak(&Scalar::from_be_bytes(center_key).unwrap()).unwrap();
        let own = PublicKey::from_secret_key(&secp, &center);
        // split-key: точки P_заказчика + k·G, находка — добавка k.
        let point = match split_key {
            Some(base) => match base.combine(&own) {
                Ok(p) => p,
                Err(_) => continue,
            },
            None => own,
        };
        let (mut qx, mut qy) = point_fields(&point);

        for window in 0..WINDOWS_PER_START {
            let base_offset = window * WINDOW;
            let addr = address_of(&qx, &qy);
            if prefixes.iter().any(|t| matches_target(&addr, t)) && !report(&start, base_offset + B as u64, &addr) {
                return;
            }

            // Прямой проход: acc[j] = Π_{i ≤ j} (x_i − x_Q).
            let mut running = FieldElement::ONE;
            for (j, (tx_, _)) in table.iter().enumerate() {
                running = running * (*tx_ - &qx).normalize_weak();
                acc[j] = running;
            }
            let mut inv = acc[B].invert().unwrap();

            // Сдвиг окна: Q + (2B+1)·G.
            let (ax, ay) = &table[B];
            let inv_b = inv * acc[B - 1];
            inv = inv * (*ax - &qx).normalize_weak();
            let lambda = (*ay - &qy).normalize_weak() * inv_b;
            let nx = (lambda.square() - &qx - ax).normalize_weak();
            let ny = (lambda * (qx - &nx).normalize_weak() - &qy).normalize_weak();

            for j in (0..B).rev() {
                let (tx_, ty_) = &table[j];
                let inv_j = if j > 0 {
                    let v = inv * acc[j - 1];
                    inv = inv * (*tx_ - &qx).normalize_weak();
                    v
                } else {
                    inv
                };
                // Q + (j+1)·G
                let lambda = (*ty_ - &qy).normalize_weak() * inv_j;
                let rx = (lambda.square() - &qx - tx_).normalize_weak();
                let ry = (lambda * (qx - &rx).normalize_weak() - &qy).normalize_weak();
                let addr = address_of(&rx, &ry);
                if prefixes.iter().any(|t| matches_target(&addr, t))
                    && !report(&start, base_offset + B as u64 + j as u64 + 1, &addr)
                {
                    return;
                }
                // Q − (j+1)·G: λ = −μ, μ = (y_j + y_Q)/(x_j − x_Q)
                let mu = (*ty_ + &qy).normalize_weak() * inv_j;
                let sx = (mu.square() - &qx - tx_).normalize_weak();
                let sy = (mu * (sx - &qx).normalize_weak() - &qy).normalize_weak();
                let addr = address_of(&sx, &sy);
                if prefixes.iter().any(|t| matches_target(&addr, t))
                    && !report(&start, base_offset + B as u64 - j as u64 - 1, &addr)
                {
                    return;
                }
            }
            qx = nx;
            qy = ny;
            checked.fetch_add(WINDOW, Ordering::Relaxed);
        }
    }
}
