"""
CREATE2: подбор salt для адреса смарт-контракта (майнинг «для заказчика»).

Адрес контракта, развёрнутого через CREATE2:
    keccak256(0xff ++ factory ++ salt ++ keccak256(init_code))[12:]
Фабрика и хеш кода — от заказчика, перебирается только salt. Приватных
ключей нет вовсе: результат — salt, он не секретный.

Первые 20 байт salt — адрес заказчика (caller). ImmutableCreate2Factory
проверяет, что они равны msg.sender (или нулям), так что найденный salt
может использовать только заказчик — подсмотреть его в мемпуле бесполезно.

Основной перебор — в Rust (ethvanity --create2, десятки млн попыток/с).
Здесь — общие описания условий, оценка редкости, сохранение находок и
медленный запасной перебор на Python на случай, если ethvanity не собран.

CLI:
    python3 create2.py --kind create3 --caller 0x… --goal leading --min 4
    python3 create2.py --init-code-hash 0x… [--factory 0x…] [--caller 0x…]
                       [--goal leading|zeros|prefix|hook] [--min N]
                       [--prefix dead] [--hook-flags 00C0] [--workers N]
                       [--engine auto|gpu|cpu]
"""
import json
import math
import multiprocessing as mp
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

from Crypto.Hash import keccak

# Фабрики, которые реально используют: у каждой свой адрес во всех EVM-сетях.
FACTORIES: Dict[str, Tuple[str, str, bool]] = {
    # ключ: (адрес, название, требует ли caller в первых 20 байтах salt)
    "immutable": ("0x0000000000FFe8B47B3e2130213B802212439497", "ImmutableCreate2Factory", True),
    "arachnid": ("0x4e59b44847b379578588920cA78FbF26c0B4956C", "Deterministic Deployment Proxy", False),
}

GOALS = ("leading", "zeros", "prefix", "hook")
KINDS = ("create2", "create3")

# CREATE3 через CreateX: адрес не зависит от кода. См. ethvanity/src/create2.rs.
CREATEX = "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed"
CREATE3_PROXY_HASH = bytes.fromhex("21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f")

# Общие объекты multiprocessing должны жить, пока дочерние процессы к ним
# подключаются: при spawn ребёнок открывает семафор по имени уже после
# p.start(), и если родитель к тому моменту его освободил — FileNotFoundError.
_KEEPALIVE: List = []
HOOK_FLAG_MASK = 0x3FFF
ADDRESS_BYTES = 20

GOAL_DESC = {
    "ru": {
        "leading": "Нулевые байты в начале (≥ {min})",
        "zeros": "Нулевые байты где угодно (≥ {min})",
        "prefix": 'Начинается с "{prefix}"',
        "hook": "Uniswap v4 hook, флаги 0x{flags:04x}",
    },
    "en": {
        "leading": "Leading zero bytes (≥ {min})",
        "zeros": "Zero bytes anywhere (≥ {min})",
        "prefix": 'Starts with "{prefix}"',
        "hook": "Uniswap v4 hook, flags 0x{flags:04x}",
    },
}

NETWORK_FULL = {
    "create2": {"ru": "Контракт · CREATE2", "en": "Contract · CREATE2"},
    "create3": {"ru": "Контракт · CREATE3", "en": "Contract · CREATE3"},
}


class Params:
    def __init__(self, factory: str, init_code_hash: str, caller: str, goal: str,
                 min_bytes: int = 1, prefix: str = "", hook_flags: int = 0, kind: str = "create2"):
        if kind not in KINDS:
            raise ValueError(f"unknown kind '{kind}'")
        self.kind = kind
        if kind == "create3":
            self.factory = normalize_hex(CREATEX, 20, "factory")
            self.init_code_hash = "0x" + "00" * 32
        else:
            self.factory = normalize_hex(factory, 20, "factory")
            self.init_code_hash = normalize_hex(init_code_hash, 32, "init code hash")
        self.caller = normalize_hex(caller, 20, "caller") if caller.strip() else "0x" + "00" * 20
        if goal not in GOALS:
            raise ValueError(f"unknown goal '{goal}'")
        self.goal = goal
        self.min_bytes = max(1, min(ADDRESS_BYTES, int(min_bytes)))
        self.prefix = prefix.lower().removeprefix("0x")
        if goal == "prefix" and not re.fullmatch(r"[0-9a-f]{1,40}", self.prefix):
            raise ValueError("prefix must be 1..40 hex characters")
        self.hook_flags = int(hook_flags) & HOOK_FLAG_MASK

    def describe(self, lang: str = "ru") -> str:
        template = GOAL_DESC.get(lang, GOAL_DESC["ru"])[self.goal]
        return template.format(min=self.min_bytes, prefix=self.prefix, flags=self.hook_flags)

    def folder(self) -> str:
        if self.goal in ("leading", "zeros"):
            return f"{self.goal}{self.min_bytes}"
        if self.goal == "prefix":
            return f"prefix_{self.prefix}"
        return f"hook_{self.hook_flags:04x}"

    def network_full(self, lang: str = "ru") -> str:
        names = NETWORK_FULL[self.kind]
        return names.get(lang, names["ru"])

    def engine_args(self) -> List[str]:
        if self.kind == "create3":
            args = ["--create3", "--caller", self.caller, "--goal", self.goal, "--min", str(self.min_bytes)]
        else:
            args = ["--create2", "--factory", self.factory, "--init-code-hash", self.init_code_hash,
                    "--caller", self.caller, "--goal", self.goal, "--min", str(self.min_bytes)]
        if self.goal == "prefix":
            args += ["--prefix", self.prefix]
        if self.goal == "hook":
            args += ["--hook-flags", f"{self.hook_flags:04x}"]
        return args


def normalize_hex(raw: str, size: int, label: str) -> str:
    value = raw.strip().lower().removeprefix("0x")
    if not re.fullmatch(r"[0-9a-f]{%d}" % (size * 2), value):
        raise ValueError(f"{label} must be {size} bytes of hex (0x + {size * 2} characters)")
    return "0x" + value


def _keccak(data: bytes) -> bytes:
    return keccak.new(digest_bits=256, data=data).digest()


def compute_address(factory: str, salt: str, init_code_hash: str) -> str:
    data = b"\xff" + bytes.fromhex(factory[2:]) + bytes.fromhex(salt[2:]) + bytes.fromhex(init_code_hash[2:])
    return "0x" + _keccak(data)[12:].hex()


def create3_address(salt: bytes, caller: bytes) -> bytes:
    """Адрес, который CreateX.deployCreate3 даст для salt при вызове с caller.
    Разрешённый salt (первые 20 байт = caller, 21-й байт 0x00) охраняется
    через keccak(caller ++ salt), иначе — keccak(salt)."""
    if caller != bytes(20) and salt[:20] == caller and salt[20] == 0:
        guarded = _keccak(bytes(12) + caller + salt)
    else:
        guarded = _keccak(salt)
    proxy = _keccak(b"\xff" + bytes.fromhex(CREATEX[2:]) + guarded + CREATE3_PROXY_HASH)[12:]
    return _keccak(b"\xd6\x94" + proxy + b"\x01")[12:]


def params_address(params: "Params", salt: str) -> str:
    """Адрес для найденного salt — независимая перепроверка находки движка."""
    if params.kind == "create3":
        return "0x" + create3_address(bytes.fromhex(salt[2:]), bytes.fromhex(params.caller[2:])).hex()
    return compute_address(params.factory, salt, params.init_code_hash)


def leading_zero_bytes(address: str) -> int:
    raw = bytes.fromhex(address[2:])
    return len(raw) - len(raw.lstrip(b"\x00"))


def zero_bytes(address: str) -> int:
    return bytes.fromhex(address[2:]).count(0)


def estimate_rarity(params: Params) -> Optional[int]:
    """«1 из N» для одного адреса — та же шкала, что у пресетов кошельков."""
    if params.goal == "leading":
        return 256 ** params.min_bytes
    if params.goal == "zeros":
        p = 1 / 256
        tail = sum(math.comb(ADDRESS_BYTES, k) * p ** k * (1 - p) ** (ADDRESS_BYTES - k)
                   for k in range(params.min_bytes, ADDRESS_BYTES + 1))
        return int(1 / tail) if tail > 0 else None
    if params.goal == "prefix":
        return 16 ** len(params.prefix)
    return HOOK_FLAG_MASK + 1


def to_checksum(address: str) -> str:
    body = address[2:].lower()
    digest = keccak.new(digest_bits=256, data=body.encode()).hexdigest()
    return "0x" + "".join(c.upper() if int(digest[i], 16) >= 8 else c for i, c in enumerate(body))


def save_result(results_dir: Path, params: Params, address: str, salt: str, lang: str = "ru") -> str:
    save_dir = results_dir / params.kind / params.folder()
    save_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filepath = save_dir / f"{timestamp}_{address[:12]}.txt"
    with open(filepath, "w") as f:
        f.write(f"Network:    {params.network_full(lang)}\n")
        f.write(f"Address:    {to_checksum(address)}\n")
        f.write(f"Salt:       {salt}\n")
        f.write(f"Factory:    {to_checksum(params.factory)}\n")
        if params.kind == "create2":
            f.write(f"InitCode:   {params.init_code_hash}\n")
        f.write(f"Caller:     {to_checksum(params.caller)}\n")
        f.write(f"Conditions: {params.describe(lang)}\n")
        f.write(f"Found:      {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    return str(filepath)


def find_gpu_engine() -> Optional[str]:
    """metalvanity — перебор на видеокарте Apple Silicon (см. metalvanity/main.swift).
    Лежит рядом со скриптами в .app или собран в репозитории metalvanity/build.sh."""
    here = os.path.dirname(os.path.abspath(__file__))
    for path in (os.path.join(here, "metalvanity"), os.path.join(here, "metalvanity", "build", "metalvanity")):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def find_engine() -> Optional[str]:
    local = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ethvanity")
    if os.path.isfile(local) and os.access(local, os.X_OK):
        return local
    built = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ethvanity", "target", "release", "ethvanity")
    if os.path.isfile(built) and os.access(built, os.X_OK):
        return built
    from shutil import which
    return which("ethvanity")


def _goal_check(params: Params) -> Callable[[bytes], Optional[int]]:
    """Проверка для Python-перебора: None — мимо, число — «очки» находки."""
    prefix = params.prefix
    if params.goal == "leading":
        return lambda a: (len(a) - len(a.lstrip(b"\x00"))) if a[0] == 0 else None
    if params.goal == "zeros":
        return lambda a: a.count(0)
    if params.goal == "prefix":
        return lambda a: a.count(0) + 1 if a.hex().startswith(prefix) else None
    flags = params.hook_flags
    return lambda a: a.count(0) + 1 if (int.from_bytes(a[18:20], "big") & HOOK_FLAG_MASK) == flags else None


def python_worker(params: Params, worker_id: int, result_queue: "mp.Queue", stats_counter, best) -> None:
    factory = bytes.fromhex(params.factory[2:])
    code_hash = bytes.fromhex(params.init_code_hash[2:])
    caller = bytes.fromhex(params.caller[2:])
    if params.kind == "create3":
        head = b"\xff" + factory + caller + b"\x00" + bytes([worker_id & 0xFF]) + secrets.token_bytes(2)
    else:
        head = b"\xff" + factory + caller + bytes([worker_id & 0xFF]) + secrets.token_bytes(3)
    check = _goal_check(params)
    counter, local = 0, 0
    while True:
        salt_tail = counter.to_bytes(8, "big")
        if params.kind == "create3":
            address = create3_address(head[21:] + salt_tail, caller)
        else:
            address = _keccak(head + salt_tail + code_hash)[12:]
        score = check(address)
        # Как в Rust: для нулей — рекорды, для префикса/хука — первое совпадение,
        # дальше только с бо́льшим числом нулевых байт.
        if score is not None and score > best.value:
            with best.get_lock():
                if score > best.value:
                    best.value = score
                    result_queue.put(("0x" + address.hex(), "0x" + (head[21:] + salt_tail).hex()))
        counter += 1
        local += 1
        if local >= 2048:
            with stats_counter.get_lock():
                stats_counter.value += local
            local = 0


def _goal_ok(params: Params, address: str) -> bool:
    return _goal_check(params)(bytes.fromhex(address[2:])) is not None


def _launch(cmd: List[str], params: Params, result_queue, stats_counter, stop_event) -> subprocess.Popen:
    """Запускает движок с построчным JSON на stdout и перекачивает его события
    в result_queue / stats_counter. Каждая находка перепроверяется здесь же:
    адрес пересчитывается из salt и должен совпасть и подойти под условие."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def pump() -> None:
        last_checked = 0
        for line in iter(proc.stdout.readline, ""):
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if payload.get("type") == "stats":
                checked = payload.get("checked", 0)
                with stats_counter.get_lock():
                    stats_counter.value += max(0, checked - last_checked)
                last_checked = checked
            elif payload.get("type") == "found":
                address, salt = payload["address"], payload["salt"]
                if params_address(params, salt) != address or not _goal_ok(params, address):
                    result_queue.put(("error", f"engine returned a wrong salt {salt}"))
                    continue
                result_queue.put((address, salt))
            elif payload.get("type") == "error":
                result_queue.put(("error", payload.get("message", "engine error")))

    threading.Thread(target=pump, daemon=True).start()
    threading.Thread(target=lambda: (stop_event.wait(), proc.kill()), daemon=True).start()
    return proc


def start_search(params: Params, workers: int, result_queue, stats_counter, stop_event,
                 engine_pref: str = "auto", gpu_limits: Tuple[str, ...] = ()) -> Tuple[str, List]:
    """Запускает перебор: GPU (metalvanity), если он есть и не выбран CPU, иначе
    Rust-движок, иначе Python-процессы. Находки кладутся в result_queue как
    (address, salt). Возвращает имя движка и список запущенного (для остановки).
    gpu_limits — флаги ограничения нагрузки для GPU-движка (--gpu-load / --max-speed)."""
    gpu = find_gpu_engine() if engine_pref != "cpu" else None
    if gpu:
        cmd = [gpu] + params.engine_args() + list(gpu_limits)
        return "metal", [_launch(cmd, params, result_queue, stats_counter, stop_event)]

    engine = find_engine()
    if engine:
        cmd = [engine, "--threads", str(workers)] + params.engine_args()
        return "ethvanity", [_launch(cmd, params, result_queue, stats_counter, stop_event)]

    floor = params.min_bytes - 1 if params.goal in ("leading", "zeros") else 0
    best = mp.Value("i", floor)
    _KEEPALIVE.append(best)
    procs = []
    for i in range(workers):
        p = mp.Process(target=python_worker, args=(params, i, result_queue, stats_counter, best), daemon=True)
        p.start()
        procs.append(p)
    return "python", procs


def params_from_args(args: List[str]) -> Params:
    def value(flag: str, default: str = "") -> str:
        if flag in args:
            idx = args.index(flag)
            if idx + 1 < len(args):
                return args[idx + 1]
        return default

    factory = value("--factory", FACTORIES["immutable"][0])
    factory = FACTORIES[factory][0] if factory in FACTORIES else factory
    return Params(
        kind=value("--kind", "create2"),
        factory=factory,
        init_code_hash=value("--init-code-hash"),
        caller=value("--caller"),
        goal=value("--goal", "leading"),
        min_bytes=int(value("--min", "1") or 1),
        prefix=value("--prefix"),
        hook_flags=int(value("--hook-flags", "0") or "0", 16),
    )


def main() -> None:
    try:
        params = params_from_args(sys.argv[1:])
    except ValueError as error:
        print(f"error: {error}\n\n{__doc__}")
        sys.exit(1)

    workers = int(sys.argv[sys.argv.index("--workers") + 1]) if "--workers" in sys.argv else (os.cpu_count() or 4)

    def interrupt(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    results_dir = Path("results")
    result_queue: "mp.Queue" = mp.Queue()
    stats_counter = mp.Value("Q", 0)
    stop_event = threading.Event()
    engine_pref = sys.argv[sys.argv.index("--engine") + 1] if "--engine" in sys.argv else "auto"
    engine, procs = start_search(params, workers, result_queue, stats_counter, stop_event, engine_pref)

    rarity = estimate_rarity(params)
    print(f"CREATE2 · {params.describe()} · 1 : {rarity:,} · {engine} × {workers}")
    print(f"factory {params.factory}\ninit    {params.init_code_hash}\ncaller  {params.caller}\n")

    start, last_print = time.time(), 0.0
    try:
        while True:
            try:
                address, salt = result_queue.get(timeout=1)
            except Exception:
                address = None
            now = time.time()
            if address == "error":
                print(f"error: {salt}")
                break
            if address:
                path = save_result(results_dir, params, address, salt)
                print(f"\n★ {to_checksum(address)}  (нулей в начале: {leading_zero_bytes(address)}, всего: {zero_bytes(address)})")
                print(f"  salt {salt}\n  → {path}")
            if now - last_print >= 2:
                last_print = now
                speed = stats_counter.value / max(now - start, 1e-9)
                print(f"\r  {stats_counter.value:,} попыток · {speed / 1e6:.1f} млн/с", end="", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        for p in procs:
            if isinstance(p, mp.Process):
                p.terminate()
            else:
                p.kill()
        print()


if __name__ == "__main__":
    main()
