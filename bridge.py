"""
JSON-мост между генератором (main.py) и внешним UI (VanityForge.app).

Переиспользует воркеры и утилиты из main.py как есть — не меняет
алгоритмы поиска/паттерны. Единственная разница: вместо print в терминал
эмитит построчный JSON (JSON Lines) в stdout и слушает stdin на команду
остановки {"cmd": "stop"}.

Использование:
    python3 bridge.py <networks> <preset>
    python3 bridge.py <networks> <preset> --fake-found <interval_seconds>
"""
import asyncio
import ctypes
import json
import math
import multiprocessing as mp
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from multiprocessing import Queue, Value
from typing import List, Optional, Tuple

import main as core
import patterns
from eth import ETH
from main import cpu_worker, find_keyhunt, keyhunt_worker, save_result
from networks import NETWORKS
from patterns import NETWORK_PRESETS, PRESET_DESC_EN, PRESETS, contains_word, _body

STATS_UPDATE_INTERVAL = 1.0
# Скорость считается по скользящему окну (не по мгновенной дельте): апстрим
# (особенно keyhunt) отдаёт прогресс рывками, окно в несколько тиков сглаживает
# это естественным образом, без искусственной задержки отклика на реальный тренд.
SPEED_WINDOW_TICKS = 6

CUSTOM_KEY = "_custom"
# Потолок находок, для которых пишем файл/эмитим детальное событие/дёргаем
# баланс за один запуск — защита от слишком "широких" паттернов (короткий
# префикс и т.п.), которые иначе заваливают диск и UI тысячами находок в
# секунду. found_count при этом продолжает расти точно, просто без деталей.
MAX_DETAILED_FINDS = 300


def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def stdin_listener(stop_event) -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            continue
        if cmd.get("cmd") == "stop":
            stop_event.set()
            break


def apply_language(lang: str) -> None:
    """Переписывает описания встроенных пресетов на нужный язык — один раз
    на процесс, до первого чтения NETWORK_PRESETS/PRESETS. Предикаты (вторые
    элементы кортежей) от языка не зависят и не трогаются."""
    if lang != "en":
        return
    seen = set()
    for presets in NETWORK_PRESETS.values():
        if id(presets) in seen:
            continue
        seen.add(id(presets))
        for key, (desc, pred) in list(presets.items()):
            presets[key] = (PRESET_DESC_EN.get(key, desc), pred)


def preset_description(preset_key: str, networks: List[str], lang: str = "ru") -> str:
    for net in networks:
        presets = NETWORK_PRESETS.get(net, PRESETS)
        if preset_key in presets:
            return presets[preset_key][0]
    return "Custom condition" if lang == "en" else "Пользовательское условие"


_CUSTOM_MODE_LABELS = {"prefix": "начало", "suffix": "конец", "contains": "содержит"}
_CUSTOM_MODE_LABELS_EN = {"prefix": "starts with", "suffix": "ends with", "contains": "contains"}


def make_custom_predicate(pattern: str, mode: str, case_sensitive: bool = False):
    """Предикат для введённого пользователем паттерна.

    Один и тот же предикат ставится во ВСЕ сети сразу (sol/eth/trx делят один
    физический словарь NETWORK_PRESETS — см. install_custom_preset), поэтому
    сеть внутри него определяется по самому адресу (0x-префикс = ETH), а не
    передаётся параметром. Для ETH с учётом регистра сравниваем не сырой
    адрес (он всегда в нижнем регистре при генерации), а его EIP-55
    checksum-представление — только там регистр вообще что-то значит.
    """
    def check(addr: str) -> bool:
        if case_sensitive:
            if addr.startswith("0x") and core._TO_CHECKSUM:
                try:
                    body = core._TO_CHECKSUM(addr)[2:]
                except Exception:
                    body = _body(addr)
            else:
                body = _body(addr)
            p = pattern
        else:
            body = _body(addr).lower()
            p = pattern.lower()

        if mode == "suffix":
            return body.endswith(p)
        if mode == "contains":
            return p in body
        return body.startswith(p)

    return check


def install_custom_preset(pattern: str, mode: str, case_sensitive: bool = False, lang: str = "ru") -> None:
    """Регистрирует пользовательский паттерн под ключом CUSTOM_KEY во всех
    словарях NETWORK_PRESETS — дальше cpu_worker/keyhunt_worker подхватывают
    его как обычный пресет, без единой правки в main.py."""
    predicate = make_custom_predicate(pattern, mode, case_sensitive=case_sensitive)
    case_note = " [Aa]" if case_sensitive else ""
    if lang == "en":
        label = _CUSTOM_MODE_LABELS_EN.get(mode, mode)
        desc = f'Custom pattern: "{pattern}" ({label}){case_note}'
    else:
        label = _CUSTOM_MODE_LABELS.get(mode, mode)
        desc = f'Свой паттерн: "{pattern}" ({label}){case_note}'
    seen = set()
    for presets in NETWORK_PRESETS.values():
        if id(presets) in seen:
            continue
        seen.add(id(presets))
        presets[CUSTOM_KEY] = (desc, predicate)


def install_word_list(words: List[str]) -> None:
    """Подменяет patterns.SEARCH_WORDS на выбор пользователя (чекбоксы +
    свои слова в UI). Мутирует атрибут модуля, а не локальную привязку —
    предикат пресета "word" в patterns.py и все места в этом файле читают
    его через `patterns.SEARCH_WORDS`, так что подмена видна сразу везде,
    где к ней обращаются по имени модуля."""
    patterns.SEARCH_WORDS = tuple(w for w in words if w)


# Баланс ETH-адреса — это RPC-запрос (сотни мс — секунды), поэтому не
# блокирует основной цикл: считается в небольшом пуле фоновых потоков и
# прилетает отдельным событием "balance", когда будет готов. Пул с
# ограниченным числом воркеров — чтобы частые находки (например, при общем
# custom-паттерне) не открывали сотни параллельных соединений к публичной RPC.
_balance_executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="balance")


def fetch_balance_and_emit(seq: int, address: str) -> None:
    try:
        balances = asyncio.run(ETH().get_all_balances(address))
    except Exception:
        balances = None
    emit({
        "type": "balance",
        "seq": seq,
        "address": address,
        "balances": balances,
    })


def build_found_event(seq: int, network_name: str, address: str, private_key: str,
                       matched: List[str], is_fake: bool = False) -> dict:
    network_presets = NETWORK_PRESETS.get(network_name, PRESETS)
    matched_desc = [network_presets[n][0] for n in matched if n in network_presets]
    conditions_str = "; ".join(matched_desc)

    found_words = []
    if "word" in matched:
        found_words = [w for w in patterns.SEARCH_WORDS if contains_word(address, w, case_sensitive=False)]

    checksum_address = None
    if network_name == "eth" and core._TO_CHECKSUM:
        try:
            checksum = core._TO_CHECKSUM(address)
            checksum_address = checksum if checksum != address else None
        except Exception:
            checksum_address = None

    # Фейковые находки (--fake-found) не проверены на реальное совпадение паттерна —
    # пишем их в отдельную поддиректорию, чтобы не засорять настоящую историю results/.
    original_results_dir = core.RESULTS_DIR
    if is_fake:
        core.RESULTS_DIR = original_results_dir / "_fake_debug"
    try:
        filepath = save_result(network_name, address, private_key, matched, conditions_str)
    finally:
        core.RESULTS_DIR = original_results_dir

    return {
        "type": "found",
        "seq": seq,
        "network": network_name,
        "network_full": NETWORKS[network_name].name(),
        "address": address,
        "checksum_address": checksum_address,
        "private_key": private_key,
        "matched": matched,
        "matched_desc": matched_desc,
        "conditions_str": conditions_str,
        "found_words": found_words,
        "filepath": filepath,
        "found_at": datetime.now().isoformat(timespec="seconds"),
    }


def cpu_worker_with_custom(network_name: str, preset_key: str, result_queue: "mp.Queue",
                            stats_counter, worker_id: int,
                            custom_pattern: Optional[Tuple[str, str, bool]] = None,
                            words: Optional[List[str]] = None) -> None:
    """Обёртка над cpu_worker для mp.Process-воркеров.

    macOS использует multiprocessing 'spawn': каждый дочерний процесс —
    свежий интерпретатор, заново импортирующий patterns.py, поэтому
    install_custom_preset()/install_word_list(), вызванные в родителе, туда
    не долетают. Устанавливаем их здесь же, внутри воркера, до cpu_worker.
    """
    if custom_pattern:
        pattern, mode, case_sensitive = custom_pattern
        install_custom_preset(pattern, mode, case_sensitive=case_sensitive)
    if words is not None:
        install_word_list(words)
    cpu_worker(network_name, preset_key, result_queue, stats_counter, worker_id)


def find_ethvanity() -> Optional[str]:
    """Ищет встроенный ethvanity — быстрый Rust-акселератор ETH-поиска,
    который идёт в комплекте с приложением (не нужно ничего ставить отдельно).
    Сначала смотрим рядом с этим файлом — так он лежит и в собранном .app
    (Contents/Resources/PythonRuntime/ethvanity), и в репозитории при
    локальной сборке (ethvanity/target/release/ethvanity скопирован сюда же
    сборочным скриптом); потом — в PATH, на случай отдельной установки."""
    local = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ethvanity")
    if os.path.isfile(local) and os.access(local, os.X_OK):
        return local
    return shutil.which("ethvanity")


def ethvanity_worker(
    binary_path: str,
    preset_key: str,
    result_queue: "mp.Queue",
    stats_counter,
    stop_event,
    extra_prefixes: Optional[List[str]] = None,
    worker_override: Optional[int] = None,
) -> None:
    """Аналог keyhunt_worker для встроенного ethvanity. Проще и надёжнее:
    вывод сразу построчный JSON, не нужно парсить ANSI/regex терминального
    вывода стороннего инструмента."""
    hex_prefixes = sorted(set(list(core.ALL_PREFIXES) + list(extra_prefixes or [])))
    threads = worker_override or (os.cpu_count() or 4)

    cmd = [binary_path, "--threads", str(threads)]
    for p in hex_prefixes:
        cmd += ["--prefix", p]

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def _kill_on_stop() -> None:
        stop_event.wait()
        proc.kill()

    threading.Thread(target=_kill_on_stop, daemon=True).start()

    presets = PRESETS
    last_checked = 0

    for line in iter(proc.stdout.readline, ""):
        if not line:
            break
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue

        event_type = payload.get("type")
        if event_type == "stats":
            checked = payload.get("checked", 0)
            delta = checked - last_checked
            if delta > 0:
                with stats_counter.get_lock():
                    stats_counter.value += delta
                last_checked = checked
        elif event_type == "found":
            address = str(payload.get("address", "")).lower()
            private_key = str(payload.get("private_key", ""))
            matched = [
                name for name, (_, pred) in presets.items()
                if name != "all" and pred(address)
            ]
            if matched and (preset_key == "all" or preset_key in matched):
                result_queue.put(("eth", address, private_key, matched, 0))

    proc.kill()


def fake_found_worker(networks: List[str], preset_key: str, result_queue: "mp.Queue",
                       stats_counter, interval: float) -> None:
    """Отладочный воркер: генерирует реальные адреса случайных сетей и объявляет их
    "найденными" без проверки паттерна — нужен только чтобы прогнать UI на живых
    событиях, не дожидаясь настоящей редкой находки."""
    import random

    while True:
        time.sleep(interval)
        net = random.choice(networks)
        try:
            address, private_key = NETWORKS[net].generate()
        except Exception:
            continue

        presets = NETWORK_PRESETS.get(net, PRESETS)
        keys = [k for k in presets if k != "all"]
        if preset_key != "all" and preset_key in presets:
            matched = [preset_key]
        elif keys:
            matched = [random.choice(keys)]
        else:
            matched = ["all"]

        result_queue.put((net, address, private_key, matched, 0))
        with stats_counter.get_lock():
            stats_counter.value += random.randint(2000, 8000)


def _keyhunt_can_target_pattern(custom_pattern: Optional[Tuple[str, str, bool]]) -> bool:
    """True, если keyhunt способен реально искать заданный custom-паттерн
    (см. подробный комментарий в generate_vanity_json)."""
    if not custom_pattern:
        return True
    pattern, mode, _ = custom_pattern
    if mode != "prefix":
        return False
    if not re.fullmatch(r"[0-9a-fA-F]+", pattern):
        return False
    return len(pattern) % 2 == 0


def _keyhunt_can_target_all(hex_targets: List[str],
                             custom_pattern: Optional[Tuple[str, str, bool]]) -> bool:
    """True, если keyhunt способен покрыть ВЕСЬ набор целей разом: и
    custom-паттерн, и текущий список слов (см. комментарий в
    generate_vanity_json — keyhunt тихо роняет любую нечётную по длине
    hex-цель, не сообщая об этом ничем, кроме строки в собственном логе)."""
    if not _keyhunt_can_target_pattern(custom_pattern):
        return False
    return all(len(t) % 2 == 0 for t in hex_targets)


def generate_vanity_json(networks: List[str], preset_key: str,
                          fake_found_interval: Optional[float] = None,
                          worker_override: Optional[int] = None,
                          custom_pattern: Optional[Tuple[str, str, bool]] = None,
                          lang: str = "ru",
                          words: Optional[List[str]] = None) -> None:
    extra_hex_prefixes: List[str] = []
    if custom_pattern:
        pattern, mode, case_sensitive = custom_pattern
        install_custom_preset(pattern, mode, case_sensitive=case_sensitive, lang=lang)
        preset_key = CUSTOM_KEY
        if mode == "prefix" and re.fullmatch(r"[0-9a-fA-F]+", pattern):
            # Регистр не важен для keyhunt/ethvanity — они всё равно ищут по
            # сырому (нижнему) hex-представлению; итоговую проверку с учётом
            # регистра (по checksum) делает уже Python-предикат выше.
            extra_hex_prefixes.append(pattern.lower())

    # main.ALL_PREFIXES вычисляется ОДИН РАЗ при импорте main.py, из
    # дефолтного patterns.SEARCH_WORDS на тот момент — он не видит
    # install_word_list(), которая переустанавливает patterns.SEARCH_WORDS
    # уже после импорта (чекбоксы/свои слова из UI, см. install_word_list).
    # Без явной передачи ниже keyhunt_worker/ethvanity_worker продолжали бы
    # искать только по исходному дефолтному списку слов, полностью
    # игнорируя то, что пользователь выключил или добавил в UI.
    extra_hex_prefixes.extend(
        w.lower() for w in patterns.SEARCH_WORDS if re.fullmatch(r"[0-9a-fA-F]+", w)
    )
    extra_hex_prefixes = sorted(set(extra_hex_prefixes))

    valid_preset = preset_key == "all" or any(
        preset_key in NETWORK_PRESETS.get(n, PRESETS) for n in networks
    )
    if not valid_preset:
        emit({
            "type": "error",
            "message": f"unknown preset '{preset_key}' for networks {networks}",
            "fatal": True,
        })
        return

    stop_event = mp.Event()
    signal.signal(signal.SIGINT, lambda *_: stop_event.set())
    signal.signal(signal.SIGTERM, lambda *_: stop_event.set())

    # Ускоритель ETH-поиска: сперва пробуем keyhunt (если он установлен у
    # конкретного пользователя отдельно — GPU/OpenCL режим), иначе — встроенный
    # ethvanity (идёт в комплекте с приложением, CPU, без внешних зависимостей).
    #
    # У keyhunt (проверено эмпирически на реальном бинарнике, не задокументировано)
    # его флаг -v для ETH принимает ТОЛЬКО префиксы с чётным числом hex-символов
    # (внутри конвертирует строку в байты) и умеет искать ТОЛЬКО префикс, не
    # суффикс/подстроку. Если цель не подходит под это, keyhunt тихо пишет в
    # свой вывод `"..." was NOT Added` и продолжает работать, ничего реально
    # не ища — приложение показывало бы "Accelerated: keyhunt" и часами не
    # находило то, что на самом деле лежит в паттерне за секунды. Это касается
    # не только custom-паттерна: 3 из 10 дефолтных слов ("badbadbad",
    # "badc0de", "6666666") сами по себе нечётной длины и ВСЕГДА молча
    # отбрасывались keyhunt'ом, даже без единой настройки пользователем.
    # Поэтому берём ethvanity (без этого ограничения, матчит по отдельным
    # полубайтам), если keyhunt не может покрыть ВЕСЬ текущий набор целей —
    # custom-паттерн и текущий список слов вместе.
    eth_tool_path: Optional[str] = None
    eth_tool_name: Optional[str] = None
    if not fake_found_interval and "eth" in networks:
        keyhunt_path = find_keyhunt()
        if keyhunt_path and _keyhunt_can_target_all(extra_hex_prefixes, custom_pattern):
            eth_tool_path, eth_tool_name = keyhunt_path, "keyhunt"
        elif not custom_pattern or custom_pattern[1] == "prefix":
            ethvanity_path = find_ethvanity()
            if ethvanity_path:
                eth_tool_path, eth_tool_name = ethvanity_path, "ethvanity"
            elif keyhunt_path:
                # ethvanity недоступен, а keyhunt не может покрыть все текущие
                # цели — лучше честный CPU-перебор (найдёт всё, просто
                # медленнее), чем "ускоренный" поиск, который часть целей
                # молча не ищет.
                pass
        # suffix/contains custom-паттерн: ни keyhunt, ни ethvanity не умеют
        # искать не-префиксы — остаётся обычная CPU-генерация с полной
        # Python-проверкой предиката, она матчит любой режим корректно.

    eth_accelerated = eth_tool_path is not None
    cpu_nets = [n for n in networks if n != "eth" or not eth_accelerated]

    result_queue: Queue = mp.Queue()
    stats_counter = Value(ctypes.c_ulonglong, 0)

    procs: List = []
    # "Эффективный" параллелизм для отображения в UI: для GPU-режима (keyhunt)
    # это не число python-потоков (их всегда 1 — controller-thread), а число
    # -t threads, которые keyhunt поднимает у себя внутри.
    effective_workers = 0

    if fake_found_interval:
        t = threading.Thread(
            target=fake_found_worker,
            args=(networks, preset_key, result_queue, stats_counter, fake_found_interval),
            daemon=True,
        )
        t.start()
        procs.append(t)
        effective_workers = 1
    else:
        worker_pool = worker_override if worker_override else (os.cpu_count() or 8)

        if eth_accelerated:
            worker_fn = keyhunt_worker if eth_tool_name == "keyhunt" else ethvanity_worker
            t = threading.Thread(
                target=worker_fn,
                args=(eth_tool_path, preset_key, result_queue, stats_counter, stop_event,
                      extra_hex_prefixes, worker_override),
                daemon=True,
            )
            t.start()
            procs.append(t)
            effective_workers += worker_pool

        for net in cpu_nets:
            workers = max(1, worker_pool // len(networks))
            for i in range(workers):
                p = mp.Process(
                    target=cpu_worker_with_custom,
                    args=(net, preset_key, result_queue, stats_counter, i, custom_pattern, words),
                )
                p.start()
                procs.append(p)
            effective_workers += workers

    workers_total = effective_workers

    emit({
        "type": "started",
        "networks": networks,
        "networks_full": {n: NETWORKS[n].name() for n in networks},
        "preset": preset_key,
        "preset_desc": preset_description(preset_key, networks, lang=lang),
        "cpu_count": os.cpu_count() or 0,
        "workers_total": workers_total,
        "gpu": {"available": eth_accelerated, "path": eth_tool_path, "tool": eth_tool_name},
        "fake": bool(fake_found_interval),
    })

    stdin_thread = threading.Thread(target=stdin_listener, args=(stop_event,), daemon=True)
    stdin_thread.start()

    def stats_loop() -> None:
        start_time = time.time()
        # (время, счётчик) на момент старта — база для окна.
        window: "deque[Tuple[float, int]]" = deque([(start_time, 0)], maxlen=SPEED_WINDOW_TICKS + 1)
        while not stop_event.is_set():
            time.sleep(STATS_UPDATE_INTERVAL)
            now = time.time()
            current = stats_counter.value
            elapsed = now - start_time

            oldest_time, oldest_count = window[0]
            dt = now - oldest_time
            # Скорость — средняя за последние ~SPEED_WINDOW_TICKS секунд, а не
            # мгновенная дельта: сглаживает как рывки апстрима (keyhunt отдаёт
            # прогресс пачками), так и дрожание планировщика под полной
            # нагрузкой CPU, без искусственной задержки реакции на тренд.
            speed = int((current - oldest_count) / dt) if dt > 0 else 0

            emit({
                "type": "stats",
                "elapsed_seconds": round(elapsed, 1),
                "total_checked": current,
                "speed": speed,
                "workers_total": workers_total,
            })
            window.append((now, current))

    stats_thread = threading.Thread(target=stats_loop, daemon=True)
    stats_thread.start()

    found_count = 0
    detailed_emitted = 0
    throttled_notified = False
    start_time = time.time()
    try:
        while not stop_event.is_set():
            try:
                network_name, address, private_key, matched, _ = result_queue.get(timeout=0.5)
            except Exception:
                continue
            found_count += 1

            # Слишком "широкий" паттерн (короткий префикс и т.п.) может давать
            # тысячи находок в секунду — запись файла + JSON на каждую забивает
            # диск и присылающий канал. После потолка продолжаем СЧИТАТЬ находки
            # (счётчик/редкость остаются точными), но перестаём писать файлы,
            # эмитить детальные события и дёргать RPC на баланс.
            if detailed_emitted < MAX_DETAILED_FINDS:
                detailed_emitted += 1
                emit(build_found_event(found_count, network_name, address, private_key, matched,
                                        is_fake=bool(fake_found_interval)))
                if network_name == "eth":
                    # Демо-режим тоже безопасно фетчит баланс — интервал там
                    # фиксирован (~1.25 находки/с), ни на диск, ни на RPC не давит.
                    _balance_executor.submit(fetch_balance_and_emit, found_count, address)
            elif not throttled_notified:
                throttled_notified = True
                if lang == "en":
                    message = (
                        f"Too many matches (pattern is very common) — "
                        f"showing the first {MAX_DETAILED_FINDS}, the rest are only counted"
                    )
                else:
                    message = (
                        f"Находок слишком много (паттерн очень широкий) — "
                        f"показаны первые {MAX_DETAILED_FINDS}, дальше только считаются"
                    )
                emit({
                    "type": "error",
                    "fatal": False,
                    "message": message,
                })
    finally:
        stop_event.set()
        for p in procs:
            if isinstance(p, mp.Process):
                p.terminate()

        total = stats_counter.value
        elapsed = time.time() - start_time
        emit({
            "type": "stopped",
            "reason": "user_stop",
            "total_checked": total,
            "found_count": found_count,
            "elapsed_seconds": round(elapsed, 1),
            "rarity_1_in": (total // found_count) if found_count > 0 else None,
        })


# ============================================================================
# Оценка редкости условий поиска — приблизительная (алфавит сети x длина
# паттерна), чтобы в UI было видно, чего ожидать от условия ДО запуска —
# как для встроенных пресетов, так и (на стороне Swift, по тем же константам)
# для собственного паттерна пользователя.
# ============================================================================

ALPHABET_SIZES = {"sol": 58, "eth": 16, "trx": 58, "ton": 64}
BODY_LENGTHS = {"sol": 44, "eth": 40, "trx": 34, "ton": 46}


def _poisson_tail_rarity(mean: float, k: int) -> Optional[int]:
    """≈ 1/P(X ≥ k) для X ~ Poisson(mean) — ведущий член хвоста распределения."""
    if mean <= 0:
        return None
    try:
        p = (mean ** k) * math.exp(-mean) / math.factorial(k)
    except OverflowError:
        return None
    return int(1 / p) if p > 0 else None


def estimate_rarity(preset_key: str, network: str) -> Optional[int]:
    """Грубая оценка «1 из N» для встроенного пресета на конкретной сети."""
    alphabet = ALPHABET_SIZES.get(network, 58)
    body_len = BODY_LENGTHS.get(network, 40)

    def anchored_run(n: int) -> int:
        return alphabet ** (n - 1)

    if preset_key in ("suffix10", "prefix10"):
        return anchored_run(10)
    if preset_key == "prefix5":
        return anchored_run(5)
    if preset_key == "deadprefixsuffix":
        return alphabet ** 8
    if preset_key == "word":
        total_p = sum(2 * (alphabet ** -len(w)) for w in patterns.SEARCH_WORDS)
        return int(1 / total_p) if total_p > 0 else None
    if preset_key == "same6":
        mean = body_len * (alphabet ** -5)
        return int(1 / mean) if mean > 0 else None
    if preset_key == "pairs8":
        return _poisson_tail_rarity(body_len / alphabet, 8)
    if preset_key == "repeat2x4":
        mean = body_len * (alphabet ** -6)
        return int(1 / mean) if mean > 0 else None
    if preset_key == "all":
        total_p = 0.0
        for k in NETWORK_PRESETS.get(network, PRESETS):
            if k == "all":
                continue
            r = estimate_rarity(k, network)
            if r:
                total_p += 1 / r
        return int(1 / total_p) if total_p > 0 else None
    return None


def emit_presets() -> None:
    """Самоописание доступных сетей/пресетов для UI — чтобы не дублировать
    и не рассинхронизировать этот список в Swift-коде."""
    presets_by_network = {
        net: [
            {"key": k, "description": desc, "rarity_1_in": estimate_rarity(k, net)}
            for k, (desc, _) in presets.items()
        ]
        for net, presets in NETWORK_PRESETS.items()
    }
    emit({
        "type": "presets",
        "network_order": list(NETWORKS.keys()),
        "networks": {k: NETWORKS[k].name() for k in NETWORKS},
        "presets_by_network": presets_by_network,
        "alphabet_sizes": ALPHABET_SIZES,
        "body_lengths": BODY_LENGTHS,
        "default_words": list(patterns.SEARCH_WORDS),
    })


def main() -> None:
    args = sys.argv[1:]
    positional = [a for a in args if not a.startswith("--")]

    lang = "ru"
    if "--lang" in args:
        idx = args.index("--lang")
        try:
            candidate = args[idx + 1].strip().lower()
            if candidate in ("en", "ru"):
                lang = candidate
        except IndexError:
            pass
    apply_language(lang)

    words_override: Optional[List[str]] = None
    if "--words" in args:
        idx = args.index("--words")
        try:
            raw = args[idx + 1]
        except IndexError:
            raw = ""
        words_override = [w.strip() for w in raw.split(",") if w.strip()]
        install_word_list(words_override)

    if "--list-presets" in args:
        emit_presets()
        return

    fake_found_interval: Optional[float] = None
    if "--fake-found" in args:
        idx = args.index("--fake-found")
        try:
            fake_found_interval = float(args[idx + 1])
        except (IndexError, ValueError):
            fake_found_interval = 1.0

    worker_override: Optional[int] = None
    if "--workers" in args:
        idx = args.index("--workers")
        try:
            worker_override = max(1, int(args[idx + 1]))
        except (IndexError, ValueError):
            worker_override = None

    custom_pattern: Optional[Tuple[str, str, bool]] = None
    if "--custom" in args:
        idx = args.index("--custom")
        try:
            raw = args[idx + 1]  # формат "mode:pattern"
        except IndexError:
            raw = ""
        mode, _, pattern = raw.partition(":")
        mode = mode.strip().lower() if mode.strip().lower() in ("prefix", "suffix", "contains") else "prefix"
        pattern = pattern.strip()
        if pattern:
            custom_pattern = (pattern, mode, "--custom-case" in args)

    if not positional:
        emit({
            "type": "error",
            "message": "usage: bridge.py <networks> <preset> [--json] [--fake-found <seconds>] [--workers <n>]",
            "fatal": True,
        })
        sys.exit(1)

    networks_arg = positional[0].lower()
    preset_key = positional[1] if len(positional) > 1 else "all"

    if networks_arg == "all":
        networks = list(NETWORKS.keys())
    else:
        networks = [n.strip() for n in networks_arg.split(",")]
        invalid = [n for n in networks if n not in NETWORKS]
        if invalid:
            emit({"type": "error", "message": f"unknown networks: {invalid}", "fatal": True})
            sys.exit(1)

    generate_vanity_json(networks, preset_key, fake_found_interval, worker_override, custom_pattern,
                          lang=lang, words=words_override)


if __name__ == "__main__":
    main()
