"""
Побочный улов: пока видеокарта ищет заданный шаблон, она проверяет миллиарды
адресов, и среди выброшенных попадаются красивые сами по себе — длинная серия
одинаковых символов на краю или слово из словаря в начале либо в конце.
metalvanity-evm ловит их на том же проходе (--bycatch-run / --bycatch-word),
здесь — словарь и разбор находки для карточки.

Слова — английские, записанные «хакерским» hex: o → 0, i и l → 1, s → 5,
t → 7, g → 9, z → 2 (deadc0ffee, 5ca1ab1e…). Не короче 9 символов: слово из 8
встречается у 90 млн адресов/с примерно раз в минуту на каждое слово, и лента
утонула бы в находках. Серия — от 9 одинаковых символов (раз в ~25 с на M4).
"""
from typing import Dict, List, Optional

MIN_RUN = 9
MIN_WORD = 9

_LEET = {**{c: c for c in "abcdef0123456789"}, "o": "0", "i": "1", "l": "1", "s": "5", "t": "7", "g": "9", "z": "2"}

# Слово (как читается) — hex получается заменами из _LEET.
_WORDS = (
    # мемы и фразы
    "deadcoffee", "badcoffee", "coffeebabe", "coffeecode", "goodcoffee", "decafcoffee", "deadbeefcafe",
    "cafebabe1337", "1337c0de", "facefeedbabe", "feedfacecafe", "acefacade", "boldbeef", "goodfood1337",
    # числа
    "0123456789", "123456789", "1234567890", "987654321", "9876543210", "0123456789abcdef", "fedcba9876543210",
    # английские слова
    "accessible", "associate", "associated", "celestial", "classical", "classified", "classless",
    "collected", "collectable", "collectible", "debatable", "decidable", "dedicated", "defeatist",
    "deletable", "desiccate", "detectable", "detestable", "dialectic", "dislocated", "dissected",
    "facilitate", "flagellate", "floodgate", "lifeblood", "satisfied", "sabbatical", "selectable",
    "sidesaddle", "steadfast", "stateside", "battlefield", "closefisted", "falsifiable", "disaffected",
    "localizable", "tessellated", "decolletage", "ecclesiastic", "gibblegabble", "fiddledeedee",
    "afflicted", "affiliate", "adiabatic", "calcified", "castigate", "bellicose", "ceaseless",
    "deflected", "disbelief", "effaceable", "delectable", "defoliate", "toastable", "scaffolded",
    "fossilized", "bottlefed", "tasteless", "blissless", "cascaded", "accolades", "decodable",
    "fabledfoe", "cabbaged", "basicallyfee",
)


def _hex(word: str) -> Optional[str]:
    if not all(c in _LEET for c in word):
        return None
    return "".join(_LEET[c] for c in word)


# hex → слово; только слова, которые записываются целиком и не короче MIN_WORD.
WORDS: Dict[str, str] = {}
for _w in _WORDS:
    _h = _hex(_w)
    if _h and len(_h) >= MIN_WORD and _h not in WORDS:
        WORDS[_h] = _w


def engine_args(run: int = MIN_RUN) -> List[str]:
    args = ["--bycatch-run", str(run)]
    for hex_word in WORDS:
        args += ["--bycatch-word", hex_word]
    return args


def _run(body: str, from_end: bool) -> int:
    text = body[::-1] if from_end else body
    return len(text) - len(text.lstrip(text[0]))


def classify(address: str, min_run: int = MIN_RUN) -> Optional[dict]:
    """Чем красив адрес EVM (0x…), или None. Из нескольких причин — самая редкая.
    rarity_1_in — шанс именно этого вида у случайного адреса: серия длины n на
    краю — 16^(n−1), конкретное слово длины n на краю — 16^n."""
    body = address.lower().removeprefix("0x")
    if len(body) != 40:
        return None
    options = []
    for where, from_end in (("start", False), ("end", True)):
        run = _run(body, from_end)
        if run >= min_run:
            text = body[-run:] if from_end else body[:run]
            options.append({"kind": "run", "where": where, "text": text, "word": None, "length": run,
                            "rarity_1_in": 16 ** (run - 1)})
    for hex_word, word in WORDS.items():
        for where, hit in (("start", body.startswith(hex_word)), ("end", body.endswith(hex_word))):
            if hit:
                options.append({"kind": "word", "where": where, "text": hex_word, "word": word,
                                "length": len(hex_word), "rarity_1_in": 16 ** len(hex_word)})
    if not options:
        return None
    return max(options, key=lambda o: o["rarity_1_in"])


def describe(info: dict, lang: str = "ru") -> str:
    where_ru = {"start": "в начале", "end": "в конце"}[info["where"]]
    where_en = {"start": "at the start", "end": "at the end"}[info["where"]]
    if info["kind"] == "run":
        n, ch = info["length"], info["text"][0]
        return (f"{n} × «{ch}» {where_en}" if lang == "en" else f"{n} × «{ch}» {where_ru}")
    word = info["word"] if info["word"] != info["text"] else info["text"]
    return (f"«{word}» {where_en}" if lang == "en" else f"«{word}» {where_ru}")
