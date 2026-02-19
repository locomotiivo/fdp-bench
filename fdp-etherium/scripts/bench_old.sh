#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# FDP Ethereum Benchmark — Non-FDP vs FDP Comparison
# ═══════════════════════════════════════════════════════════════════════
#
# Runs the SAME workload TWICE on the same hardware:
#   Round 1 ▸ Non-FDP baseline  (STREAMS=1, single placement ID)
#   Round 2 ▸ FDP               (STREAMS=8, 8 placement IDs)
#
# Then prints a side-by-side comparison of key metrics.
#
# See README.md for full design rationale and methodology.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source environment & helpers ──────────────────────────────────────
export STREAMS=8
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/helpers.sh"

# ── Spamoor binary ───────────────────────────────────────────────────
SPAMOOR="${SPAMOOR:-$HOME/spamoor/bin/spamoor}"
if [[ ! -x "$SPAMOOR" ]]; then
  echo "ERROR: spamoor binary not found at $SPAMOOR"
  echo "Build it:  cd ~/spamoor && make build"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════

SLOT_DURATION="${SLOT_DURATION:-4s}"
MODE="${MODE:-realistic}"

# ── Single-mode duration ─────────────────────────────────────────────
DURATION="${DURATION:-900}"

# ── Realistic-mode phase durations ───────────────────────────────────
# Phase 1 fills the SSD past GC threshold (~47 min on 106 GB FEMU).
# Phase 2 is the MEASURED DeFi window under active GC.
# Phase 3 is a short burst (airdrop/mint spike).
# Total: ~67 min per round, ~2.5 h for both rounds.
SEED_DURATION="${SEED_DURATION:-3300}"         # 55 min
DEFI_DURATION="${DEFI_DURATION:-600}"          # 10 min (MEASURED)
TOKEN_DURATION="${TOKEN_DURATION:-120}"        # 2 min

# ── Spamoor throughputs (tx/slot) ─────────────────────────────────────
SEED_THROUGHPUT="${SEED_THROUGHPUT:-120}"
SEED_GAS_BURN="${SEED_GAS_BURN:-2000000}"
DEFI_THROUGHPUT="${DEFI_THROUGHPUT:-400}"
BURST_THROUGHPUT="${BURST_THROUGHPUT:-1000}"
BG_THROUGHPUT="${BG_THROUGHPUT:-85}"
BG_GAS_BURN="${BG_GAS_BURN:-2000000}"

# ── EIP-1559 gas pricing ─────────────────────────────────────────────
BASEFEE_GWEI="${BASEFEE_GWEI:-50}"
TIPFEE_GWEI="${TIPFEE_GWEI:-2}"
REFILL_ETH="${REFILL_ETH:-10}"

RESULTS_DIR="$SCRIPT_DIR/../results"
RESULT_FILE="$SCRIPT_DIR/../results_eth.txt"

# ═══════════════════════════════════════════════════════════════════════
# Workload Phases
# ═══════════════════════════════════════════════════════════════════════

# Run the 3-phase realistic workload.
# Sets: defi_start_block, defi_end_block, defi_start_ts, defi_end_ts, main_log_file
run_realistic_workload() {
  local rdir="$1"
  local total_secs=$((SEED_DURATION + DEFI_DURATION + TOKEN_DURATION))
  log "=== REALISTIC MODE: 3 phases, total ${total_secs}s (~$((total_secs/60)) min) ==="

  # ── Phase 1: storagespam (state accumulation) ──────────────────────
  if [[ "$SEED_DURATION" -gt 0 ]]; then
    log "──── Phase 1: storagespam (state accumulation) × ${SEED_DURATION}s ────"
    run_spamoor storagespam "$SEED_DURATION" "$SEED_THROUGHPUT" \
      "$rdir/phase_seed.log" "$DEV_PRIVKEY" \
      --gas-units-to-burn "$SEED_GAS_BURN"
  fi
  snapshot_femu

  # ── Phase 2: uniswap-swaps (MEASURED) + bg storagespam ─────────────
  defi_start_block=$(get_block_number)
  defi_start_ts=$(date +%s)

  local bg_churn_pid=""
  if [[ "$DEFI_DURATION" -gt 0 && "$BG_THROUGHPUT" -gt 0 ]]; then
    local bg_timeout
    bg_timeout=$(secs_to_duration "$DEFI_DURATION")
    log "Starting background storagespam (throughput=$BG_THROUGHPUT tx/slot)"
    "$SPAMOOR" storagespam \
      -h "http://127.0.0.1:8545" \
      -p "0x${DEV_PRIVKEY}" \
      --slot-duration "$SLOT_DURATION" \
      --timeout "$bg_timeout" \
      --throughput "$BG_THROUGHPUT" \
      --gas-units-to-burn "$BG_GAS_BURN" \
      --basefee "$BASEFEE_GWEI" \
      --tipfee "$TIPFEE_GWEI" \
      --refill-amount "$REFILL_ETH" \
      > "$rdir/phase_bg_churn.log" 2>&1 &
    bg_churn_pid=$!
  fi

  if [[ "$DEFI_DURATION" -gt 0 ]]; then
    log "──── Phase 2: uniswap-swaps (MEASURED) × ${DEFI_DURATION}s ────"
    run_spamoor uniswap-swaps "$DEFI_DURATION" "$DEFI_THROUGHPUT" \
      "$rdir/phase_defi.log" "$BG_PRIVKEY"
  fi

  if [[ -n "$bg_churn_pid" ]]; then
    kill "$bg_churn_pid" 2>/dev/null || true
    wait "$bg_churn_pid" 2>/dev/null || true
    log "Background storagespam stopped"
  fi

  defi_end_block=$(get_block_number)
  defi_end_ts=$(date +%s)
  main_log_file="$rdir/phase_defi.log"
  snapshot_femu

  # ── Phase 3: erc20tx burst ────────────────────────────────────────
  if [[ "$TOKEN_DURATION" -gt 0 ]]; then
    log "──── Phase 3: erc20tx (ERC-20 burst) × ${TOKEN_DURATION}s ────"
    run_spamoor erc20tx "$TOKEN_DURATION" "$BURST_THROUGHPUT" \
      "$rdir/phase_token.log" "$BG_PRIVKEY"
  fi
}

# Run a single-mode workload.
run_single_workload() {
  local rdir="$1" scenario="$2" throughput="$3" privkey="$4"
  shift 4

  defi_start_block=$(get_block_number)
  defi_start_ts=$(date +%s)
  log "──── Single mode: $scenario × ${DURATION}s ────"
  run_spamoor "$scenario" "$DURATION" "$throughput" \
    "$rdir/phase_main.log" "$privkey" "$@"
  defi_end_block=$(get_block_number)
  defi_end_ts=$(date +%s)
  main_log_file="$rdir/phase_main.log"
}

# ═══════════════════════════════════════════════════════════════════════
# run_full_benchmark  STREAMS  LABEL
# ═══════════════════════════════════════════════════════════════════════

run_full_benchmark() {
  local streams="$1"
  local label="$2"
  local rdir="$RESULTS_DIR/$label"
  rm -rf "$rdir"
  mkdir -p "$rdir"

  log ""
  log "╔═══════════════════════════════════════════════════════════════╗"
  log "║  Benchmark round: $label  (STREAMS=$streams)                "
  log "╚═══════════════════════════════════════════════════════════════╝"

  export STREAMS="$streams"

  # ── 1. Prepare filesystem ──────────────────────────────────────────
  prepare_fs "$streams"
  # Re-source env to create dirs on the fresh FS with correct PID mapping
  _ETH_ENV_SOURCED=""
  source "$SCRIPT_DIR/env.sh"

  if [[ "$streams" -gt 1 ]]; then
    log "FDP PID allocation ($streams streams):"
    log "  p0 → WAL  |  p1 → Flush L0  |  p2 → L0→Lbase  |  p3 → Deep SSTs"
    log "  p4 → CL Hot  |  p5 → CL Cold  |  p6 → Ancient  |  p7 → Meta+Logs"
  else
    log "Non-FDP baseline (single stream — all data maps to p0)"
  fi

  reset_femu_counters

  # ── 2. Generate genesis + start EL + CL ────────────────────────────
  if [ ! -x "$LIGHTHOUSE_BIN" ]; then
    log "ERROR: Lighthouse not found at $LIGHTHOUSE_BIN"; return 1
  fi
  if [ ! -d "$TESTNET_DIR/validator_keys/keys" ]; then
    log "ERROR: Validator keys missing. Run setup_testnet.sh first."; return 1
  fi

  log "Generating EL + CL genesis ..."
  "$SCRIPT_DIR/gen_genesis.sh"

  log "Starting geth (EL) ..."
  "$SCRIPT_DIR/run_geth.sh" </dev/null &
  CUR_GETH_PID=$!

  for i in {1..30}; do
    if curl -sf http://127.0.0.1:8545 >/dev/null 2>&1; then break; fi
    sleep 1
    if [[ "$i" -eq 30 ]]; then log "Geth RPC not up after 30s"; return 1; fi
  done
  log "Geth RPC is up"

  log "Starting Lighthouse (CL) ..."
  "$SCRIPT_DIR/run_lighthouse.sh"
  log "CL running — blocks every 4s"

  # ── 3. Run workload ────────────────────────────────────────────────
  local bench_start_block bench_end_block bench_start_ts bench_end_ts
  local defi_start_block defi_end_block defi_start_ts defi_end_ts
  local main_log_file confirmed_txs=0

  bench_start_block=$(get_block_number)
  bench_start_ts=$(date +%s)

  case "$MODE" in
    realistic)   run_realistic_workload "$rdir" ;;
    storagespam) run_single_workload "$rdir" storagespam "$SEED_THROUGHPUT" "$DEV_PRIVKEY" --gas-units-to-burn "$SEED_GAS_BURN" ;;
    uniswap)     run_single_workload "$rdir" uniswap-swaps "$DEFI_THROUGHPUT" "$DEV_PRIVKEY" ;;
    erc20)       run_single_workload "$rdir" erc20tx "$BURST_THROUGHPUT" "$DEV_PRIVKEY" ;;
    *)           log "Unknown MODE=$MODE"; return 1 ;;
  esac

  bench_end_block=$(get_block_number)
  bench_end_ts=$(date +%s)

  # ── 4. Count confirmed transactions ────────────────────────────────
  if [[ "$defi_end_block" -gt "$defi_start_block" ]]; then
    log "Counting confirmed txs in blocks $((defi_start_block+1))..$defi_end_block ..."
    confirmed_txs=$(count_confirmed_txs "$defi_start_block" "$defi_end_block")
    log "Confirmed txs in measurement window: $confirmed_txs"
  fi

  # ── 5. Collect metrics ─────────────────────────────────────────────
  snapshot_femu
  local waf_value femu_raw
  waf_value=$(get_waf_from_host)
  femu_raw=$(get_femu_raw_stats)

  pid_disk_usage "$label" > "$rdir/disk_usage.txt"
  scrape_pebble_metrics "$rdir"

  # ── 6. Stop EL + CL ────────────────────────────────────────────────
  log "Stopping EL + CL for $label"
  kill_el_cl
  sleep 3

  if [ -f "${DIR_LOGS:-/tmp}/geth.log" ] 2>/dev/null; then
    cp "$DIR_LOGS/geth.log" "$rdir/geth.log" 2>/dev/null || true
  fi
  teardown_fs
  CUR_GETH_PID=""

  # ── 7. Parse & save metrics ────────────────────────────────────────
  local m_txb m_bps m_total_bps m_confirmed_tps
  local block_delta time_delta total_blocks total_time

  m_txb=$(parse_throughput_txb "$main_log_file")
  block_delta=$((defi_end_block - defi_start_block))
  time_delta=$((defi_end_ts - defi_start_ts))
  m_bps=$(python3 -c "print(f'{$block_delta / max($time_delta,1):.4f}')")
  m_confirmed_tps=$(python3 -c "print(f'{$confirmed_txs / max($time_delta,1):.1f}')")
  total_blocks=$((bench_end_block - bench_start_block))
  total_time=$((bench_end_ts - bench_start_ts))
  m_total_bps=$(python3 -c "print(f'{$total_blocks / max($total_time,1):.4f}')")

  parse_stall_stats "$rdir/geth.log"

  write_metrics "$rdir/metrics.txt" \
    "$label" "$streams" "$MODE" \
    "$m_confirmed_tps" "$confirmed_txs" "$m_txb" "$waf_value" \
    "$m_bps" "$m_total_bps" "$block_delta" "$time_delta" \
    "$total_blocks" "$total_time" \
    "$m_stall_count" "$m_stall_time_ms" "$m_compaction_time_ms" \
    "${live_l0_comp:-0}" "${live_nonl0_comp:-0}"

  write_summary "$rdir" "$label" "$streams" \
    "$m_confirmed_tps" "$confirmed_txs" "$m_txb" "$waf_value" \
    "$m_bps" "$block_delta" "$time_delta" \
    "$m_stall_count" "$m_stall_time_ms" "$m_compaction_time_ms" \
    "$femu_raw"

  log "Round '$label' complete.  TPS=$m_confirmed_tps  Throughput=${m_txb}tx/B  WAF=$waf_value  Stalls=$m_stall_count"
}

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

cleanup_on_exit() {
  log "Cleaning up (EXIT trap) ..."
  kill_el_cl
  teardown_fs
}
trap cleanup_on_exit EXIT

mkdir -p "$RESULTS_DIR"

log "FDP Ethereum Benchmark"
log "  Mode: $MODE"
log "  Phases: ${SEED_DURATION}s + ${DEFI_DURATION}s + ${TOKEN_DURATION}s"
log ""

# ── Round 1: Non-FDP baseline ────────────────────────────────────────
run_full_benchmark 1 "non-fdp"
sleep 10

# ── Round 2: FDP ─────────────────────────────────────────────────────
run_full_benchmark 8 "fdp"

# ── Comparison ───────────────────────────────────────────────────────
log ""
log "Both rounds complete — generating comparison ..."

NFDP="$RESULTS_DIR/non-fdp/metrics.txt"
FDP_M="$RESULTS_DIR/fdp/metrics.txt"

print_comparison "$NFDP" "$FDP_M"

# Save combined report
{
  echo "=== FDP Ethereum Benchmark — Comparison Report ==="
  echo "Date: $(date)"
  echo "Mode: $MODE   Workload: spamoor (EthPandaOps)"
  echo ""
  print_comparison "$NFDP" "$FDP_M"
  echo ""
  echo "──────────────── Non-FDP Round Details ────────────────"
  cat "$RESULTS_DIR/non-fdp/summary.txt" 2>/dev/null || echo "(no summary)"
  echo ""
  echo "──────────────── FDP Round Details ────────────────────"
  cat "$RESULTS_DIR/fdp/summary.txt" 2>/dev/null || echo "(no summary)"
} > "$RESULT_FILE"

log "Full report saved to $RESULT_FILE"
log "Done"
