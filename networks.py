"""
Генераторы адресов для разных блокчейнов.
"""
import hashlib
import os
import secrets
from typing import Protocol, Tuple

# Импорты для быстрой генерации ETH/TRON (вынесены на уровень модуля для скорости)
try:
    from coincurve import PrivateKey
    from Crypto.Hash import keccak
    _KECCAK = keccak.new(digest_bits=256)
    HAS_FAST_EC = True
except ImportError:
    _KECCAK = None
    HAS_FAST_EC = False

BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def base58check_encode(payload: bytes, version_byte: int = 0x41) -> str:
    """Base58Check encoding для Tron адресов."""
    data = bytes([version_byte]) + payload
    checksum = hashlib.sha256(hashlib.sha256(data).digest()).digest()[:4]
    data_wc = data + checksum

    leading_zeros = 0
    for b in data_wc:
        if b == 0:
            leading_zeros += 1
        else:
            break

    n = int.from_bytes(data_wc, 'big')
    result = []
    while n > 0:
        n, r = divmod(n, 58)
        result.append(BASE58_ALPHABET[r])

    return "T" + "1" * leading_zeros + "".join(reversed(result))


class NetworkGenerator(Protocol):
    """Интерфейс для генераторов адресов."""

    @staticmethod
    def generate() -> Tuple[str, str]:
        """Генерирует (адрес, приватный_ключ)."""
        ...

    @staticmethod
    def name() -> str:
        """Название сети."""
        ...


class SolanaGenerator:
    """Генератор Solana-адресов."""

    @staticmethod
    def generate() -> Tuple[str, str]:
        from solders.keypair import Keypair

        keypair = Keypair()
        return str(keypair.pubkey()), str(keypair)

    @staticmethod
    def name() -> str:
        return "Solana"


class TonGenerator:
    """Генератор TON-адресов."""

    @staticmethod
    def generate() -> Tuple[str, str]:
        try:
            from tonsdk.utils import bytes_to_b64str
            from tonsdk.contract.wallet import Wallets, WalletVersionEnum

            mnemonics, pub_k, priv_k, wallet = Wallets.create(
                WalletVersionEnum.v4r2, workchain=0
            )
            address = wallet.address.to_string(True, True, True)
            private_key_b64 = bytes_to_b64str(priv_k)
            return address, private_key_b64
        except ImportError as e:
            print(e)
            import base64
            pk = os.urandom(32)
            mock_addr = "EQ" + base64.b64encode(os.urandom(32)).decode()[:46]
            return mock_addr, base64.b64encode(pk).decode()

    @staticmethod
    def name() -> str:
        return "TON"


def _derive_eth_key() -> Tuple[str, str]:
    """Быстрая генерация secp256k1 ключа и hex-адреса.
    Используется Ethereum и Tron.
    """
    private_key_bytes = os.urandom(32)
    private_key_obj = PrivateKey(private_key_bytes)
    public_key_bytes = private_key_obj.public_key.format(compressed=False)[1:]
    h = _KECCAK.new()
    h.update(public_key_bytes)
    address = "0x" + h.hexdigest()[-40:]
    return address, private_key_bytes.hex()


class EthGenerator:
    """Генератор Ethereum-адресов."""

    @staticmethod
    def generate() -> Tuple[str, str]:
        if HAS_FAST_EC:
            return _derive_eth_key()
        try:
            from eth_account import Account
            account = Account.create()
            return account.address, account.key.hex()
        except ImportError:
            private_key = secrets.token_hex(32)
            address = "0x" + secrets.token_hex(20)
            return address, private_key

    @staticmethod
    def name() -> str:
        # Адрес и приватный ключ — стандартные secp256k1/Keccak-256, те же,
        # что у любой EVM-совместимой сети (одна и та же пара работает и в
        # MetaMask на BSC/Polygon/Arbitrum и т.д.) — название отражает это,
        # а не ограничивает находку одним только Ethereum mainnet.
        return "EVM (ETH, BSC, Polygon)"


class TronGenerator:
    """Генератор Tron-адресов (совместим с EVM, адрес в Base58Check с T)."""

    @staticmethod
    def generate() -> Tuple[str, str]:
        if HAS_FAST_EC:
            hex_addr, priv_key = _derive_eth_key()
            raw_bytes = bytes.fromhex(hex_addr[2:])
            tron_addr = base58check_encode(raw_bytes, version_byte=0x41)
            return tron_addr, priv_key
        try:
            from eth_account import Account
            account = Account.create()
            raw_bytes = bytes.fromhex(account.address[2:])
            tron_addr = base58check_encode(raw_bytes, version_byte=0x41)
            return tron_addr, account.key.hex()
        except ImportError:
            private_key = secrets.token_hex(32)
            tron_addr = "T" + secrets.token_hex(20)[:33]
            return tron_addr, private_key

    @staticmethod
    def name() -> str:
        return "Tron"


NETWORKS = {
    "sol": SolanaGenerator,
    "ton": TonGenerator,
    "eth": EthGenerator,
    "trx": TronGenerator,
}
