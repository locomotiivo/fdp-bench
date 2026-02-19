#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# sui-bench/scripts/env.sh — Sui-specific environment
# ═══════════════════════════════════════════════════════════════════════
#
# Sources common/ for shared FDP/mount infrastructure, then defines
# Sui-specific paths, binaries, and FDP configuration.

[[ -n "${_SUI_ENV_SOURCED:-}" ]] && return 0
_SUI_ENV_SOURCED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared infrastructure
source "$SCRIPT_DIR/../../common/env.sh"

# ── Sui Binaries ─────────────────────────────────────────────────────
SUI_BENCH_BIN="${SUI_BENCH_BIN:-$HOME/sui-fdp/target/release/sui-single-node-benchmark}"

# ── Benchmark Parameters ─────────────────────────────────────────────
NUM_ROUNDS="${NUM_ROUNDS:-10}"
TX_COUNT="${TX_COUNT:-20000}"
NUM_BATCHES="${NUM_BATCHES:-10}"
NUM_TRANSFERS="${NUM_TRANSFERS:-10}"
NUM_MINTS="${NUM_MINTS:-4}"
NFT_SIZE="${NFT_SIZE:-8000}"

# Benchmark component:
# - "baseline": execution + storage only (fastest, no consensus overhead)
# - "validator-with-fake-consensus": full validator pipeline (most realistic)
BENCH_COMPONENT="${BENCH_COMPONENT:-validator-with-fake-consensus}"

# RocksDB tuning
export MAX_WRITE_BUFFER_SIZE_MB="${MAX_WRITE_BUFFER_SIZE_MB:-64}"
export MAX_WRITE_BUFFER_NUMBER="${MAX_WRITE_BUFFER_NUMBER:-2}"

# ── Store paths (depend on STREAMS set by caller) ─────────────────────
# FDP mode: store goes into p1 (RocksDB manages WAL/SST placement)
# Non-FDP:  store goes into p7 (single stream)
sui_store_path() {
  local mode="$1"
  if [[ "$mode" == "fdp" ]]; then
    echo "$MOUNT_POINT/p1/aaaaaaaaaaaa/sui_bench"
  else
    echo "$MOUNT_POINT/p7/bbbbbbbbbbbb/sui_bench"
  fi
}

# ── FDP environment for Sui ──────────────────────────────────────────
set_sui_fdp_env() {
  local mode="$1"
  if [[ "$mode" == "fdp" ]]; then
    export SUI_FDP_WAL_SEMANTIC=1
    export SUI_FDP_BASE_PATH="$MOUNT_POINT"
    export SUI_FDP_HOT_SIZE_MB=64
  else
    unset SUI_FDP_WAL_SEMANTIC SUI_FDP_BASE_PATH SUI_FDP_HOT_SIZE_MB \
          SUI_FDP_ENABLED SUI_FDP_SEMANTIC 2>/dev/null || true
  fi
}

# Results directory
RESULTS_DIR="$SCRIPT_DIR/../results"
