"""Тест TON-специфичных паттернов."""
from patterns import PRESETS_TON

# Тестовые TON адреса
test_addresses = [
    "EQaaaaabcdefghijklmnopqrstuvwxyz123456",  # много a подряд
    "EQABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh",    # много заглавных
    "EQabcdefghijklmnopqrstuvwxyzABCDEFGH",    # много строчных
    "EQAAAA1234567890BCDEFGHIJKLMNOP",         # EQ+4 одинаковых
    "EQxyz+abc/def=ghi",                       # спецсимволы
    "EQxyzabcdefghijklmnopqrstABCDEF",         # 20+ без спецсимволов
    "EQaabbccddee1234567890",                  # двойные пары
    "EQ12345678901234567890abcdefgh",          # красивый конец
]

print("🧪 Тест TON паттернов:\n")

for addr in test_addresses:
    print(f"Адрес: {addr}")
    matched = []
    for name, (desc, pred) in PRESETS_TON.items():
        if name != "all" and pred(addr):
            matched.append(f"{name} ({desc})")
    
    if matched:
        print(f"  ✅ Совпадения: {', '.join(matched)}")
    else:
        print(f"  ❌ Не совпало")
    print()
