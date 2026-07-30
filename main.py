"""
GPU-ускоренный генератор vanity-адресов.
Использует keyhunt (patched CryptoXploit/keyhunt-cuda) для ETH + CPU для остальных сетей.
"""
import asyncio
import ctypes
import multiprocessing as mp
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime
from multiprocessing import Queue, Value
from pathlib import Path
from typing import List, Optional, Tuple

# ANSI escape sequence pattern for stripping
_ANSI_RE = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

from eth import ETH
from networks import NETWORKS
from patterns import NETWORK_PRESETS, PRESETS, SEARCH_WORDS, contains_word

try:
    from web3 import Web3
    _TO_CHECKSUM = Web3.to_checksum_address
except ImportError:
    _TO_CHECKSUM = None

RESULTS_DIR = Path("results")
STATS_UPDATE_INTERVAL = 2

# Hex-префиксы, которые keyhunt ищет напрямую (быстрее, чем фильтровать
# постфактум) — базовый набор "N одинаковых подряд" плюс любые слова из
# SEARCH_WORDS, которые сами по себе валидный hex.
PATTERN_PREFIXES = {
    "same10": [f"{h*10}" for h in "0123456789abcdef"],
}

ALL_PREFIXES = sorted(set(
    list(sum(PATTERN_PREFIXES.values(), [])) +
    [w for w in SEARCH_WORDS if all(c in "0123456789abcdef" for c in w.lower())]
))


def find_keyhunt() -> Optional[str]:
    """Ищет keyhunt в системе (любой: CryptoXploit, keyhunt-cuda)."""
    for name in ("keyhunt", "KeyHunt-Cuda", "keyhunt-cuda"):
        path = shutil.which(name)
        if path:
            return path
    return None


def save_result(
    network_name: str, address: str, private_key: str,
    matched: List[str], conditions_str: str,
) -> str:
    if len(matched) == 1:
        folder_name = matched[0]
    else:
        folder_name = "combo"
    save_dir = RESULTS_DIR / network_name / folder_name
    save_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    safe_addr = address[:12].replace("/", "_").replace(":", "_")
    filename = f"{timestamp}_{safe_addr}.txt"
    filepath = save_dir / filename
    with open(filepath, "w") as f:
        f.write(f"Network:    {NETWORKS[network_name].name()}\n")
        f.write(f"Address:    {address}\n")
        f.write(f"Private:    {private_key}\n")
        f.write(f"Conditions: {conditions_str}\n")
        f.write(f"Found:      {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    return str(filepath)


def show_result(
    found_count: int, network_name: str,
    address: str, private_key: str,
    conditions_str: str, matched: List[str],
    filepath: str,
):
    """Вывод результата с проверкой баланса."""
    balance_line = ""
    if network_name == "eth":
        try:
            balances = asyncio.run(ETH().get_all_balances(address))
            if balances:
                parts = [f"{v:.6f} {k}" for k, v in sorted(balances.items(), key=lambda x: -x[1])]
                balance_line = f"💰 Balance:    {' | '.join(parts)}"
            else:
                balance_line = "💰 Balance:    N/A (RPC error)"
        except:
            balance_line = "💰 Balance:    N/A (RPC error)"

    if "word" in matched:
        found_words = [w for w in SEARCH_WORDS if contains_word(address, w, case_sensitive=False)]
        if found_words:
            conditions_str += f" [{', '.join(found_words)}]"

    network_full = NETWORKS[network_name].name()
    if network_name == "eth" and _TO_CHECKSUM:
        checksum_addr = _TO_CHECKSUM(address)
    else:
        checksum_addr = ""

    print(f"\n\n{'='*80}")
    print(f"  НАЙДЕН #{found_count} | {network_full}")
    print(f"{'='*80}")
    print(f"  Address:    {address}")
    if checksum_addr and checksum_addr != address:
        print(f"  Checksum:   {checksum_addr}")
    print(f"  Private:    {private_key[:20]}...{private_key[-8:]}")
    print(f"  Conditions: {conditions_str}")
    if balance_line:
        print(f"  {balance_line}")
    print(f"  Saved:      {filepath}")
    print(f"{'='*80}\n")


# ============================================================
# GPU — keyhunt process
# ============================================================

def keyhunt_worker(
    keyhunt_path: str,
    preset_key: str,
    result_queue: "mp.Queue[Tuple[str, str, str, List[str], int]]",
    stats_counter: "mp.Value",
    stop_event: threading.Event,
    extra_prefixes: Optional[List[str]] = None,
    worker_override: Optional[int] = None,
):
    """Запускает keyhunt для ETH vanity, парсит вывод.

    Поддерживаются форматы:
      - keyhunt-cuda:  PubAddress: / PrivKey:
      - CryptoXploit:  address: / Private Key ►
    """
    hex_prefixes = list(ALL_PREFIXES)
    if extra_prefixes:
        hex_prefixes.extend(extra_prefixes)
    hex_prefixes = sorted(set(hex_prefixes))
    bn = os.path.basename(keyhunt_path).lower()
    is_cudav = "cuda" in bn

    cpu_count = worker_override or (os.cpu_count() or 4)

    if is_cudav:
        cmd = [keyhunt_path, "-m", "vanity", "-c", "eth", "-R"]
    else:
        cmd = [keyhunt_path, "-m", "address", "-c", "eth", "-b", "256", "-R", "-t", str(cpu_count), "-s", "5", "-q"]

    for p in hex_prefixes:
        cmd += ["-v", p]

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    # readline() ниже блокирующий: пока keyhunt молчит между строками вывода,
    # проверка stop_event внутри цикла не выполняется, и proc.kill() в конце
    # функции может не наступить вовремя — keyhunt остаётся висеть в фоне после
    # остановки поиска. Отдельный поток гарантированно убивает процесс сразу же,
    # как только stop_event выставлен, независимо от состояния readline().
    def _kill_on_stop() -> None:
        stop_event.wait()
        proc.kill()

    stop_watcher = threading.Thread(target=_kill_on_stop, daemon=True)
    stop_watcher.start()

    key_pattern = re.compile(r"Private\s*Key\s*►\s*(0x[0-9a-fA-F]{64}|[0-9a-fA-F]{64})", re.I)
    addr_pattern = re.compile(r"address:\s*(0x[0-9a-fA-F]{40})", re.I)

    pending_pk: Optional[str] = None

    for line in iter(proc.stdout.readline, ""):
        if stop_event.is_set():
            break
        if not line:
            break

        clean = _ANSI_RE.sub("", line)

        key_m = key_pattern.search(clean)
        if key_m:
            pk = key_m.group(1)
            pending_pk = pk[2:] if pk.startswith("0x") else pk
            continue

        addr_m = addr_pattern.search(clean)
        if addr_m and pending_pk:
            address = addr_m.group(1).lower()
            private_key = pending_pk
            pending_pk = None

            presets = PRESETS
            matched = [
                name
                for name, (_, pred) in presets.items()
                if name != "all" and pred(address)
            ]

            if matched and (preset_key == "all" or preset_key in matched):
                result_queue.put(("eth", address, private_key, matched, 0))

        total_m = re.search(r"Total\s*[►▸>]\s*([\d,]+)", clean)
        if total_m:
            try:
                total = int(total_m.group(1).replace(",", ""))
                if total > 0:
                    with stats_counter.get_lock():
                        stats_counter.value = total
            except ValueError:
                pass

    proc.kill()


# ============================================================
# CPU workers (same as v2)
# ============================================================

def cpu_worker(
    network_name: str,
    preset_key: str,
    result_queue: "mp.Queue",
    stats_counter: "mp.Value",
    worker_id: int,
):
    """CPU воркер для сетей без GPU."""
    network = NETWORKS[network_name]
    presets = NETWORK_PRESETS.get(network_name, PRESETS)
    attempts = 0

    while True:
        attempts += 1
        try:
            address, private_key = network.generate()
        except Exception:
            continue

        matched = [
            name
            for name, (_, pred) in presets.items()
            if name != "all" and pred(address)
        ]

        if matched and (preset_key == "all" or preset_key in matched):
            result_queue.put((network_name, address, private_key, matched, attempts))

        if attempts % 1000 == 0:
            with stats_counter.get_lock():
                stats_counter.value += 1000


# ============================================================
# Stats
# ============================================================

def stats_monitor(
    stats_counter: "mp.Value",
    networks: List[str],
    workers_total: int,
    stop_event: threading.Event,
):
    start_time = time.time()
    last_count = 0

    while not stop_event.is_set():
        time.sleep(STATS_UPDATE_INTERVAL)
        current = stats_counter.value
        elapsed = time.time() - start_time
        if elapsed > 0:
            delta = current - last_count
            speed = delta / STATS_UPDATE_INTERVAL
            total = f"{current:,}".replace(",", " ")
            spd = f"{int(speed):,}".replace(",", " ")
            nets = ", ".join([NETWORKS[n].name() for n in networks])
            print(
                f"\r\033[K  {total} addr | {spd} addr/s | {int(elapsed)}s | {workers_total} workers ({nets})",
                end="", flush=True,
            )
            last_count = current


# ============================================================
# Main
# ============================================================

def generate_vanity(networks: List[str], preset_key: str = "all"):
    if preset_key not in PRESETS:
        print("Доступные условия:")
        for k, (desc, _) in PRESETS.items():
            print(f"  {k:15} - {desc}")
        return

    keyhunt_path = find_keyhunt()
    eth_gpu = "eth" in networks and keyhunt_path is not None
    cpu_nets = [n for n in networks if n != "eth" or not eth_gpu]

    desc, _ = PRESETS[preset_key]
    print(f"  Условие: {desc}")
    print(f"  Сети: {', '.join(NETWORKS[n].name() for n in networks)}")
    print(f"  CPU: {os.cpu_count()} ядер")

    if eth_gpu:
        print(f"  GPU ETH: {keyhunt_path}")
    else:
        print(f"  GPU ETH: keyhunt не обнаружен (используется CPU)")

    RESULTS_DIR.mkdir(exist_ok=True)

    result_queue: Queue = mp.Queue()
    stats_counter = Value(ctypes.c_ulonglong, 0)
    stop_event = mp.Event()

    procs = []

    # GPU воркер для ETH (keyhunt-cuda)
    if eth_gpu:
        t = threading.Thread(
            target=keyhunt_worker,
            args=(keyhunt_path, preset_key, result_queue, stats_counter, stop_event),
            daemon=True,
        )
        t.start()
        procs.append(t)
        print(f"  GPU ETH: запущен keyhunt")

    # CPU воркеры для всех сетей (включая ETH, если GPU недоступен)
    for net in cpu_nets:
        workers = max(1, (os.cpu_count() or 8) // len(networks))
        for i in range(workers):
            p = mp.Process(target=cpu_worker, args=(net, preset_key, result_queue, stats_counter, i))
            p.start()
            procs.append(p)

    total_workers = len(procs)
    print(f"  Всего воркеров: {total_workers}")
    print(f"\n  Запуск (Ctrl+C для выхода)...\n")

    # Статистика (в основном процессе, чтобы не было гонок с print)
    def stats_loop():
        start_time = time.time()
        last_count = 0
        while not stop_event.is_set():
            time.sleep(STATS_UPDATE_INTERVAL)
            current = stats_counter.value
            elapsed = time.time() - start_time
            if elapsed > 0:
                delta = current - last_count
                speed = delta / STATS_UPDATE_INTERVAL
                total = f"{current:,}".replace(",", " ")
                spd = f"{int(speed):,}".replace(",", " ")
                nets = ", ".join([NETWORKS[n].name() for n in networks])
            print(
                f"\r\033[K  {total} addr | {spd} addr/s | {int(elapsed)}s | {total_workers} workers ({nets})",
                end="", flush=True,
            )
            last_count = current

    stats_thread = threading.Thread(target=stats_loop, daemon=True)
    stats_thread.start()

    found_count = 0
    try:
        while not stop_event.is_set():
            try:
                network_name, address, private_key, matched, _ = result_queue.get(timeout=0.5)
            except Exception:
                continue

            found_count += 1

            network_presets = NETWORK_PRESETS.get(network_name, PRESETS)
            matched_desc = [network_presets[n][0] for n in matched if n in network_presets]
            conditions_str = "; ".join(matched_desc)

            filepath = save_result(network_name, address, private_key, matched, conditions_str)
            show_result(found_count, network_name, address, private_key, conditions_str, matched, filepath)

    except Exception:
        pass
    finally:
        stop_event.set()
        for p in procs:
            if isinstance(p, mp.Process):
                p.terminate()

        total = stats_counter.value
        print(f"\n\n  Финальная статистика:")
        print(f"    Проверено: {total:,} адресов")
        print(f"    Найдено:   {found_count}")
        if found_count > 0 and total > 0:
            print(f"    Редкость:  1 из {total // found_count:,}")


def main():
    if len(sys.argv) < 2:
        print("Использование:")
        print("  python main.py <сети> [условие]")
        print()
        print("Сети:")
        print("  sol     - Solana")
        print("  ton     - TON")
        print("  eth     - EVM: ETH, BSC, Polygon и т.п. (GPU через keyhunt если установлен)")
        print("  trx     - Tron")
        print("  all     - Все сети")
        print()
        print("Условия:")
        for k, (desc, _) in PRESETS.items():
            if k != "all":
                print(f"  {k:15} - {desc}")
        print()
        print("GPU ускорение ETH:")
        print("  keyhunt даёт ~100-500M addr/s на NVIDIA")
        print("  Установка: https://github.com/mlowasp/keyhunt-cuda")
        print()
        print("Примеры:")
        print("  python main.py eth suffix10   # ETH через GPU если есть keyhunt")
        print("  python main.py all word       # Все сети, CPU")
        return

    networks_arg = sys.argv[1].lower()
    preset = sys.argv[2] if len(sys.argv) > 2 else "all"

    if networks_arg == "all":
        networks = list(NETWORKS.keys())
    else:
        networks = [n.strip() for n in networks_arg.split(",")]
        invalid = [n for n in networks if n not in NETWORKS]
        if invalid:
            print(f"Ошибка: неизвестные сети {invalid}")
            print(f"Доступные: {list(NETWORKS.keys())}")
            return

    generate_vanity(networks, preset)


if __name__ == "__main__":
    main()
