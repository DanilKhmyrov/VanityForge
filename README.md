**English** | [Русский](README.ru.md)

# VanityForge

A generator for "vanity" crypto addresses: **EVM (ETH, BSC, Polygon, etc.)**, **Tron**, **Solana**, **TON**, plus vanity **smart-contract addresses** (CREATE2/CREATE3). A native macOS app and a CLI, both on the same engines; EVM and TRON search runs on the Apple Silicon GPU.

![VanityForge finding vanity addresses on the GPU](docs/demo.gif)

## Features

- **Wallets:** presets (10 identical characters at the start or end, DEAD…DEAD, a word from your list) or your own pattern — start, end or anywhere, with or without case sensitivity
- **GPU (Metal):** EVM and TRON at tens of millions of addresses per second; the load can be capped at 25/50/75%
- **Contracts:** mining a salt for CREATE2 or CREATE3 (CreateX) — leading zeros, zero bytes, a prefix, Uniswap v4 hook flags
- **Split-key:** mine a vanity EVM/TRON address for a client who sends only a public key — only they will know the private key
- Exact rarity and time estimates, the chance of having found something by now; impossible patterns are flagged before the start
- Find cards with the matching part highlighted, a QR code, a block-explorer link; history of all finds
- The Mac doesn't sleep during a search, a find counter on the Dock icon, notifications; UI in English and Russian

## Installation

**From a release:** download `VanityForge.dmg` from [Releases](../../releases) and drag the app into `Applications`. The app isn't notarized: on first launch go to System Settings → Privacy & Security → Open Anyway. The Python runtime and all engines are inside the `.app`.

**From source:** you need Xcode Command Line Tools (`xcode-select --install`) and [Rust](https://rustup.rs) for the engines. Python is downloaded by the build script as a self-contained runtime.

```bash
git clone git@github.com:DanilKhmyrov/VanityForge.git
cd VanityForge/app
./scripts/make_app.sh      # VanityForge.app (./scripts/make_dmg.sh — the .dmg)
open VanityForge.app
```

## Speed (MacBook Air M4)

| What | Engine | Addresses/s |
|---|---|---|
| EVM: start / end / anywhere | GPU, `metalvanity-evm` | ~90M |
| TRON: start | GPU | ~60M |
| TRON: end / anywhere | GPU | ~25M |
| EVM, GPU off | CPU, `ethvanity` | ~10M |
| Solana | CPU, 10 processes | ~50–90K |
| TON, new wallet | CPU, 10 processes | ~120 |
| TON, subwallet of an existing key | CPU, `ethvanity` | ~7.5M |
| Contracts CREATE2 / CREATE3 | GPU, `metalvanity` | ~170M / ~60M |

Figures are for a cool machine: a fanless MacBook Air slows down after a few minutes under load (we saw the GPU drop from ~90M to 40–60M).

## How the search works

EVM and TRON go to the GPU; with the GPU off, EVM is searched by `ethvanity` (Rust, CPU, the same window trick with one batched inversion per 1025 points). Solana and TON run on the CPU. Python is only a fallback for when the engines aren't built.

- **`metalvanity-evm`** ([engines/metalvanity-evm](engines/metalvanity-evm)) — secp256k1 and keccak in a Metal kernel. Each thread checks a window of points Q ± j·G with one batched inversion per 513 points. The same pass checks TRON: a base58 prefix becomes a numeric range, the end and the middle of the address are checked via sha256d and base58 on the GPU.
- Every find is re-derived from its private key on the CPU twice (libsecp256k1, then coincurve) before it is shown. Each GPU thread starts from its own random key, all starts are reseeded every 30 s.
- **TON:** a new key is derived from a mnemonic (PBKDF2), so only ~120 addresses/s. It is much faster to search a vanity address for an existing wallet by its subwallet number: 2^32 options in about 10 minutes, the key and the mnemonic stay the same (`python3 python/bridge.py --ton-subwallet <public key or address> --custom prefix:ABC`).

## Contracts (CREATE2 / CREATE3)

The address of a CREATE2 contract is `keccak256(0xff ++ factory ++ salt ++ keccak256(code))[12:]`; VanityForge iterates the salt. **CREATE3** via CreateX doesn't depend on the code: mine a salt once, deploy any contract later. There are no private keys: the result is a salt, which can be handed to the client as is. The first 20 bytes of the salt are the client's wallet, so nobody else can use the salt (or front-run it).

```bash
python3 python/create2.py --init-code-hash 0x… --caller 0x… --goal leading --min 4
python3 python/create2.py --kind create3 --caller 0x… --goal leading --min 4
```

`--goal`: `leading`, `zeros`, `prefix` (with `--prefix dead`), `hook` (with `--hook-flags 00C0`); `--factory`: `immutable` (default), `arachnid` or any address.

## Split-key

The client runs `python3 python/splitkey.py new` and sends only the public key. The app looks for a tweak k such that the address of P + k·G is pretty; the client builds the key themselves: `python3 python/splitkey.py combine <their private key> <k> [eth|trx]`. Works for EVM and TRON, on the GPU too.

## CLI

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r python/requirements.txt
python3 python/main.py eth prefix10     # EVM, 10 identical characters at the start
python3 python/main.py eth,trx word     # EVM and Tron, a word from the list
```

Networks: `eth`, `trx`, `sol`, `ton`, `all`. Conditions: `prefix10`, `suffix10`, `deadprefixsuffix`, `word`, `all`; for TON — `same6`, `prefix5`, `pairs8`, `repeat2x4`, `word`. The CLI uses the same engines as the app (GPU for EVM and TRON); custom patterns are available in the app.

## Where finds are saved

The app keeps them in `~/Library/Application Support/VanityForge/results/` (the "Results folder" button), the CLI in `results/` in the current folder: one file per find with the network, address, key (or salt / tweak k), conditions and time.

**Private keys are stored in plain text.** This is a generator, not a wallet: move the keys you need into secure storage and don't keep `results/` longer than necessary.

## Repository layout

```
app/                     macOS app (SwiftUI) and build scripts (app/scripts)
engines/ethvanity/       Rust, CPU: EVM wallets, CREATE2/CREATE3, TON subwallets
engines/metalvanity/     Swift + Metal, GPU: CREATE2/CREATE3
engines/metalvanity-evm/ Rust + Metal, GPU: EVM and TRON wallets
python/                  bridge.py (app ↔ engines), CLI main.py, create2/splitkey/tonsub
docs/                    roadmap, demo
```

## License

[GPL-3.0](LICENSE)
