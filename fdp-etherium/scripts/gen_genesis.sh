#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# Generate EL (geth) + CL (beacon) genesis with current timestamp.
# Called by bench.sh at the start of each benchmark run.
# ═══════════════════════════════════════════════════════════════════════
#
# Outputs (in testnet/):
#   genesis.json  — EL genesis for `geth init`
#   genesis.ssz   — CL genesis for `lighthouse bn --testnet-dir`
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$SCRIPT_DIR/../testnet"

export PATH="$HOME/go/bin:$PATH"

log() { echo "[$(date +%H:%M:%S)] GEN: $*"; }

# ── Validate prerequisites ────────────────────────────────────────────
for cmd in eth2-testnet-genesis; do
  if ! command -v "$cmd" &>/dev/null; then
    log "ERROR: $cmd not found. Run setup_testnet.sh first."
    exit 1
  fi
done
for f in "$TESTNET_DIR/config.yaml" "$TESTNET_DIR/mnemonics.yaml"; do
  if [ ! -f "$f" ]; then
    log "ERROR: $f not found. Run setup_testnet.sh first."
    exit 1
  fi
done

# ── Parameters ────────────────────────────────────────────────────────
CHAIN_ID=32382
DEV_ADDRESS="71562b71999873DB5b286dF957af199Ec94617F7"
BG_ADDRESS="f39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
TIMESTAMP=$(date +%s)
TIMESTAMP_HEX=$(printf '0x%x' "$TIMESTAMP")

log "Generating genesis (chainId=$CHAIN_ID, timestamp=$TIMESTAMP)"

# ── 1. Create EL genesis.json ────────────────────────────────────────
cat > "$TESTNET_DIR/genesis.json" << ELEOF
{
  "config": {
    "chainId": $CHAIN_ID,
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "muirGlacierBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "mergeNetsplitBlock": 0,
    "terminalTotalDifficulty": 0,
    "terminalTotalDifficultyPassed": true,
    "shanghaiTime": $TIMESTAMP,
    "cancunTime": $TIMESTAMP,
    "blobSchedule": {
      "cancun": {
        "target": 3,
        "max": 6,
        "baseFeeUpdateFraction": 3338477
      }
    }
  },
  "nonce": "0x0",
  "timestamp": "$TIMESTAMP_HEX",
  "extraData": "0x",
  "gasLimit": "0x11e1a300",
  "difficulty": "0x1",
  "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "coinbase": "0x0000000000000000000000000000000000000000",
  "alloc": {
    "$DEV_ADDRESS": {
      "balance": "0x200000000000000000000000000000000000000000000000000000000000000"
    },
    "$BG_ADDRESS": {
      "balance": "0x200000000000000000000000000000000000000000000000000000000000000"
    }
  }
}
ELEOF

log "Created genesis.json"

# ── 2. Generate CL genesis.ssz ───────────────────────────────────────
log "Running eth2-testnet-genesis deneb ..."
cd "$TESTNET_DIR"
eth2-testnet-genesis deneb \
  --config "$TESTNET_DIR/config.yaml" \
  --mnemonics "$TESTNET_DIR/mnemonics.yaml" \
  --eth1-config "$TESTNET_DIR/genesis.json"

if [ ! -f "$TESTNET_DIR/genesis.ssz" ]; then
  log "ERROR: genesis.ssz was not created"
  exit 1
fi

# ── 3. Lighthouse requires deposit_contract_block.txt + deploy_block.txt ──
echo "0" > "$TESTNET_DIR/deposit_contract_block.txt"
echo "0" > "$TESTNET_DIR/deploy_block.txt"

SSZ_SIZE=$(stat -c %s "$TESTNET_DIR/genesis.ssz" 2>/dev/null || echo "?")
log "Genesis generation complete"
log "  EL genesis : $TESTNET_DIR/genesis.json"
log "  CL genesis : $TESTNET_DIR/genesis.ssz ($SSZ_SIZE bytes)"
log "  Genesis time: $TIMESTAMP ($(date -d @"$TIMESTAMP" '+%H:%M:%S'))"
