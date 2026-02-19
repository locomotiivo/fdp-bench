#!/bin/bash
# 10-round FDP vs Non-FDP comparison benchmark
# WAF rises significantly around rounds 9-10, so we run exactly 10 rounds

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUI_BENCH="/home/femu/sui-fdp/target/release/sui-single-node-benchmark"
FDP_TOOLS_DIR="/home/femu/fdp-scripts/f2fs-tools-fdp"
FDP_STATS="$SCRIPT_DIR/fdp_stats"
MOUNT_POINT="/home/femu/f2fs_fdp_mount"
NVME_DEV="/dev/nvme0n1"

# Fixed 10 rounds (not time-based) to ensure WAF reaches meaningful levels
NUM_ROUNDS=10

# Benchmark parameters (same as previous successful run)
TX_COUNT=20000
NUM_BATCHES=10
NUM_TRANSFERS=10
NUM_MINTS=4
NFT_SIZE=8000

# RocksDB tuning
export MAX_WRITE_BUFFER_SIZE_MB=64
export MAX_WRITE_BUFFER_NUMBER=2

# Host SSH for FEMU stats
HOST_IP="10.0.2.2"
HOST_USER="hajin"
HOST_FEMU_LOG="/home/hajin/femu-scripts/run-fdp.log"

log() { echo "[$(date +%H:%M:%S)] $1"; }

get_femu_stats() {
    sudo "$FDP_STATS" "$NVME_DEV" --read-only >/dev/null 2>&1
    sleep 2
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ${HOST_USER}@${HOST_IP} \
        "tail -50 '$HOST_FEMU_LOG' | tr -d '\0' | grep -E 'Host written|GC copied|WAF:'" 2>/dev/null | tail -3
}

run_benchmark() {
    local mode=$1  # "fdp" or "nofdp"
    local streams=$2  # 8 for FDP, 1 for non-FDP
    local result_file="$SCRIPT_DIR/results_${mode}_10rounds.txt"
    
    log "=========================================="
    log "Starting $mode benchmark (${streams} streams)"
    log "Rounds: $NUM_ROUNDS"
    log "=========================================="
    
    # Unmount if mounted
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    sleep 2
    
    # Format and mount
    log "Formatting F2FS..."
    sudo "$FDP_TOOLS_DIR/mkfs/mkfs.f2fs" -f -O lost_found "$NVME_DEV" >/dev/null 2>&1
    
    log "Mounting with $streams stream(s)..."
    sudo "$FDP_TOOLS_DIR/fdp_f2fs_mount" "$streams"
    sudo chmod -R 777 "$MOUNT_POINT"
    
    # Reset FEMU counters
    log "Resetting FEMU FTL counters..."
    sudo "$FDP_STATS" "$NVME_DEV" --reset >/dev/null 2>&1
    sleep 2
    
    # Configure FDP environment variables
    local fdp_env=""
    if [ "$mode" = "fdp" ]; then
        # Enable WAL-Semantic FDP - separates WAL from SST, hot from cold
        fdp_env="SUI_FDP_WAL_SEMANTIC=1 SUI_FDP_BASE_PATH=$MOUNT_POINT SUI_FDP_HOT_SIZE_MB=64"
        log "FDP env enabled: WAL→p0, SST L0→p1, L1-2→p2, L3+→p3, checkpoints→p4, epochs→p5"
        
        # Use 12-char hex ID in path so FDP extracts consistent instance ID across runs
        local store_path="$MOUNT_POINT/p1/aaaaaaaaaaaa/sui_bench"
    else
        # No FDP env vars - all data stays in single directory
        # F2FS with fdp_log_n=1 maps all pX to same stream anyway
        fdp_env=""
        log "FDP env disabled: all data to p7 (single stream)"
        
        # MUST be inside p0-p7, use 12-char hex ID for --append consistency
        local store_path="$MOUNT_POINT/p7/bbbbbbbbbbbb/sui_bench"
    fi
    mkdir -p "$store_path"
    
    # Setup phase
    log "Setup: Creating accounts..."
    if [ -n "$fdp_env" ]; then
        env $fdp_env "$SUI_BENCH" --tx-count $TX_COUNT --component baseline \
            --store-path "$store_path" ptb --num-transfers $NUM_TRANSFERS 2>&1 | tail -3
    else
        # MUST unset FDP vars - they may be globally exported!
        env -u SUI_FDP_WAL_SEMANTIC -u SUI_FDP_BASE_PATH -u SUI_FDP_HOT_SIZE_MB -u SUI_FDP_ENABLED -u SUI_FDP_SEMANTIC \
            "$SUI_BENCH" --tx-count $TX_COUNT --component baseline \
            --store-path "$store_path" ptb --num-transfers $NUM_TRANSFERS 2>&1 | tail -3
    fi
    
    # Record start time
    local start_time=$(date +%s)
    local total_tx=0
    local tps_sum=0
    local tps_count=0
    
    log "Benchmark phase: Running $NUM_ROUNDS rounds..."
    echo "Mode: $mode" > "$result_file"
    echo "Streams: $streams" >> "$result_file"
    echo "Start: $(date)" >> "$result_file"
    
    for round in $(seq 1 $NUM_ROUNDS); do
        local elapsed=$(( $(date +%s) - start_time ))
        log "Round $round/$NUM_ROUNDS (${elapsed}s elapsed)"
        
        # Run one round (10 batches of 20K TXs) with FDP env vars if enabled
        local output=""
        if [ -n "$fdp_env" ]; then
            output=$(env $fdp_env "$SUI_BENCH" --tx-count $TX_COUNT --num-batches $NUM_BATCHES \
                --component baseline --store-path "$store_path" --append \
                ptb --num-transfers $NUM_TRANSFERS --num-mints $NUM_MINTS --nft-size $NFT_SIZE 2>&1)
        else
            # MUST unset FDP vars - they may be globally exported!
            output=$(env -u SUI_FDP_WAL_SEMANTIC -u SUI_FDP_BASE_PATH -u SUI_FDP_HOT_SIZE_MB -u SUI_FDP_ENABLED -u SUI_FDP_SEMANTIC \
                "$SUI_BENCH" --tx-count $TX_COUNT --num-batches $NUM_BATCHES \
                --component baseline --store-path "$store_path" --append \
                ptb --num-transfers $NUM_TRANSFERS --num-mints $NUM_MINTS --nft-size $NFT_SIZE 2>&1)
        fi
        
        # Extract TPS from output
        local batch_tps=$(echo "$output" | grep -oP 'TPS=\K[0-9.]+' | tail -1)
        if [ -n "$batch_tps" ]; then
            tps_sum=$(echo "$tps_sum + $batch_tps" | bc)
            tps_count=$((tps_count + 1))
        fi
        
        total_tx=$((total_tx + TX_COUNT * NUM_BATCHES))
        
        # Log disk usage every 3 rounds
        if [ $((round % 3)) -eq 0 ]; then
            df -h "$MOUNT_POINT" | tail -1
        fi
    done
    
    local actual_duration=$(( $(date +%s) - start_time ))
    
    # Get final stats
    log "Collecting final stats..."
    local femu_stats=$(get_femu_stats)
    local host_written=$(echo "$femu_stats" | grep "Host written" | grep -oE '[0-9]+' | tail -1)
    local gc_copied=$(echo "$femu_stats" | grep "GC copied" | grep -oE '[0-9]+' | tail -1)
    local waf=$(echo "$femu_stats" | grep "WAF:" | grep -oE '[0-9]+\.[0-9]+' | tail -1)
    
    # Calculate averages
    local avg_tps=0
    if [ $tps_count -gt 0 ]; then
        avg_tps=$(echo "scale=0; $tps_sum / $tps_count" | bc)
    fi
    
    # SUI checkpoints (blocks) = total_tx / 100 (default checkpoint size)
    local checkpoints=$((total_tx / 100))
    local checkpoints_per_sec=$(echo "scale=2; $checkpoints / $actual_duration" | bc)
    
    # Write results
    {
        echo "End: $(date)"
        echo "Duration: ${actual_duration}s"
        echo "Rounds completed: $NUM_ROUNDS"
        echo ""
        echo "=== Transaction Stats ==="
        echo "Total TXs: $total_tx"
        echo "Avg TPS: $avg_tps"
        echo "Checkpoints (blocks): $checkpoints"
        echo "Checkpoints/sec: $checkpoints_per_sec"
        echo ""
        echo "=== FEMU FTL Stats ==="
        echo "Host written: $host_written pages"
        echo "GC copied: $gc_copied pages"
        echo "WAF: $waf"
    } >> "$result_file"
    
    log "Results saved to $result_file"
    cat "$result_file"
    
    # Cleanup
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
}

# Main
MODE="${1:-both}"  # "fdp", "nofdp", or "both"

if [ "$MODE" = "nofdp" ] || [ "$MODE" = "both" ]; then
    run_benchmark "nofdp" 1
    sleep 10
fi

if [ "$MODE" = "fdp" ] || [ "$MODE" = "both" ]; then
    run_benchmark "fdp" 8
fi

# Compare results if both ran
if [ "$MODE" = "both" ]; then
    echo ""
    echo "=========================================="
    echo "        COMPARISON SUMMARY (10 ROUNDS)"
    echo "=========================================="
    echo ""
    echo "--- Non-FDP (1 stream) ---"
    grep -E "Total TXs|Avg TPS|Checkpoints|WAF:" "$SCRIPT_DIR/results_nofdp_10rounds.txt"
    echo ""
    echo "--- FDP (8 streams) ---"
    grep -E "Total TXs|Avg TPS|Checkpoints|WAF:" "$SCRIPT_DIR/results_fdp_10rounds.txt"
fi
