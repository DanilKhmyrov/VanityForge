"""
TON: красивый адрес кошелька без нового ключа.

Адрес кошелька v4r2 зависит от публичного ключа и 32-битного номера подкошелька
(wallet_id / subwallet_id). Перебираем номер — ключ и сид-фраза владельца те же,
майнеру нужен только публичный ключ (или адрес уже работающего кошелька).

Быстрый путь — `ethvanity --ton-subwallet`; здесь — разбор ключа, запасной
перебор на Python и сохранение находок.
"""
import base64
import hashlib
import json
import os
import re
import subprocess
import threading
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Tuple

CODE_HASH = bytes.fromhex("feb5ff6820e2ff0d9483e7e0d62c817d846789fb4ae580c878866d959dabd5c0")
CODE_DEPTH = 7
DEFAULT_WALLET_ID = 698983191
SPACE = 2 ** 32

_KEEPALIVE: List = []


def resolve_public_key(raw: str) -> bytes:
    """Принимает ed25519-ключ в hex (64 символа) или адрес TON: для адреса ключ
    берётся из самого кошелька через tonapi (кошелёк должен быть развёрнут)."""
    value = raw.strip()
    body = value.lower().removeprefix("0x")
    if re.fullmatch(r"[0-9a-f]{64}", body):
        return bytes.fromhex(body)
    if not re.fullmatch(r"[A-Za-z0-9_\-+/]{48}|-?\d:[0-9a-fA-F]{64}", value):
        raise ValueError("нужен публичный ключ (64 hex-символа) или адрес TON")
    try:
        with urllib.request.urlopen(f"https://tonapi.io/v2/accounts/{value}/publickey", timeout=15) as response:
            key = json.load(response).get("public_key", "")
    except Exception:
        raise ValueError("не удалось получить публичный ключ по адресу — кошелёк должен быть уже развёрнут "
                         "(хотя бы одна исходящая транзакция), или вставьте ключ вручную")
    if not re.fullmatch(r"[0-9a-f]{64}", key):
        raise ValueError("у этого адреса нет публичного ключа — это не кошелёк или он ещё не развёрнут")
    return bytes.fromhex(key)


def _crc16(data: bytes) -> bytes:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1
            crc &= 0xFFFF
    return crc.to_bytes(2, "big")


def address_for(public_key: bytes, wallet_id: int, bounceable: bool = False) -> str:
    data_hash = hashlib.sha256(b"\x00\x51" + bytes(4) + wallet_id.to_bytes(4, "big") + public_key + b"\x40").digest()
    state_hash = hashlib.sha256(b"\x02\x01\x34" + CODE_DEPTH.to_bytes(2, "big") + b"\x00\x00"
                                + CODE_HASH + data_hash).digest()
    raw = bytes([0x11 if bounceable else 0x51, 0x00]) + state_hash
    return base64.urlsafe_b64encode(raw + _crc16(raw)).decode()


def matches(address: str, pattern: str, mode: str, case_sensitive: bool) -> bool:
    body, p = address[2:], pattern
    if not case_sensitive:
        body, p = body.lower(), p.lower()
    if mode == "suffix":
        return body.endswith(p)
    if mode == "contains":
        return p in body
    return body.startswith(p)


def python_worker(public_key: bytes, pattern: str, mode: str, case_sensitive: bool, bounceable: bool,
                  start: int, step: int, result_queue, stats_counter) -> None:
    local = 0
    for wallet_id in range(start, SPACE, step):
        address = address_for(public_key, wallet_id, bounceable)
        if matches(address, pattern, mode, case_sensitive):
            result_queue.put((address, wallet_id))
        local += 1
        if local == 4096:
            with stats_counter.get_lock():
                stats_counter.value += local
            local = 0
    result_queue.put(("done", 0))


def start_search(public_key: bytes, pattern: str, mode: str, case_sensitive: bool, bounceable: bool,
                 workers: int, result_queue, stats_counter, stop_event) -> Tuple[str, List]:
    """Находки — (address, wallet_id) в result_queue; ("done", 0) — пространство перебрано."""
    from create2 import find_engine
    import multiprocessing as mp

    engine = find_engine()
    if engine:
        cmd = [engine, "--ton-subwallet", public_key.hex(), "--pattern", pattern, "--mode", mode,
               "--threads", str(workers)]
        if case_sensitive:
            cmd.append("--case")
        if bounceable:
            cmd.append("--bounceable")
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)

        def pump() -> None:
            last = 0
            for line in iter(proc.stdout.readline, ""):
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    continue
                kind = payload.get("type")
                if kind == "stats":
                    checked = payload.get("checked", 0)
                    with stats_counter.get_lock():
                        stats_counter.value += max(0, checked - last)
                    last = checked
                elif kind == "found":
                    result_queue.put((payload["address"], int(payload["wallet_id"])))
                elif kind == "done":
                    result_queue.put(("done", 0))
                elif kind == "error":
                    result_queue.put(("error", payload.get("message", "engine error")))

        threading.Thread(target=pump, daemon=True).start()
        threading.Thread(target=lambda: (stop_event.wait(), proc.kill()), daemon=True).start()
        return "ethvanity", [proc]

    procs = []
    for i in range(workers):
        p = mp.Process(target=python_worker, daemon=True,
                       args=(public_key, pattern, mode, case_sensitive, bounceable, i, workers,
                             result_queue, stats_counter))
        p.start()
        procs.append(p)
    return "python", procs


def save_result(results_dir: Path, address: str, wallet_id: int, public_key: bytes, conditions: str) -> str:
    save_dir = results_dir / "tonsub" / "custom"
    save_dir.mkdir(parents=True, exist_ok=True)
    filepath = save_dir / f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{address[:12]}.txt"
    with open(filepath, "w") as f:
        f.write("Network:    TON · subwallet (v4r2)\n")
        f.write(f"Address:    {address}\n")
        f.write(f"Subwallet:  {wallet_id}\n")
        f.write(f"PublicKey:  {public_key.hex()}\n")
        f.write(f"Conditions: {conditions}\n")
        f.write(f"Found:      {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    return str(filepath)
