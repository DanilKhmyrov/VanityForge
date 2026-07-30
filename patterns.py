"""
Общие паттерны "красоты" для адресов любых сетей.
"""
import re


def _body(addr: str) -> str:
    """Возвращает адрес без известных префиксов (0x, EQ, UQ)."""
    if addr.startswith("0x"):
        return addr[2:]
    if addr.startswith(("EQ", "UQ")) and len(addr) > 2:
        return addr[2:]
    return addr


def has_n_same_chars(addr: str, n: int = 5) -> bool:
    """N одинаковых символов подряд."""
    return bool(re.search(r"(.)\1{" + str(n - 1) + r"}", _body(addr)))


def has_same_suffix(addr: str, n: int = 4) -> bool:
    """Последние n символов одинаковые."""
    b = _body(addr)
    if len(b) < n:
        return False
    return len(set(b[-n:])) == 1


def has_same_prefix(addr: str, n: int = 4) -> bool:
    """Первые n символов (без префикса) одинаковые."""
    b = _body(addr)
    if len(b) < n:
        return False
    return len(set(b[:n])) == 1


def is_sequential_hex(addr: str) -> bool:
    """Шестигранник: 0123456789abcdef"""
    hex_seq = '0123456789abcdef'
    if hex_seq in _body(addr).lower():
        return True
    return False


def has_sequence(addr: str, seq: str = "12345") -> bool:
    """Содержит последовательность."""
    b = _body(addr)
    return seq in b or seq.lower() in b.lower()


def is_palindrome_snippet(addr: str, length: int = 6) -> bool:
    """Есть кусок length символов - палиндром."""
    b = _body(addr)
    for i in range(len(b) - length + 1):
        chunk = b[i: i + length]
        if chunk == chunk[::-1]:
            return True
    return False


def contains_word(addr: str, word: str, case_sensitive: bool = True) -> bool:
    """Адрес (без префикса) начинается или заканчивается на word."""
    if not word:
        return False
    b = _body(addr)
    if case_sensitive:
        return b.startswith(word) or b.endswith(word)
    a, w = b.lower(), word.lower()
    return a.startswith(w) or a.endswith(w)


def has_ascending_sequence(addr: str, length: int = 4) -> bool:
    """Есть возрастающая последовательность цифр."""
    b = _body(addr)
    digits = "0123456789"
    for i in range(len(digits) - length + 1):
        if digits[i: i + length] in b:
            return True
    return False


def has_descending_sequence(addr: str, length: int = 4) -> bool:
    """Есть убывающая последовательность цифр."""
    b = _body(addr)
    digits = "9876543210"
    for i in range(len(digits) - length + 1):
        if digits[i: i + length] in b:
            return True
    return False


def has_repeated_pattern(addr: str, pattern_len: int = 2, repeats: int = 3) -> bool:
    """Повторяющийся паттерн (например: ababab, 123123123)."""
    b = _body(addr)
    for i in range(len(b) - pattern_len * repeats + 1):
        pattern = b[i: i + pattern_len]
        full_pattern = pattern * repeats
        if full_pattern in b[i:]:
            return True
    return False


def is_symmetric(addr: str) -> bool:
    """Адрес (без префикса) симметричен (полный палиндром)."""
    return _body(addr) == _body(addr)[::-1]


def has_only_letters(addr: str) -> bool:
    """Только буквы (без цифр) в теле адреса."""
    return _body(addr).isalpha()


def has_only_digits(addr: str) -> bool:
    """Только цифры (без букв) в теле адреса."""
    return _body(addr).isdigit()


def has_alternating_case(addr: str, length: int = 6) -> bool:
    """Чередование заглавных/строчных букв."""
    b = _body(addr)
    for i in range(len(b) - length + 1):
        chunk = b[i: i + length]
        if all(
            (j % 2 == 0 and c.isupper()) or (j % 2 == 1 and c.islower())
            for j, c in enumerate(chunk)
            if c.isalpha()
        ):
            return True
    return False


# ============================================================================
# TON-специфичные паттерны (для base64 адресов)
# ============================================================================

def ton_no_special_chars(addr: str, min_length: int = 20) -> bool:
    """TON: нет специальных символов (+/=) на большой длине."""
    body = addr[2:] if addr.startswith(("EQ", "UQ")) else addr
    clean_length = 0
    max_clean = 0
    for char in body:
        if char.isalnum():
            clean_length += 1
            max_clean = max(max_clean, clean_length)
        else:
            clean_length = 0
    return max_clean >= min_length


def ton_many_uppercase(addr: str, min_count: int = 8) -> bool:
    """TON: много заглавных букв подряд."""
    body = addr[2:] if addr.startswith(("EQ", "UQ")) else addr
    count = 0
    max_count = 0
    for char in body:
        if char.isupper() and char.isalpha():
            count += 1
            max_count = max(max_count, count)
        else:
            count = 0
    return max_count >= min_count


def ton_many_lowercase(addr: str, min_count: int = 8) -> bool:
    """TON: много строчных букв подряд."""
    body = addr[2:] if addr.startswith(("EQ", "UQ")) else addr
    count = 0
    max_count = 0
    for char in body:
        if char.islower() and char.isalpha():
            count += 1
            max_count = max(max_count, count)
        else:
            count = 0
    return max_count >= min_count


def ton_same_char_after_prefix(addr: str, n: int = 4) -> bool:
    """TON: одинаковые символы сразу после EQ/UQ."""
    if not addr.startswith(("EQ", "UQ")):
        return False
    body = addr[2:]
    if len(body) < n:
        return False
    return len(set(body[:n])) == 1


def ton_nice_ending(addr: str, min_alpha: int = 6) -> bool:
    """TON: красивое окончание - только буквы/цифры (без +/=)."""
    if len(addr) < min_alpha:
        return False
    ending = addr[-min_alpha:]
    return all(c.isalnum() for c in ending)

def dead_prefix_suffix(a: str) -> bool:
    b = _body(a).lower()
    return b.startswith("dead") and b.endswith("dead")

def ton_repeating_pairs(addr: str, pair_repeats: int = 3) -> bool:
    """TON: повторяющиеся пары символов (AA, BB, CC и т.д.)."""
    body = addr[2:] if addr.startswith(("EQ", "UQ")) else addr
    pairs_found = 0
    i = 0
    while i < len(body) - 1:
        if body[i] == body[i + 1] and body[i].isalnum():
            pairs_found += 1
            if pairs_found >= pair_repeats:
                return True
            i += 2
        else:
            i += 1
    return False


# Дефолтные слова для условия "word" (адрес начинается или заканчивается
# одним из них) — настраиваются в приложении: можно выключать эти и
# добавлять свои.
SEARCH_WORDS = (
    'deaddead', 'badbadbad', 'badc0de', 'deadc0de', '6666666',
    'deadd00d', 'cafebabe', 'facade', 'ghost', 'phantom',
)

# ============================================================================
# Пресеты для Solana, Ethereum, Tron (стандартные адреса)
# ============================================================================

PRESETS_STANDARD = {
    "suffix10": ("Конец: 10 одинаковых", lambda a: has_same_suffix(a, 10)),
    "prefix10": ("Начало: 10 одинаковых", lambda a: has_same_prefix(a, 10)),
    "deadprefixsuffix": ("Префикс DEAD + суффикс DEAD", lambda a: dead_prefix_suffix(a)),
    "word": ("Слово из списка", lambda a: any(contains_word(a, w) for w in SEARCH_WORDS)),
    "all": ("Любое условие", lambda a: False),
}

# ============================================================================
# Пресеты для TON (base64 адреса с - + / =)
# ============================================================================

PRESETS_TON = {
    "same6": ("6 одинаковых подряд", lambda a: has_n_same_chars(a, 6)),
    "prefix5": ("EQ+5 одинаковых", lambda a: ton_same_char_after_prefix(a, 5)),
    "pairs8": ("8+ двойных пар", lambda a: ton_repeating_pairs(a, 8)),
    "repeat2x4": ("Повтор паттерна 2x4", lambda a: has_repeated_pattern(a, 2, 4)),
    "word": ("Слово из списка", lambda a: any(contains_word(a, w) for w in SEARCH_WORDS)),
    "all": ("Любое условие", lambda a: False),
}

# Английские переводы описаний пресетов (ключ -> текст) — используются
# bridge.py при --lang en вместо русских описаний выше. Сами предикаты и
# ключи пресетов от языка не зависят, поэтому это отдельная плоская таблица,
# а не дублирование PRESETS_STANDARD/PRESETS_TON целиком.
PRESET_DESC_EN = {
    "suffix10": "Ends: 10 same chars",
    "prefix10": "Starts: 10 same chars",
    "deadprefixsuffix": "Prefix DEAD + suffix DEAD",
    "word": "Word from list",
    "all": "Any condition",
    "same6": "6 same chars in a row",
    "prefix5": "EQ+5 same chars",
    "pairs8": "8+ double pairs",
    "repeat2x4": "Repeating 2x4 pattern",
}

# Хex-префиксы, которые keyhunt должен искать напрямую, по ключу пресета.
PRESET_KEYHUNT_PREFIXES: dict[str, list[str]] = {
    "deadprefixsuffix": ["dead"],
}

NETWORK_PRESETS = {
    "sol": PRESETS_STANDARD,
    "eth": PRESETS_STANDARD,
    "trx": PRESETS_STANDARD,
    "ton": PRESETS_TON,
}

PRESETS = PRESETS_STANDARD
