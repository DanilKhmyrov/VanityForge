// Перебор EVM-адресов на GPU: secp256k1 + keccak.
//
// У каждого потока своя точка Q (аффинная, в `points`) — центр окна. За один
// запуск поток проверяет 2B+1 точек: Q и Q ± j·G (j = 1..B, таблица j·G — в
// `table`). У Q + j·G и Q − j·G общий знаменатель (x_j − x_Q), поэтому одно
// обратное даёт сразу две точки. Все B (+1) обращений сводятся к одному
// приёмом Монтгомери: прямой проход копит произведения в `scratch`, обратный
// раздаёт каждому его обратное. Последняя запись таблицы — (2B+1)·G: ею Q
// сдвигается к центру следующего окна.
//
// Поле: 8 слов по 32 бита, little-endian (v[0] — младшее).
// cfg: [0] threads, [1] B, [2] capacity, [3] число шаблонов K, дальше K шаблонов
//      по 10 слов: значение (5) и маска (5) — адрес подходит, если совпал с любым.
// out: по 8 uint на совпадение — поток, смещение в окне (0..2B, центр = B), адрес (5 слов), 0.

#include <metal_stdlib>
using namespace metal;

struct Fe { uint v[8]; };

static inline bool fe_gte_p(thread const Fe &a) {
    for (int i = 7; i >= 2; i--) if (a.v[i] != 0xFFFFFFFFu) return false;
    if (a.v[1] != 0xFFFFFFFEu) return a.v[1] > 0xFFFFFFFEu;
    return a.v[0] >= 0xFFFFFC2Fu;
}

// a + (2^256 − p) mod 2^256 — то же, что a − p, когда a ≥ p или был перенос за 2^256.
static inline void fe_fold(thread Fe &a) {
    ulong c = ulong(a.v[0]) + 0x3D1u;
    a.v[0] = uint(c); c >>= 32;
    c += ulong(a.v[1]) + 1u;
    a.v[1] = uint(c); c >>= 32;
    for (int i = 2; i < 8; i++) { c += a.v[i]; a.v[i] = uint(c); c >>= 32; }
}

static inline Fe fe_add(thread const Fe &a, thread const Fe &b) {
    Fe r;
    ulong c = 0;
    for (int i = 0; i < 8; i++) { c += ulong(a.v[i]) + b.v[i]; r.v[i] = uint(c); c >>= 32; }
    if (c != 0 || fe_gte_p(r)) fe_fold(r);
    return r;
}

static inline Fe fe_sub(thread const Fe &a, thread const Fe &b) {
    Fe r;
    long c = 0;
    for (int i = 0; i < 8; i++) {
        c += long(a.v[i]) - long(b.v[i]);
        r.v[i] = uint(c);
        c >>= 32;
    }
    if (c != 0) {
        // Заём: прибавляем p = 2^256 − 0x1000003D1, то есть вычитаем 0x1000003D1 по модулю 2^256.
        long d = long(r.v[0]) - 0x3D1;
        r.v[0] = uint(d); d >>= 32;
        d += long(r.v[1]) - 1;
        r.v[1] = uint(d); d >>= 32;
        for (int i = 2; i < 8; i++) { d += long(r.v[i]); r.v[i] = uint(d); d >>= 32; }
    }
    return r;
}

// t (512 бит) mod p: hi·2^256 ≡ hi·(2^32 + 977).
static inline Fe fe_reduce(thread const uint *t) {
    Fe r;
    ulong c = 0;
    for (int i = 0; i < 8; i++) {
        c += ulong(t[i]) + ulong(t[8 + i]) * 977u;
        if (i > 0) c += t[7 + i];
        r.v[i] = uint(c);
        c >>= 32;
    }
    c += t[15];
    ulong d = ulong(r.v[0]) + c * 977u;
    r.v[0] = uint(d); d >>= 32;
    d += ulong(r.v[1]) + c;
    r.v[1] = uint(d); d >>= 32;
    for (int i = 2; i < 8; i++) { d += r.v[i]; r.v[i] = uint(d); d >>= 32; }
    if (d != 0 || fe_gte_p(r)) fe_fold(r);
    return r;
}

static inline Fe fe_mul(thread const Fe &a, thread const Fe &b) {
    uint t[16];
    for (int i = 0; i < 16; i++) t[i] = 0;
    for (int i = 0; i < 8; i++) {
        ulong c = 0;
        for (int j = 0; j < 8; j++) {
            c += ulong(a.v[i]) * b.v[j] + t[i + j];
            t[i + j] = uint(c);
            c >>= 32;
        }
        t[i + 8] = uint(c);
    }
    return fe_reduce(t);
}

// Квадрат: 28 перекрёстных произведений (удваиваются) + 8 диагональных вместо 64.
static inline Fe fe_sqr(thread const Fe &a) {
    uint t[16];
    for (int i = 0; i < 16; i++) t[i] = 0;
    for (int i = 0; i < 7; i++) {
        ulong c = 0;
        for (int j = i + 1; j < 8; j++) {
            c += ulong(a.v[i]) * a.v[j] + t[i + j];
            t[i + j] = uint(c);
            c >>= 32;
        }
        t[i + 8] = uint(c);
    }
    for (int k = 15; k > 0; k--) t[k] = (t[k] << 1) | (t[k - 1] >> 31);
    t[0] <<= 1;
    ulong c = 0;
    for (int i = 0; i < 8; i++) {
        ulong sq = ulong(a.v[i]) * a.v[i];
        c += ulong(t[2 * i]) + (sq & 0xFFFFFFFFu);
        t[2 * i] = uint(c); c >>= 32;
        c += ulong(t[2 * i + 1]) + (sq >> 32);
        t[2 * i + 1] = uint(c); c >>= 32;
    }
    return fe_reduce(t);
}

static inline Fe fe_sqr_n(Fe a, int n) {
    for (int i = 0; i < n; i++) a = fe_sqr(a);
    return a;
}

// a^(p−2) — цепочка из libsecp256k1 (255 возведений в квадрат + 15 умножений).
static inline Fe fe_inv(thread const Fe &a) {
    Fe x2 = fe_mul(fe_sqr_n(a, 1), a);
    Fe x3 = fe_mul(fe_sqr_n(x2, 1), a);
    Fe x6 = fe_mul(fe_sqr_n(x3, 3), x3);
    Fe x9 = fe_mul(fe_sqr_n(x6, 3), x3);
    Fe x11 = fe_mul(fe_sqr_n(x9, 2), x2);
    Fe x22 = fe_mul(fe_sqr_n(x11, 11), x11);
    Fe x44 = fe_mul(fe_sqr_n(x22, 22), x22);
    Fe x88 = fe_mul(fe_sqr_n(x44, 44), x44);
    Fe x176 = fe_mul(fe_sqr_n(x88, 88), x88);
    Fe x220 = fe_mul(fe_sqr_n(x176, 44), x44);
    Fe x223 = fe_mul(fe_sqr_n(x220, 3), x3);
    Fe t = fe_mul(fe_sqr_n(x223, 23), x22);
    t = fe_mul(fe_sqr_n(t, 5), a);
    t = fe_mul(fe_sqr_n(t, 3), x2);
    return fe_mul(fe_sqr_n(t, 2), a);
}

static inline Fe load_fe(device const uint *p) { Fe r; for (int i = 0; i < 8; i++) r.v[i] = p[i]; return r; }
static inline Fe load_fe(constant uint *p) { Fe r; for (int i = 0; i < 8; i++) r.v[i] = p[i]; return r; }
static inline void store_fe(device uint *p, thread const Fe &a) { for (int i = 0; i < 8; i++) p[i] = a.v[i]; }

// ---- keccak256 от 64 байт (x ++ y, big-endian) ----

constant ulong RC[24] = {
    0x0000000000000001UL, 0x0000000000008082UL, 0x800000000000808aUL, 0x8000000080008000UL,
    0x000000000000808bUL, 0x0000000080000001UL, 0x8000000080008081UL, 0x8000000000008009UL,
    0x000000000000008aUL, 0x0000000000000088UL, 0x0000000080008009UL, 0x000000008000000aUL,
    0x000000008000808bUL, 0x800000000000008bUL, 0x8000000000008089UL, 0x8000000000008003UL,
    0x8000000000008002UL, 0x8000000000000080UL, 0x000000000000800aUL, 0x800000008000000aUL,
    0x8000000080008081UL, 0x8000000000008080UL, 0x0000000080000001UL, 0x8000000080008008UL,
};

#define ROTL(x, n) (((x) << (n)) | ((x) >> (64 - (n))))

static inline void keccakf(thread ulong *s) {
    for (int r = 0; r < 24; r++) {
        ulong c0 = s[0] ^ s[5] ^ s[10] ^ s[15] ^ s[20];
        ulong c1 = s[1] ^ s[6] ^ s[11] ^ s[16] ^ s[21];
        ulong c2 = s[2] ^ s[7] ^ s[12] ^ s[17] ^ s[22];
        ulong c3 = s[3] ^ s[8] ^ s[13] ^ s[18] ^ s[23];
        ulong c4 = s[4] ^ s[9] ^ s[14] ^ s[19] ^ s[24];
        ulong d0 = c4 ^ ROTL(c1, 1);
        ulong d1 = c0 ^ ROTL(c2, 1);
        ulong d2 = c1 ^ ROTL(c3, 1);
        ulong d3 = c2 ^ ROTL(c4, 1);
        ulong d4 = c3 ^ ROTL(c0, 1);
        ulong b0  = s[0] ^ d0;
        ulong b10 = ROTL(s[1]  ^ d1, 1);
        ulong b20 = ROTL(s[2]  ^ d2, 62);
        ulong b5  = ROTL(s[3]  ^ d3, 28);
        ulong b15 = ROTL(s[4]  ^ d4, 27);
        ulong b16 = ROTL(s[5]  ^ d0, 36);
        ulong b1  = ROTL(s[6]  ^ d1, 44);
        ulong b11 = ROTL(s[7]  ^ d2, 6);
        ulong b21 = ROTL(s[8]  ^ d3, 55);
        ulong b6  = ROTL(s[9]  ^ d4, 20);
        ulong b7  = ROTL(s[10] ^ d0, 3);
        ulong b17 = ROTL(s[11] ^ d1, 10);
        ulong b2  = ROTL(s[12] ^ d2, 43);
        ulong b12 = ROTL(s[13] ^ d3, 25);
        ulong b22 = ROTL(s[14] ^ d4, 39);
        ulong b23 = ROTL(s[15] ^ d0, 41);
        ulong b8  = ROTL(s[16] ^ d1, 45);
        ulong b18 = ROTL(s[17] ^ d2, 15);
        ulong b3  = ROTL(s[18] ^ d3, 21);
        ulong b13 = ROTL(s[19] ^ d4, 8);
        ulong b14 = ROTL(s[20] ^ d0, 18);
        ulong b24 = ROTL(s[21] ^ d1, 2);
        ulong b9  = ROTL(s[22] ^ d2, 61);
        ulong b19 = ROTL(s[23] ^ d3, 56);
        ulong b4  = ROTL(s[24] ^ d4, 14);
        s[0]  = b0  ^ (~b1  & b2);  s[1]  = b1  ^ (~b2  & b3);  s[2]  = b2  ^ (~b3  & b4);
        s[3]  = b3  ^ (~b4  & b0);  s[4]  = b4  ^ (~b0  & b1);
        s[5]  = b5  ^ (~b6  & b7);  s[6]  = b6  ^ (~b7  & b8);  s[7]  = b7  ^ (~b8  & b9);
        s[8]  = b8  ^ (~b9  & b5);  s[9]  = b9  ^ (~b5  & b6);
        s[10] = b10 ^ (~b11 & b12); s[11] = b11 ^ (~b12 & b13); s[12] = b12 ^ (~b13 & b14);
        s[13] = b13 ^ (~b14 & b10); s[14] = b14 ^ (~b10 & b11);
        s[15] = b15 ^ (~b16 & b17); s[16] = b16 ^ (~b17 & b18); s[17] = b17 ^ (~b18 & b19);
        s[18] = b18 ^ (~b19 & b15); s[19] = b19 ^ (~b15 & b16);
        s[20] = b20 ^ (~b21 & b22); s[21] = b21 ^ (~b22 & b23); s[22] = b22 ^ (~b23 & b24);
        s[23] = b23 ^ (~b24 & b20); s[24] = b24 ^ (~b20 & b21);
        s[0] ^= RC[r];
    }
}

static inline uint bswap(uint x) {
    return (x >> 24) | ((x >> 8) & 0xff00u) | ((x << 8) & 0xff0000u) | (x << 24);
}

// Адрес (байты 12..31 keccak256(x ++ y)), упакованный в 5 uint little-endian.
static inline void eth_address(thread const Fe &x, thread const Fe &y, thread uint *a) {
    ulong s[25];
    for (int l = 0; l < 4; l++) {
        s[l]     = ulong(bswap(x.v[7 - 2 * l])) | (ulong(bswap(x.v[6 - 2 * l])) << 32);
        s[4 + l] = ulong(bswap(y.v[7 - 2 * l])) | (ulong(bswap(y.v[6 - 2 * l])) << 32);
    }
    s[8] = 1;
    for (int i = 9; i < 25; i++) s[i] = 0;
    s[16] = 0x8000000000000000UL;
    keccakf(s);
    a[0] = uint(s[1] >> 32); a[1] = uint(s[2]); a[2] = uint(s[2] >> 32);
    a[3] = uint(s[3]);       a[4] = uint(s[3] >> 32);
}

// ---- TRON: тот же 20-байтный адрес, base58check(0x41 ++ адрес ++ checksum) ----

constant uint K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static inline uint rotr32(uint x, uint n) { return (x >> n) | (x << (32 - n)); }

// Один блок SHA-256 (сообщение уже дополнено): w — 16 слов big-endian, h — результат.
static inline void sha256_block(thread uint *w, thread uint *h) {
    uint st[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
    uint a = st[0], b = st[1], c = st[2], d = st[3], e = st[4], f = st[5], g = st[6], hh = st[7];
    for (int i = 0; i < 64; i++) {
        uint wi;
        if (i < 16) {
            wi = w[i];
        } else {
            uint w15 = w[(i - 15) & 15], w2 = w[(i - 2) & 15];
            uint s0 = rotr32(w15, 7) ^ rotr32(w15, 18) ^ (w15 >> 3);
            uint s1 = rotr32(w2, 17) ^ rotr32(w2, 19) ^ (w2 >> 10);
            wi = w[i & 15] + s0 + w[(i - 7) & 15] + s1;
            w[i & 15] = wi;
        }
        uint t1 = hh + (rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + wi;
        uint t2 = (rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] = st[0] + a; h[1] = st[1] + b; h[2] = st[2] + c; h[3] = st[3] + d;
    h[4] = st[4] + e; h[5] = st[5] + f; h[6] = st[6] + g; h[7] = st[7] + hh;
}

// v — 0x41 ++ адрес как 6 слов big-endian (v[0] = 0x41). Возвращает первые 4 байта
// sha256(sha256(21 байт)) — контрольную сумму base58check.
static inline uint tron_checksum(thread const uint *v) {
    uint w[16];
    // 21 байт: 0x41, затем 20 байт адреса; сдвигаем на 3 байта влево внутри слов.
    w[0] = (v[0] << 24) | (v[1] >> 8);
    w[1] = (v[1] << 24) | (v[2] >> 8);
    w[2] = (v[2] << 24) | (v[3] >> 8);
    w[3] = (v[3] << 24) | (v[4] >> 8);
    w[4] = (v[4] << 24) | (v[5] >> 8);
    w[5] = (v[5] << 24) | 0x800000u;   // последний байт адреса, затем 0x80
    for (int i = 6; i < 15; i++) w[i] = 0;
    w[15] = 21 * 8;
    uint h1[8];
    sha256_block(w, h1);
    for (int i = 0; i < 8; i++) w[i] = h1[i];
    w[8] = 0x80000000u;
    for (int i = 9; i < 15; i++) w[i] = 0;
    w[15] = 32 * 8;
    uint h2[8];
    sha256_block(w, h2);
    return h2[0];
}

static inline int cmp6(thread const uint *v, constant uint *bound) {
    for (int i = 0; i < 6; i++) {
        if (v[i] != bound[i]) return v[i] < bound[i] ? -1 : 1;
    }
    return 0;
}

static inline void record(uint t, uint offset, thread const uint *a, uint network,
                          constant uint *cfg, device atomic_uint *hits, device uint *out) {
    uint idx = atomic_fetch_add_explicit(hits, 1, memory_order_relaxed);
    if (idx >= cfg[2]) return;
    device uint *slot = out + idx * 8;
    slot[0] = t; slot[1] = offset;
    for (int i = 0; i < 5; i++) slot[2 + i] = a[i];
    slot[7] = network;
}

// cfg после ETH-шаблонов: число TRON-целей и цели по 20 слов:
//   [0] флаги (1 — есть начало, 2 — есть конец), [1] k — длина конца (≤ 10),
//   [2..7] / [8..13] — границы (0x41 ++ адрес) для начала, 6 слов big-endian,
//   [14] конец mod 2^k, [15..16] конец mod 29^k, [17..18] 29^k (lo, hi).
// Начало base58 — это диапазон чисел, проверка без контрольной суммы. Конец —
// остаток числа (адрес ++ checksum) по модулю 58^k = 2^k · 29^k.
static inline void check(thread const Fe &x, thread const Fe &y, uint t, uint offset,
                         constant uint *cfg, device atomic_uint *hits, device uint *out) {
    uint a[5];
    eth_address(x, y, a);
    bool ok = false;
    for (uint k = 0; k < cfg[3] && !ok; k++) {
        constant uint *pat = cfg + 4 + k * 10;
        ok = (a[0] & pat[5]) == pat[0] && (a[1] & pat[6]) == pat[1] && (a[2] & pat[7]) == pat[2]
          && (a[3] & pat[8]) == pat[3] && (a[4] & pat[9]) == pat[4];
    }
    if (ok) record(t, offset, a, 0, cfg, hits, out);

    constant uint *tron = cfg + 4 + cfg[3] * 10;
    uint ntron = tron[0];
    if (ntron == 0) return;
    uint v[6] = { 0x41u, bswap(a[0]), bswap(a[1]), bswap(a[2]), bswap(a[3]), bswap(a[4]) };
    bool have_chk = false;
    uint chk = 0;
    for (uint k = 0; k < ntron; k++) {
        constant uint *tt = tron + 1 + k * 20;
        if ((tt[0] & 1u) && (cmp6(v, tt + 2) < 0 || cmp6(v, tt + 8) > 0)) continue;
        if (tt[0] & 2u) {
            if (!have_chk) { chk = tron_checksum(v); have_chk = true; }
            uint kk = tt[1];
            if ((chk & ((1u << kk) - 1u)) != tt[14]) continue;
            ulong m = ulong(tt[17]) | (ulong(tt[18]) << 32);
            ulong r = 0;
            for (int i = 0; i < 6; i++) {
                uint word = v[i];
                int first = i == 0 ? 3 : 0;   // v[0] — один байт 0x41
                for (int b = first; b < 4; b++) r = (r * 256 + ((word >> (24 - 8 * b)) & 0xffu)) % m;
            }
            for (int b = 0; b < 4; b++) r = (r * 256 + ((chk >> (24 - 8 * b)) & 0xffu)) % m;
            if (r != (ulong(tt[15]) | (ulong(tt[16]) << 32))) continue;
        }
        record(t, offset, a, 1, cfg, hits, out);
        return;
    }
}

kernel void step(device uint *points        [[buffer(0)]],
                 constant uint *table       [[buffer(1)]],
                 device uint *scratch       [[buffer(2)]],
                 constant uint *cfg         [[buffer(3)]],
                 device atomic_uint *hits   [[buffer(4)]],
                 device uint *out           [[buffer(5)]],
                 uint t [[thread_position_in_grid]]) {
    uint threads = cfg[0], batch = cfg[1];
    if (t >= threads) return;
    Fe qx = load_fe(points + t * 16), qy = load_fe(points + t * 16 + 8);

    check(qx, qy, t, batch, cfg, hits, out);

    // Прямой проход по записям 0..B (последняя — сдвиг окна): scratch[j] = Π_{i ≤ j} (x_i − x_Q).
    Fe acc = fe_sub(load_fe(table), qx);
    store_fe(scratch + t * 8, acc);
    for (uint j = 1; j <= batch; j++) {
        acc = fe_mul(acc, fe_sub(load_fe(table + j * 16), qx));
        if (j < batch) store_fe(scratch + (j * threads + t) * 8, acc);
    }
    Fe inv = fe_inv(acc);

    // Сдвиг окна: Q + (2B+1)·G.
    Fe next_x, next_y;
    {
        Fe tx = load_fe(table + batch * 16), ty = load_fe(table + batch * 16 + 8);
        Fe inv_b = fe_mul(inv, load_fe(scratch + ((batch - 1) * threads + t) * 8));
        inv = fe_mul(inv, fe_sub(tx, qx));
        Fe lambda = fe_mul(fe_sub(ty, qy), inv_b);
        next_x = fe_sub(fe_sub(fe_sqr(lambda), qx), tx);
        next_y = fe_sub(fe_mul(lambda, fe_sub(qx, next_x)), qy);
    }

    for (int j = int(batch) - 1; j >= 0; j--) {
        Fe tx = load_fe(table + j * 16), ty = load_fe(table + j * 16 + 8);
        Fe inv_j = inv;
        if (j > 0) {
            inv_j = fe_mul(inv, load_fe(scratch + ((j - 1) * threads + t) * 8));
            inv = fe_mul(inv, fe_sub(tx, qx));
        }
        // Q + (j+1)·G
        Fe lambda = fe_mul(fe_sub(ty, qy), inv_j);
        Fe rx = fe_sub(fe_sub(fe_sqr(lambda), qx), tx);
        Fe ry = fe_sub(fe_mul(lambda, fe_sub(qx, rx)), qy);
        check(rx, ry, t, batch + uint(j) + 1, cfg, hits, out);
        // Q − (j+1)·G: λ = −μ, μ = (y_j + y_Q)/(x_j − x_Q)
        Fe mu = fe_mul(fe_add(ty, qy), inv_j);
        Fe sx = fe_sub(fe_sub(fe_sqr(mu), qx), tx);
        Fe sy = fe_sub(fe_mul(mu, fe_sub(sx, qx)), qy);
        check(sx, sy, t, batch - uint(j) - 1, cfg, hits, out);
    }
    store_fe(points + t * 16, next_x);
    store_fe(points + t * 16 + 8, next_y);
}
