import hashlib
import base58
import ecdsa
import secrets

def generate_brain_wallet(phrase: str) -> dict:
    """
    Генерация Bitcoin адреса из фразы (brain wallet)
    ⚠️ ТОЛЬКО ДЛЯ ОБУЧЕНИЯ! НЕ ИСПОЛЬЗУЙТЕ ДЛЯ РЕАЛЬНЫХ ДЕНЕГ!
    """
    
    # 1. Превращаем фразу в приватный ключ (256 бит)
    # ВАЖНО: используется SHA256, который даёт 32 байта
    private_key_bytes = hashlib.sha256(phrase.encode('utf-8')).digest()
    
    # 2. Приватный ключ в hex формате
    private_key_hex = private_key_bytes.hex()
    
    # 3. Генерируем публичный ключ через secp256k1 (кривая Bitcoin)
    # Используем библиотеку ecdsa
    sk = ecdsa.SigningKey.from_string(private_key_bytes, curve=ecdsa.SECP256k1)
    vk = sk.get_verifying_key()
    public_key_bytes = b'\x04' + vk.to_string()  # uncompressed format (0x04 + X + Y)
    
    # 4. SHA256 от публичного ключа
    sha256_public = hashlib.sha256(public_key_bytes).digest()
    
    # 5. RIPEMD160 от результата (это и есть адрес без чексуммы)
    ripemd160 = hashlib.new('ripemd160')
    ripemd160.update(sha256_public)
    public_key_hash = ripemd160.digest()
    
    # 6. Добавляем версию сети (0x00 для Bitcoin mainnet)
    network_byte = b'\x00' + public_key_hash
    
    # 7. Дважды SHA256 для чексуммы
    checksum = hashlib.sha256(hashlib.sha256(network_byte).digest()).digest()[:4]
    
    # 8. Финальный адрес (Base58Check кодирование)
    address_bytes = network_byte + checksum
    bitcoin_address = base58.b58encode(address_bytes).decode('utf-8')
    
    return {
        'phrase': phrase,
        'private_key_hex': private_key_hex,
        'bitcoin_address': bitcoin_address
    }

# Пример использования:
brain_wallet = generate_brain_wallet("test")
print(f"Фраза: {brain_wallet['phrase']}")
print(f"Приватный ключ: {brain_wallet['private_key_hex']}")
print(f"Bitcoin адрес: {brain_wallet['bitcoin_address']}")