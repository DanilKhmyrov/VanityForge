"""
Split-key: майнинг красивого кошелька для другого человека без знания его ключа.

1. Заказчик генерирует свой ключ и отдаёт только публичный ключ P
   (`python3 splitkey.py new`).
2. Майнер перебирает точки P + k·G и ищет такое k, при котором адрес красивый.
   Приватный ключ этой точки — (секрет_заказчика + k), и его не знает никто,
   кроме заказчика: майнер видел только P и k.
3. Заказчик получает k и сам собирает ключ (`python3 splitkey.py combine`).

Работает для сетей на secp256k1: EVM (0x…) и TRON (T…). Быстрый путь для EVM —
`ethvanity --split-key`; здесь — общий перебор на Python и утилита заказчика.
"""
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional

import coincurve
from Crypto.Hash import keccak

from networks import NETWORKS, base58check_encode
from patterns import NETWORK_PRESETS, PRESETS

NETWORKS_SUPPORTED = ("eth", "trx")
_G = coincurve.PublicKey.from_secret((1).to_bytes(32, "big"))


def parse_public_key(raw: str) -> coincurve.PublicKey:
    value = raw.strip().lower().removeprefix("0x")
    try:
        return coincurve.PublicKey(bytes.fromhex(value))
    except Exception:
        raise ValueError("public key must be a secp256k1 key: 33 bytes (02…/03…) or 65 bytes (04…) of hex")


def address_for(network: str, point: coincurve.PublicKey) -> str:
    raw = keccak.new(digest_bits=256, data=point.format(compressed=False)[1:]).digest()[12:]
    if network == "eth":
        return "0x" + raw.hex()
    return base58check_encode(raw, version_byte=0x41)


def split_worker(network: str, preset_key: str, result_queue, stats_counter, worker_id: int,
                 client_pub_hex: str, custom_pattern=None, words=None) -> None:
    """Как main.cpu_worker, только точки — P_заказчика + k·G, а в очередь
    вместо приватного ключа уходит k."""
    if custom_pattern:
        from bridge import install_custom_preset
        pattern, mode, case_sensitive = custom_pattern
        install_custom_preset(pattern, mode, case_sensitive=case_sensitive)
    if words is not None:
        from bridge import install_word_list
        install_word_list(words)

    presets = NETWORK_PRESETS.get(network, PRESETS)
    base = parse_public_key(client_pub_hex)
    k = int.from_bytes(os.urandom(32), "big") % (coincurve.utils.GROUP_ORDER_INT - 2**40)
    point = coincurve.PublicKey.combine_keys([base, coincurve.PublicKey.from_secret(k.to_bytes(32, "big"))])
    attempts = 0
    while True:
        address = address_for(network, point)
        matched = [name for name, (_, pred) in presets.items() if name != "all" and pred(address)]
        if matched and (preset_key == "all" or preset_key in matched):
            result_queue.put((network, address, k.to_bytes(32, "big").hex(), matched, attempts))
        point = coincurve.PublicKey.combine_keys([point, _G])
        k += 1
        attempts += 1
        if attempts % 1000 == 0:
            with stats_counter.get_lock():
                stats_counter.value += 1000


def combine(client_secret_hex: str, tweak_hex: str) -> str:
    secret = coincurve.PrivateKey.from_hex(client_secret_hex.strip().lower().removeprefix("0x"))
    return secret.add(bytes.fromhex(tweak_hex.strip().lower().removeprefix("0x"))).to_hex()


def save_result(results_dir: Path, network: str, address: str, tweak: str, client_pub: str,
                matched_folder: str, conditions: str) -> str:
    save_dir = results_dir / "splitkey" / f"{network}_{matched_folder}"
    save_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filepath = save_dir / f"{timestamp}_{address[:12]}.txt"
    with open(filepath, "w") as f:
        f.write(f"Network:    Split-key · {NETWORKS[network].name()}\n")
        f.write(f"Address:    {address}\n")
        f.write(f"Tweak:      {tweak}\n")
        f.write(f"ClientKey:  {client_pub}\n")
        f.write(f"Conditions: {conditions}\n")
        f.write(f"Found:      {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    return str(filepath)


USAGE = """usage:
  python3 splitkey.py new
      создать ключ: публичный — отдать майнеру, приватный — хранить у себя
  python3 splitkey.py combine <ваш приватный ключ> <добавка k от майнера> [eth|trx]
      собрать итоговый ключ красивого адреса"""


def main() -> None:
    args = sys.argv[1:]
    if args[:1] == ["new"]:
        secret = coincurve.PrivateKey()
        print("Публичный ключ (отправьте майнеру):")
        print("  " + secret.public_key.format(compressed=True).hex())
        print("Приватный ключ (никому не отправляйте, он понадобится для combine):")
        print("  " + secret.to_hex())
        return
    if args[:1] == ["combine"] and len(args) >= 3:
        network = args[3] if len(args) > 3 else "eth"
        if network not in NETWORKS_SUPPORTED:
            print(f"сеть должна быть одной из: {', '.join(NETWORKS_SUPPORTED)}")
            sys.exit(1)
        final = combine(args[1], args[2])
        point = coincurve.PrivateKey.from_hex(final).public_key
        print(f"Адрес:           {address_for(network, point)}")
        print(f"Приватный ключ:  {final}")
        return
    print(USAGE)
    sys.exit(1)


if __name__ == "__main__":
    main()
