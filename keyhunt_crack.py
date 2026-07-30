"""
Поиск приватных ключей для ETH адресов через keyhunt (bruteforce).
Читает файл с адресами (по одному на строку), запускает keyhunt -m address.
При нахождении совпадения проверяет баланс и сохраняет результат.
"""
import argparse
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
from pathlib import Path

RESULTS_DIR = Path("results") / "crack"

_ANSI_RE = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

KEY_RE = re.compile(r"Private\s*Key\s*►\s*(0x[0-9a-fA-F]{64}|[0-9a-fA-F]{64})", re.I)
ADDR_RE = re.compile(r"address:\s*(0x[0-9a-fA-F]{40})", re.I)
TOTAL_RE = re.compile(r"Total\s*[►▸>]\s*([\d,]+)")


def load_addresses(path: str) -> list[str]:
    addresses = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            addr = line.split()[0]
            addr = addr.lower().removeprefix("0x")
            if re.fullmatch(r"[0-9a-f]{40}", addr):
                addresses.append(addr)
    return sorted(set(addresses))


def find_keyhunt() -> str | None:
    for name in ("keyhunt", "KeyHunt-Cuda", "keyhunt-cuda"):
        path = shutil.which(name)
        if path:
            return path
    return None


def save_found(address: str, private_key: str, balance: str = ""):
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    fname = f"{ts}_{address[2:12]}.txt"
    with open(RESULTS_DIR / fname, "w") as f:
        f.write(f"Address:    {address}\n")
        f.write(f"Private:    {private_key}\n")
        if balance:
            f.write(f"Balance:    {balance}\n")
        f.write(f"Found:      {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    return str(RESULTS_DIR / fname)


def check_balance(address: str) -> str:
    try:
        from eth import ETH
        balances = asyncio.run(ETH().get_all_balances(address))
        if balances:
            return " | ".join(f"{v:.6f} {k}" for k, v in sorted(balances.items(), key=lambda x: -x[1]))
        return "N/A (RPC error)"
    except Exception:
        return "N/A (RPC error)"


def keyhunt_worker(
    keyhunt_path: str,
    addrs_file: str,
    result_queue: mp.Queue,
    stats_counter: mp.Value,
    stop_event: threading.Event,
):
    cpu_count = os.cpu_count() or 4
    cmd = [
        keyhunt_path, "-m", "address", "-c", "eth",
        "-b", "256", "-R", "-t", str(cpu_count),
        "-s", "5", "-q", "-f", addrs_file,
    ]

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    pending_pk = None

    for line in iter(proc.stdout.readline, ""):
        if stop_event.is_set():
            break
        if not line:
            break

        clean = _ANSI_RE.sub("", line)

        key_m = KEY_RE.search(clean)
        if key_m:
            pk = key_m.group(1)
            pending_pk = pk[2:] if pk.startswith("0x") else pk
            continue

        addr_m = ADDR_RE.search(clean)
        if addr_m and pending_pk:
            address = addr_m.group(1).lower()
            private_key = pending_pk
            pending_pk = None
            result_queue.put(("hit", address, private_key))
            continue

        total_m = TOTAL_RE.search(clean)
        if total_m:
            try:
                total = int(total_m.group(1).replace(",", ""))
                if total > 0:
                    with stats_counter.get_lock():
                        stats_counter.value = total
            except ValueError:
                pass

    proc.kill()


def main():
    parser = argparse.ArgumentParser(
        description="Bruteforce ETH приватных ключей через keyhunt",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Примеры:
  python keyhunt_crack.py addresses.txt
  python keyhunt_crack.py wallets.txt --check-balance
        """,
    )
    parser.add_argument("input", help="Файл с ETH адресами (по одному на строку)")
    parser.add_argument("--check-balance", action="store_true", help="Проверять баланс через RPC при нахождении")
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"Файл не найден: {args.input}")
        sys.exit(1)

    keyhunt_path = find_keyhunt()
    if not keyhunt_path:
        print("keyhunt не обнаружен. Установите: https://github.com/CryptoXploit/keyhunt")
        sys.exit(1)

    addresses = load_addresses(args.input)
    print(f"  Адресов загружено: {len(addresses)}")
    if not addresses:
        print("Нет валидных ETH адресов в файле")
        sys.exit(1)

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    addrs_file = str(RESULTS_DIR / "addresses.txt")
    with open(addrs_file, "w") as f:
        for addr in addresses:
            f.write(addr + "\n")

    print(f"  keyhunt: {keyhunt_path}")
    print(f"  Тредов: {os.cpu_count() or 4}")
    print(f"  Проверка баланса: {'да' if args.check_balance else 'нет'}")
    print(f"\n  Запуск (Ctrl+C для выхода)...\n")

    result_queue: mp.Queue = mp.Queue()
    stats_counter = mp.Value(ctypes.c_ulonglong, 0)
    stop_event = mp.Event()

    t = threading.Thread(
        target=keyhunt_worker,
        args=(keyhunt_path, addrs_file, result_queue, stats_counter, stop_event),
        daemon=True,
    )
    t.start()

    start = time.time()
    last_count = 0
    found_count = 0

    try:
        while not stop_event.is_set():
            try:
                tag, address, private_key = result_queue.get(timeout=1)
            except Exception:
                elapsed = int(time.time() - start)
                current = stats_counter.value
                delta = current - last_count
                speed = delta / 1 if delta > 0 else 0
                if elapsed > 0:
                    total_s = f"{current:,}".replace(",", " ")
                    speed_s = f"{int(speed):,}".replace(",", " ")
                    print(f"\r\033[K  {total_s} keys | {speed_s} keys/s | {elapsed}s | found: {found_count}", end="", flush=True)
                    last_count = current
                continue

            found_count += 1
            ts = datetime.now().strftime("%H:%M:%S")
            print(f"\n\n{'='*80}")
            print(f"  НАЙДЕН #{found_count} | {ts}")
            print(f"{'='*80}")
            print(f"  Address:    {address}")
            print(f"  Private:    {private_key}")

            balance = check_balance(address) if args.check_balance else ""
            if balance:
                print(f"  Balance:    {balance}")

            fp = save_found(address, private_key, balance)
            print(f"  Saved:      {fp}")
            print(f"{'='*80}\n")

    except KeyboardInterrupt:
        print("\n  Остановка...")
    finally:
        stop_event.set()
        if os.path.exists(addrs_file):
            os.remove(addrs_file)

        elapsed = int(time.time() - start)
        total = stats_counter.value
        print(f"\n  Статистика:")
        print(f"    Проверено: {total:,} keys")
        print(f"    Найдено:   {found_count}")
        print(f"    Время:     {elapsed}s")


if __name__ == "__main__":
    import asyncio
    main()
