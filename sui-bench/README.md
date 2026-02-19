# FDP SUI Benchmark

High-throughput I/O benchmark for measuring Write Amplification Factor (WAF) on FDP vs non-FDP storage using the SUI blockchain.

## Overview

This benchmark is designed to maximize disk I/O to measure the effectiveness of Flexible Data Placement (FDP) in reducing write amplification on SSDs. It uses a custom Move contract (`io_churn`) that generates small, un-compactible objects and updates them frequently.

## Key Improvements Over Previous Approach

The original `bench.sh` script spawned hundreds of `sui client` CLI processes, each:
- Creating a full Rust binary (~50-100MB resident memory)
- Opening RPC connections to the SUI node
- Serializing/deserializing JSON

This caused severe memory pressure and limited throughput to ~65 TPS.

The new SDK-based approach:
1. **Direct SDK transaction submission** - No CLI process spawning overhead
2. **Async connection pooling** - Single connection pool shared across workers
3. **Proper concurrency control** - Semaphores limit in-flight transactions
4. **Efficient object tracking** - In-memory version tracking without RPC queries

## Quick Start

### 1. Normalize RocksDB Settings (Recommended)

The SUI source has aggressive RocksDB settings that aren't realistic. Restore production-like settings:

```bash
cd /home/femu/fdp-scripts/sui-bench/scripts
./normalize_rocksdb.sh --apply
```

Then rebuild SUI:
```bash
cd /home/femu/sui
cargo build --release -p sui
sudo cp target/release/sui /usr/local/bin/sui
```

### 2. Run the SDK Benchmark

```bash
cd /home/femu/fdp-scripts/sui-bench/scripts
./bench_sdk.sh
```

### Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `DURATION` | 300 | Benchmark duration in seconds |
| `WORKERS` | 8 | Number of concurrent workers |
| `BATCH_SIZE` | 50 | Objects per transaction |
| `MAX_INFLIGHT` | 100 | Max concurrent in-flight transactions |
| `CREATE_PCT` | 40 | Percentage of CREATE operations (vs UPDATE) |
| `NOFDP` | no | Set to "yes" to skip FDP benchmark |
| `NONFDP` | no | Set to "yes" to skip non-FDP benchmark |

Example with custom settings:
```bash
DURATION=600 WORKERS=16 BATCH_SIZE=100 ./bench_sdk.sh
```

## Architecture

### Move Contract (`io_churn`)

Located in `move/io_churn/sources/io_churn.move`:

- **MicroCounter**: ~100 byte objects with unique checksums (un-compactible)
- **LargeBlob**: 4KB objects for high I/O volume testing
- **create_batch**: Creates multiple objects in a single transaction
- **increment_simple**: Updates an object with unique data

### Workload Mix

The benchmark uses a mixed workload for FDP testing:

- **CREATE operations (40%)**: Generate new "cold" data (written once)
- **UPDATE operations (60%)**: Modify existing "hot" data (frequently rewritten)

FDP segregates hot and cold data into different placement IDs:
- Hot data: High invalidity rate → cheap GC
- Cold data: Rarely needs GC → isolated from hot churn
- Result: Lower WAF compared to non-FDP

### SDK Benchmark (`src/main.rs`)

Key components:

1. **Worker State**: Each worker has its own address, keypair, and object pool
2. **TrackedObject**: Tracks object ID, version, and digest for updates
3. **Semaphore**: Controls maximum in-flight transactions
4. **Async Execution**: Uses Tokio for concurrent transaction submission

## Results

Results are written to `scripts/results/sdk_<timestamp>/`:

- `nfdp/`: Non-FDP benchmark results
- `fdp/`: FDP-enabled benchmark results
- `final_comparison.txt`: WAF comparison summary

Each run directory contains:
- `benchmark_info.txt`: Configuration and metrics
- `bench_results.json`: Detailed benchmark statistics
- `bench.log`: Full benchmark output
- `summary.txt`: Human-readable summary

## Troubleshooting

### Low Throughput

1. Check if SUI node is running: `curl http://127.0.0.1:9000`
2. Verify gas is available: Check faucet at `http://127.0.0.1:9123`
3. Reduce `MAX_INFLIGHT` if memory is constrained

### Build Errors

Ensure Rust toolchain matches SUI requirements:
```bash
cd /home/femu/sui
rustup show
```

### Memory Issues

- Reduce `WORKERS` and `MAX_INFLIGHT`
- Ensure `SUI_ROCKSDB_BENCHMARK` is NOT set (use production settings)

## Academic References

- Rosenblum & Ousterhout, "The Design and Implementation of a Log-Structured File System" (1992)
- NVMe TP4146: "Flexible Data Placement"
- RocksDB Wiki: "Write Amplification Analysis"
