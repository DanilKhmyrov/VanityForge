"""
Консольный генератор vanity-адресов. ETH и TRON ищутся теми же движками, что и
в приложении (видеокарта — metalvanity-evm, без неё для ETH — ethvanity),
остальные сети и условия — CPU-процессами на Python.
"""
import asyncio
import ctypes
import multiprocessing as mp
import os
import sys
import threading
import time
from datetime import datetime
from multiprocessing import Queue, Value
from pathlib import Path
from typing import List

from eth import ETH
from networks import NETWORKS
from patterns import NETWORK_PRESETS, PRESETS, SEARCH_WORDS, contains_word

try:
    from web3 import Web3
    _TO_CHECKSUM = Web3.to_checksum_address
except ImportError:
    _TO_CHECKSUM = None

# Куда сохраняются находки. Приложение передаёт постоянную папку
# (~/Library/Application Support/VanityForge/results) через переменную
# окружения — внутри .app их хранить нельзя: пересборка бандла стирает его
# целиком. Путь абсолютный, чтобы filepath в событиях открывался откуда угодно.
RESULTS_DIR = Path(os.environ.get("VANITYFORGE_RESULTS_DIR") or "results").absolute()
STATS_UPDATE_INTERVAL = 2

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

    # Движки — из bridge.py (импорт здесь: bridge сам импортирует этот модуль).
    import bridge

    gpu_path = bridge.find_gpu_eth()
    gpu_eth = bridge.eth_hex_targets(preset_key, None, allow_contains=True) if "eth" in networks and gpu_path else None
    gpu_trx = bridge.tron_targets(preset_key, None) if "trx" in networks and gpu_path else None
    ethvanity_path = bridge.find_ethvanity() if "eth" in networks and not gpu_eth else None
    eth_targets = bridge.eth_hex_targets(preset_key, None) if ethvanity_path else None
    accelerated = {n for n, t in (("eth", gpu_eth), ("trx", gpu_trx)) if t} | ({"eth"} if eth_targets else set())
    cpu_nets = [n for n in networks if n not in accelerated]

    desc, _ = PRESETS[preset_key]
    print(f"  Условие: {desc}")
    print(f"  Сети: {', '.join(NETWORKS[n].name() for n in networks)}")
    print(f"  CPU: {os.cpu_count()} ядер")
    if gpu_eth or gpu_trx:
        print(f"  Видеокарта: {', '.join(n for n, t in (('eth', gpu_eth), ('trx', gpu_trx)) if t)}")
    if eth_targets:
        print("  ETH: ethvanity (CPU)")

    RESULTS_DIR.mkdir(exist_ok=True)

    result_queue: Queue = mp.Queue()
    stats_counter = Value(ctypes.c_ulonglong, 0)
    stop_event = mp.Event()

    procs = []

    if gpu_eth or gpu_trx:
        t = threading.Thread(target=bridge.metal_eth_worker, daemon=True,
                             args=(gpu_path, gpu_eth, gpu_trx, preset_key, result_queue, stats_counter, stop_event))
        t.start()
        procs.append(t)
    if eth_targets:
        t = threading.Thread(target=bridge.ethvanity_worker, daemon=True,
                             args=(ethvanity_path, preset_key, result_queue, stats_counter, stop_event, eth_targets))
        t.start()
        procs.append(t)

    # CPU-процессы на Python — для сетей, которые движки не покрыли
    for net in cpu_nets:
        workers = max(1, (os.cpu_count() or 8) // len(cpu_nets))
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
        print("  python3 python/main.py <сети> [условие]")
        print()
        print("Сети:")
        print("  sol     - Solana")
        print("  ton     - TON")
        print("  eth     - EVM: ETH, BSC, Polygon и т.п.")
        print("  trx     - Tron")
        print("  all     - Все сети")
        print()
        print("Условия:")
        for k, (desc, _) in PRESETS.items():
            if k != "all":
                print(f"  {k:15} - {desc}")
        print()
        print("Примеры:")
        print("  python3 python/main.py eth suffix10   # ETH, на видеокарте")
        print("  python3 python/main.py eth,trx word   # ETH и Tron, слово из списка")
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
