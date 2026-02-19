# FDP Sui Benchmark

High-throughput I/O benchmark for measuring Write Amplification Factor
(WAF) on FDP vs non-FDP storage using the Sui blockchain.

## Overview

Uses `sui-single-node-benchmark` with a custom `io_churn` Move contract
that generates small, un-compactible objects and updates them frequently.
The `ValidatorWithFakeConsensus` component provides a full validator
pipeline without requiring network consensus.

Unlike Ethereum (where real mainnet replay is viable), `sui-tool replay`
uses in-memory storage only (no RocksDB writes), making it unsuitable
for I/O benchmarking. This SDK-based synthetic workload is the only
viable approach for Sui FDP measurement.

## Quick Start

### 1. Normalize RocksDB Settings (Recommended)

The Sui source has aggressive RocksDB settings that aren't realistic.
Restore production-like settings:

```bash
cd /home/femu/fdp-scripts/sui-bench/scripts
./normalize_rocksdb.sh --apply
```

Then rebuild Sui:
```bash
cd /home/femu/sui-fdp
cargo build --release -p sui-single-node-benchmark
```

### 2. Run the Benchmark

```bash
cd /home/femu/fdp-scripts/sui-bench/scripts
./bench.sh
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NUM_ROUNDS` | 10 | Number of benchmark rounds |
| `TX_COUNT` | 20000 | Transactions per round |
| `NUM_BATCHES` | 10 | Batches per round |
| `NUM_TRANSFERS` | 10 | Transfer operations per batch |
| `NUM_MINTS` | 4 | Mint operations per batch |
| `NFT_SIZE` | 8000 | NFT object size in bytes |
| `BENCH_COMPONENT` | validator-with-fake-consensus | Benchmark component mode |
| `MAX_WRITE_BUFFER_SIZE_MB` | 64 | RocksDB memtable size |
| `MAX_WRITE_BUFFER_NUMBER` | 2 | Number of RocksDB memtables |

### FDP Mode (Hybrid-Semantic, 8 PIDs)

In FDP mode (`SUI_FDP_WAL_SEMANTIC=1`), the hybrid-semantic strategy
combines WAL separation, per-CF routing within authority_db, and per-DB
isolation across all 8 NVMe placement IDs:

| PID | Directory    | Temp      | Content                               |
|-----|-------------|-----------|---------------------------------------|
| p0  | wal/        | HOTTEST   | All WAL files (all DBs, seconds)      |
| p1  | obj_hot/    | HOT       | authority_db objects CFs (fresh L0)   |
| p2  | obj_cold/   | WARM      | authority_db objects CFs (compacted)  |
| p3  | ledger/     | COOL      | authority_db ledger CFs (append-only) |
| p4  | consensus/  | EPHEMERAL | consensus_db (FIFO, per-epoch drop)   |
| p5  | epoch/      | EPHEMERAL | epoch_db (entire DB dropped)          |
| p6  | checkpoint/ | MEDIUM    | checkpoint_db (bulk-pruned)           |
| p7  | meta/       | COLDEST   | committee_store + metadata + fallback |

Environment variables:
- `SUI_FDP_WAL_SEMANTIC=1` — Enable hybrid-semantic FDP placement
- `SUI_FDP_BASE_PATH` — Base path for FDP directory mapping (F2FS mount)
- `SUI_FDP_HOT_SIZE_MB=64` — Hot data size threshold before overflow

Non-FDP mode unsets all FDP variables and uses a single stream.

## Architecture

### Move Contract (`io_churn`)

Located in `move/io_churn/sources/io_churn.move`:

- **MicroCounter**: ~100 byte objects with unique checksums (un-compactible)
- **LargeBlob**: 4 KB objects for high I/O volume testing
- **create_batch**: Creates multiple objects in a single transaction
- **increment_simple**: Updates an object with unique data

### Workload Mix

The benchmark uses a mixed workload optimized for FDP differentiation:

- **CREATE operations (40%)**: Generate new "cold" data (written once)
- **UPDATE operations (60%)**: Modify existing "hot" data (frequently rewritten)

FDP separates hot and cold data into different placement IDs:
- Hot data → high invalidity rate → cheap GC
- Cold data → rarely needs GC → isolated from hot churn
- Result: lower WAF compared to non-FDP

### SDK Benchmark (`src/main.rs`)

Key components:

1. **Worker State**: Each worker has its own address, keypair, and object pool
2. **TrackedObject**: Tracks object ID, version, and digest for updates
3. **Semaphore**: Controls maximum in-flight transactions
4. **Async Execution**: Uses Tokio for concurrent transaction submission

## Directory Structure

```
sui-bench/
├── README.md                  # This file
├── Cargo.toml                 # Rust SDK benchmark crate
├── src/
│   └── main.rs                # SDK benchmark entry point
├── move/
│   └── io_churn/              # Custom Move contract
│       └── sources/
│           └── io_churn.move
└── scripts/
    ├── bench.sh               # Main benchmark script
    └── env.sh                 # Sui-specific config + FDP env
```

## Results

Results are written to `scripts/results/`:

Each run directory contains:
- `benchmark_info.txt`: Configuration and metrics
- `bench_results.json`: Detailed benchmark statistics
- `bench.log`: Full benchmark output
- `summary.txt`: Human-readable summary

## Troubleshooting

### Low Throughput

1. Check if Sui node is running: `curl http://127.0.0.1:9000`
2. Verify gas is available
3. Reduce concurrency if memory is constrained

### Build Errors

Ensure Rust toolchain matches Sui requirements:
```bash
cd /home/femu/sui-fdp
rustup show
```

### Memory Issues

- Reduce worker/batch counts
- Ensure `SUI_ROCKSDB_BENCHMARK` is NOT set (use production settings)

## Academic References

- Rosenblum & Ousterhout, "The Design and Implementation of a
  Log-Structured File System" (1992)
- NVMe TP4146: "Flexible Data Placement"
- RocksDB Wiki: "Write Amplification Analysis"
