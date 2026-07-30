"""Быстрый тест генерации адресов для всех сетей."""
from networks import NETWORKS

print("Тест генерации адресов:\n")

for net_id, generator in NETWORKS.items():
    print(f"{generator.name()}:")
    try:
        for i in range(3):
            address, private = generator.generate()
            print(f"  {i+1}. {address}")
    except Exception as e:
        print(f"  Ошибка: {e}")
    print()
