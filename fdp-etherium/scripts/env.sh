#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# Ethereum-specific environment for FDP benchmarks (EL + CL)
# ═══════════════════════════════════════════════════════════════════════
#
# Sources common/env.sh, then adds Ethereum-specific paths, keys,
# and the FDP PID-to-directory mapping for Geth/Pebble + Lighthouse.
#
[[ -n "${_ETH_ENV_SOURCED:-}" ]] && return 0
_ETH_ENV_SOURCED=1

ETH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common environment (device, mount, fdp_stats, SSH config)
source "$ETH_SCRIPT_DIR/../../common/env.sh"

# ── Binaries ──────────────────────────────────────────────────────────
export GETH_BIN="${GETH_BIN:-$HOME/go-ethereum/build/bin/geth}"
export LIGHTHOUSE_BIN="${LIGHTHOUSE_BIN:-$HOME/lighthouse/lighthouse}"

# ── Accounts ──────────────────────────────────────────────────────────
export DEV_PRIVKEY="b71c71a67e1177ad4e901695e1b4b9ee17ae16c6668d313eac2f96dbcda3f291"
export DEV_ADDRESS="0x71562b71999873DB5b286dF957af199Ec94617F7"

# Background churn account (separate nonce space from DEV_PRIVKEY)
export BG_PRIVKEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
export BG_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# ── Testnet config directory (on main FS, not FDP mount) ──────────────
export TESTNET_DIR="${TESTNET_DIR:-$ETH_SCRIPT_DIR/../testnet}"

# ── Engine API (EL ↔ CL communication) ───────────────────────────────
export ENGINE_API_PORT="${ENGINE_API_PORT:-8551}"
export ENGINE_API_URL="http://localhost:${ENGINE_API_PORT}"
export BEACON_API_PORT="${BEACON_API_PORT:-5052}"
export BEACON_API_URL="http://localhost:${BEACON_API_PORT}"

# ═══════════════════════════════════════════════════════════════════════
# FDP PID-to-directory mapping  (EL Geth/Pebble + CL Lighthouse/LevelDB)
# ═══════════════════════════════════════════════════════════════════════
#
# ┌──────┬────────────────────┬───────────┬────────────────────────────────┐
# │ PID  │ Directory          │ Temp      │ Content                        │
# ├──────┼────────────────────┼───────────┼────────────────────────────────┤
# │ p0   │ wal/               │ HOTTEST   │ EL Pebble WAL (write buffer)   │
# │ p1   │ sst_flush/         │ HOT       │ EL Pebble flush L0 SSTs (fresh)│
# │ p2   │ sst_l0cmp/         │ WARM      │ EL Pebble L0→Lbase compaction  │
# │ p3   │ sst_midcmp/        │ COOL      │ EL Pebble mid-level compaction │
# │ p4   │ chaindata/         │ COLD      │ EL Pebble deep/stable SSTs     │
# │ p5   │ ancient/           │ COLDEST   │ EL frozen blocks (ancient)     │
# │ p6   │ cl_hot/            │ HOT       │ CL Lighthouse hot DB (chain)   │
# │ p7   │ cl_cold/           │ COOL      │ CL Lighthouse freezer DB       │
# └──────┴────────────────────┴───────────┴────────────────────────────────┘
#
export STREAMS="${STREAMS:-8}"

if [[ "$STREAMS" -gt 1 ]]; then
  export PID_WAL="p0"          PID_FLUSH="p1"     PID_L0CMP="p2"
  export PID_MIDCMP="p3"       PID_CHAINDATA="p4"
  export PID_ANCIENT="p5"      PID_CL_HOT="p6"    PID_CL_COLD="p7"
else
  export PID_WAL="p0"          PID_FLUSH="p0"     PID_L0CMP="p0"
  export PID_MIDCMP="p0"       PID_CHAINDATA="p0"
  export PID_ANCIENT="p0"      PID_CL_HOT="p0"    PID_CL_COLD="p0"
fi

# ── EL derived paths ─────────────────────────────────────────────────
# DATA_ROOT uses PID_CHAINDATA since deep/stable SSTs (the bulk of data) live there.
export DATA_ROOT="$MOUNT_POINT/$PID_CHAINDATA/gethdata"
export DIR_WAL="$MOUNT_POINT/$PID_WAL/wal"
export DIR_FLUSH="$MOUNT_POINT/$PID_FLUSH/sst_flush"
export DIR_L0CMP="$MOUNT_POINT/$PID_L0CMP/sst_l0cmp"
export DIR_MIDCMP="$MOUNT_POINT/$PID_MIDCMP/sst_midcmp"
export DIR_CHAINDATA="$MOUNT_POINT/$PID_CHAINDATA/chaindata"
export DIR_ANCIENT="$MOUNT_POINT/$PID_ANCIENT/ancient"

# ── CL derived paths ─────────────────────────────────────────────────
export DIR_CL_HOT="$MOUNT_POINT/$PID_CL_HOT/cl_hot"
export DIR_CL_COLD="$MOUNT_POINT/$PID_CL_COLD/cl_cold"

# ── Shared metadata paths (on chaindata PID) ─────────────────────────
export DIR_LOGS="$MOUNT_POINT/$PID_CHAINDATA/logs"
export DIR_CL_VC="$MOUNT_POINT/$PID_CHAINDATA/cl_vc"
export JWT_SECRET="$MOUNT_POINT/$PID_CHAINDATA/jwt.hex"

# ── Ensure directories exist ─────────────────────────────────────────
mkdir -p "$DATA_ROOT" \
         "$DIR_WAL" "$DIR_FLUSH" "$DIR_L0CMP" "$DIR_MIDCMP" "$DIR_CHAINDATA" \
         "$DIR_ANCIENT" \
         "$DIR_CL_HOT" "$DIR_CL_COLD" \
         "$DIR_LOGS" "$DIR_CL_VC"
