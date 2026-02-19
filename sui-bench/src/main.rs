// FDP SUI Benchmark - SDK-based High-Throughput I/O Benchmark
//
// This benchmark bypasses the `sui client` CLI overhead by directly using
// the SUI SDK to submit transactions. It's designed to maximize disk I/O
// for measuring Write Amplification Factor (WAF) on FDP vs non-FDP storage.
//
// Key features:
// - Direct SDK transaction submission (no CLI process spawning)
// - Async connection pooling to the SUI node
// - Batched PTB transactions (multiple operations per TX)
// - Mixed CREATE/UPDATE workload for hot/cold data segregation testing
// - Memory-efficient with configurable concurrency limits
//
// Usage:
//   cargo run --release -- \
//     --rpc-url http://127.0.0.1:9000 \
//     --package-id <PACKAGE_ID> \
//     --duration 300 \
//     --workers 8 \
//     --batch-size 50 \
//     --target-tps 500

use anyhow::{Context, Result, anyhow};
use clap::Parser;
use futures::{StreamExt, stream::FuturesUnordered};
use rand::Rng;
use rand::SeedableRng;
use serde::{Serialize, Deserialize};
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::sync::atomic::{AtomicU64, AtomicU8, AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use sui_sdk::{SuiClient, SuiClientBuilder};
use sui_sdk::rpc_types::{
    SuiTransactionBlockEffectsAPI,
    SuiTransactionBlockResponseOptions,
};
use sui_sdk::types::{
    base_types::{ObjectID, ObjectRef, SuiAddress},
    crypto::{get_key_pair, SuiKeyPair, AccountKeyPair, KeypairTraits, EncodeDecodeBase64},
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Transaction, TransactionData},
    transaction_driver_types::ExecuteTransactionRequestType,
    Identifier,
};
use tokio::sync::{Semaphore, RwLock};
use tokio::time::sleep;
use tracing::{info, warn, error, debug};

/// Maximum objects tracked per worker to prevent memory bloat
const MAX_TRACKED_OBJECTS_PER_WORKER: usize = 5000;

/// Memory pressure levels for graduated throttling
/// Level 0: Normal operation
/// Level 1: Light throttle (75-85% memory) - small delay, keep 75% objects
/// Level 2: Heavy throttle (85-92% memory) - longer delay, keep 50% objects  
/// Level 3: Emergency throttle (>92% memory) - max delay, keep 25% objects, skip creates
const MEM_PRESSURE_NORMAL: u8 = 0;
const MEM_PRESSURE_LIGHT: u8 = 1;
const MEM_PRESSURE_HEAVY: u8 = 2;
const MEM_PRESSURE_EMERGENCY: u8 = 3;

/// Get memory usage percentage (0.0 - 1.0) by reading /proc/meminfo
fn get_memory_usage_pct() -> f64 {
    let file = match File::open("/proc/meminfo") {
        Ok(f) => f,
        Err(_) => return 0.0, // Can't read, assume OK
    };
    let reader = BufReader::new(file);
    
    let mut mem_total: u64 = 0;
    let mut mem_available: u64 = 0;
    
    for line in reader.lines().flatten() {
        if line.starts_with("MemTotal:") {
            mem_total = line.split_whitespace()
                .nth(1)
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
        } else if line.starts_with("MemAvailable:") {
            mem_available = line.split_whitespace()
                .nth(1)
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
        }
        if mem_total > 0 && mem_available > 0 {
            break;
        }
    }
    
    if mem_total == 0 {
        return 0.0;
    }
    
    let used = mem_total.saturating_sub(mem_available);
    used as f64 / mem_total as f64
}

/// FDP SUI Benchmark - High-throughput I/O load generator
#[derive(Parser, Debug, Clone)]
#[clap(name = "fdp-sui-bench")]
struct Args {
    /// SUI RPC URL
    #[clap(long, default_value = "http://127.0.0.1:9000")]
    rpc_url: String,

    /// Package ID of the deployed io_churn contract
    #[clap(long, env = "FDP_PACKAGE_ID")]
    package_id: String,

    /// Benchmark duration in seconds
    #[clap(long, default_value = "300")]
    duration: u64,

    /// Number of concurrent workers (keep low for VM stability!)
    #[clap(long, default_value = "8")]
    workers: usize,

    /// Objects per transaction batch (higher = more I/O per TX)
    #[clap(long, default_value = "50")]
    batch_size: usize,

    /// Target transactions per second (0 = unlimited)
    #[clap(long, default_value = "0")]
    target_tps: u64,

    /// Maximum concurrent in-flight transactions (keep low for VM stability!)
    #[clap(long, default_value = "100")]
    max_inflight: usize,

    /// Percentage of CREATE operations (vs UPDATE) - keep low to reduce memory growth!
    #[clap(long, default_value = "5")]
    create_pct: u8,

    /// Initial seed objects to create per worker
    #[clap(long, default_value = "500")]
    seed_objects: usize,

    /// Maximum tracked objects per worker (caps memory usage)
    #[clap(long, default_value = "5000")]
    max_tracked_objects: usize,

    /// Memory usage threshold (0.0-1.0) above which to throttle (default: 0.75 = 75%)
    #[clap(long, default_value = "0.75")]
    memory_threshold: f64,

    /// Critical memory threshold that stops all workers (default: 0.85 = 85%)
    #[clap(long, default_value = "0.85")]
    memory_critical: f64,

    /// Emergency memory threshold that aborts benchmark (default: 0.92 = 92%)
    #[clap(long, default_value = "0.92")]
    memory_emergency: f64,

    /// Gas budget per transaction
    #[clap(long, default_value = "500000000")]
    gas_budget: u64,

    /// Stats reporting interval in seconds
    #[clap(long, default_value = "30")]
    stats_interval: u64,

    /// Use 4KB LargeBlob objects instead of MicroCounters for more I/O per TX
    #[clap(long, default_value = "false")]
    use_blobs: bool,

    /// Output file for results (JSON)
    #[clap(long)]
    output: Option<String>,

    /// Keystore path for signing transactions
    #[clap(long)]
    keystore: Option<String>,

    /// Save created/tracked objects to file (for use with --load-objects in next phase)
    #[clap(long)]
    save_objects: Option<String>,

    /// Load objects from file instead of creating seed objects (use objects from previous phase)
    #[clap(long)]
    load_objects: Option<String>,
}

/// Tracked object for updates
#[derive(Debug, Clone, Serialize, Deserialize)]
struct TrackedObject {
    #[serde(with = "object_id_serde")]
    id: ObjectID,
    version: u64,
    #[serde(with = "object_digest_serde")]
    digest: sui_sdk::types::base_types::ObjectDigest,
}

/// Custom serde for ObjectID (serialize as hex string)
mod object_id_serde {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use sui_sdk::types::base_types::ObjectID;
    use std::str::FromStr;

    pub fn serialize<S>(id: &ObjectID, serializer: S) -> Result<S::Ok, S::Error>
    where S: Serializer {
        id.to_string().serialize(serializer)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<ObjectID, D::Error>
    where D: Deserializer<'de> {
        let s = String::deserialize(deserializer)?;
        ObjectID::from_str(&s).map_err(serde::de::Error::custom)
    }
}

/// Custom serde for ObjectDigest (serialize as base58 string)
mod object_digest_serde {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use sui_sdk::types::base_types::ObjectDigest;
    use std::str::FromStr;

    pub fn serialize<S>(digest: &ObjectDigest, serializer: S) -> Result<S::Ok, S::Error>
    where S: Serializer {
        digest.to_string().serialize(serializer)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<ObjectDigest, D::Error>
    where D: Deserializer<'de> {
        let s = String::deserialize(deserializer)?;
        ObjectDigest::from_str(&s).map_err(serde::de::Error::custom)
    }
}

/// Serializable worker objects for save/load between phases
#[derive(Debug, Clone, Serialize, Deserialize)]
struct SavedWorkerObjects {
    worker_id: usize,
    #[serde(with = "sui_address_serde")]
    address: SuiAddress,
    /// Base64-encoded keypair bytes for restoring worker identity
    keypair_base64: String,
    objects: Vec<TrackedObject>,
}

/// Custom serde for SuiAddress
mod sui_address_serde {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use sui_sdk::types::base_types::SuiAddress;
    use std::str::FromStr;

    pub fn serialize<S>(addr: &SuiAddress, serializer: S) -> Result<S::Ok, S::Error>
    where S: Serializer {
        addr.to_string().serialize(serializer)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<SuiAddress, D::Error>
    where D: Deserializer<'de> {
        let s = String::deserialize(deserializer)?;
        SuiAddress::from_str(&s).map_err(serde::de::Error::custom)
    }
}

/// Full saved state for all workers
#[derive(Debug, Serialize, Deserialize)]
struct SavedBenchmarkState {
    total_objects: usize,
    workers: Vec<SavedWorkerObjects>,
}

/// Worker state
struct WorkerState {
    id: usize,
    address: SuiAddress,
    keypair: SuiKeyPair,
    gas_coin: ObjectRef,
    objects: Vec<TrackedObject>,
}

/// Global benchmark statistics
struct BenchStats {
    tx_submitted: AtomicU64,
    tx_success: AtomicU64,
    tx_failed: AtomicU64,
    objects_created: AtomicU64,
    objects_updated: AtomicU64,
    start_time: Instant,
}

impl BenchStats {
    fn new() -> Self {
        Self {
            tx_submitted: AtomicU64::new(0),
            tx_success: AtomicU64::new(0),
            tx_failed: AtomicU64::new(0),
            objects_created: AtomicU64::new(0),
            objects_updated: AtomicU64::new(0),
            start_time: Instant::now(),
        }
    }

    fn report(&self) -> String {
        let elapsed = self.start_time.elapsed().as_secs_f64();
        let submitted = self.tx_submitted.load(Ordering::Relaxed);
        let success = self.tx_success.load(Ordering::Relaxed);
        let failed = self.tx_failed.load(Ordering::Relaxed);
        let created = self.objects_created.load(Ordering::Relaxed);
        let updated = self.objects_updated.load(Ordering::Relaxed);

        let tps = if elapsed > 0.0 { success as f64 / elapsed } else { 0.0 };
        let ops_rate = if elapsed > 0.0 { (created + updated) as f64 / elapsed } else { 0.0 };

        format!(
            "Elapsed: {:.1}s | TX: {} submitted, {} success, {} failed | TPS: {:.1} | Objects: {} created, {} updated | Ops/s: {:.1}",
            elapsed, submitted, success, failed, tps, created, updated, ops_rate
        )
    }
}

/// Main benchmark runner
#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let args = Args::parse();

    info!("╔═══════════════════════════════════════════════════════════════╗");
    info!("║  FDP SUI Benchmark - SDK-based High-Throughput I/O           ║");
    info!("╚═══════════════════════════════════════════════════════════════╝");
    info!("");
    info!("Configuration:");
    info!("  RPC URL:       {}", args.rpc_url);
    info!("  Package ID:    {}", args.package_id);
    info!("  Duration:      {}s", args.duration);
    info!("  Workers:       {}", args.workers);
    info!("  Batch Size:    {} objects/tx", args.batch_size);
    info!("  Max Inflight:  {}", args.max_inflight);
    info!("  Create %:      {}%", args.create_pct);
    info!("  Seed Objects:  {} per worker", args.seed_objects);
    info!("  Memory Limit:  {:.0}% throttle, {:.0}% critical, {:.0}% abort", 
          args.memory_threshold * 100.0, args.memory_critical * 100.0, args.memory_emergency * 100.0);
    info!("");

    // Parse package ID
    let package_id = ObjectID::from_hex_literal(&args.package_id)
        .context("Invalid package ID format")?;

    // Connect to SUI node
    info!("Connecting to SUI node...");
    let client = SuiClientBuilder::default()
        .build(&args.rpc_url)
        .await
        .context("Failed to connect to SUI node")?;

    info!("Connected to SUI node");

    // Cache reference gas price (fetch once, not per transaction)
    let cached_rgp = client
        .governance_api()
        .get_reference_gas_price()
        .await
        .unwrap_or(1000);
    info!("Cached reference gas price: {}", cached_rgp);

    // Running flag for workers
    let running = Arc::new(AtomicBool::new(true));

    // Semaphore for concurrency control - per-worker semaphore for better parallelism
    let semaphore = Arc::new(Semaphore::new(args.max_inflight));

    // Initialize workers IN PARALLEL (much faster than sequential)
    info!("Initializing {} workers in parallel...", args.workers);
    let init_start = Instant::now();
    
    // Worker initialization depends on whether we're loading from previous phase
    let mut workers = Vec::new();
    
    if let Some(load_path) = &args.load_objects {
        // ═══════════════════════════════════════════════════════════════════════════
        // LOAD MODE: Restore workers from saved state (same keypairs = same ownership)
        // ═══════════════════════════════════════════════════════════════════════════
        info!("Loading workers and objects from {}...", load_path);
        let load_start = Instant::now();
        
        let file_content = std::fs::read_to_string(load_path)
            .context(format!("Failed to read objects file: {}", load_path))?;
        let saved_state: SavedBenchmarkState = serde_json::from_str(&file_content)
            .context("Failed to parse objects file")?;
        
        info!("Found {} saved workers with {} total objects", 
            saved_state.workers.len(), saved_state.total_objects);
        
        // Restore workers with their original keypairs
        for saved_worker in &saved_state.workers {
            // Decode the keypair from base64
            let keypair = SuiKeyPair::decode_base64(&saved_worker.keypair_base64)
                .context(format!("Failed to decode keypair for worker {}", saved_worker.worker_id))?;
            
            // Request gas for this address (same address that owns the objects)
            let gas_coin = request_gas_from_faucet(&client, saved_worker.address).await?;
            
            info!("Worker {}: restored with {} objects (address: {})", 
                saved_worker.worker_id, saved_worker.objects.len(), 
                &saved_worker.address.to_string()[..16]);
            
            workers.push(Arc::new(RwLock::new(WorkerState {
                id: saved_worker.worker_id,
                address: saved_worker.address,
                keypair,
                gas_coin,
                objects: saved_worker.objects.clone(),
            })));
        }
        
        info!("Loaded {} workers in {:.1}s", workers.len(), load_start.elapsed().as_secs_f64());
        
        // Refresh object versions from chain (objects may have been updated since save)
        info!("Refreshing object versions from chain...");
        let refresh_start = Instant::now();
        for worker in &workers {
            refresh_worker_objects(&client, worker.clone()).await?;
        }
        info!("Object versions refreshed in {:.1}s", refresh_start.elapsed().as_secs_f64());
        
    } else {
        // ═══════════════════════════════════════════════════════════════════════════
        // FRESH MODE: Create new workers with random keypairs
        // ═══════════════════════════════════════════════════════════════════════════
        let keypairs: Vec<_> = (0..args.workers)
            .map(|i| {
                let (address, keypair): (SuiAddress, AccountKeyPair) = get_key_pair();
                (i, address, keypair)
            })
            .collect();
        
        // Request gas from faucet in parallel batches (to avoid overwhelming faucet)
        let batch_size = 8; // Process 8 workers at a time
        
        for chunk in keypairs.chunks(batch_size) {
            let mut faucet_futures = Vec::new();
            for (i, address, keypair) in chunk {
                let client = client.clone();
                let addr = *address;
                let id = *i;
                let kp = keypair.copy();
                faucet_futures.push(async move {
                    let gas_coin = request_gas_from_faucet(&client, addr).await?;
                    Ok::<_, anyhow::Error>((id, addr, kp, gas_coin))
                });
            }
            
            // Execute batch in parallel
            let results = futures::future::join_all(faucet_futures).await;
            for result in results {
                let (id, address, keypair, gas_coin) = result?;
                info!("Worker {}: ready", id);
                workers.push(Arc::new(RwLock::new(WorkerState {
                    id,
                    address,
                    keypair: SuiKeyPair::Ed25519(keypair),
                    gas_coin,
                    objects: Vec::new(),
                })));
            }
        }
        info!("Workers initialized in {:.1}s", init_start.elapsed().as_secs_f64());

        // Create seed objects for each worker IN PARALLEL
        info!("Creating seed objects ({} per worker) in parallel...", args.seed_objects);
        let seed_start = Instant::now();
        let mut seed_futures = Vec::new();
        for worker in &workers {
            let client = client.clone();
            let w = worker.clone();
            seed_futures.push(async move {
                create_seed_objects(&client, w, package_id, args.seed_objects, args.gas_budget).await
            });
        }
        // Execute all seed creations in parallel
        let seed_results = futures::future::join_all(seed_futures).await;
        for result in seed_results {
            result?;
        }
        info!("Seed objects created in {:.1}s", seed_start.elapsed().as_secs_f64());
    }

    // Initialize stats AFTER setup - this ensures DURATION measures actual benchmark time
    let stats = Arc::new(BenchStats::new());
    
    // Start benchmark
    info!("");
    info!("═══════════════════════════════════════════════════════════════");
    info!("  BENCHMARK STARTED (duration: {}s)", args.duration);
    info!("═══════════════════════════════════════════════════════════════");

    // Start stats reporter
    let stats_clone = stats.clone();
    let running_clone = running.clone();
    let stats_interval = args.stats_interval;
    tokio::spawn(async move {
        while running_clone.load(Ordering::Relaxed) {
            sleep(Duration::from_secs(stats_interval)).await;
            info!("{}", stats_clone.report());
        }
    });

    // Memory pressure level (0-3) for graduated throttling - NEVER abort, only throttle
    let memory_pressure = Arc::new(AtomicU8::new(MEM_PRESSURE_NORMAL));
    
    // Start memory monitor task
    let memory_pressure_clone = memory_pressure.clone();
    let running_clone = running.clone();
    let mem_threshold = args.memory_threshold;
    let mem_critical = args.memory_critical;
    let mem_emergency = args.memory_emergency;
    tokio::spawn(async move {
        let mut last_level = MEM_PRESSURE_NORMAL;
        let mut last_log_time = Instant::now();
        
        while running_clone.load(Ordering::Relaxed) {
            let usage = get_memory_usage_pct();
            
            let new_level = if usage >= mem_emergency {
                MEM_PRESSURE_EMERGENCY  // >92%: max throttle (but NO abort!)
            } else if usage >= mem_critical {
                MEM_PRESSURE_HEAVY      // >85%: heavy throttle
            } else if usage >= mem_threshold {
                MEM_PRESSURE_LIGHT      // >75%: light throttle
            } else {
                MEM_PRESSURE_NORMAL     // <75%: normal operation
            };
            
            // Log level changes or periodic updates during pressure
            if new_level != last_level || (new_level > MEM_PRESSURE_NORMAL && last_log_time.elapsed() > Duration::from_secs(30)) {
                match new_level {
                    MEM_PRESSURE_EMERGENCY => warn!("🔴 EMERGENCY THROTTLE: {:.1}% - max delay, dropping 75% objects, skipping creates", usage * 100.0),
                    MEM_PRESSURE_HEAVY => warn!("🟠 HEAVY THROTTLE: {:.1}% - long delay, dropping 50% objects", usage * 100.0),
                    MEM_PRESSURE_LIGHT => warn!("🟡 LIGHT THROTTLE: {:.1}% - small delay, dropping 25% objects", usage * 100.0),
                    _ => if last_level > MEM_PRESSURE_NORMAL {
                        info!("🟢 Memory recovered: {:.1}% - resuming normal operation", usage * 100.0);
                    },
                }
                last_level = new_level;
                last_log_time = Instant::now();
            }
            
            memory_pressure_clone.store(new_level, Ordering::Relaxed);
            
            // Check every 500ms for faster reaction to memory spikes
            sleep(Duration::from_millis(500)).await;
        }
    });

    let deadline = Instant::now() + Duration::from_secs(args.duration);
    let mut handles = FuturesUnordered::new();

    // Spawn worker tasks (clone worker refs so we can still access them after benchmark)
    for worker in &workers {
        let client = client.clone();
        let args = args.clone();
        let stats = stats.clone();
        let running = running.clone();
        let semaphore = semaphore.clone();
        let memory_pressure = memory_pressure.clone();
        let worker = worker.clone();  // Clone the Arc

        let handle = tokio::spawn(async move {
            run_worker(
                client,
                worker,
                package_id,
                args,
                stats,
                running,
                semaphore,
                deadline,
                cached_rgp,
                memory_pressure,
            ).await
        });

        handles.push(handle);
    }

    // Wait for all workers
    while let Some(result) = handles.next().await {
        if let Err(e) = result {
            error!("Worker error: {:?}", e);
        }
    }

    // Stop stats reporter
    running.store(false, Ordering::Relaxed);

    // Final report
    info!("");
    info!("═══════════════════════════════════════════════════════════════");
    info!("  BENCHMARK COMPLETE");
    info!("═══════════════════════════════════════════════════════════════");
    info!("{}", stats.report());

    // Write output file if requested
    if let Some(output_path) = &args.output {
        let elapsed = stats.start_time.elapsed().as_secs_f64();
        let result = serde_json::json!({
            "duration_secs": elapsed,
            "tx_submitted": stats.tx_submitted.load(Ordering::Relaxed),
            "tx_success": stats.tx_success.load(Ordering::Relaxed),
            "tx_failed": stats.tx_failed.load(Ordering::Relaxed),
            "objects_created": stats.objects_created.load(Ordering::Relaxed),
            "objects_updated": stats.objects_updated.load(Ordering::Relaxed),
            "tps": stats.tx_success.load(Ordering::Relaxed) as f64 / elapsed,
            "config": {
                "workers": args.workers,
                "batch_size": args.batch_size,
                "create_pct": args.create_pct,
                "max_inflight": args.max_inflight,
            }
        });

        std::fs::write(output_path, serde_json::to_string_pretty(&result)?)?;
        info!("Results written to {}", output_path);
    }

    // Save objects to file if requested (for use in next phase)
    if let Some(save_path) = &args.save_objects {
        info!("Saving objects and keypairs to {}...", save_path);
        
        let mut saved_workers = Vec::new();
        let mut total_objects = 0usize;
        
        for worker in &workers {
            let state = worker.read().await;
            total_objects += state.objects.len();
            
            // Encode keypair to base64 for portability
            let keypair_base64 = state.keypair.encode_base64();
            
            saved_workers.push(SavedWorkerObjects {
                worker_id: state.id,
                address: state.address,
                keypair_base64,
                objects: state.objects.clone(),
            });
        }
        
        let saved_state = SavedBenchmarkState {
            total_objects,
            workers: saved_workers,
        };
        
        let json = serde_json::to_string_pretty(&saved_state)?;
        let mut file = File::create(save_path)?;
        file.write_all(json.as_bytes())?;
        
        info!("Saved {} objects and {} worker keypairs to {}", total_objects, workers.len(), save_path);
    }

    Ok(())
}

/// Request gas from the local faucet
async fn request_gas_from_faucet(client: &SuiClient, address: SuiAddress) -> Result<ObjectRef> {
    // Try local faucet first
    let faucet_url = "http://127.0.0.1:9123/gas";

    let faucet_client = reqwest::Client::new();
    
    // Retry faucet request up to 3 times
    let mut faucet_success = false;
    for attempt in 1..=3 {
        let response = faucet_client
            .post(faucet_url)
            .json(&serde_json::json!({
                "FixedAmountRequest": {
                    "recipient": address.to_string()
                }
            }))
            .send()
            .await;

        match response {
            Ok(resp) if resp.status().is_success() => {
                debug!("Faucet request succeeded for {} (attempt {})", address, attempt);
                faucet_success = true;
                break;
            }
            Ok(resp) => {
                warn!("Faucet returned status {} for {} (attempt {})", resp.status(), address, attempt);
            }
            Err(e) => {
                warn!("Faucet request error for {} (attempt {}): {}", address, attempt, e);
            }
        }
        
        if attempt < 3 {
            sleep(Duration::from_millis(500)).await;
        }
    }
    
    if !faucet_success {
        warn!("All faucet attempts failed for {}, checking existing coins...", address);
    }

    // Wait for the faucet transaction to be processed
    sleep(Duration::from_secs(2)).await;

    // Retry getting coins with exponential backoff
    for attempt in 1..=5 {
        let coins = client
            .coin_read_api()
            .get_coins(address, None, None, None)
            .await
            .context("Failed to get coins")?;

        if let Some(coin) = coins.data.into_iter().max_by_key(|c| c.balance) {
            info!("Got gas coin for {}: {} (balance: {})", address, coin.coin_object_id, coin.balance);
            return Ok((coin.coin_object_id, coin.version, coin.digest));
        }
        
        if attempt < 5 {
            let delay = Duration::from_millis(500 * (1 << attempt)); // exponential backoff
            debug!("No coins found for {} (attempt {}), retrying in {:?}...", address, attempt, delay);
            sleep(delay).await;
        }
    }

    Err(anyhow!("No gas coins found for address {} after multiple retries", address))
}

/// Create initial seed objects for a worker
async fn create_seed_objects(
    client: &SuiClient,
    worker: Arc<RwLock<WorkerState>>,
    package_id: ObjectID,
    count: usize,
    gas_budget: u64,
) -> Result<()> {
    let mut remaining = count;
    let batch_size = 100; // Create in batches

    while remaining > 0 {
        let batch = remaining.min(batch_size);
        remaining -= batch;

        let mut state = worker.write().await;

        // Build create_batch transaction
        let mut builder = ProgrammableTransactionBuilder::new();
        // Must call pure() before programmable_move_call to avoid borrow conflict
        let batch_arg = builder.pure(batch as u64).unwrap();
        builder.programmable_move_call(
            package_id,
            Identifier::new("io_churn").unwrap(),
            Identifier::new("create_batch").unwrap(),
            vec![],
            vec![batch_arg],
        );

        let pt = builder.finish();

        // Get reference gas price
        let rgp = client
            .governance_api()
            .get_reference_gas_price()
            .await
            .unwrap_or(1000);

        let tx_data = TransactionData::new_programmable(
            state.address,
            vec![state.gas_coin],
            pt,
            gas_budget,
            rgp,
        );

        // Sign and create transaction using Transaction::from_data_and_signer
        let tx = Transaction::from_data_and_signer(
            tx_data,
            vec![&state.keypair],
        );

        let response = client
            .quorum_driver_api()
            .execute_transaction_block(
                tx,
                SuiTransactionBlockResponseOptions::new()
                    .with_effects()
                    .with_object_changes(),
                Some(ExecuteTransactionRequestType::WaitForEffectsCert),
            )
            .await
            .context("Failed to execute create_batch")?;

        // Update gas coin
        if let Some(effects) = &response.effects {
            let gas_obj = effects.gas_object();
            state.gas_coin = (gas_obj.object_id(), gas_obj.version(), gas_obj.reference.digest);

            // Track created objects
            if let Some(changes) = &response.object_changes {
                for change in changes {
                    if let sui_sdk::rpc_types::ObjectChange::Created { object_id, version, digest, .. } = change {
                        // Cap tracked objects to prevent memory bloat
                        if state.objects.len() < MAX_TRACKED_OBJECTS_PER_WORKER {
                            state.objects.push(TrackedObject {
                                id: *object_id,
                                version: version.value(),
                                digest: *digest,
                            });
                        }
                    }
                }
            }
        }

        debug!("Worker {}: created {} seed objects, total: {}", state.id, batch, state.objects.len());
    }

    Ok(())
}

/// Refresh object versions from chain (needed when loading objects from previous phase)
async fn refresh_worker_objects(
    client: &SuiClient,
    worker: Arc<RwLock<WorkerState>>,
) -> Result<()> {
    let mut state = worker.write().await;
    
    if state.objects.is_empty() {
        return Ok(());
    }
    
    // Query objects in batches to get current versions
    let batch_size = 50;
    let mut refreshed_objects = Vec::new();
    
    for chunk in state.objects.chunks(batch_size) {
        let object_ids: Vec<ObjectID> = chunk.iter().map(|o| o.id).collect();
        
        let response = client
            .read_api()
            .multi_get_object_with_options(
                object_ids.clone(),
                sui_sdk::rpc_types::SuiObjectDataOptions::new()
                    .with_owner(),
            )
            .await
            .context("Failed to query objects")?;
        
        for obj_response in response {
            if let Some(data) = obj_response.data {
                refreshed_objects.push(TrackedObject {
                    id: data.object_id,
                    version: data.version.value(),
                    digest: data.digest,
                });
            }
        }
    }
    
    let old_count = state.objects.len();
    let new_count = refreshed_objects.len();
    
    state.objects = refreshed_objects;
    
    if new_count < old_count {
        debug!("Worker {}: refreshed {} objects ({} no longer exist)", 
            state.id, new_count, old_count - new_count);
    } else {
        debug!("Worker {}: refreshed {} objects", state.id, new_count);
    }
    
    Ok(())
}

/// Run a single worker
async fn run_worker(
    client: SuiClient,
    worker: Arc<RwLock<WorkerState>>,
    package_id: ObjectID,
    args: Args,
    stats: Arc<BenchStats>,
    running: Arc<AtomicBool>,
    semaphore: Arc<Semaphore>,
    deadline: Instant,
    cached_rgp: u64,
    memory_pressure: Arc<AtomicU8>,
) -> Result<()> {
    // Use StdRng which is Send (unlike thread_rng)
    let mut rng = rand::rngs::StdRng::from_entropy();
    let mut consecutive_failures = 0u32;
    const MAX_CONSECUTIVE_FAILURES: u32 = 10;
    const BACKOFF_ON_FAILURE: Duration = Duration::from_millis(500);
    const MAX_BACKOFF: Duration = Duration::from_secs(5);

    while running.load(Ordering::Relaxed) && Instant::now() < deadline {
        // Graduated memory pressure throttling
        let pressure_level = memory_pressure.load(Ordering::Relaxed);
        
        if pressure_level > MEM_PRESSURE_NORMAL {
            // Apply throttling based on pressure level
            let (drop_pct, delay_ms, skip_creates) = match pressure_level {
                MEM_PRESSURE_EMERGENCY => (75, 2000, true),   // Drop 75%, 2s delay, no creates
                MEM_PRESSURE_HEAVY => (50, 1000, false),      // Drop 50%, 1s delay
                MEM_PRESSURE_LIGHT => (25, 250, false),       // Drop 25%, 250ms delay
                _ => (0, 0, false),
            };
            
            // Drop tracked objects to free memory
            if drop_pct > 0 {
                let mut state = worker.write().await;
                let before = state.objects.len();
                if before > 50 {
                    let keep = before * (100 - drop_pct) / 100;
                    state.objects.truncate(keep);
                    debug!("Pressure L{}: dropped {} objects (keeping {})", pressure_level, before - keep, keep);
                }
            }
            
            // Delay to let memory recover
            if delay_ms > 0 {
                sleep(Duration::from_millis(delay_ms)).await;
            }
            
            // At emergency level, skip creates entirely and only do updates
            if skip_creates {
                let state = worker.read().await;
                if state.objects.is_empty() {
                    // No objects to update - just wait
                    sleep(Duration::from_secs(1)).await;
                    continue;
                }
                drop(state);
                
                // Force update-only operation
                let _permit = semaphore.acquire().await?;
                let result = if args.use_blobs {
                    execute_update_blob_batch(&client, &worker, package_id, args.batch_size, args.gas_budget, cached_rgp).await
                } else {
                    execute_update_batch(&client, &worker, package_id, args.batch_size, args.gas_budget, cached_rgp).await
                };
                
                stats.tx_submitted.fetch_add(1, Ordering::Relaxed);
                match result {
                    Ok((created, updated)) => {
                        stats.tx_success.fetch_add(1, Ordering::Relaxed);
                        stats.objects_created.fetch_add(created, Ordering::Relaxed);
                        stats.objects_updated.fetch_add(updated, Ordering::Relaxed);
                        consecutive_failures = 0;
                    }
                    Err(_) => {
                        stats.tx_failed.fetch_add(1, Ordering::Relaxed);
                    }
                }
                continue;
            }
        }
        
        // Adaptive throttling based on failure rate
        let total = stats.tx_submitted.load(Ordering::Relaxed);
        let failed = stats.tx_failed.load(Ordering::Relaxed);
        
        if total > 100 {
            let failure_rate = failed as f64 / total as f64;
            if failure_rate > 0.30 {
                // Critical: >30% failure rate - pause significantly
                warn!("Critical failure rate ({:.1}%) - pausing 5s", failure_rate * 100.0);
                sleep(Duration::from_secs(5)).await;
            } else if failure_rate > 0.10 {
                // High: >10% failure rate - slow down
                sleep(Duration::from_millis(200)).await;
            }
        }

        // Acquire permit
        let _permit = semaphore.acquire().await?;

        // Decide operation type
        let do_create = rng.gen_range(0..100) < args.create_pct as u32;

        let result = if args.use_blobs {
            // Use 4KB LargeBlob objects (40x more I/O per object)
            if do_create {
                execute_create_blob_batch(&client, &worker, package_id, args.batch_size, args.gas_budget, cached_rgp).await
            } else {
                execute_update_blob_batch(&client, &worker, package_id, args.batch_size, args.gas_budget, cached_rgp).await
            }
        } else {
            // Use MicroCounter objects (~100 bytes each)
            if do_create {
                execute_create_batch(&client, &worker, package_id, args.batch_size, args.gas_budget, cached_rgp).await
            } else {
                execute_update_batch(&client, &worker, package_id, args.batch_size, args.gas_budget, cached_rgp).await
            }
        };

        stats.tx_submitted.fetch_add(1, Ordering::Relaxed);

        match result {
            Ok((created, updated)) => {
                stats.tx_success.fetch_add(1, Ordering::Relaxed);
                stats.objects_created.fetch_add(created, Ordering::Relaxed);
                stats.objects_updated.fetch_add(updated, Ordering::Relaxed);
                consecutive_failures = 0;  // Reset on success
            }
            Err(e) => {
                stats.tx_failed.fetch_add(1, Ordering::Relaxed);
                debug!("Transaction failed: {:?}", e);
                
                // Exponential backoff on consecutive failures
                consecutive_failures += 1;
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
                    let backoff = std::cmp::min(
                        BACKOFF_ON_FAILURE * consecutive_failures,
                        MAX_BACKOFF
                    );
                    warn!("Worker: {} consecutive failures, backing off {:?}", consecutive_failures, backoff);
                    sleep(backoff).await;
                }
            }
        }

        // Rate limiting if target TPS is set
        if args.target_tps > 0 {
            let target_interval = Duration::from_secs_f64(1.0 / args.target_tps as f64 * args.workers as f64);
            sleep(target_interval).await;
        }
    }

    Ok(())
}
/// Execute a create_batch transaction
async fn execute_create_batch(
    client: &SuiClient,
    worker: &Arc<RwLock<WorkerState>>,
    package_id: ObjectID,
    count: usize,
    gas_budget: u64,
    rgp: u64,
) -> Result<(u64, u64)> {
    let mut state = worker.write().await;

    let mut builder = ProgrammableTransactionBuilder::new();
    // Must call pure() before programmable_move_call to avoid borrow conflict
    let count_arg = builder.pure(count as u64).unwrap();
    builder.programmable_move_call(
        package_id,
        Identifier::new("io_churn").unwrap(),
        Identifier::new("create_batch").unwrap(),
        vec![],
        vec![count_arg],
    );

    let pt = builder.finish();

    let tx_data = TransactionData::new_programmable(
        state.address,
        vec![state.gas_coin],
        pt,
        gas_budget,
        rgp,
    );

    // Sign and create transaction using Transaction::from_data_and_signer
    let tx = Transaction::from_data_and_signer(
        tx_data,
        vec![&state.keypair],
    );

    let response = client
        .quorum_driver_api()
        .execute_transaction_block(
            tx,
            SuiTransactionBlockResponseOptions::new()
                .with_effects()
                .with_object_changes(),
            Some(ExecuteTransactionRequestType::WaitForEffectsCert),
        )
        .await?;

    let mut created_count = 0u64;

    if let Some(effects) = &response.effects {
        let gas_obj = effects.gas_object();
        state.gas_coin = (gas_obj.object_id(), gas_obj.version(), gas_obj.reference.digest);

        if let Some(changes) = &response.object_changes {
            for change in changes {
                if let sui_sdk::rpc_types::ObjectChange::Created { object_id, version, digest, .. } = change {
                    // Cap tracked objects to prevent memory bloat
                    if state.objects.len() < MAX_TRACKED_OBJECTS_PER_WORKER {
                        state.objects.push(TrackedObject {
                            id: *object_id,
                            version: version.value(),
                            digest: *digest,
                        });
                    }
                    created_count += 1;
                }
            }
        }
    }

    Ok((created_count, 0))
}

/// Execute an update batch transaction (increment_simple on multiple objects)
async fn execute_update_batch(
    client: &SuiClient,
    worker: &Arc<RwLock<WorkerState>>,
    package_id: ObjectID,
    count: usize,
    gas_budget: u64,
    rgp: u64,
) -> Result<(u64, u64)> {
    let mut state = worker.write().await;

    if state.objects.is_empty() {
        return Err(anyhow!("No objects to update"));
    }

    let update_count = count.min(state.objects.len());
    let mut builder = ProgrammableTransactionBuilder::new();

    // Select objects to update (round-robin with random start)
    let start_idx = rand::rngs::StdRng::from_entropy().gen_range(0..state.objects.len());
    let mut updated_indices = Vec::new();

    for i in 0..update_count {
        let idx = (start_idx + i) % state.objects.len();
        let obj = &state.objects[idx];

        let obj_arg = builder.obj(sui_sdk::types::transaction::ObjectArg::ImmOrOwnedObject(
            (obj.id, obj.version.into(), obj.digest),
        ))?;

        builder.programmable_move_call(
            package_id,
            Identifier::new("io_churn").unwrap(),
            Identifier::new("increment_simple").unwrap(),
            vec![],
            vec![obj_arg],
        );

        updated_indices.push(idx);
    }

    let pt = builder.finish();

    let tx_data = TransactionData::new_programmable(
        state.address,
        vec![state.gas_coin],
        pt,
        gas_budget,
        rgp,
    );

    // Sign and create transaction using Transaction::from_data_and_signer
    let tx = Transaction::from_data_and_signer(
        tx_data,
        vec![&state.keypair],
    );

    let response = client
        .quorum_driver_api()
        .execute_transaction_block(
            tx,
            SuiTransactionBlockResponseOptions::new()
                .with_effects()
                .with_object_changes(),
            Some(ExecuteTransactionRequestType::WaitForEffectsCert),
        )
        .await?;

    let mut updated_count = 0u64;

    if let Some(effects) = &response.effects {
        // Update gas coin
        let gas_obj = effects.gas_object();
        state.gas_coin = (gas_obj.object_id(), gas_obj.version(), gas_obj.reference.digest);

        // Update object versions
        if let Some(changes) = &response.object_changes {
            for change in changes {
                if let sui_sdk::rpc_types::ObjectChange::Mutated { object_id, version, digest, .. } = change {
                    if let Some(obj) = state.objects.iter_mut().find(|o| o.id == *object_id) {
                        obj.version = version.value();
                        obj.digest = *digest;
                        updated_count += 1;
                    }
                }
            }
        }
    }

    Ok((0, updated_count))
}

/// Execute a create_blob_batch transaction (4KB objects instead of ~100B)
async fn execute_create_blob_batch(
    client: &SuiClient,
    worker: &Arc<RwLock<WorkerState>>,
    package_id: ObjectID,
    count: usize,
    gas_budget: u64,
    rgp: u64,
) -> Result<(u64, u64)> {
    let mut state = worker.write().await;

    // Limit blob batch size since each blob is 4KB
    let batch = count.min(20); // 20 blobs = 80KB per TX

    let mut builder = ProgrammableTransactionBuilder::new();
    let count_arg = builder.pure(batch as u64).unwrap();
    builder.programmable_move_call(
        package_id,
        Identifier::new("io_churn").unwrap(),
        Identifier::new("create_blob_batch").unwrap(),
        vec![],
        vec![count_arg],
    );

    let pt = builder.finish();

    let tx_data = TransactionData::new_programmable(
        state.address,
        vec![state.gas_coin],
        pt,
        gas_budget,
        rgp,
    );

    let tx = Transaction::from_data_and_signer(
        tx_data,
        vec![&state.keypair],
    );

    let response = client
        .quorum_driver_api()
        .execute_transaction_block(
            tx,
            SuiTransactionBlockResponseOptions::new()
                .with_effects()
                .with_object_changes(),
            Some(ExecuteTransactionRequestType::WaitForEffectsCert),
        )
        .await?;

    let mut created_count = 0u64;

    if let Some(effects) = &response.effects {
        let gas_obj = effects.gas_object();
        state.gas_coin = (gas_obj.object_id(), gas_obj.version(), gas_obj.reference.digest);

        if let Some(changes) = &response.object_changes {
            for change in changes {
                if let sui_sdk::rpc_types::ObjectChange::Created { object_id, version, digest, .. } = change {
                    // Cap tracked objects to prevent memory bloat
                    if state.objects.len() < MAX_TRACKED_OBJECTS_PER_WORKER {
                        state.objects.push(TrackedObject {
                            id: *object_id,
                            version: version.value(),
                            digest: *digest,
                        });
                    }
                    created_count += 1;
                }
            }
        }
    }

    Ok((created_count, 0))
}

/// Execute an update_blob batch transaction (4KB update per object)
async fn execute_update_blob_batch(
    client: &SuiClient,
    worker: &Arc<RwLock<WorkerState>>,
    package_id: ObjectID,
    count: usize,
    gas_budget: u64,
    rgp: u64,
) -> Result<(u64, u64)> {
    let mut state = worker.write().await;

    if state.objects.is_empty() {
        return Err(anyhow!("No objects to update"));
    }

    // Limit blob updates since each is 4KB
    let update_count = count.min(20).min(state.objects.len());
    let mut builder = ProgrammableTransactionBuilder::new();

    let start_idx = rand::rngs::StdRng::from_entropy().gen_range(0..state.objects.len());
    let mut updated_indices = Vec::new();

    for i in 0..update_count {
        let idx = (start_idx + i) % state.objects.len();
        let obj = &state.objects[idx];

        let obj_arg = builder.obj(sui_sdk::types::transaction::ObjectArg::ImmOrOwnedObject(
            (obj.id, obj.version.into(), obj.digest),
        ))?;

        // Use update_blob instead of increment_simple
        builder.programmable_move_call(
            package_id,
            Identifier::new("io_churn").unwrap(),
            Identifier::new("update_blob").unwrap(),
            vec![],
            vec![obj_arg],
        );

        updated_indices.push(idx);
    }

    let pt = builder.finish();

    let tx_data = TransactionData::new_programmable(
        state.address,
        vec![state.gas_coin],
        pt,
        gas_budget,
        rgp,
    );

    let tx = Transaction::from_data_and_signer(
        tx_data,
        vec![&state.keypair],
    );

    let response = client
        .quorum_driver_api()
        .execute_transaction_block(
            tx,
            SuiTransactionBlockResponseOptions::new()
                .with_effects()
                .with_object_changes(),
            Some(ExecuteTransactionRequestType::WaitForEffectsCert),
        )
        .await?;

    let mut updated_count = 0u64;

    if let Some(effects) = &response.effects {
        let gas_obj = effects.gas_object();
        state.gas_coin = (gas_obj.object_id(), gas_obj.version(), gas_obj.reference.digest);

        if let Some(changes) = &response.object_changes {
            for change in changes {
                if let sui_sdk::rpc_types::ObjectChange::Mutated { object_id, version, digest, .. } = change {
                    if let Some(obj) = state.objects.iter_mut().find(|o| o.id == *object_id) {
                        obj.version = version.value();
                        obj.digest = *digest;
                        updated_count += 1;
                    }
                }
            }
        }
    }

    Ok((0, updated_count))
}
