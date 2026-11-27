"""
Bitcoin на том же secp256k1, что EVM и TRON: сжатый публичный ключ →
hash160 = RIPEMD-160(SHA-256(ключ)), из него два вида адреса:

  btc  — SegWit P2WPKH, bc1q… (bech32, BIP-173): сейчас по умолчанию в кошельках;
  btc1 — Legacy P2PKH, 1… (Base58Check с версией 0x00): классика vanitygen.

Приватный ключ отдаём в WIF (compressed): Electrum, Sparrow, Bitcoin Core
импортируют его как есть (для bc1q в Electrum — с префиксом «p2wpkh:»).
"""
import hashlib
from typing import List, Tuple

BECH32_CHARS = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
SEGWIT_PREFIX = "bc1q"
NETWORKS = ("btc", "btc1")


def hash160(pub33: bytes) -> bytes:
    return hashlib.new("ripemd160", hashlib.sha256(pub33).digest()).digest()


def _b58check(payload: bytes) -> str:
    data = payload + hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    n = int.from_bytes(data, "big")
    out = ""
    while n > 0:
        n, r = divmod(n, 58)
        out = BASE58_ALPHABET[r] + out
    zeros = len(data) - len(data.lstrip(b"\0"))
    return "1" * zeros + out


def legacy_address(h160: bytes) -> str:
    return _b58check(b"\x00" + h160)


def _polymod(values: List[int]) -> int:
    gen = (0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3)
    chk = 1
    for v in values:
        top = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ v
        for i in range(5):
            if (top >> i) & 1:
                chk ^= gen[i]
    return chk


def segwit_address(h160: bytes) -> str:
    data = [0]
    acc = bits = 0
    for b in h160:
        acc = (acc << 8) | b
        bits += 8
        while bits >= 5:
            bits -= 5
            data.append((acc >> bits) & 31)
    pm = _polymod([3, 3, 0, 2, 3] + data + [0] * 6) ^ 1
    data += [(pm >> (5 * (5 - i))) & 31 for i in range(6)]
    return "bc1" + "".join(BECH32_CHARS[d] for d in data)


def address(network: str, pub33: bytes) -> str:
    h = hash160(pub33)
    return segwit_address(h) if network == "btc" else legacy_address(h)


def wif(private_key: bytes) -> str:
    """WIF для сжатого ключа mainnet: 0x80 ++ ключ ++ 0x01."""
    return _b58check(b"\x80" + private_key + b"\x01")


def generate(network: str) -> Tuple[str, str]:
    import os
    from coincurve import PrivateKey
    key = os.urandom(32)
    return address(network, PrivateKey(key).public_key.format(compressed=True)), wif(key)
