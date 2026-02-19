#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# One-time setup: install CL tools and pre-generate validator keystores
# ═══════════════════════════════════════════════════════════════════════
#
# Run this ONCE before benchmarking.  It:
#   1. Downloads the Lighthouse CL binary
#   2. Installs eth2-testnet-genesis (Go tool for CL genesis)
#   3. Installs eth2-val-tools (Go tool for validator keystores)
#   4. Generates 64 validator keystores from a deterministic mnemonic
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Tunables ──────────────────────────────────────────────────────────
LIGHTHOUSE_VERSION="${LIGHTHOUSE_VERSION:-v8.1.0}"
LIGHTHOUSE_URL="https://github.com/sigp/lighthouse/releases/download/${LIGHTHOUSE_VERSION}/lighthouse-${LIGHTHOUSE_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
LIGHTHOUSE_DIR="$HOME/lighthouse"
LIGHTHOUSE_BIN="$LIGHTHOUSE_DIR/lighthouse"

TESTNET_DIR="$SCRIPT_DIR/../testnet"
VALIDATOR_COUNT=64
MNEMONIC="test test test test test test test test test test test junk"

export PATH="$HOME/go/bin:$PATH"

log() { echo "[$(date +%H:%M:%S)] SETUP: $*"; }

# ── 1. Lighthouse binary ─────────────────────────────────────────────
if [ ! -x "$LIGHTHOUSE_BIN" ]; then
  log "Downloading Lighthouse ${LIGHTHOUSE_VERSION} ..."
  mkdir -p "$LIGHTHOUSE_DIR"
  curl -fSL "$LIGHTHOUSE_URL" | tar xz -C "$LIGHTHOUSE_DIR"
  chmod +x "$LIGHTHOUSE_BIN"
  log "Lighthouse installed: $("$LIGHTHOUSE_BIN" --version 2>&1 | head -1)"
else
  log "Lighthouse already installed: $("$LIGHTHOUSE_BIN" --version 2>&1 | head -1)"
fi

# ── 2. eth2-testnet-genesis ──────────────────────────────────────────
if ! command -v eth2-testnet-genesis &>/dev/null; then
  log "Installing eth2-testnet-genesis ..."
  go install github.com/protolambda/eth2-testnet-genesis@latest
  log "Installed: $(eth2-testnet-genesis version 2>&1 || true)"
else
  log "eth2-testnet-genesis already installed"
fi

# ── 3. eth2-val-tools ────────────────────────────────────────────────
if ! command -v eth2-val-tools &>/dev/null; then
  log "Installing eth2-val-tools ..."
  go install github.com/protolambda/eth2-val-tools@latest
  log "Installed eth2-val-tools"
else
  log "eth2-val-tools already installed"
fi

# ── 4. Generate validator keystores ──────────────────────────────────
KEYS_DIR="$TESTNET_DIR/validator_keys"
if [ ! -d "$KEYS_DIR/keys" ]; then
  log "Generating $VALIDATOR_COUNT validator keystores ..."
  mkdir -p "$KEYS_DIR"
  eth2-val-tools keystores \
    --source-mnemonic "$MNEMONIC" \
    --source-min 0 --source-max "$VALIDATOR_COUNT" \
    --out-loc "$KEYS_DIR"
  NUM_KEYS=$(ls "$KEYS_DIR/keys" 2>/dev/null | wc -l)
  log "Generated $NUM_KEYS validator keystores in $KEYS_DIR/"
else
  NUM_KEYS=$(ls "$KEYS_DIR/keys" 2>/dev/null | wc -l)
  log "Validator keys already exist ($NUM_KEYS keys)"
fi

# ── Summary ───────────────────────────────────────────────────────────
log "═══ Setup complete ═══"
log "  Lighthouse : $LIGHTHOUSE_BIN"
log "  Genesis gen: $(command -v eth2-testnet-genesis)"
log "  Val tools  : $(command -v eth2-val-tools)"
log "  Testnet dir: $TESTNET_DIR"
log "  Val count  : $VALIDATOR_COUNT"
log ""
log "Next: run ./bench.sh (it calls gen_genesis.sh automatically)"
