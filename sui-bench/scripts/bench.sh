#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# Sui FDP Benchmark — Main Orchestrator
# ═══════════════════════════════════════════════════════════════════════
#
# Runs sui-single-node-benchmark with ValidatorWithFakeConsensus for
# realistic transaction processing, measuring WAF, TPS, and compaction
# under FDP vs non-FDP F2FS.
#
# WAF rises significantly around rounds 9-10 with 10 rounds; use 30+
# for steady-state GC behavior.
#
# Usage:
#   ./bench.sh [fdp|nofdp|both]
#
# Environment overrides:
#   NUM_ROUNDS=30  TX_COUNT=20000  BENCH_COMPONENT=baseline  ./bench.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source environment (common + sui-specific)
source "$SCRIPT_DIR/env.sh"

# ═══════════════════════════════════════════════════════════════════════
# run_benchmark   MODE  STREAMS
# ═══════════════════════════════════════════════════════════════════════

run_benchmark() {
  local mode="$1"    # "fdp" or "nofdp"
  local streams="$2" # 8 for FDP, 1 for non-FDP
  local rdir="$RESULTS_DIR/$mode"
  rm -rf "$rdir"
  mkdir -p "$rdir"

  local store_path
  store_path=$(sui_store_path "$mode")

  log ""
  log "╔═══════════════════════════════════════════════════════════════╗"
  log "║  Sui Benchmark: $mode  (STREAMS=$streams)                   "
  log "║  Rounds: $NUM_ROUNDS × $((TX_COUNT * NUM_BATCHES)) TXs      "
  log "║  Component: $BENCH_COMPONENT                                "
  log "╚═══════════════════════════════════════════════════════════════╝"

  # ── 1. Prepare filesystem ──────────────────────────────────────────
  prepare_fs "$streams"
  set_sui_fdp_env "$mode"
  mkdir -p "$store_path"

  if [[ "$mode" == "fdp" ]]; then
    log "FDP env: WAL→p0, SST PRIMARY→p1, SST OVERFLOW→p2"
  else
    log "Non-FDP: all data to single stream (p7)"
  fi

  reset_femu_counters

  # ── 2. Setup phase: create accounts ────────────────────────────────
  log "Setup: Creating accounts (baseline mode for speed)..."
  if [[ "$mode" == "fdp" ]]; then
    "$SUI_BENCH_BIN" --tx-count "$TX_COUNT" --component baseline \
      --store-path "$store_path" ptb --num-transfers "$NUM_TRANSFERS" 2>&1 | tail -3
  else
    env -u SUI_FDP_WAL_SEMANTIC -u SUI_FDP_BASE_PATH -u SUI_FDP_HOT_SIZE_MB \
        -u SUI_FDP_ENABLED -u SUI_FDP_SEMANTIC \
      "$SUI_BENCH_BIN" --tx-count "$TX_COUNT" --component baseline \
      --store-path "$store_path" ptb --num-transfers "$NUM_TRANSFERS" 2>&1 | tail -3
  fi

  # ── 3. Benchmark rounds ───────────────────────────────────────────
  local start_time
  start_time=$(date +%s)
  local total_tx=0
  local tps_sum=0
  local tps_count=0
  local -a round_durations=()
  local -a round_tps=()

  log "Benchmark: Running $NUM_ROUNDS rounds (component=$BENCH_COMPONENT)..."

  for round in $(seq 1 "$NUM_ROUNDS"); do
    local round_start
    round_start=$(date +%s)
    local elapsed=$((round_start - start_time))

    local output=""
    if [[ "$mode" == "fdp" ]]; then
      output=$("$SUI_BENCH_BIN" --tx-count "$TX_COUNT" --num-batches "$NUM_BATCHES" \
        --component "$BENCH_COMPONENT" --store-path "$store_path" --append \
        ptb --num-transfers "$NUM_TRANSFERS" --num-mints "$NUM_MINTS" --nft-size "$NFT_SIZE" 2>&1)
    else
      output=$(env -u SUI_FDP_WAL_SEMANTIC -u SUI_FDP_BASE_PATH -u SUI_FDP_HOT_SIZE_MB \
          -u SUI_FDP_ENABLED -u SUI_FDP_SEMANTIC \
        "$SUI_BENCH_BIN" --tx-count "$TX_COUNT" --num-batches "$NUM_BATCHES" \
        --component "$BENCH_COMPONENT" --store-path "$store_path" --append \
        ptb --num-transfers "$NUM_TRANSFERS" --num-mints "$NUM_MINTS" --nft-size "$NFT_SIZE" 2>&1)
    fi

    local round_end
    round_end=$(date +%s)
    local round_duration=$((round_end - round_start))
    round_durations+=("$round_duration")

    # Extract TPS
    local batch_tps
    batch_tps=$(echo "$output" | grep -oP '(Committed-TPS|Exec-TPS)=\K[0-9.]+' | tail -1 || true)
    round_tps+=("${batch_tps:-0}")

    if [[ -n "$batch_tps" ]]; then
      tps_sum=$(echo "$tps_sum + $batch_tps" | bc)
      tps_count=$((tps_count + 1))
    fi

    total_tx=$((total_tx + TX_COUNT * NUM_BATCHES))
    log "  Round $round/$NUM_ROUNDS: ${round_duration}s  TPS=${batch_tps:-n/a}  (${elapsed}s total)"

    # Periodic disk usage
    if [[ $((round % 3)) -eq 0 ]]; then
      df -h "$MOUNT_POINT" 2>/dev/null | tail -1 || true
    fi
  done

  local actual_duration=$(( $(date +%s) - start_time ))

  # ── 4. Collect FEMU stats ──────────────────────────────────────────
  log "Collecting final stats..."
  snapshot_femu
  sleep 2
  local waf_value femu_raw
  waf_value=$(get_waf_from_host)
  femu_raw=$(get_femu_raw_stats)

  pid_disk_usage "$mode" > "$rdir/disk_usage.txt"

  # ── 5. Calculate metrics ───────────────────────────────────────────
  local avg_tps=0
  if [[ $tps_count -gt 0 ]]; then
    avg_tps=$(echo "scale=0; $tps_sum / $tps_count" | bc)
  fi

  local committed_tps=0
  if [[ $actual_duration -gt 0 ]]; then
    committed_tps=$(echo "scale=0; $total_tx / $actual_duration" | bc)
  fi

  # Per-round latency stats
  local max_round=0 min_round=999999
  for d in "${round_durations[@]}"; do
    [[ "$d" -gt "$max_round" ]] && max_round=$d
    [[ "$d" -lt "$min_round" ]] && min_round=$d
  done

  teardown_fs

  # ── 6. Save metrics ───────────────────────────────────────────────
  cat > "$rdir/metrics.txt" <<EOF
label=$mode
streams=$streams
mode=synthetic
component=$BENCH_COMPONENT
num_rounds=$NUM_ROUNDS
total_txs=$total_tx
duration_s=$actual_duration
avg_tps=$avg_tps
committed_tps=$committed_tps
waf=${waf_value:-0}
min_round_s=$min_round
max_round_s=$max_round
EOF

  cat > "$rdir/summary.txt" <<EOF
=== Sui Benchmark: $mode (STREAMS=$streams) ===
Date: $(date)
Component: $BENCH_COMPONENT
Rounds: $NUM_ROUNDS × $((TX_COUNT * NUM_BATCHES)) TXs
Duration: $(secs_to_duration $actual_duration)
Total TXs: $total_tx
Avg TPS: $avg_tps
Committed TPS: $committed_tps
WAF: ${waf_value:-0}
Round latency: min=${min_round}s  max=${max_round}s

--- Per-Round ---
$(for i in "${!round_durations[@]}"; do echo "  Round $((i+1)): ${round_durations[$i]}s  TPS=${round_tps[$i]}"; done)

--- Disk Usage ---
$(cat "$rdir/disk_usage.txt" 2>/dev/null)

--- FEMU FTL Stats ---
$femu_raw
EOF

  log "Round '$mode' complete."
  log "  TXs=$total_tx  Duration=$(secs_to_duration $actual_duration)  Avg TPS=$avg_tps"
  log "  WAF=${waf_value:-0}  Round latency: ${min_round}s-${max_round}s"
}

# ═══════════════════════════════════════════════════════════════════════
# Comparison Table
# ═══════════════════════════════════════════════════════════════════════

print_comparison() {
  local nfdp_file="$1" fdp_file="$2"

  local n_txs f_txs n_dur f_dur n_atps f_atps n_ctps f_ctps
  local n_waf f_waf n_min f_min n_max f_max

  n_txs=$(load_metric "$nfdp_file" total_txs)
  f_txs=$(load_metric "$fdp_file" total_txs)
  n_dur=$(load_metric "$nfdp_file" duration_s)
  f_dur=$(load_metric "$fdp_file" duration_s)
  n_atps=$(load_metric "$nfdp_file" avg_tps)
  f_atps=$(load_metric "$fdp_file" avg_tps)
  n_ctps=$(load_metric "$nfdp_file" committed_tps)
  f_ctps=$(load_metric "$fdp_file" committed_tps)
  n_waf=$(load_metric "$nfdp_file" waf)
  f_waf=$(load_metric "$fdp_file" waf)
  n_min=$(load_metric "$nfdp_file" min_round_s)
  f_min=$(load_metric "$fdp_file" min_round_s)
  n_max=$(load_metric "$nfdp_file" max_round_s)
  f_max=$(load_metric "$fdp_file" max_round_s)

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo "         Sui Benchmark: Non-FDP vs FDP Comparison"
  echo "═══════════════════════════════════════════════════════════════════════"
  printf "  %-22s %14s %14s %10s\n" "Metric" "Non-FDP" "FDP" "Delta"
  echo "───────────────────────────────────────────────────────────────────────"
  printf "  %-22s %14s %14s %10s\n" "Total TXs"           "$n_txs"   "$f_txs"   ""
  printf "  %-22s %14s %14s %10s\n" "Duration"            "$(secs_to_duration "${n_dur:-0}")" "$(secs_to_duration "${f_dur:-0}")" "$(pct_change "$n_dur" "$f_dur")"
  printf "  %-22s %14s %14s %10s\n" "Avg TPS"             "$n_atps"  "$f_atps"  "$(pct_change "$n_atps" "$f_atps")"
  printf "  %-22s %14s %14s %10s\n" "Committed TPS"       "$n_ctps"  "$f_ctps"  "$(pct_change "$n_ctps" "$f_ctps")"
  printf "  %-22s %14s %14s %10s\n" "WAF"                 "$n_waf"   "$f_waf"   "$(pct_change "$n_waf" "$f_waf")"
  printf "  %-22s %14s %14s %10s\n" "Min Round (s)"       "$n_min"   "$f_min"   "$(pct_change "$n_min" "$f_min")"
  printf "  %-22s %14s %14s %10s\n" "Max Round (s)"       "$n_max"   "$f_max"   "$(pct_change "$n_max" "$f_max")"
  echo "───────────────────────────────────────────────────────────────────────"
  echo "  Workload: sui-single-node-benchmark (component=$BENCH_COMPONENT)"
  echo "  For TPS: positive delta = FDP is better"
  echo "  For WAF & Round time: negative delta = FDP is better"
  echo "═══════════════════════════════════════════════════════════════════════"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

MODE="${1:-both}"

log "═══ Sui FDP Benchmark ═══"
log "  Component: $BENCH_COMPONENT"
log "  Rounds: $NUM_ROUNDS × $((TX_COUNT * NUM_BATCHES)) TXs/round"

mkdir -p "$RESULTS_DIR"

if [[ "$MODE" == "nofdp" || "$MODE" == "both" ]]; then
  run_benchmark "nofdp" 1
  sleep 10
fi

if [[ "$MODE" == "fdp" || "$MODE" == "both" ]]; then
  run_benchmark "fdp" 8
fi

if [[ "$MODE" == "both" ]]; then
  log "Both rounds complete — generating comparison ..."
  NFDP="$RESULTS_DIR/nofdp/metrics.txt"
  FDP_M="$RESULTS_DIR/fdp/metrics.txt"
  print_comparison "$NFDP" "$FDP_M"

  {
    echo "=== Sui FDP Benchmark — Comparison Report ==="
    echo "Date: $(date)"
    echo ""
    print_comparison "$NFDP" "$FDP_M"
    echo ""
    echo "──────────────── Non-FDP Details ────────────────"
    cat "$RESULTS_DIR/nofdp/summary.txt" 2>/dev/null
    echo ""
    echo "──────────────── FDP Details ────────────────────"
    cat "$RESULTS_DIR/fdp/summary.txt" 2>/dev/null
  } > "$RESULTS_DIR/comparison.txt"
  log "Report saved to $RESULTS_DIR/comparison.txt"
fi
