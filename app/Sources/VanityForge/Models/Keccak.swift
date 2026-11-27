import Foundation

/// Keccak-256 (как в Ethereum, с паддингом 0x01, не SHA3) — нужен для EIP-55:
/// регистр букв адреса задаётся хешем его же строки в нижнем регистре.
enum Keccak {
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    private static let rotations: [Int] = [
        0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14,
    ]

    private static func permute(_ s: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        var b = [UInt64](repeating: 0, count: 25)
        for round in 0..<24 {
            for x in 0..<5 { c[x] = s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20] }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ ((c[(x + 1) % 5] << 1) | (c[(x + 1) % 5] >> 63))
                for y in 0..<5 { s[x + 5 * y] ^= d }
            }
            // ρ и π: b[y, 2x+3y] = rot(s[x, y]).
            for x in 0..<5 {
                for y in 0..<5 {
                    let i = x + 5 * y
                    let r = rotations[i]
                    let v = r == 0 ? s[i] : (s[i] << UInt64(r)) | (s[i] >> UInt64(64 - r))
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = v
                }
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    s[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
                }
            }
            s[0] ^= roundConstants[round]
        }
    }

    static func hash256(_ input: [UInt8]) -> [UInt8] {
        let rate = 136
        var message = input
        message.append(0x01)
        while message.count % rate != 0 { message.append(0) }
        message[message.count - 1] |= 0x80
        var state = [UInt64](repeating: 0, count: 25)
        for block in stride(from: 0, to: message.count, by: rate) {
            for i in 0..<(rate / 8) {
                var lane: UInt64 = 0
                for k in 0..<8 { lane |= UInt64(message[block + i * 8 + k]) << UInt64(8 * k) }
                state[i] ^= lane
            }
            permute(&state)
        }
        var out: [UInt8] = []
        for i in 0..<4 {
            for k in 0..<8 { out.append(UInt8((state[i] >> UInt64(8 * k)) & 0xff)) }
        }
        return out
    }

    /// EIP-55: буква в верхнем регистре, если соответствующий полубайт хеша ≥ 8.
    static func checksumAddress(_ address: String) -> String {
        let body = address.lowercased().hasPrefix("0x") ? String(address.lowercased().dropFirst(2)) : address.lowercased()
        let hash = hash256(Array(body.utf8))
        var out = "0x"
        for (i, ch) in body.enumerated() {
            let nibble = i % 2 == 0 ? hash[i / 2] >> 4 : hash[i / 2] & 0x0f
            out.append(ch.isLetter && nibble >= 8 ? Character(ch.uppercased()) : ch)
        }
        return out
    }
}
