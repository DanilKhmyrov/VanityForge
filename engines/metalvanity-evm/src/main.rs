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
//!                   [--avatar <описание blockies>] [--bycatch-run R] [--bycatch-word hex ...]
//!                   [--btc-target 1Abc:xyz | *abc | ?abc ...] [--bech32-target abc: | :xyz | *abc ...]
//!
//! Bitcoin — сжатый ключ: 1… (P2PKH, цели как у TRON, найденный адрес — сеть btc1)
//! и bc1q… (P2WPKH, символы после «bc1q», сеть btc). Ключ в выводе — hex.
//!                   [--threads N] [--batch B] [--reseed-secs S]
//!                   [--gpu-load 1..100] [--max-speed адресов/с]
//!
//! --gpu-load и --max-speed ограничивают нагрузку паузами между запусками: GPU
//! считает пачку (~0,1 с), потом ждёт столько, чтобы доля работы не превышала
//! gpu-load %, а средняя скорость — max-speed.
//!
//! Цель — «начало:конец» в hex (любая часть может быть пустой) или «*подстрока»
//! (где угодно в адресе); адрес подходит, если совпал хотя бы с одной целью.
//! Итоговую проверку условия делает bridge.py.
//!
//! --tron-target — то же для TRON, в base58 («начало» включает ведущую T, конец —
//! до 10 символов, «*подстрока» — где угодно, «?подстрока» — где угодно без учёта регистра). У TRON и EVM из одного ключа одинаковые 20 байт адреса, так что
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

#[derive(Clone)]
struct TronTarget {
    prefix: String,
    suffix: String,
    /// Длина адреса, под которую строится диапазон начала: у TRON всегда 34,
    /// у Bitcoin 1… — 34 или (реже) 33, поэтому там цель уходит на GPU дважды.
    len: usize,
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
        TronTarget { prefix: prefix.to_string(), suffix: suffix.to_string(), len: TRON_LEN }
    }

    fn matches(&self, address: &str) -> bool {
        address.starts_with(&self.prefix) && address.ends_with(&self.suffix)
    }

    /// 20 слов для ядра (раскладка — в комментарии к check() в kernel.metal).
    fn words(&self) -> [u32; 20] {
        let mut w = [0u32; 20];
        if !self.prefix.is_empty() {
            w[0] |= 1;
            let fill = self.len.saturating_sub(self.prefix.len());
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

/// Классы символов base58 без учёта регистра — как B58_FOLD в ядре.
const B58_FOLD_CLASSES: &str = "123456789abcdefghijklmnopqrstuvwxyz";

/// Цели «*подстрока»: ETH — полубайты, TRON — цифры base58 (или, без учёта
/// регистра — «?подстрока», — классы B58_FOLD_CLASSES; флаг в старшем бите длины).
struct Contains {
    eth: Vec<Vec<u8>>,
    tron: Vec<Vec<u8>>,
    tron_folded: Vec<Vec<u8>>,
}

impl Contains {
    fn none() -> Contains {
        Contains { eth: Vec::new(), tron: Vec::new(), tron_folded: Vec::new() }
    }

    fn parse_eth(raw: &str) -> Vec<u8> {
        let nibbles: Option<Vec<u8>> = raw.chars().map(|c| c.to_digit(16).map(|d| d as u8)).collect();
        match nibbles {
            Some(n) if !n.is_empty() && n.len() <= 40 => n,
            _ => fail("contains target must be 1..40 hex characters"),
        }
    }

    fn parse_tron(raw: &str) -> Vec<u8> {
        let digits: Option<Vec<u8>> = raw.chars().map(|c| b58_digit(c).map(|d| d as u8)).collect();
        match digits {
            Some(d) if !d.is_empty() && d.len() <= TRON_LEN => d,
            _ => fail("tron contains target must be 1..34 base58 characters"),
        }
    }

    fn parse_tron_folded(raw: &str) -> Vec<u8> {
        let classes: Option<Vec<u8>> = raw
            .chars()
            .map(|c| c.to_lowercase().next().and_then(|l| B58_FOLD_CLASSES.find(l)).map(|i| i as u8))
            .collect();
        match classes {
            Some(d) if !d.is_empty() && d.len() <= TRON_LEN => d,
            _ => fail("tron contains target must be 1..34 base58 characters"),
        }
    }

    /// Секции конфигурации ядра: длина и по символу на байт.
    fn words(items: &[(Vec<u8>, bool)], stride: usize) -> Vec<u32> {
        let mut out = vec![items.len() as u32];
        for (item, folded) in items {
            let mut w = vec![0u32; stride];
            w[0] = item.len() as u32 | if *folded { 1 << 16 } else { 0 };
            for (j, &v) in item.iter().enumerate() {
                w[1 + j / 4] |= (v as u32) << (8 * (j % 4));
            }
            out.extend(w);
        }
        out
    }

    fn eth_matches(&self, address: &[u8; 20]) -> bool {
        let hex = to_hex(address);
        self.eth.iter().any(|n| {
            let needle: String = n.iter().map(|&d| char::from_digit(d as u32, 16).unwrap()).collect();
            hex.contains(&needle)
        })
    }

    fn tron_matches(&self, address: &str) -> bool {
        let lower = address.to_lowercase();
        self.tron.iter().any(|d| {
            let needle: String = d.iter().map(|&x| B58[x as usize] as char).collect();
            address.contains(&needle)
        }) || self.tron_folded.iter().any(|d| {
            let needle: String = d.iter().map(|&x| B58_FOLD_CLASSES.as_bytes()[x as usize] as char).collect();
            lower.contains(&needle)
        })
    }

    fn tron_section(&self) -> Vec<(Vec<u8>, bool)> {
        self.tron.iter().map(|d| (d.clone(), false)).chain(self.tron_folded.iter().map(|d| (d.clone(), true))).collect()
    }
}

/// Побочный улов: адреса, которые не подходят под цель, но сами по себе
/// красивые — серия из `run` одинаковых символов на краю или слово из словаря
/// в начале либо в конце. Ядро сравнивает только 8 крайних полубайтов слова,
/// слово целиком сверяет `matches`.
struct Bycatch {
    run: u32,
    words: Vec<Vec<u8>>,
}

const MAX_RUN: u32 = 24;
const MIN_BYCATCH_WORD: usize = 8;

impl Bycatch {
    fn none() -> Bycatch {
        Bycatch { run: 0, words: Vec::new() }
    }

    fn parse_word(raw: &str) -> Vec<u8> {
        let nibbles: Option<Vec<u8>> = raw.chars().map(|c| c.to_digit(16).map(|d| d as u8)).collect();
        match nibbles {
            Some(n) if n.len() >= MIN_BYCATCH_WORD && n.len() <= 40 => n,
            _ => fail("bycatch word must be 8..40 hex characters"),
        }
    }

    fn key(nibbles: &[u8]) -> u32 {
        nibbles.iter().fold(0u32, |acc, &d| (acc << 4) | d as u32)
    }

    /// Секция ядра: R, ключи начала по возрастанию, ключи конца по возрастанию.
    fn words(&self) -> Vec<u32> {
        let sorted = |keys: Vec<u32>| {
            let mut keys = keys;
            keys.sort_unstable();
            keys.dedup();
            keys
        };
        let pre = sorted(self.words.iter().map(|w| Bycatch::key(&w[..8])).collect());
        let suf = sorted(self.words.iter().map(|w| Bycatch::key(&w[w.len() - 8..])).collect());
        let mut out = vec![self.run, pre.len() as u32];
        out.extend(&pre);
        out.push(suf.len() as u32);
        out.extend(&suf);
        out
    }

    fn matches(&self, address: &[u8; 20]) -> bool {
        let hex: Vec<u8> = to_hex(address).bytes().collect();
        let run_start = hex.iter().take_while(|&&c| c == hex[0]).count() as u32;
        let run_end = hex.iter().rev().take_while(|&&c| c == hex[39]).count() as u32;
        if self.run > 0 && (run_start >= self.run || run_end >= self.run) {
            return true;
        }
        let digits: Vec<u8> = hex.iter().map(|&c| (c as char).to_digit(16).unwrap() as u8).collect();
        self.words.iter().any(|w| digits.starts_with(w) || digits.ends_with(w))
    }
}

/// Аватарка blockies (Etherscan, MetaMask) — раскладка и формулы как в ядре
/// (avatar_hit). Описание: `cells=<32 символа>;miss=N;color=h1-h2/l1-l2;bg=…;spot=…`,
/// клетки — левая половина 8×8 построчно по 4: «.» любая, b фон, c цвет, s пятна.
struct Avatar {
    misses: u32,
    cells: [u8; 32],
    colors: [[u32; 4]; 3],
}

const ANY_COLOR: [u32; 4] = [0, 359, 0, 200];

impl Avatar {
    fn parse(spec: &str) -> Avatar {
        let mut avatar = Avatar { misses: 0, cells: [3; 32], colors: [ANY_COLOR; 3] };
        for part in spec.split(';').map(str::trim).filter(|p| !p.is_empty()) {
            let (name, value) = part.split_once('=').unwrap_or_else(|| fail("avatar spec: expected name=value"));
            match name {
                "cells" => {
                    if value.chars().count() != 32 {
                        fail("avatar spec: cells must be 32 characters");
                    }
                    for (i, c) in value.chars().enumerate() {
                        avatar.cells[i] = match c {
                            'b' => 0,
                            'c' => 1,
                            's' => 2,
                            '.' => 3,
                            _ => fail("avatar spec: cells use . b c s"),
                        };
                    }
                }
                "miss" => avatar.misses = value.parse().unwrap_or_else(|_| fail("avatar spec: bad miss")),
                "color" | "bg" | "spot" => {
                    let slot = ["color", "bg", "spot"].iter().position(|n| *n == name).unwrap();
                    let numbers: Vec<u32> = value
                        .split(['-', '/'])
                        .map(|v| v.parse().unwrap_or_else(|_| fail("avatar spec: bad color range")))
                        .collect();
                    if numbers.len() != 4 || numbers[0] > 359 || numbers[1] > 359 || numbers[2] > numbers[3] {
                        fail("avatar spec: color is hue-hue/light-light");
                    }
                    avatar.colors[slot] = [numbers[0], numbers[1], numbers[2], numbers[3]];
                }
                _ => fail("avatar spec: unknown part"),
            }
        }
        avatar
    }

    /// Секция ядра; без аватарки — 16 нулей (ядро смотрит только на флаг).
    fn words(avatar: Option<&Avatar>) -> Vec<u32> {
        let mut out = vec![0u32; 16];
        if let Some(a) = avatar {
            out[0] = 1;
            out[1] = a.misses;
            for (i, &c) in a.cells.iter().enumerate() {
                out[2 + i / 16] |= (c as u32) << (2 * (i % 16));
            }
            for (slot, color) in a.colors.iter().enumerate() {
                out[4 + slot * 4..8 + slot * 4].copy_from_slice(color);
            }
        }
        out
    }

    fn matches(&self, address: &[u8; 20]) -> bool {
        let mut s = [0u32; 4];
        for (i, c) in format!("0x{}", to_hex(address)).bytes().enumerate() {
            s[i % 4] = s[i % 4].wrapping_mul(31).wrapping_add(c as u32);
        }
        let mut next = || {
            let t = s[0] ^ (s[0] << 11);
            s[0] = s[1];
            s[1] = s[2];
            s[2] = s[3];
            s[3] = ((s[3] as i32) ^ ((s[3] as i32) >> 19) ^ (t as i32) ^ ((t as i32) >> 8)) as u32;
            s[3] as u64
        };
        for spec in &self.colors {
            let hue = ((next() * 360) >> 31) as u32 % 360;
            next();
            let l25 = (next() + next() + next() + next()) * 25;
            let hue_ok = if spec[0] <= spec[1] { hue >= spec[0] && hue <= spec[1] } else { hue >= spec[0] || hue <= spec[1] };
            if !hue_ok || l25 < (spec[2] as u64) << 31 || l25 > (spec[3] as u64) << 31 {
                return false;
            }
        }
        let mut miss = 0;
        for &want in &self.cells {
            let v = (next() * 23) / (10u64 << 31);
            let cell = v.min(2) as u8;
            if want != 3 && want != cell {
                miss += 1;
                if miss > self.misses {
                    return false;
                }
            }
        }
        true
    }
}

// ---- Bitcoin: hash160 сжатого ключа; 1… — Base58Check (версия 0x00), bc1q… — bech32 ----

fn hash160(pk: &PublicKey) -> [u8; 20] {
    use ripemd::{Digest as _, Ripemd160};
    let sha = Sha256::digest(pk.serialize());
    let mut out = [0u8; 20];
    out.copy_from_slice(&Ripemd160::digest(sha));
    out
}

fn btc_legacy_address(h160: &[u8; 20]) -> String {
    let mut payload = vec![0x00u8];
    payload.extend_from_slice(h160);
    let checksum = Sha256::digest(Sha256::digest(&payload));
    payload.extend_from_slice(&checksum[..4]);
    b58_encode(&payload)
}

const BECH32: &[u8; 32] = b"qpzry9x8gf2tvdw0s3jn54khce6mua7l";

fn bech32_polymod(values: &[u8]) -> u32 {
    const GEN: [u32; 5] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    let mut chk = 1u32;
    for &v in values {
        let top = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ v as u32;
        for (i, g) in GEN.iter().enumerate() {
            if (top >> i) & 1 == 1 {
                chk ^= g;
            }
        }
    }
    chk
}

/// P2WPKH: bc1q + 32 символа hash160 по 5 бит + 6 символов контрольной суммы (BIP-173).
fn btc_bech32_address(h160: &[u8; 20]) -> String {
    let mut data = vec![0u8];
    let (mut acc, mut bits) = (0u32, 0u32);
    for &b in h160 {
        acc = (acc << 8) | b as u32;
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            data.push(((acc >> bits) & 31) as u8);
        }
    }
    let mut values = vec![3u8, 3, 0, 2, 3];
    values.extend(&data);
    values.extend([0u8; 6]);
    let pm = bech32_polymod(&values) ^ 1;
    data.extend((0..6).map(|i| ((pm >> (5 * (5 - i))) & 31) as u8));
    format!("bc1{}", data.iter().map(|&d| BECH32[d as usize] as char).collect::<String>())
}

/// Цель для bc1q…: символы после «bc1q» — в начале, в конце или где угодно.
struct Bech32Target {
    mode: u32, // 0 — начало, 1 — конец, 2 — где угодно
    symbols: Vec<u8>,
}

const BECH32_BODY: usize = 38;

impl Bech32Target {
    fn parse(raw: &str) -> Bech32Target {
        let raw = raw.to_lowercase();
        let (mode, text) = if let Some(rest) = raw.strip_prefix('*') {
            (2, rest.to_string())
        } else {
            match raw.split_once(':') {
                Some((pre, "")) => (0, pre.to_string()),
                Some(("", suf)) => (1, suf.to_string()),
                None => (0, raw.clone()),
                _ => fail("bech32 target: prefix: or :suffix or *substring, not both"),
            }
        };
        let symbols: Option<Vec<u8>> =
            text.chars().map(|c| BECH32.iter().position(|&b| b as char == c).map(|p| p as u8)).collect();
        match symbols {
            Some(s) if !s.is_empty() && s.len() <= if mode == 0 { 32 } else { BECH32_BODY } => Bech32Target { mode, symbols: s },
            _ => fail("bech32 target: characters of qpzry9x8gf2tvdw0s3jn54khce6mua7l, prefix ≤ 32, others ≤ 38"),
        }
    }

    fn words(&self) -> [u32; 11] {
        let mut w = [0u32; 11];
        w[0] = self.mode | (self.symbols.len() as u32) << 8;
        for (j, &s) in self.symbols.iter().enumerate() {
            w[1 + j / 4] |= (s as u32) << (8 * (j % 4));
        }
        w
    }

    fn matches(&self, address: &str) -> bool {
        let body = &address[4..];
        let needle: String = self.symbols.iter().map(|&s| BECH32[s as usize] as char).collect();
        match self.mode {
            0 => body.starts_with(&needle),
            1 => body.ends_with(&needle),
            _ => body.contains(&needle),
        }
    }
}

/// Цели Bitcoin: 1… — те же цели и «содержит», что у TRON (Base58Check, только
/// версия 0x00 и hash160 вместо адреса EVM), bc1q… — Bech32Target.
struct Btc {
    legacy: Vec<TronTarget>,
    legacy_contains: Contains,
    bech32: Vec<Bech32Target>,
}

impl Btc {
    fn none() -> Btc {
        Btc { legacy: Vec::new(), legacy_contains: Contains::none(), bech32: Vec::new() }
    }

    fn active(&self) -> bool {
        !self.legacy.is_empty() || !self.legacy_contains.tron_section().is_empty() || !self.bech32.is_empty()
    }

    fn words(&self) -> Vec<u32> {
        let short: Vec<TronTarget> = self
            .legacy
            .iter()
            .filter(|t| !t.prefix.is_empty() && t.prefix.len() <= TRON_LEN - 1)
            .map(|t| TronTarget { len: TRON_LEN - 1, ..t.clone() })
            .collect();
        let mut out = vec![(self.legacy.len() + short.len()) as u32];
        for target in self.legacy.iter().chain(&short) {
            out.extend(target.words());
        }
        out.extend(Contains::words(&self.legacy_contains.tron_section(), 10));
        out.push(self.bech32.len() as u32);
        for target in &self.bech32 {
            out.extend(target.words());
        }
        out
    }

    fn legacy_matches(&self, address: &str) -> bool {
        self.legacy.iter().any(|t| t.matches(address)) || self.legacy_contains.tron_matches(address)
    }

    fn bech32_matches(&self, address: &str) -> bool {
        self.bech32.iter().any(|t| t.matches(address))
    }
}

/// Цели сверх шаблонов адреса: улов, аватарка и Bitcoin.
struct Extra {
    bycatch: Bycatch,
    avatar: Option<Avatar>,
    btc: Btc,
}

impl Extra {
    fn none() -> Extra {
        Extra { bycatch: Bycatch::none(), avatar: None, btc: Btc::none() }
    }
}

struct Hit {
    thread: u32,
    run: u64,
    j: u32, // смещение в окне 0..2B
    address: [u8; 20],
    network: u32, // 0 — EVM, 1 — TRON, 2 — побочный улов, 3 — аватарка, 4 — Bitcoin 1…, 5 — bc1q… (адрес — hash160)
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
    fn new(threads: u32, batch: u32, capacity: u32, start: &[PublicKey], patterns: &[Pattern], tron: &[TronTarget],
           contains: &Contains, extra: &Extra) -> Gpu {
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
        let eth_section: Vec<(Vec<u8>, bool)> = contains.eth.iter().map(|n| (n.clone(), false)).collect();
        cfg.extend(Contains::words(&eth_section, 11));
        cfg.extend(Contains::words(&contains.tron_section(), 10));
        cfg.extend(extra.bycatch.words());
        cfg.extend(Avatar::words(extra.avatar.as_ref()));
        cfg.extend(extra.btc.words());

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
    contains: &Contains,
    extra: &Extra,
) -> Option<(SecretKey, String)> {
    let key = keys.key(hit);
    let public = keys.public(secp, &key);
    if hit.network == 4 || hit.network == 5 {
        let h160 = hash160(&public);
        if h160 != hit.address {
            fail(&format!("GPU hash160 mismatch: thread {} run {} j {}", hit.thread, hit.run, hit.j));
        }
        if hit.network == 4 {
            // Начало 1… на GPU — диапазон чуть шире точного условия: «почти» отсеиваем тихо.
            let text = btc_legacy_address(&h160);
            return extra.btc.legacy_matches(&text).then_some((key, text));
        }
        let text = btc_bech32_address(&h160);
        if !extra.btc.bech32_matches(&text) {
            fail(&format!("GPU bech32 mismatch: thread {} run {} j {}", hit.thread, hit.run, hit.j));
        }
        return Some((key, text));
    }
    let address = eth_address(&public);
    if address != hit.address {
        fail(&format!("GPU result mismatch: thread {} run {} j {}", hit.thread, hit.run, hit.j));
    }
    let evm = || (key, format!("0x{}", to_hex(&address)));
    if hit.network == 2 {
        // Ядро сравнило только крайние 8 полубайтов слова — остальное отсеиваем тут.
        return extra.bycatch.matches(&address).then(evm);
    }
    if hit.network == 3 {
        if !extra.avatar.as_ref().is_some_and(|a| a.matches(&address)) {
            fail(&format!("GPU avatar mismatch: thread {} run {} j {}", hit.thread, hit.run, hit.j));
        }
        return Some(evm());
    }
    if hit.network == 1 {
        let text = tron_address(&address);
        let hit = tron.iter().any(|t| t.matches(&text)) || contains.tron_matches(&text);
        return hit.then_some((key, text));
    }
    if !patterns.iter().any(|(value, mask)| (0..20).all(|i| address[i] & mask[i] == value[i]))
        && !contains.eth_matches(&address)
    {
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
        let gpu = Gpu::new(threads, batch, capacity, &keys.points(), &everything, &[], &Contains::none(), &Extra::none());
        for run in 0..3u64 {
            let command = gpu.submit(0);
            let hits = gpu.collect(0, &command, run);
            if hits.len() != (threads * window) as usize {
                fail(&format!("{name} run {run}: expected {} hits, got {}", threads * window, hits.len()));
            }
            for hit in &hits {
                verify(&secp, &keys, hit, &everything, &[], &Contains::none(), &Extra::none());
            }
            println!("{{\"type\":\"self_test\",\"case\":\"{name}\",\"run\":{run},\"checked\":{},\"ok\":true}}", hits.len());
        }
    }

    // TRON и «содержит»: GPU должен найти ровно то, что находит CPU перебором
    // всех кандидатов.
    let tron = [TronTarget::parse("TX:"), TronTarget::parse(":a"), TronTarget::parse("TR:z")];
    let avatar = |spec: &str| Extra { avatar: Some(Avatar::parse(spec)), ..Extra::none() };
    let btc = |btc: Btc| Extra { btc, ..Extra::none() };
    let cases: [(&str, &[TronTarget], Contains, Extra); 11] = [
        ("tron", &tron, Contains::none(), Extra::none()),
        ("tron contains", &[], Contains { tron: vec![Contains::parse_tron("abc"), Contains::parse_tron("Zz")], ..Contains::none() }, Extra::none()),
        ("tron contains, any case", &[], Contains { tron_folded: vec![Contains::parse_tron_folded("aBc"), Contains::parse_tron_folded("tr")], ..Contains::none() }, Extra::none()),
        ("evm contains", &[], Contains { eth: vec![Contains::parse_eth("abc"), Contains::parse_eth("0f0")], ..Contains::none() }, Extra::none()),
        ("bycatch runs", &[], Contains::none(), Extra { bycatch: Bycatch { run: 3, words: Vec::new() }, ..Extra::none() }),
        // Слова подставляются ниже — из адресов настоящих кандидатов этого прогона.
        ("bycatch words", &[], Contains::none(), Extra::none()),
        ("avatar cells", &[], Contains::none(), avatar("cells=cs.b............................;miss=1")),
        ("avatar colors", &[], Contains::none(), avatar("color=300-60/0-200;bg=0-359/0-60;cells=..s.............................")),
        ("btc legacy", &[], Contains::none(), btc(Btc {
            legacy: vec![TronTarget::parse("1A:"), TronTarget::parse(":z"), TronTarget::parse("1Bc:x")], ..Btc::none() })),
        ("btc legacy contains", &[], Contains::none(), btc(Btc {
            legacy_contains: Contains { tron: vec![Contains::parse_tron("abc")], tron_folded: vec![Contains::parse_tron_folded("Xy")], ..Contains::none() },
            ..Btc::none() })),
        ("btc bech32", &[], Contains::none(), btc(Btc {
            bech32: vec![Bech32Target::parse("qq:"), Bech32Target::parse(":7l"), Bech32Target::parse("*xyz")], ..Btc::none() })),
    ];
    for (name, tron, contains, extra) in cases.iter() {
        let keys = Keys::random(threads, batch, None);
        let mut words_extra = Extra::none();
        let extra = if *name == "bycatch words" {
            // Начало одного кандидата и конец другого: GPU должен найти их
            // (и всё, что случайно совпало по 8 полубайтам, отсеет хост).
            let address = |t: u32, j: u32| {
                let hit = Hit { thread: t, run: 1, j, address: [0; 20], network: 2 };
                to_hex(&eth_address(&keys.public(&secp, &keys.key(&hit))))
            };
            let (a, b) = (address(7, 3), address(300, 100));
            words_extra.bycatch = Bycatch { run: 0, words: vec![Bycatch::parse_word(&a[..9]), Bycatch::parse_word(&b[30..])] };
            &words_extra
        } else {
            extra
        };
        let gpu = Gpu::new(threads, batch, capacity, &keys.points(), &[], tron, contains, extra);
        for run in 0..2u64 {
            let command = gpu.submit(0);
            let mut found: Vec<String> = gpu
                .collect(0, &command, run)
                .iter()
                .filter_map(|hit| verify(&secp, &keys, hit, &[], tron, contains, extra).map(|(_, a)| a))
                .collect();
            let mut expected: Vec<String> = Vec::new();
            for t in 0..threads {
                for j in 0..window {
                    let hit = Hit { thread: t, run, j, address: [0; 20], network: 1 };
                    let raw = eth_address(&keys.public(&secp, &keys.key(&hit)));
                    let text = tron_address(&raw);
                    if tron.iter().any(|target| target.matches(&text)) || contains.tron_matches(&text) {
                        expected.push(text);
                    }
                    if contains.eth_matches(&raw) || extra.bycatch.matches(&raw) {
                        expected.push(format!("0x{}", to_hex(&raw)));
                    }
                    if extra.avatar.as_ref().is_some_and(|a| a.matches(&raw)) {
                        expected.push(format!("0x{}", to_hex(&raw)));
                    }
                    if extra.btc.active() {
                        let h160 = hash160(&keys.public(&secp, &keys.key(&hit)));
                        let legacy = btc_legacy_address(&h160);
                        if extra.btc.legacy_matches(&legacy) {
                            expected.push(legacy);
                        }
                        let segwit = btc_bech32_address(&h160);
                        if extra.btc.bech32_matches(&segwit) {
                            expected.push(segwit);
                        }
                    }
                }
            }
            found.sort();
            expected.sort();
            if found != expected {
                fail(&format!("{name} run {run}: GPU found {}, CPU expected {}", found.len(), expected.len()));
            }
            println!("{{\"type\":\"self_test\",\"case\":\"{name}\",\"run\":{run},\"matched\":{},\"ok\":true}}", found.len());
        }
    }
    std::process::exit(0);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.iter().any(|a| a == "--self-test") {
        self_test();
    }
    let value_of = |flag: &str| args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned();
    let mut contains = Contains::none();
    for w in args.windows(2) {
        if w[0] == "--target" {
            if let Some(needle) = w[1].strip_prefix('*') {
                contains.eth.push(Contains::parse_eth(&needle.to_lowercase()));
            }
        } else if w[0] == "--tron-target" {
            if let Some(needle) = w[1].strip_prefix('*') {
                contains.tron.push(Contains::parse_tron(needle));
            } else if let Some(needle) = w[1].strip_prefix('?') {
                contains.tron_folded.push(Contains::parse_tron_folded(needle));
            }
        }
    }
    let mut patterns: Vec<Pattern> = args
        .windows(2)
        .filter(|w| w[0] == "--target" && !w[1].starts_with('*'))
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
        .filter(|w| w[0] == "--tron-target" && !w[1].starts_with('*') && !w[1].starts_with('?'))
        .map(|w| TronTarget::parse(&w[1]))
        .collect();
    let split_base = value_of("--split-key").map(|raw| {
        let hex = raw.trim().trim_start_matches("0x");
        let bytes: Option<Vec<u8>> = (0..hex.len() / 2).map(|i| u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).ok()).collect();
        bytes
            .and_then(|b| PublicKey::from_slice(&b).ok())
            .unwrap_or_else(|| fail("--split-key must be a secp256k1 public key (33 or 65 bytes hex)"))
    });
    let bycatch_words: Vec<Vec<u8>> = args
        .windows(2)
        .filter(|w| w[0] == "--bycatch-word")
        .map(|w| Bycatch::parse_word(&w[1].to_lowercase()))
        .collect();
    let mut btc = Btc::none();
    for w in args.windows(2) {
        if w[0] == "--btc-target" {
            if let Some(needle) = w[1].strip_prefix('*') {
                btc.legacy_contains.tron.push(Contains::parse_tron(needle));
            } else if let Some(needle) = w[1].strip_prefix('?') {
                btc.legacy_contains.tron_folded.push(Contains::parse_tron_folded(needle));
            } else {
                btc.legacy.push(TronTarget::parse(&w[1]));
            }
        } else if w[0] == "--bech32-target" {
            btc.bech32.push(Bech32Target::parse(&w[1]));
        }
    }
    let extra = Extra {
        bycatch: Bycatch {
            run: value_of("--bycatch-run").and_then(|v| v.parse().ok()).unwrap_or(0u32).min(MAX_RUN),
            words: bycatch_words,
        },
        avatar: value_of("--avatar").map(|spec| Avatar::parse(&spec)),
        btc,
    };
    if extra.bycatch.words.len() > 4 * MAX_PATTERNS {
        fail("too many bycatch words");
    }
    if extra.btc.legacy.len() > MAX_PATTERNS || extra.btc.bech32.len() > MAX_PATTERNS
        || extra.btc.legacy_contains.tron_section().len() > MAX_PATTERNS
    {
        fail("too many bitcoin targets");
    }
    if patterns.is_empty() && tron.is_empty() && contains.eth.is_empty() && contains.tron_section().is_empty()
        && extra.avatar.is_none() && !extra.btc.active()
    {
        eprintln!("usage: metalvanity-evm --target <prefix>:<suffix> [--tron-target <prefix>:<suffix>] [...]");
        std::process::exit(1);
    }
    if patterns.len() > MAX_PATTERNS || tron.len() > MAX_PATTERNS
        || contains.eth.len() > MAX_PATTERNS || contains.tron_section().len() > MAX_PATTERNS
    {
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
    let gpu = Gpu::new(threads, batch, 1024, &keys.points(), &patterns, &tron, &contains, &extra);
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
            if let Some((key, address)) = verify(&secp, keys, &hit, &patterns, &tron, &contains, &extra) {
                let network = match hit.network {
                    1 => "trx",
                    4 => "btc1",
                    5 => "btc",
                    _ => "eth",
                };
                let kind = match hit.network {
                    2 => ",\"bycatch\":true",
                    3 => ",\"avatar\":true",
                    _ => "",
                };
                println!(
                    "{{\"type\":\"found\",\"network\":\"{network}\",\"address\":\"{address}\",\"private_key\":\"{}\"{kind}}}",
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
