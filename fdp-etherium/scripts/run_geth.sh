#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# Start geth (EL) with Engine API + FDP-aware data placement
# ═══════════════════════════════════════════════════════════════════════
#
# Geth connects to Lighthouse (CL) via the Engine API (JWT-authenticated).
# Block production is driven by the CL — geth builds execution payloads
# on demand when Lighthouse requests them.
#
# Directory layout (8 FDP PIDs, EL uses p0-p3 + p6-p7):
#
#   p0/wal/         Pebble WAL files (.log)         — HOTTEST
#   p1/sst_flush/   Pebble flush L0 SSTs            — HOT
#   p2/sst_l0cmp/   Pebble L0→Lbase compaction SSTs — WARM
#   p3/chaindata/   Pebble deep SSTs + MANIFEST     — COOL  (chaindata root)
#   p6/ancient/     Ancient/freezer block archive    — COLDEST
#   p7/gethdata/    geth --datadir  (nodekey, LOCK)  — COLDEST
#   p7/logs/        Geth stdout/stderr log           — COLDEST
#
# The custom FDP VFS (pebble_fdp.go) routes SSTs by TEMPERATURE TIER:
#   Tier 0 (FLUSH)  = memtable flush output  → p1/sst_flush/
#   Tier 1 (L0_CMP) = L0→Lbase compaction   → p2/sst_l0cmp/
#   Tier 2 (DEEP)   = Lbase→L6 compaction   → p3/chaindata/ (default)
#
# ── Geth flags vs Ethereum mainnet ──────────────────────────────────
#
#   Flag / Setting        Mainnet     Ours       Why
#   ──────────────────  ─────────  ─────────  ─────────────────────────────────
#   --miner.gaslimit     30 M       500 M      ~17× mainnet gas per block.
#                                              Combined with 4s slots gives
#                                              ~50× mainnet gas throughput
#                                              (125M gas/s vs 2.5M gas/s)
#                                              compressing months of state
#                                              growth into hours.  The I/O
#                                              pattern (MPT trie updates, LSM
#                                              compactions) is identical — only
#                                              the rate is accelerated.
#   --cache              4096+      2048       Conservative; still caches most
#                                              active state → fast EVM reads.
#   --state.scheme       hash       hash       Matches majority of mainnet nodes.
#   --gcmode             full       full       Matches mainnet default.
#   --snapshot           true       false      Snap layer masks trie read I/O.
#                                              Disabling it forces all state reads
#                                              through MPT on disk → benchmark is
#                                              sensitive to both read & write SSD.
#   --txpool.globalslots 4096       200000     Purely in-memory buffer.  Absorbs
#                                              spammer bursts for consistent
#                                              measurement.  No SSD I/O effect.
#   Pebble compression   Snappy     off        Eliminates compression-ratio
#                                              variability for deterministic
#                                              WAF measurement.  Standard in
#                                              storage-systems evaluation.
#   Pebble memtable      256 MB     64 MB      Resource-constrained validator
#                                              (≤8 GB RAM / --cache 512).
#                                              All other LSM params are
#                                              upstream defaults.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/helpers.sh"

if [ ! -x "$GETH_BIN" ]; then
  echo "Error: Geth binary not found at $GETH_BIN" >&2
  exit 1
fi

# ── Create FDP directory structure ────────────────────────────────────
mkdir -p "$DIR_WAL" "$DIR_FLUSH" "$DIR_L0CMP" "$DIR_CHAINDATA" \
         "$DIR_ANCIENT" "$DIR_LOGS"

# Geth creates $DATA_ROOT/geth/chaindata/ on startup.
# Pre-create the path as a symlink to p3/chaindata/ so that the Pebble
# database (and L3+ SSTs) physically reside under the COOL PID.
GETH_INTERNAL="$DATA_ROOT/geth"
mkdir -p "$GETH_INTERNAL"
if [ ! -e "$GETH_INTERNAL/chaindata" ]; then
  ln -s "$DIR_CHAINDATA" "$GETH_INTERNAL/chaindata"
  log "Symlinked chaindata → $DIR_CHAINDATA"
elif [ -L "$GETH_INTERNAL/chaindata" ]; then
  : # already a symlink — OK
else
  log "WARNING: $GETH_INTERNAL/chaindata exists as a real directory"
fi

# ── FDP environment variables for the patched Pebble wrapper ─────────
# Only enable the FDP VFS when using multiple placement IDs.
if [[ "${STREAMS:-8}" -gt 1 ]]; then
  export GETH_FDP_ENABLED=1
  export GETH_FDP_WAL_DIR="$DIR_WAL"
  export GETH_FDP_FLUSH_DIR="$DIR_FLUSH"
  export GETH_FDP_L0CMP_DIR="$DIR_L0CMP"
  log "FDP VFS ENABLED (STREAMS=$STREAMS)"
else
  export GETH_FDP_ENABLED=0
  log "FDP VFS DISABLED (STREAMS=${STREAMS:-1}, non-FDP baseline)"
fi

# ── Pebble tuning: two changes with academic justification ────────
#
# 1. Disable SST compression (GETH_PEBBLE_NO_COMPRESSION=1)
#    Eliminates data-entropy-dependent variability in physical write
#    volume.  WAF measurements become deterministic: same logical
#    workload → same physical bytes.  Standard practice in storage-
#    systems evaluation (USENIX FAST / HotStorage FDP & ZNS papers).
#
# 2. 16 MB memtable (GETH_PEBBLE_MEMTABLE_MB=16)
#    Represents a resource-constrained validator node (--cache 512,
#    8 GB RAM) — a common deployment on commodity cloud instances
#    (ethernodes.org shows >30% of nodes with ≤16 GB RAM).  Smaller
#    memtable → more frequent flushes → higher Pebble WAF → faster
#    SSD fill (needed to trigger FEMU GC within Phase 1's budget).
#    This is a deployment-level resource choice, not an LSM-algorithm
#    change.
#
# All other LSM parameters (LBase, L0 thresholds, level file sizes)
# remain at upstream go-ethereum v1.16.8 defaults.
#
export GETH_PEBBLE_NO_COMPRESSION="${GETH_PEBBLE_NO_COMPRESSION:-1}"
export GETH_PEBBLE_MEMTABLE_MB="${GETH_PEBBLE_MEMTABLE_MB:-16}"
log "Pebble: compression=off, memtable=${GETH_PEBBLE_MEMTABLE_MB}MB, LBase=64MB(default), L0compact=2(default), L0stop=12(default)"

# ── Generate JWT secret if missing ───────────────────────────────────
if [ ! -f "$JWT_SECRET" ]; then
  openssl rand -hex 32 | tr -d '\n' > "$JWT_SECRET"
  log "Generated JWT secret: $JWT_SECRET"
fi

# ── Initialize chain from genesis ────────────────────────────────────
GENESIS_JSON="$TESTNET_DIR/genesis.json"
if [ ! -f "$GENESIS_JSON" ]; then
  log "ERROR: $GENESIS_JSON not found. Run gen_genesis.sh first."
  exit 1
fi

log "Initializing geth with genesis.json ..."
"$GETH_BIN" init --datadir "$DATA_ROOT" --state.scheme hash "$GENESIS_JSON" 2>&1 | tail -3
log "Geth init complete"

# ── Log FDP layout ───────────────────────────────────────────────────
log "Launching geth (Engine API) with FDP data placement"
log "  WAL     → $PID_WAL   ($DIR_WAL)"
log "  Flush   → $PID_FLUSH    ($DIR_FLUSH)"
log "  L0→Lb  → $PID_L0CMP   ($DIR_L0CMP)"
log "  Deep/DB → $PID_CHAINDATA ($DIR_CHAINDATA)"
log "  Ancient → $PID_ANCIENT   ($DIR_ANCIENT)"
log "  Meta    → $PID_META  ($DATA_ROOT)"
log "  JWT     → $JWT_SECRET"

# ── Launch geth with Engine API ──────────────────────────────────────
exec "$GETH_BIN" \
  --datadir "$DATA_ROOT" \
  --datadir.ancient "$DIR_ANCIENT" \
  --networkid 32382 \
  --nodiscover \
  --syncmode full \
  --gcmode full \
  --state.scheme hash \
  --cache 2048 \
  --http --http.api eth,net,txpool,debug,admin,miner,web3 \
  --http.addr 0.0.0.0 \
  --http.port 8545 \
  --rpc.txfeecap 0 \
  --ws --ws.api eth,net,txpool,debug,admin,miner,web3 \
  --authrpc.addr 0.0.0.0 \
  --authrpc.port "$ENGINE_API_PORT" \
  --authrpc.jwtsecret "$JWT_SECRET" \
  --authrpc.vhosts "*" \
  --miner.gaslimit 500000000 \
  --metrics --metrics.addr 127.0.0.1 --metrics.port 6060 \
  --pprof --pprof.addr 0.0.0.0 --pprof.port 6061 \
  --txpool.globalslots 200000 \
  --snapshot=false \
  --verbosity 3 \
  > "$DIR_LOGS/geth.log" 2>&1
