#!/bin/bash
# Copyright © Aptos Foundation
# SPDX-License-Identifier: Apache-2.0

# Set the maximum number of file descriptors
ulimit -n 1048576

# Function to run the benchmark
run_benchmark() {
    FLOW=$1\
    NUM_BLOCKS_PER_TEST=$2\
    HIDE_OUTPUT=$3\
    ENABLE_PRUNER=$4\
    NUMBER_OF_EXECUTION_THREADS=$5\
    SKIP_MOVE_E2E=1\
    CHANNEL_BUFFER_SIZE=$CHANNEL_BUFFER_SIZE\
    ./testsuite/single_node_performance.py
}

# sj: Function to run time-based benchmark (duration-based instead of block count)
run_benchmark_time_based() {
    FLOW=$1\
    NUM_BLOCKS_PER_TEST=$2\
    BENCHMARK_DURATION_SECS=$3\
    HIDE_OUTPUT=$4\
    ENABLE_PRUNER=$5\
    NUMBER_OF_EXECUTION_THREADS=$6\
    SKIP_MOVE_E2E=1\
    CHANNEL_BUFFER_SIZE=$CHANNEL_BUFFER_SIZE\
    ./testsuite/single_node_performance.py
}

VIRTUAL_CORES=$(getconf _NPROCESSORS_ONLN)

DEFAULT_THREADS=$(($VIRTUAL_CORES > 64 ? 32 : $VIRTUAL_CORES / 2))

THREADS="${NUMBER_OF_EXECUTION_THREADS:-$DEFAULT_THREADS}"

echo "Using NUMBER_OF_EXECUTION_THREADS = $THREADS (found $VIRTUAL_CORES virtual cores)"
THREADS=8

NBPT=300
HD=0
EP=1

# sj: Channel buffer size for memory optimization (OOM prevention)
# Default: 20 (good balance between memory and performance)
# Lower values = less memory but potentially slower
# Higher values = more memory usage
CHANNEL_BUFFER_SIZE=${CHANNEL_BUFFER_SIZE:-20}

# Check for the flag
if [ "$1" == "--short" ]; then
    echo "Running short benchmark..."
    run_benchmark "MAINNET" 50 1 0 $THREADS
elif [ "$1" == "--long" ]; then
    echo "Running long benchmark..."
    run_benchmark "MAINNET_LARGE_DB" 300 1 1 $THREADS
elif [ "$1" == "--sj" ]; then
    echo "Running sj benchmark..."
    run_benchmark "MAINNET" $NBPT $HD $EP $THREADS
elif [ "$1" == "--sj-time" ]; then
    # sj: Time-based benchmark (1200 seconds = 20 minutes)
    echo "Running time-based apt-fa-transfer-sj benchmark (1200 seconds)"
    run_benchmark_time_based "ADHOC" 1000000 1200 $HD $EP $THREADS
else
    echo "Usage: $0 [--short | --long | --sj | --sj-time]"
    exit 1
fi
