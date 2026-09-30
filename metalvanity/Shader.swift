// Ядро перебора salt на GPU. Компилируется в рантайме (device.makeLibrary(source:)),
// поэтому для сборки не нужен Metal Toolchain — только Xcode Command Line Tools.
//
// Каждый поток берёт свой счётчик (base + gid), вписывает его в заранее собранный
// блок keccak (хост кладёт в `lanes` уже дополненные padding'ом 17 слов), считает
// адрес и проверяет условие. Всё, что набрало больше `threshold` очков, уходит
// в `out` через атомарный счётчик; хост пересчитывает каждую находку на CPU.
//
// cfg: [0] threshold (int), [1] goal (0 leading, 1 zeros, 2 prefix, 3 hook),
//      [2] mode (0 create2, 1 create3 с охраной caller, 2 create3 без неё),
//      [3] capacity, [4] hook flags, [5..9] prefix, [10..14] prefix mask
//      (адрес упакован в 5 uint little-endian: байт 0 адреса — младший байт слова 0).
// out: по 8 uint на находку — counter lo, counter hi, адрес (5 слов), очки.

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

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

        // theta + rho + pi: b[y + 5*((2x+3y)%5)] = rotl(s[x+5y] ^ d[x], rho[x+5y])
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

        // chi + iota
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

static inline void load_block(thread ulong *s, constant ulong *lanes) {
    for (int i = 0; i < 17; i++) s[i] = lanes[i];
    for (int i = 17; i < 25; i++) s[i] = 0;
}

static inline void xor_byte(thread ulong *s, int pos, ulong value) {
    s[pos >> 3] ^= value << ((pos & 7) * 8);
}

static inline ulong get_byte(thread const ulong *s, int pos) {
    return (s[pos >> 3] >> ((pos & 7) * 8)) & 0xff;
}

// Счётчик — последние 8 байт salt, big-endian, начиная с байта `at` блока.
template <int at>
static inline void put_counter(thread ulong *s, ulong counter) {
    for (int i = 0; i < 8; i++) xor_byte(s, at + i, (counter >> (56 - 8 * i)) & 0xff);
}

kernel void search(constant ulong *lanes   [[buffer(0)]],
                   constant uint *cfg      [[buffer(1)]],
                   constant ulong &base    [[buffer(2)]],
                   device atomic_uint *hits [[buffer(3)]],
                   device uint *out        [[buffer(4)]],
                   uint gid [[thread_position_in_grid]]) {
    ulong counter = base + gid;
    uint mode = cfg[2];
    ulong s[25];

    load_block(s, lanes);
    if (mode == 0) {
        // 0xff ++ factory ++ salt ++ init_code_hash, счётчик — байты 45..52.
        put_counter<45>(s, counter);
        keccakf(s);
    } else {
        // CREATE3 через CreateX: охрана salt -> адрес прокси (CREATE2) -> адрес контракта (CREATE, nonce 1).
        if (mode == 1) put_counter<56>(s, counter); else put_counter<24>(s, counter);
        keccakf(s);
        ulong t[25];
        load_block(t, lanes + 17);
        for (int j = 0; j < 32; j++) xor_byte(t, 21 + j, get_byte(s, j));
        keccakf(t);
        load_block(s, lanes + 34);
        for (int j = 0; j < 20; j++) xor_byte(s, 2 + j, get_byte(t, 12 + j));
        keccakf(s);
    }

    // Адрес — байты 12..31 хеша.
    uint a[5] = { uint(s[1] >> 32), uint(s[2]), uint(s[2] >> 32), uint(s[3]), uint(s[3] >> 32) };
    uint goal = cfg[1];

    if (goal == 0 && (a[0] & 0xff) != 0) return;

    uint zeros = 0;
    for (int i = 0; i < 5; i++)
        for (int k = 0; k < 4; k++)
            zeros += ((a[i] >> (8 * k)) & 0xff) == 0 ? 1 : 0;

    int score;
    if (goal == 0) {
        uint lead = 0;
        bool run = true;
        for (int i = 0; i < 5; i++)
            for (int k = 0; k < 4; k++) {
                run = run && ((a[i] >> (8 * k)) & 0xff) == 0;
                lead += run ? 1 : 0;
            }
        score = int(lead);
    } else if (goal == 1) {
        score = int(zeros);
    } else if (goal == 2) {
        for (int i = 0; i < 5; i++)
            if ((a[i] & cfg[10 + i]) != cfg[5 + i]) return;
        score = int(zeros) + 1;
    } else {
        uint flags = (((a[4] >> 16) & 0xff) << 8) | (a[4] >> 24);
        if ((flags & 0x3fff) != cfg[4]) return;
        score = int(zeros) + 1;
    }

    if (score <= int(cfg[0])) return;
    uint idx = atomic_fetch_add_explicit(hits, 1, memory_order_relaxed);
    if (idx >= cfg[3]) return;
    device uint *slot = out + idx * 8;
    slot[0] = uint(counter);
    slot[1] = uint(counter >> 32);
    for (int i = 0; i < 5; i++) slot[2 + i] = a[i];
    slot[7] = uint(score);
}
"""
