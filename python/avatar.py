"""
Аватарки blockies — квадратные «пиксельные» иконки адреса в Etherscan и
MetaMask (ethereum/blockies). Иконка однозначно выводится из адреса в нижнем
регистре, поэтому её, как и сам адрес, можно подбирать перебором ключей.

Алгоритм ethereum/blockies: сид — строка «0x…»; четыре 32-битных слова
h = h·31 + символ по кругу; затем xorshift128. Сдвиги в нём знаковые, у
результата старший бит всегда 0, поэтому rand() = u / 2^31 лежит в [0, 1):
оттенок — floor(rand·360), насыщенность rand·60 + 40 %, яркость
(rand+rand+rand+rand)·25 % (колокол вокруг 50, белых и чёрных почти нет),
клетка — floor(rand·2.3): 0 фон (43%), 1 цвет (43%), 2 пятна (13%). Сначала три
цвета (цвет, фон, пятна), затем 8 строк по 4 клетки (правая половина — зеркало).

Сравнение идёт целыми числами — так же, как в ядре metalvanity-evm
(avatar_hit) и в его хосте, чтобы все три проверки совпадали бит в бит.

Описание цели — строка `cells=<32 символа>;miss=N;color=h1-h2/l1-l2;bg=…;spot=…`:
клетки построчно, «.» — любая, b — фон, c — цвет, s — пятна; оттенок h1-h2 в
градусах (h1 > h2 — через 0°), яркость l1-l2 в процентах (0-200 — любая).
Яркость в blockies меньше 100 и редко выходит за 15..85.
"""
from typing import List, Optional, Tuple

CELLS = 32
ANY_COLOR = (0, 359, 0, 200)
_CELL_CODES = {".": 3, "b": 0, "c": 1, "s": 2}
SLOTS = ("color", "bg", "spot")


def _seed(address: str) -> List[int]:
    s = [0, 0, 0, 0]
    for i, ch in enumerate(address.lower()):
        s[i % 4] = (s[i % 4] * 31 + ord(ch)) & 0xFFFFFFFF
    return s


def _to_i32(x: int) -> int:
    return x - (1 << 32) if x & 0x80000000 else x


def _stream(address: str):
    """Сырые 32-битные значения rand() (до деления на 2^31)."""
    s = _seed(address)
    while True:
        t = (s[0] ^ (s[0] << 11)) & 0xFFFFFFFF
        s[0], s[1], s[2] = s[1], s[2], s[3]
        s3 = _to_i32(s[3])
        s[3] = (s3 ^ (s3 >> 19) ^ _to_i32(t) ^ (_to_i32(t) >> 8)) & 0xFFFFFFFF
        yield s[3]


def blockie(address: str) -> dict:
    """Цвета (оттенок, насыщенность %, яркость %) и 64 клетки 8×8 — как их рисует браузер."""
    rand = (u / 2 ** 31 for u in _stream(address))
    colors = []
    for _ in SLOTS:
        hue = int(next(rand) * 360) % 360
        sat = min(100.0, next(rand) * 60 + 40)
        light = min(100.0, (next(rand) + next(rand) + next(rand) + next(rand)) * 25)
        colors.append((hue, sat, light))
    cells = []
    for _ in range(8):
        row = [min(2, int(next(rand) * 2.3)) for _ in range(4)]
        cells += row + row[::-1]
    return {"color": colors[0], "bg": colors[1], "spot": colors[2], "cells": cells}


class AvatarSpec:
    def __init__(self, cells: List[int], misses: int, colors: List[Tuple[int, int, int, int]]):
        self.cells = cells
        self.misses = misses
        self.colors = colors

    @classmethod
    def parse(cls, spec: str) -> "AvatarSpec":
        cells = [3] * CELLS
        misses = 0
        colors = [ANY_COLOR] * 3
        for part in (p.strip() for p in spec.split(";")):
            if not part:
                continue
            name, sep, value = part.partition("=")
            if not sep:
                raise ValueError("avatar spec: expected name=value")
            if name == "cells":
                if len(value) != CELLS or any(c not in _CELL_CODES for c in value):
                    raise ValueError("avatar spec: cells must be 32 of . b c s")
                cells = [_CELL_CODES[c] for c in value]
            elif name == "miss":
                misses = int(value)
            elif name in SLOTS:
                hue, _, light = value.partition("/")
                h1, h2 = (int(v) for v in hue.split("-"))
                l1, l2 = (int(v) for v in light.split("-"))
                if not (0 <= h1 <= 359 and 0 <= h2 <= 359 and l1 <= l2):
                    raise ValueError("avatar spec: color is hue-hue/light-light")
                colors[SLOTS.index(name)] = (h1, h2, l1, l2)
            else:
                raise ValueError(f"avatar spec: unknown part {name}")
        return cls(cells, misses, colors)

    def matches(self, address: str) -> bool:
        if not address.startswith("0x") or len(address) != 42:
            return False
        rand = _stream(address)
        for h1, h2, l1, l2 in self.colors:
            hue = ((next(rand) * 360) >> 31) % 360
            next(rand)
            l25 = (next(rand) + next(rand) + next(rand) + next(rand)) * 25
            hue_ok = (h1 <= hue <= h2) if h1 <= h2 else (hue >= h1 or hue <= h2)
            if not hue_ok or l25 < (l1 << 31) or l25 > (l2 << 31):
                return False
        miss = 0
        for want in self.cells:
            cell = min(2, (next(rand) * 23) // (10 << 31))
            if want != 3 and want != cell:
                miss += 1
                if miss > self.misses:
                    return False
        return True

    def constrained(self) -> int:
        return sum(1 for c in self.cells if c != 3)

    def describe(self, lang: str = "ru") -> str:
        n = self.constrained()
        if lang == "en":
            text = f"Avatar: {n} of 32 cells"
            if self.misses:
                text += f", up to {self.misses} off"
        else:
            text = f"Аватарка: {n} из 32 клеток"
            if self.misses:
                text += f", до {self.misses} мимо"
        colored = sum(1 for c in self.colors if c != ANY_COLOR)
        if colored:
            text += (f", colors: {colored}" if lang == "en" else f", цвета: {colored}")
        return text


def parse(spec: Optional[str]) -> Optional[AvatarSpec]:
    return AvatarSpec.parse(spec) if spec else None
