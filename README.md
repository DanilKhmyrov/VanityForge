**English** | [Русский](README.ru.md)

# VanityForge

A generator for "vanity" crypto addresses: **Solana**, **EVM (ETH, BSC, Polygon, etc.)**, **Tron**, **TON**. Comes in two forms — a native macOS app (live stats, a speed chart, a searchable find history) and a plain CLI script, both built on the same Python engine.

## Features

- Search up to 4 networks at once, with built-in condition presets (repeated characters, palindromes, word lists, sequences…) plus a case-sensitive custom pattern
- UI in Russian and English, switchable at runtime
- Live speed chart, CPU/memory/GPU usage
- Rarity indicator and estimated time-to-find for every condition
- EVM search acceleration kicks in automatically, nothing to install separately (details below)
- Full find history, organized by network and condition

## Installation

### Option 1 — .dmg (easiest)

1. Download `VanityForge.dmg` from [Releases](../../releases)
2. Open it, drag `VanityForge.app` into `Applications`
3. On first launch — right-click the app → "Open" (it isn't signed with an Apple Developer certificate, so Gatekeeper will ask for confirmation once)

The Python runtime, all dependencies, and the EVM search accelerator are already packaged inside the `.app` — nothing else to install.

### Option 2 — build from source

You'll need:
- Xcode Command Line Tools (`xcode-select --install`) — to build the Swift app
- [Rust](https://rustup.rs) — to build `ethvanity` (optional: the app still works without it, just without CPU acceleration for EVM search)

No need to install Python separately — the build script downloads a self-contained runtime on its own (it doesn't touch your system Python or any of your venvs).

```bash
git clone git@github.com:DanilKhmyrov/VanityForge.git
cd VanityForge/VanityForge
./Scripts/make_app.sh      # builds VanityForge.app
open VanityForge.app

# or build the .dmg directly for distribution:
./Scripts/make_dmg.sh
```

## How EVM search acceleration works

Vanity address search is bottlenecked by how fast you can try keys. For EVM networks (the address and private key are identical whether you call it Ethereum, BSC, Polygon, Arbitrum, or any other EVM-compatible chain), the app picks the best of two available accelerators automatically:

1. **`keyhunt`**, if installed separately and visible on `PATH` — a third-party tool; some builds have a GPU/OpenCL mode and are usually the fastest option. The app doesn't install or bundle it itself: the provenance and licensing of the modified `keyhunt` builds floating around online aren't always clear, and shipping an unverified third-party binary alongside your own app is a bad idea.
2. **[`ethvanity`](ethvanity)** (GPL-3.0, source included right in this repo) — a Rust accelerator written specifically for this project. Instead of a full elliptic-curve point multiplication per candidate (as in naive generation), it derives the next address via point addition — `P(k+1) = P(k) + G` — through the safe, audited API of the `secp256k1` crate, plus prefix comparison works on raw nibbles instead of formatting every candidate as a hex string. That's roughly a 7x speedup over naive Python/coincurve generation. It's built automatically by `make_app.sh`/`make_dmg.sh` and bundled inside the `.app` — works for everyone out of the box, no manual step required.

If neither is available (or for the other networks, which don't have a GPU/ethvanity mode), the app falls back to regular multi-process Python generation.

## CLI version (no app)

If you don't need the GUI and just want a console script:

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python3 main.py <networks> [condition]
```

### Examples

```bash
python3 main.py sol same5        # Solana, 5 same chars in a row
python3 main.py all all          # all networks, any condition
python3 main.py eth,sol word     # EVM and Solana, search by word list
```

## Supported networks

- `sol` — Solana
- `ton` — TON
- `eth` — EVM (ETH, BSC, Polygon, etc. — the same address/key works on all of them)
- `trx` — Tron
- `all` — all networks at once

## Search conditions

### Repeated characters
- `same5` / `same6` / `same7` / `same8` / `same9` — N identical characters in a row

### End of address
- `suffix4`…`suffix8` — last N characters are identical

### Start of address
- `prefix4`…`prefix8` — first N characters are identical

### Sequences
- `seq12345` / `seq123456` — contains a numeric sequence
- `ascending4` / `ascending5`, `descending4` / `descending5`

### Palindromes
- `palindrome6` / `palindrome8` / `palindrome12` / `palindrome20`, `symmetric`

### Repeats
- `repeat2x3` / `repeat3x3`

### Word list
- `word` — address contains a word from the list

### Custom pattern
- In the app — any string (prefix/suffix/contains), with an optional case-sensitive toggle

### Any
- `all` — any condition from the list above

### For TON (base64 addresses)
- `same7` / `prefix5` / `pairs10` / `repeat2x3` / `word`

## Be careful with custom patterns

The shorter and more "popular" a pattern, the more often it matches — a short 2-3 character prefix comes up very often (with a 16-character hex alphabet, a two-character prefix is 1 in 256 addresses). The app caps how many finds it processes in detail per session, but you should still be careful with very broad patterns: start with 4+ characters and don't leave a search running for long if you're not sure how rare the pattern actually is.

## Save file structure

```
results/
├── sol/
│   ├── same5/
│   │   └── 20250205_143022_GxCRRRRR.txt
│   └── word/
├── eth/
├── trx/
└── ton/
```

Each file contains: network, address, private key, conditions, time found.

**Private keys are stored in these files in plain text.** This is an address-generation tool, not a wallet — move any keys you find into secure storage (a hardware wallet, a password manager) and don't keep `results/` around longer than you need to.

## Performance (M4 Mac, 1 core)

| Network | addr/s | Algorithm |
|---------|--------|-----------|
| Solana | ~15,000 | Ed25519 (solders) |
| EVM | ~41,000 | secp256k1 (coincurve) |
| EVM (`ethvanity`) | ~280,000 | secp256k1, incremental point addition |
| Tron | ~40,000 | secp256k1 + Base58 |
| TON | ~50,000 | tonsdk |

More detail — [PERFORMANCE.md](PERFORMANCE.md).

## License

[GPL-3.0](LICENSE)
