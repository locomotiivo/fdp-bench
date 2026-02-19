use {
    crate::{
        bench_tps_client::*,
        block_metrics,
        cli::{ComputeUnitPrice, Config, InstructionPaddingConfig},
        perf_utils::{sample_txs, SampleStats},
        send_batch::*,
    },
    log::*,
    rand::distributions::{Distribution, Uniform},
    rayon::prelude::*,
    solana_client::{nonce_utils, rpc_request::MAX_MULTIPLE_ACCOUNTS},
    solana_metrics::{self, datapoint_info},
    solana_sdk::{
        account::Account,
        clock::{DEFAULT_MS_PER_SLOT, DEFAULT_S_PER_SLOT, MAX_PROCESSING_AGE},
        commitment_config::CommitmentConfig,
        compute_budget::ComputeBudgetInstruction,
        hash::Hash,
        instruction::{AccountMeta, Instruction},
        message::Message,
        native_token::Sol,
        pubkey::Pubkey,
        signature::{Keypair, Signature, Signer},
        system_instruction,
        timing::{duration_as_ms, duration_as_s, duration_as_us, timestamp},
        transaction::Transaction,
    },
    spl_instruction_padding::instruction::wrap_instruction,
    std::{
        collections::{HashMap, HashSet, VecDeque},
        fs::File,
        io::Write as IoWrite,
        process::exit,
        sync::{
            atomic::{AtomicBool, AtomicIsize, AtomicUsize, Ordering},
            Arc, RwLock,
        },
        thread::{sleep, Builder, JoinHandle},
        time::{Duration, Instant},
    },
};

// The point at which transactions become "too old", in seconds.
const MAX_TX_QUEUE_AGE: u64 = (MAX_PROCESSING_AGE as f64 * DEFAULT_S_PER_SLOT) as u64;

// Add prioritization fee to transfer transactions, if `compute_unit_price` is set.
// If `Random` the compute-unit-price is determined by generating a random number in the range
// 0..MAX_RANDOM_COMPUTE_UNIT_PRICE then multiplying by COMPUTE_UNIT_PRICE_MULTIPLIER.
// If `Fixed` the compute-unit-price is the value of the `compute-unit-price` parameter.
// It also sets transaction's compute-unit to TRANSFER_TRANSACTION_COMPUTE_UNIT. Therefore the
// max additional cost is:
// `TRANSFER_TRANSACTION_COMPUTE_UNIT * MAX_COMPUTE_UNIT_PRICE * COMPUTE_UNIT_PRICE_MULTIPLIER / 1_000_000`
const MAX_RANDOM_COMPUTE_UNIT_PRICE: u64 = 50;
const COMPUTE_UNIT_PRICE_MULTIPLIER: u64 = 1_000;
const TRANSFER_TRANSACTION_COMPUTE_UNIT: u32 = 600; // 1 transfer is plus 3 compute_budget ixs
const PADDED_TRANSFER_COMPUTE_UNIT: u32 = 3_000; // padding program execution requires consumes this amount

/// calculate maximum possible prioritization fee, if `use-randomized-compute-unit-price` is
/// enabled, round to nearest lamports.
pub fn max_lamports_for_prioritization(compute_unit_price: &Option<ComputeUnitPrice>) -> u64 {
    let Some(compute_unit_price) = compute_unit_price else {
        return 0;
    };

    let compute_unit_price = match compute_unit_price {
        ComputeUnitPrice::Random => (MAX_RANDOM_COMPUTE_UNIT_PRICE as u128)
            .saturating_mul(COMPUTE_UNIT_PRICE_MULTIPLIER as u128),
        ComputeUnitPrice::Fixed(compute_unit_price) => *compute_unit_price as u128,
    };

    const MICRO_LAMPORTS_PER_LAMPORT: u64 = 1_000_000;
    let micro_lamport_fee: u128 =
        compute_unit_price.saturating_mul(TRANSFER_TRANSACTION_COMPUTE_UNIT as u128);
    let fee = micro_lamport_fee
        .saturating_add(MICRO_LAMPORTS_PER_LAMPORT.saturating_sub(1) as u128)
        .saturating_div(MICRO_LAMPORTS_PER_LAMPORT as u128);
    u64::try_from(fee).unwrap_or(u64::MAX)
}

// In case of plain transfer transaction, set loaded account data size to 30K.
// It is large enough yet smaller than 32K page size, so it'd cost 0 extra CU.
const TRANSFER_TRANSACTION_LOADED_ACCOUNTS_DATA_SIZE: u32 = 30 * 1024;
// In case of padding program usage, we need to take into account program size
const PADDING_PROGRAM_ACCOUNT_DATA_SIZE: u32 = 28 * 1024;
fn get_transaction_loaded_accounts_data_size(enable_padding: bool) -> u32 {
    if enable_padding {
        TRANSFER_TRANSACTION_LOADED_ACCOUNTS_DATA_SIZE + PADDING_PROGRAM_ACCOUNT_DATA_SIZE
    } else {
        TRANSFER_TRANSACTION_LOADED_ACCOUNTS_DATA_SIZE
    }
}

pub type TimestampedTransaction = (Transaction, Option<u64>);
pub type SharedTransactions = Arc<RwLock<VecDeque<Vec<TimestampedTransaction>>>>;
/// signature → submit_slot mapping for per-tx slot-latency measurement //sj
pub type PendingMap = Arc<RwLock<HashMap<Signature, u64>>>;

/// Keypairs split into source and destination
/// used for transfer transactions
struct KeypairChunks<'a> {
    source: Vec<Vec<&'a Keypair>>,
    dest: Vec<VecDeque<&'a Keypair>>,
}

impl<'a> KeypairChunks<'a> {
    /// Split input slice of keypairs into two sets of chunks of given size
    fn new(keypairs: &'a [Keypair], chunk_size: usize) -> Self {
        // Use `chunk_size` as the number of conflict groups per chunk so that each destination key is unique
        Self::new_with_conflict_groups(keypairs, chunk_size, chunk_size)
    }

    /// Split input slice of keypairs into two sets of chunks of given size. Each chunk
    /// has a set of source keys and a set of destination keys. There will be
    /// `num_conflict_groups_per_chunk` unique destination keys per chunk, so that the
    /// destination keys may conflict with each other.
    fn new_with_conflict_groups(
        keypairs: &'a [Keypair],
        chunk_size: usize,
        num_conflict_groups_per_chunk: usize,
    ) -> Self {
        let mut source_keypair_chunks: Vec<Vec<&Keypair>> = Vec::new();
        let mut dest_keypair_chunks: Vec<VecDeque<&Keypair>> = Vec::new();
        for chunk in keypairs.chunks_exact(2 * chunk_size) {
            source_keypair_chunks.push(chunk[..chunk_size].iter().collect());
            dest_keypair_chunks.push(
                std::iter::repeat(&chunk[chunk_size..chunk_size + num_conflict_groups_per_chunk])
                    .flatten()
                    .take(chunk_size)
                    .collect(),
            );
        }
        KeypairChunks {
            source: source_keypair_chunks,
            dest: dest_keypair_chunks,
        }
    }
}

struct TransactionChunkGenerator<'a, 'b, T: ?Sized> {
    client: Arc<T>,
    account_chunks: KeypairChunks<'a>,
    nonce_chunks: Option<KeypairChunks<'b>>,
    chunk_index: usize,
    reclaim_lamports_back_to_source_account: bool,
    compute_unit_price: Option<ComputeUnitPrice>,
    instruction_padding_config: Option<InstructionPaddingConfig>,
}

impl<'a, 'b, T> TransactionChunkGenerator<'a, 'b, T>
where
    T: 'static + BenchTpsClient + Send + Sync + ?Sized,
{
    fn new(
        client: Arc<T>,
        gen_keypairs: &'a [Keypair],
        nonce_keypairs: Option<&'b Vec<Keypair>>,
        chunk_size: usize,
        compute_unit_price: Option<ComputeUnitPrice>,
        instruction_padding_config: Option<InstructionPaddingConfig>,
        num_conflict_groups: Option<usize>,
    ) -> Self {
        let account_chunks = if let Some(num_conflict_groups) = num_conflict_groups {
            KeypairChunks::new_with_conflict_groups(gen_keypairs, chunk_size, num_conflict_groups)
        } else {
            KeypairChunks::new(gen_keypairs, chunk_size)
        };
        let nonce_chunks =
            nonce_keypairs.map(|nonce_keypairs| KeypairChunks::new(nonce_keypairs, chunk_size));

        TransactionChunkGenerator {
            client,
            account_chunks,
            nonce_chunks,
            chunk_index: 0,
            reclaim_lamports_back_to_source_account: false,
            compute_unit_price,
            instruction_padding_config,
        }
    }

    /// generate transactions to transfer lamports from source to destination accounts
    /// if durable nonce is used, blockhash is None
    fn generate(&mut self, blockhash: Option<&Hash>) -> Vec<TimestampedTransaction> {
        let tx_count = self.account_chunks.source.len();
        info!(
            "Signing transactions... {} (reclaim={}, blockhash={:?})",
            tx_count, self.reclaim_lamports_back_to_source_account, blockhash
        );
        let signing_start = Instant::now();

        let source_chunk = &self.account_chunks.source[self.chunk_index];
        let dest_chunk = &self.account_chunks.dest[self.chunk_index];
        let transactions = if let Some(nonce_chunks) = &self.nonce_chunks {
            let source_nonce_chunk = &nonce_chunks.source[self.chunk_index];
            let dest_nonce_chunk: &VecDeque<&Keypair> = &nonce_chunks.dest[self.chunk_index];
            generate_nonced_system_txs(
                self.client.clone(),
                source_chunk,
                dest_chunk,
                source_nonce_chunk,
                dest_nonce_chunk,
                self.reclaim_lamports_back_to_source_account,
                &self.instruction_padding_config,
            )
        } else {
            assert!(blockhash.is_some());
            generate_system_txs(
                source_chunk,
                dest_chunk,
                self.reclaim_lamports_back_to_source_account,
                blockhash.unwrap(),
                &self.instruction_padding_config,
                &self.compute_unit_price,
            )
        };

        let duration = signing_start.elapsed();
        let ns = duration.as_secs() * 1_000_000_000 + u64::from(duration.subsec_nanos());
        let bsps = (tx_count) as f64 / ns as f64;
        let nsps = ns as f64 / (tx_count) as f64;
        info!(
            "Done. {:.2} thousand signatures per second, {:.2} us per signature, {} ms total time, {:?}",
            bsps * 1_000_000_f64,
            nsps / 1_000_f64,
            duration_as_ms(&duration),
            blockhash,
        );
        datapoint_info!(
            "bench-tps-generate_txs",
            ("duration", duration_as_us(&duration), i64)
        );

        transactions
    }

    fn advance(&mut self) {
        // Rotate destination keypairs so that the next round of transactions will have different
        // transaction signatures even when blockhash is reused.
        self.account_chunks.dest[self.chunk_index].rotate_left(1);
        if let Some(nonce_chunks) = &mut self.nonce_chunks {
            nonce_chunks.dest[self.chunk_index].rotate_left(1);
        }
        // Move on to next chunk
        self.chunk_index = (self.chunk_index + 1) % self.account_chunks.source.len();

        // Switch directions after transferring for each "chunk"
        if self.chunk_index == 0 {
            self.reclaim_lamports_back_to_source_account =
                !self.reclaim_lamports_back_to_source_account;
        }
    }
}

fn wait_for_target_slots_per_epoch<T>(target_slots_per_epoch: u64, client: &Arc<T>)
where
    T: 'static + BenchTpsClient + Send + Sync + ?Sized,
{
    if target_slots_per_epoch != 0 {
        info!(
            "Waiting until epochs are {} slots long..",
            target_slots_per_epoch
        );
        loop {
            if let Ok(epoch_info) = client.get_epoch_info() {
                if epoch_info.slots_in_epoch >= target_slots_per_epoch {
                    info!("Done epoch_info: {:?}", epoch_info);
                    break;
                }
                info!(
                    "Waiting for epoch: {} now: {}",
                    target_slots_per_epoch, epoch_info.slots_in_epoch
                );
            }
            sleep(Duration::from_secs(3));
        }
    }
}

fn create_sampler_thread<T>(
    client: &Arc<T>,
    exit_signal: Arc<AtomicBool>,
    sample_period: u64,
    maxes: &Arc<RwLock<Vec<(String, SampleStats)>>>,
    ttps: &mut Arc<RwLock<Vec<u64>>>,  
) -> JoinHandle<()>
where
    T: 'static + BenchTpsClient + Send + Sync + ?Sized,
{
    info!("Sampling TPS every {} second...", sample_period);
    let maxes = maxes.clone();
    let client = client.clone();
    let mut ttps= ttps.clone();
    Builder::new()
        .name("solana-client-sample".to_string())
        .spawn(move || {
            sample_txs(exit_signal, &maxes, sample_period, &client , &mut ttps);
        })
        .unwrap()
}

fn generate_chunked_transfers<T: 'static + BenchTpsClient + Send + Sync + ?Sized>(
    recent_blockhash: Arc<RwLock<Hash>>,
    shared_txs: &SharedTransactions,
    shared_tx_active_thread_count: Arc<AtomicIsize>,
    mut chunk_generator: TransactionChunkGenerator<'_, '_, T>,
    threads: usize,
    duration: Duration,
    sustained: bool,
    use_durable_nonce: bool,
) {
    // generate and send transactions for the specified duration
    let start = Instant::now();
    let mut last_generate_txs_time = Instant::now();

    while start.elapsed() < duration {
        generate_txs(
            shared_txs,
            &recent_blockhash,
            &mut chunk_generator,
            threads,
            use_durable_nonce,
        );

        datapoint_info!(
            "blockhash_stats",
            (
                "time_elapsed_since_last_generate_txs",
                last_generate_txs_time.elapsed().as_millis(),
                i64
            )
        );

        last_generate_txs_time = Instant::now();

        // In sustained mode, overlap the transfers with generation. This has higher average
        // performance but lower peak performance in tested environments.
        if sustained {
            // Ensure that we don't generate more transactions than we can handle.
            while shared_txs.read().unwrap().len() > 2 * threads {
                sleep(Duration::from_millis(1));
            }
        } else {
            while !shared_txs.read().unwrap().is_empty()
                || shared_tx_active_thread_count.load(Ordering::Relaxed) > 0
            {
                sleep(Duration::from_millis(1));
            }
        }
        chunk_generator.advance();
    }
}

/// Polls getSignatureStatuses in a background thread and records per-tx slot latency.
/// slot_latency = confirm_slot - submit_slot (unit: slots, 1 slot ≈ 400ms) //sj
fn create_confirm_poller_thread<T>(
    client: Arc<T>,
    exit_signal: Arc<AtomicBool>,
    pending_map: PendingMap,
    slot_latencies: Arc<RwLock<Vec<u64>>>,
) -> JoinHandle<()>
where
    T: 'static + BenchTpsClient + Send + Sync + ?Sized,
{
    Builder::new()
        .name("solana-confirm-poller".to_string())
        .spawn(move || {
            const POLL_INTERVAL_MS: u64 = 1000;
            const BATCH_SIZE: usize = 256;
            let mut drain_start: Option<Instant> = None;
            let bench_start = Instant::now(); //sj time-series baseline

            // Open CSV file for per-second latency time-series //sj
            let csv_path = "slot_latency_timeseries.csv";
            let mut csv_file = File::create(csv_path).expect("Failed to create CSV file");
            writeln!(csv_file, "time_s,n,avg_ms,p50_ms,p95_ms,p99_ms,p99.9_ms,p99.99_ms")
                .expect("Failed to write CSV header");

            loop {
                sleep(Duration::from_millis(POLL_INTERVAL_MS));

                let elapsed_s = bench_start.elapsed().as_secs();
                let is_exiting = exit_signal.load(Ordering::Relaxed);
                if is_exiting && drain_start.is_none() {
                    drain_start = Some(Instant::now());
                }
                // Stop draining after 60s post-benchmark to avoid hanging
                if let Some(start) = drain_start {
                    if start.elapsed().as_secs() > 60 {
                        info!("confirm_poller: drain timeout, {} sigs unresolved",
                            pending_map.read().unwrap().len());
                        break;
                    }
                }

                // Snapshot pending entries
                let entries: Vec<(Signature, u64)> = {
                    let pending = pending_map.read().unwrap();
                    pending.iter().map(|(&sig, &slot)| (sig, slot)).collect()
                };

                if entries.is_empty() {
                    if is_exiting { break; }
                    continue;
                }

                // Collect per-interval latencies for time-series output //sj
                let mut interval_lats: Vec<u64> = Vec::new();

                // Process in batches of 256 (cap per iteration to avoid blocking too long)
                const MAX_BATCHES_PER_ITER: usize = 20; // 20 * 256 = 5120 sigs per iteration
                let mut timed_out = false;
                for (batch_idx, chunk) in entries.chunks(BATCH_SIZE).enumerate() {
                    if batch_idx >= MAX_BATCHES_PER_ITER {
                        break; // process rest next iteration
                    }
                    // Check drain timeout inside inner loop
                    if let Some(start) = drain_start {
                        if start.elapsed().as_secs() > 60 {
                            timed_out = true;
                            break;
                        }
                    }
                    let sigs: Vec<Signature> = chunk.iter().map(|(s, _)| *s).collect();
                    match client.get_signature_statuses(&sigs) {
                        Ok(statuses) => {
                            let mut pending = pending_map.write().unwrap();
                            let mut lats = slot_latencies.write().unwrap();
                            for ((sig, submit_slot), status_opt) in chunk.iter().zip(statuses.iter()) {
                                if let Some((confirm_slot, _has_err)) = status_opt {
                                    let lat = confirm_slot.saturating_sub(*submit_slot);
                                    lats.push(lat);
                                    interval_lats.push(lat);
                                    pending.remove(sig);
                                }
                            }
                        }
                        Err(e) => warn!("confirm_poller get_signature_statuses error: {}", e),
                    }
                }

                // Write per-second time-series latency stats to CSV //sj
                if !interval_lats.is_empty() {
                    interval_lats.sort_unstable();
                    let n = interval_lats.len();
                    let avg_ms = interval_lats.iter().sum::<u64>() as f64 / n as f64 * 400.0;
                    let pct = |p: f64| -> f64 {
                        let idx = ((p / 100.0) * (n as f64 - 1.0)).ceil() as usize;
                        interval_lats[idx.min(n - 1)] as f64 * 400.0
                    };
                    let _ = writeln!(csv_file, "{},{},{:.1},{:.1},{:.1},{:.1},{:.1},{:.1}",
                        elapsed_s, n, avg_ms, pct(50.0), pct(95.0), pct(99.0), pct(99.9), pct(99.99));
                }

                if timed_out {
                    info!("confirm_poller: drain timeout (inner), {} sigs unresolved",
                        pending_map.read().unwrap().len());
                    break;
                }

                if is_exiting && pending_map.read().unwrap().is_empty() {
                    break;
                }
            }
            let _ = csv_file.flush();
            info!("confirm_poller: CSV written to {}", csv_path);
        })
        .unwrap()
}

fn create_sender_threads<T>(
    client: &Arc<T>,
    shared_txs: &SharedTransactions,
    thread_batch_sleep_ms: usize,
    total_tx_sent_count: &Arc<AtomicUsize>,
    ttps: &mut Arc<RwLock<Vec<u64>>>,
    latencies: &mut Arc<RwLock <Vec<u64>>>,
    tpss: &mut Arc<RwLock<Vec<f32>>>,
    threads: usize,
    exit_signal: Arc<AtomicBool>,
    shared_tx_active_thread_count: &Arc<AtomicIsize>,
    pending_map: &PendingMap, //sj slot-latency
) -> Vec<JoinHandle<()>>
where
    T: 'static + BenchTpsClient + Send + Sync + ?Sized,
{
    (0..threads)
    .map(|_| {
        let exit_signal = exit_signal.clone();
        let shared_txs = shared_txs.clone();
        let shared_tx_active_thread_count = shared_tx_active_thread_count.clone();
        let total_tx_sent_count = total_tx_sent_count.clone();
        let client = client.clone();
        let mut latencies = latencies.clone();
        let mut tpss = tpss.clone();
        let mut ttps = ttps.clone();
        let pending_map = pending_map.clone(); //sj

        Builder::new()
            .name("solana-client-sender".to_string())
            .spawn(move || {
                do_tx_transfers(
                    &exit_signal,
                    &shared_txs,
                    &shared_tx_active_thread_count,
                    &total_tx_sent_count,
                    &mut ttps,
                    &mut latencies,
                    &mut tpss,
                    thread_batch_sleep_ms,
                    &client,
                    &pending_map, //sj
                );
            })
            .unwrap()
        })
        .collect()
}
fn sungjin_mean_f32(data: Arc<RwLock<Vec<f32>>>) -> f32 {
    let data = data.read().unwrap();
    let sum: f32 = data.iter().sum();
    sum / data.len() as f32
}
fn sungjin_stddev_f32(data: Arc<RwLock<Vec<f32>>>) -> f32 {
    let data = data.read().unwrap();
    // let mean = sungjin_mean_f32(Arc::clone(&data));

    let sum: f32 = data.iter().sum();
    let mean = sum / data.len() as f32;


    let variance = data.iter()
        .map(|&value| {
            let diff = value - mean;
            diff * diff
        })
        .sum::<f32>() / data.len() as f32;
    variance.sqrt()
}

fn sungjin_percentile_u64_to_f32(data: Arc<RwLock<Vec<u64>>>, percentile: f32) -> f32 {
    let data = data.read().unwrap();
    assert!(!data.is_empty());
    let mut sorted: Vec<f32> = data.iter().map(|&x| x as f32).collect();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let index = ((percentile / 100.0) * (sorted.len() as f32 - 1.0)).ceil() as usize;
    sorted[index]
}

fn sungjin_percentile_f32(data: Arc<RwLock<Vec<f32>>>, percentile: f32) -> f32 {
    let data = data.read().unwrap();
    assert!(!data.is_empty());
    let mut sorted = data.clone();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let index = ((percentile / 100.0) * (sorted.len() as f32 - 1.0)).ceil() as usize;
    sorted[index]
}



fn sungjin_mean(data: Arc<RwLock<Vec<u64>>>) -> f64 {
    let data = data.read().unwrap();
    let sum: u64 = data.iter().sum();
    sum as f64 / data.len() as f64
}

fn sungjin_stddev(data: Arc<RwLock<Vec<u64>>>) -> f64 {
    let data = data.read().unwrap();
    // let mean = sungjin_mean(Arc::clone(&data));
    let sum: u64 = data.iter().sum();
    let mean =    sum as f64 / data.len() as f64;


    let variance = data.iter()
        .map(|&value| {
            let diff = value as f64 - mean;
            diff * diff
        })
        .sum::<f64>() / data.len() as f64;
    variance.sqrt()
}


fn sungjin_percentile(data: Arc<RwLock<Vec<u64>>>, percentile: f64) -> u64 {
    let data = data.read().unwrap();
    assert!(!data.is_empty());
    let mut sorted = data.clone(); // Vec<u64> 복사
    sorted.sort_unstable(); // f64 아님 → unwrap 불필요
    let index = ((percentile / 100.0) * (sorted.len() as f64 - 1.0)).ceil() as usize;
    sorted[index]
}


pub fn do_bench_tps<T>(
    client: Arc<T>,
    config: Config,
    gen_keypairs: Vec<Keypair>,
    nonce_keypairs: Option<Vec<Keypair>>,
) -> u64
where
    T: 'static + BenchTpsClient + Send + Sync + ?Sized,
{
    let Config {
        id,
        threads,
        thread_batch_sleep_ms,
        duration,
        tx_count,
        sustained,
        target_slots_per_epoch,
        compute_unit_price,
        use_durable_nonce,
        instruction_padding_config,
        num_conflict_groups,
        ..
    } = config;

    assert!(gen_keypairs.len() >= 2 * tx_count);
    let chunk_generator = TransactionChunkGenerator::new(
        client.clone(),
        &gen_keypairs,
        nonce_keypairs.as_ref(),
        tx_count,
        compute_unit_price,
        instruction_padding_config,
        num_conflict_groups,
    );

    let first_tx_count = loop {
        match client.get_transaction_count() {
            Ok(count) => break count,
            Err(err) => {
                info!("Couldn't get transaction count: {:?}", err);
                sleep(Duration::from_secs(1));
            }
        }
    };
    info!("Initial transaction count {}", first_tx_count);

    let exit_signal = Arc::new(AtomicBool::new(false));

    // Setup a thread per validator to sample every period
    // collect the max transaction rate and total tx count seen
    let maxes = Arc::new(RwLock::new(Vec::new()));
    let sample_period = 1; // in seconds
    info!("Sungjin printk\n");
    let mut latencies: Arc<RwLock<Vec<u64>>> = Arc::new(RwLock::new(Vec::new()));
    let mut tpss: Arc<RwLock<Vec::<f32>>> = Arc::new(RwLock::new(Vec::new()));
    let mut time_tracked_tps: Arc<RwLock<Vec::<u64>>> = Arc::new(RwLock::new(Vec::new()));
    // slot-latency measurement: pending_map tracks in-flight sigs, slot_latencies stores results //sj
    let pending_map: PendingMap = Arc::new(RwLock::new(HashMap::new()));
    let slot_latencies: Arc<RwLock<Vec<u64>>> = Arc::new(RwLock::new(Vec::new()));


    let sample_thread = create_sampler_thread(&client, exit_signal.clone(), sample_period, &maxes, &mut time_tracked_tps);

    let shared_txs: SharedTransactions = Arc::new(RwLock::new(VecDeque::new()));

    let blockhash = Arc::new(RwLock::new(get_latest_blockhash(client.as_ref())));
    let shared_tx_active_thread_count = Arc::new(AtomicIsize::new(0));
    let total_tx_sent_count = Arc::new(AtomicUsize::new(0));

    // if we use durable nonce, we don't need blockhash thread
    let blockhash_thread = if !use_durable_nonce {
        let exit_signal = exit_signal.clone();
        let blockhash = blockhash.clone();
        let client = client.clone();
        let id = id.pubkey();
        Some(
            Builder::new()
                .name("solana-blockhash-poller".to_string())
                .spawn(move || {
                    poll_blockhash(&exit_signal, &blockhash, &client, &id);
                })
                .unwrap(),
        )
    } else {
        None
    };


    
    // assert!(latencies.is_empty());
    // assert!(tpss.is_empty());

    let s_threads = create_sender_threads(
        &client,
        &shared_txs,
        thread_batch_sleep_ms,
        &total_tx_sent_count,
        &mut time_tracked_tps,
        &mut latencies,
        &mut tpss,
        threads,
        exit_signal.clone(),
        &shared_tx_active_thread_count,
        &pending_map, //sj
    );

    // Spawn confirm poller thread for slot-based per-tx latency measurement //sj
    let confirm_poller_thread = create_confirm_poller_thread(
        client.clone(),
        exit_signal.clone(),
        pending_map.clone(),
        slot_latencies.clone(),
    );

    wait_for_target_slots_per_epoch(target_slots_per_epoch, &client);

    // Record starting slot for block metrics measurement
    let start_slot = match client.get_slot_with_commitment(CommitmentConfig::processed()) {
        Ok(slot) => slot,
        Err(_) => {
            warn!("Could not get starting slot for block metrics");
            0
        }
    };

    let start = Instant::now();

    generate_chunked_transfers(
        blockhash,
        &shared_txs,
        shared_tx_active_thread_count,
        chunk_generator,
        threads,
        duration,
        sustained,
        use_durable_nonce,
    );

    // Stop the sampling threads so it will collect the stats
    exit_signal.store(true, Ordering::Relaxed);

    info!("Waiting for sampler threads...");
    if let Err(err) = sample_thread.join() {
        info!("  join() failed with: {:?}", err);
    }

    // join the tx send threads
    info!("Waiting for transmit threads...");
    for t in s_threads {
        if let Err(err) = t.join() {
            info!("  join() failed with: {:?}", err);
        }
    }

    // Wait for confirm poller to drain remaining in-flight txs //sj
    info!("Waiting for confirm poller thread...");
    if let Err(err) = confirm_poller_thread.join() {
        info!("  confirm_poller join() failed with: {:?}", err);
    }

    if let Some(blockhash_thread) = blockhash_thread {
        info!("Waiting for blockhash thread...");
        if let Err(err) = blockhash_thread.join() {
            info!("  join() failed with: {:?}", err);
        }
    }

    if let Some(nonce_keypairs) = nonce_keypairs {
        withdraw_durable_nonce_accounts(client.clone(), &gen_keypairs, &nonce_keypairs);
    }

    let balance = client.get_balance(&id.pubkey()).unwrap_or(0);
    metrics_submit_lamport_balance(balance);

    compute_and_report_stats(
        &maxes,
        sample_period,
        &start.elapsed(),
        total_tx_sent_count.load(Ordering::Relaxed),
    );
    // sungjinstat

    let mean = sungjin_mean(Arc::clone(&latencies));
    let stdev = sungjin_stddev(Arc::clone(&latencies));
    
    let min = sungjin_percentile(Arc::clone(&latencies), 0.0);
    let max = sungjin_percentile(Arc::clone(&latencies), 100.0);

    let p5 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 5.0);
    let p10 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 10.0);
    let p20 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 20.0);
    let p30 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 30.0);
    let p40 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 40.0);
    let p50 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 50.0);
    let p60 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 60.0);
    let p70 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 70.0);
    let p75 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 75.0);
    let p80 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 80.0);
    let p90 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 90.0);
    let p99 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 99.0);
    let p999 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 99.9);
    let p9999 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 99.99);
    let p99999 = sungjin_percentile_u64_to_f32(Arc::clone(&latencies), 99.999);
    
    let latencies_len = latencies.read().unwrap().len();
    println!("time elapsed {}", duration_as_s(&start.elapsed()));
    println!("latency stats (n = {}):", latencies_len);
    println!("mean    : {:.2}", mean);
    println!("stdev   : {:.2}", stdev);
    println!("min     : {:.2}", min);
    
    println!("p5     : {:.2}", p5);
    println!("p10     : {:.2}", p10);
    println!("p20     : {:.2}", p20);
    println!("p30     : {:.2}", p30);
    println!("p40     : {:.2}", p40);
    println!("p50     : {:.2}", p50);
    println!("p60     : {:.2}", p60);
    println!("p70     : {:.2}", p70);
    println!("p75     : {:.2}", p75);
    println!("p80     : {:.2}", p80);
    println!("p90     : {:.2}", p90);
    println!("p99     : {:.2}", p99);
    println!("p99.9   : {:.2}", p999);
    println!("p99.99  : {:.2}", p9999);
    println!("p99.999 : {:.2}", p99999);
    println!("max     : {:.2}", max);

    println!("\nSorted latencies for cumulative graph:");
    let mut sorted_latencies = latencies.read().unwrap().clone();
    sorted_latencies.sort_unstable();
    // for latency in sorted_latencies {
    //     println!("{}", latency);
    // }
       

    let mean = sungjin_mean_f32(Arc::clone(&tpss));
    let stdev = sungjin_stddev_f32(Arc::clone(&tpss));
    
    let min = sungjin_percentile_f32(Arc::clone(&tpss), 0.0);
    let max = sungjin_percentile_f32(Arc::clone(&tpss), 100.0);
    let p5 = sungjin_percentile_f32(Arc::clone(&tpss), 5.0);
    let p10 = sungjin_percentile_f32(Arc::clone(&tpss), 10.0);
    let p20 = sungjin_percentile_f32(Arc::clone(&tpss), 20.0);
    let p30 = sungjin_percentile_f32(Arc::clone(&tpss), 30.0);
    let p40 = sungjin_percentile_f32(Arc::clone(&tpss), 40.0);
    let p50 = sungjin_percentile_f32(Arc::clone(&tpss), 50.0);
    let p60 = sungjin_percentile_f32(Arc::clone(&tpss), 60.0);
    let p70 = sungjin_percentile_f32(Arc::clone(&tpss), 70.0);
    let p75 = sungjin_percentile_f32(Arc::clone(&tpss), 75.0);
    let p80 = sungjin_percentile_f32(Arc::clone(&tpss), 80.0);
    let p90 = sungjin_percentile_f32(Arc::clone(&tpss), 90.0);
    let p99 = sungjin_percentile_f32(Arc::clone(&tpss), 99.0);
    let p999 = sungjin_percentile_f32(Arc::clone(&tpss), 99.9);
    let p9999 = sungjin_percentile_f32(Arc::clone(&tpss), 99.99);
    let p99999 = sungjin_percentile_f32(Arc::clone(&tpss), 99.999);
    
    let tpss_len = tpss.read().unwrap().len();
    println!("tps stats (n = {}):", tpss_len);
    println!("mean    : {:.2}", mean);
    println!("stdev   : {:.2}", stdev);
    println!("min     : {:.2}", min);
    
    println!("p5     : {:.2}", p5);
    println!("p10     : {:.2}", p10);
    println!("p20     : {:.2}", p20);
    println!("p30     : {:.2}", p30);
    println!("p40     : {:.2}", p40);
    println!("p50     : {:.2}", p50);
    println!("p60     : {:.2}", p60);
    println!("p70     : {:.2}", p70);
    println!("p75     : {:.2}", p75);
    println!("p80     : {:.2}", p80);
    println!("p90     : {:.2}", p90);
    println!("p99     : {:.2}", p99);
    println!("p99.9   : {:.2}", p999);
    println!("p99.99  : {:.2}", p9999);
    println!("p99.999 : {:.2}", p99999);
    println!("max     : {:.2}", max);
    let tttps = time_tracked_tps.read().unwrap();

    // ========== SLOT LATENCY STATS (per-tx, slot-based) //sj ==========
    // slot_latency = confirm_slot - submit_slot  (1 slot ≈ 400ms)
    {
        let sl = slot_latencies.read().unwrap();
        if sl.is_empty() {
            println!("\nslot latency stats: no confirmed txs recorded (poller may not have run yet)");
        } else {
            let n = sl.len();
            let mean_s = sl.iter().sum::<u64>() as f64 / n as f64;
            let mut sorted = sl.clone();
            sorted.sort_unstable();
            let pct = |p: f64| -> u64 {
                let idx = ((p / 100.0) * (sorted.len() as f64 - 1.0)).ceil() as usize;
                sorted[idx]
            };
            let ms = |slots: u64| slots as f64 * 400.0;
            println!("\n========== Slot Latency Stats (per-tx confirm latency) ==========");
            println!("n       : {}", n);
            println!("mean    : {:.2} slots  ({:.0} ms)", mean_s, mean_s * 400.0);
            println!("min     : {} slots  ({:.0} ms)", pct(0.0),   ms(pct(0.0)));
            println!("p10     : {} slots  ({:.0} ms)", pct(10.0),  ms(pct(10.0)));
            println!("p20     : {} slots  ({:.0} ms)", pct(20.0),  ms(pct(20.0)));
            println!("p30     : {} slots  ({:.0} ms)", pct(30.0),  ms(pct(30.0)));
            println!("p40     : {} slots  ({:.0} ms)", pct(40.0),  ms(pct(40.0)));
            println!("p50     : {} slots  ({:.0} ms)", pct(50.0),  ms(pct(50.0)));
            println!("p60     : {} slots  ({:.0} ms)", pct(60.0),  ms(pct(60.0)));
            println!("p70     : {} slots  ({:.0} ms)", pct(70.0),  ms(pct(70.0)));
            println!("p75     : {} slots  ({:.0} ms)", pct(75.0),  ms(pct(75.0)));
            println!("p80     : {} slots  ({:.0} ms)", pct(80.0),  ms(pct(80.0)));
            println!("p90     : {} slots  ({:.0} ms)", pct(90.0),  ms(pct(90.0)));
            println!("p99     : {} slots  ({:.0} ms)", pct(99.0),  ms(pct(99.0)));
            println!("p99.9   : {} slots  ({:.0} ms)", pct(99.9),  ms(pct(99.9)));
            println!("p99.99  : {} slots  ({:.0} ms)", pct(99.99), ms(pct(99.99)));
            println!("p99.999 : {} slots  ({:.0} ms)", pct(99.999),ms(pct(99.999)));
            println!("max     : {} slots  ({:.0} ms)", pct(100.0), ms(pct(100.0)));
        }
    }

    // ========== BLOCK METRICS MEASUREMENT (post-benchmark) ==========
    // Measure block generation speed and transactions per block AFTER benchmark completes
    // This avoids any performance impact during the actual benchmark
    println!("\n========== Measuring Block Metrics ==========");

    // Get the final slot to determine measurement range
    let final_slot = match client.get_slot_with_commitment(CommitmentConfig::processed()) {
        Ok(slot) => slot,
        Err(_) => {
            warn!("Could not get final slot for block metrics");
            0
        }
    };

    println!("DEBUG: start_slot={}, final_slot={}", start_slot, final_slot);

    if start_slot > 0 && final_slot > start_slot {
        println!(
            "Measuring block metrics from slot {} to {} (전체 벤치마크 범위)",
            start_slot, final_slot
        );

        match block_metrics::measure_block_metrics_post_benchmark(&client, start_slot, final_slot) {
            metrics if metrics.total_blocks > 0 => {
                metrics.print_report();
                block_metrics::print_block_metrics_detailed(&metrics);
            }
            _ => {
                println!("No block metrics were collected");
            }
        }
    } else {
        println!("Could not measure block metrics - invalid slot range (start_slot={}, final_slot={})", start_slot, final_slot);
    }

    ////////////
    let r_maxes = maxes.read().unwrap();
    r_maxes.first().unwrap().1.txs
}

fn metrics_submit_lamport_balance(lamport_balance: u64) {
    info!("Token balance: {}", lamport_balance);
    datapoint_info!(
        "bench-tps-lamport_balance",
        ("balance", lamport_balance, i64)
    );
}

fn generate_system_txs(
    source: &[&Keypair],
    dest: &VecDeque<&Keypair>,
    reclaim: bool,
    blockhash: &Hash,
    instruction_padding_config: &Option<InstructionPaddingConfig>,
    compute_unit_price: &Option<ComputeUnitPrice>,
) -> Vec<TimestampedTransaction> {
    let pairs: Vec<_> = if !reclaim {
        source.iter().zip(dest.iter()).collect()
    } else {
        dest.iter().zip(source.iter()).collect()
    };

    if let Some(compute_unit_price) = compute_unit_price {
        let compute_unit_prices = match compute_unit_price {
            ComputeUnitPrice::Random => {
                let mut rng = rand::thread_rng();
                let range = Uniform::from(0..MAX_RANDOM_COMPUTE_UNIT_PRICE);
                (0..pairs.len())
                    .map(|_| {
                        range
                            .sample(&mut rng)
                            .saturating_mul(COMPUTE_UNIT_PRICE_MULTIPLIER)
                    })
                    .collect()
            }
            ComputeUnitPrice::Fixed(compute_unit_price) => vec![*compute_unit_price; pairs.len()],
        };

        let pairs_with_compute_unit_prices: Vec<_> =
            pairs.iter().zip(compute_unit_prices.iter()).collect();

        pairs_with_compute_unit_prices
            .par_iter()
            .map(|((from, to), compute_unit_price)| {
                (
                    transfer_with_compute_unit_price_and_padding(
                        from,
                        &to.pubkey(),
                        1,
                        *blockhash,
                        instruction_padding_config,
                        Some(**compute_unit_price),
                    ),
                    Some(timestamp()),
                )
            })
            .collect()
    } else {
        pairs
            .par_iter()
            .map(|(from, to)| {
                (
                    transfer_with_compute_unit_price_and_padding(
                        from,
                        &to.pubkey(),
                        1,
                        *blockhash,
                        instruction_padding_config,
                        None,
                    ),
                    Some(timestamp()),
                )
            })
            .collect()
    }
}

fn transfer_with_compute_unit_price_and_padding(
    from_keypair: &Keypair,
    to: &Pubkey,
    lamports: u64,
    recent_blockhash: Hash,
    instruction_padding_config: &Option<InstructionPaddingConfig>,
    compute_unit_price: Option<u64>,
) -> Transaction {
    let from_pubkey = from_keypair.pubkey();
    let transfer_instruction = system_instruction::transfer(&from_pubkey, to, lamports);
    let instruction = if let Some(instruction_padding_config) = instruction_padding_config {
        wrap_instruction(
            instruction_padding_config.program_id,
            transfer_instruction,
            vec![],
            instruction_padding_config.data_size,
        )
        .expect("Could not create padded instruction")
    } else {
        transfer_instruction
    };
    let mut instructions = vec![
        ComputeBudgetInstruction::set_loaded_accounts_data_size_limit(
            get_transaction_loaded_accounts_data_size(instruction_padding_config.is_some()),
        ),
        instruction,
    ];
    if instruction_padding_config.is_some() {
        // By default, CU budget is DEFAULT_INSTRUCTION_COMPUTE_UNIT_LIMIT which is much larger than needed
        instructions.push(ComputeBudgetInstruction::set_compute_unit_limit(
            PADDED_TRANSFER_COMPUTE_UNIT,
        ));
    }

    if let Some(compute_unit_price) = compute_unit_price {
        instructions.extend_from_slice(&[
            ComputeBudgetInstruction::set_compute_unit_limit(TRANSFER_TRANSACTION_COMPUTE_UNIT),
            ComputeBudgetInstruction::set_compute_unit_price(compute_unit_price),
        ])
    }
    let message = Message::new(&instructions, Some(&from_pubkey));
    Transaction::new(&[from_keypair], message, recent_blockhash)
}

fn get_nonce_accounts<T: 'static + BenchTpsClient + Send + Sync + ?Sized>(
    client: &Arc<T>,
    nonce_pubkeys: &[Pubkey],
) -> Vec<Option<Account>> {
    // get_multiple_accounts supports maximum MAX_MULTIPLE_ACCOUNTS pubkeys in request
    assert!(nonce_pubkeys.len() <= MAX_MULTIPLE_ACCOUNTS);
    loop {
        match client.get_multiple_accounts(nonce_pubkeys) {
            Ok(nonce_accounts) => {
                return nonce_accounts;
            }
            Err(err) => {
                info!("Couldn't get durable nonce account: {:?}", err);
                sleep(Duration::from_secs(1));
            }
        }
    }
}

fn get_nonce_blockhashes<T: 'static + BenchTpsClient + Send + Sync + ?Sized>(
    client: &Arc<T>,
    nonce_pubkeys: &[Pubkey],
) -> Vec<Hash> {
    let num_accounts = nonce_pubkeys.len();
    let mut blockhashes = vec![Hash::default(); num_accounts];
    let mut unprocessed = (0..num_accounts).collect::<HashSet<_>>();

    let mut request_pubkeys = Vec::<Pubkey>::with_capacity(num_accounts);
    let mut request_indexes = Vec::<usize>::with_capacity(num_accounts);

    while !unprocessed.is_empty() {
        for i in &unprocessed {
            request_pubkeys.push(nonce_pubkeys[*i]);
            request_indexes.push(*i);
        }

        let num_unprocessed_before = unprocessed.len();
        let accounts: Vec<Option<Account>> = nonce_pubkeys
            .chunks(MAX_MULTIPLE_ACCOUNTS)
            .flat_map(|pubkeys| get_nonce_accounts(client, pubkeys))
            .collect();

        for (account, index) in accounts.iter().zip(request_indexes.iter()) {
            if let Some(nonce_account) = account {
                let nonce_data = nonce_utils::data_from_account(nonce_account).unwrap();
                blockhashes[*index] = nonce_data.blockhash();
                unprocessed.remove(index);
            }
        }
        let num_unprocessed_after = unprocessed.len();
        debug!(
            "Received {} durable nonce accounts",
            num_unprocessed_before - num_unprocessed_after
        );
        request_pubkeys.clear();
        request_indexes.clear();
    }
    blockhashes
}

fn nonced_transfer_with_padding(
    from_keypair: &Keypair,
    to: &Pubkey,
    lamports: u64,
    nonce_account: &Pubkey,
    nonce_authority: &Keypair,
    nonce_hash: Hash,
    instruction_padding_config: &Option<InstructionPaddingConfig>,
) -> Transaction {
    let from_pubkey = from_keypair.pubkey();
    let transfer_instruction = system_instruction::transfer(&from_pubkey, to, lamports);
    let instruction = if let Some(instruction_padding_config) = instruction_padding_config {
        wrap_instruction(
            instruction_padding_config.program_id,
            transfer_instruction,
            vec![],
            instruction_padding_config.data_size,
        )
        .expect("Could not create padded instruction")
    } else {
        transfer_instruction
    };
    let instructions = vec![
        ComputeBudgetInstruction::set_loaded_accounts_data_size_limit(
            get_transaction_loaded_accounts_data_size(instruction_padding_config.is_some()),
        ),
        instruction,
    ];
    let message = Message::new_with_nonce(
        instructions,
        Some(&from_pubkey),
        nonce_account,
        &nonce_authority.pubkey(),
    );
    Transaction::new(&[from_keypair, nonce_authority], message, nonce_hash)
}

fn generate_nonced_system_txs<T: 'static + BenchTpsClient + Send + Sync + ?Sized>(
    client: Arc<T>,
    source: &[&Keypair],
    dest: &VecDeque<&Keypair>,
    source_nonce: &[&Keypair],
    dest_nonce: &VecDeque<&Keypair>,
    reclaim: bool,
    instruction_padding_config: &Option<InstructionPaddingConfig>,
) -> Vec<TimestampedTransaction> {
    let length = source.len();
    let mut transactions: Vec<TimestampedTransaction> = Vec::with_capacity(length);
    if !reclaim {
        let pubkeys: Vec<Pubkey> = source_nonce
            .iter()
            .map(|keypair| keypair.pubkey())
            .collect();

        let blockhashes: Vec<Hash> = get_nonce_blockhashes(&client, &pubkeys);
        for i in 0..length {
            transactions.push((
                nonced_transfer_with_padding(
                    source[i],
                    &dest[i].pubkey(),
                    1,
                    &source_nonce[i].pubkey(),
                    source[i],
                    blockhashes[i],
                    instruction_padding_config,
                ),
                None,
            ));
        }
    } else {
        let pubkeys: Vec<Pubkey> = dest_nonce.iter().map(|keypair| keypair.pubkey()).collect();
        let blockhashes: Vec<Hash> = get_nonce_blockhashes(&client, &pubkeys);

        for i in 0..length {
            transactions.push((
                nonced_transfer_with_padding(
                    dest[i],
                    &source[i].pubkey(),
                    1,
                    &dest_nonce[i].pubkey(),
                    dest[i],
                    blockhashes[i],
                    instruction_padding_config,
                ),
                None,
            ));
        }
    }
    transactions
}

fn generate_txs<T: 'static + BenchTpsClient + Send + Sync + ?Sized>(
    shared_txs: &SharedTransactions,
    blockhash: &Arc<RwLock<Hash>>,
    chunk_generator: &mut TransactionChunkGenerator<'_, '_, T>,
    threads: usize,
    use_durable_nonce: bool,
) {
    let transactions = if use_durable_nonce {
        chunk_generator.generate(None)
    } else {
        let blockhash = blockhash.read().map(|x| *x).ok();
        chunk_generator.generate(blockhash.as_ref())
    };

    let sz = transactions.len() / threads;
    let chunks: Vec<_> = transactions.chunks(sz).collect();
    {
        let mut shared_txs_wl = shared_txs.write().unwrap();
        for chunk in chunks {
            shared_txs_wl.push_back(chunk.to_vec());
        }
    }
}

fn get_new_latest_blockhash<T: BenchTpsClient + ?Sized>(
    client: &Arc<T>,
    blockhash: &Hash,
) -> Option<Hash> {
    let start = Instant::now();
    while start.elapsed().as_secs() < 5 {
        if let Ok(new_blockhash) = client.get_latest_blockhash() {
            if new_blockhash != *blockhash {
                return Some(new_blockhash);
            }
        }
        debug!("Got same blockhash ({:?}), will retry...", blockhash);

        // Retry ~twice during a slot
        sleep(Duration::from_millis(DEFAULT_MS_PER_SLOT / 2));
    }
    None
}

fn poll_blockhash<T: BenchTpsClient + ?Sized>(
    exit_signal: &AtomicBool,
    blockhash: &Arc<RwLock<Hash>>,
    client: &Arc<T>,
    id: &Pubkey,
) {
    let mut blockhash_last_updated = Instant::now();
    let mut last_error_log = Instant::now();
    loop {
        let blockhash_updated = {
            let old_blockhash = *blockhash.read().unwrap();
            if let Some(new_blockhash) = get_new_latest_blockhash(client, &old_blockhash) {
                *blockhash.write().unwrap() = new_blockhash;
                blockhash_last_updated = Instant::now();
                true
            } else {
                if blockhash_last_updated.elapsed().as_secs() > 120 {
                    eprintln!("Blockhash is stuck");
                    exit(1)
                } else if blockhash_last_updated.elapsed().as_secs() > 30
                    && last_error_log.elapsed().as_secs() >= 1
                {
                    last_error_log = Instant::now();
                    error!("Blockhash is not updating");
                }
                false
            }
        };

        if blockhash_updated {
            let balance = client.get_balance(id).unwrap_or(0);
            metrics_submit_lamport_balance(balance);
            datapoint_info!(
                "blockhash_stats",
                (
                    "time_elapsed_since_last_blockhash_update",
                    blockhash_last_updated.elapsed().as_millis(),
                    i64
                )
            )
        }

        if exit_signal.load(Ordering::Relaxed) {
            break;
        }

        sleep(Duration::from_millis(50));
    }
}

fn do_tx_transfers<T: BenchTpsClient + ?Sized>(
    exit_signal: &AtomicBool,
    shared_txs: &SharedTransactions,
    shared_tx_thread_count: &Arc<AtomicIsize>,
    total_tx_sent_count: &Arc<AtomicUsize>,
    ttps: &mut Arc<RwLock<Vec<u64>>>,
    latencies: &mut Arc<RwLock<Vec<u64>>>,
    tpss: &mut Arc<RwLock<Vec<f32>>>,
    thread_batch_sleep_ms: usize,
    client: &Arc<T>,
    pending_map: &PendingMap, //sj slot-latency
) {
    let start_time = Instant::now();
    let mut last_sent_time = timestamp();
    loop {
        if thread_batch_sleep_ms > 0 {
            sleep(Duration::from_millis(thread_batch_sleep_ms as u64));
        }
        let txs = {
            let mut shared_txs_wl = shared_txs.write().expect("write lock in do_tx_transfers");
            shared_txs_wl.pop_front()
        };
        if let Some(txs0) = txs {
            shared_tx_thread_count.fetch_add(1, Ordering::Relaxed);
            info!("Transferring 1 unit {} times...", txs0.len());
            let tx_len = txs0.len();
            let transfer_start = Instant::now();
            let mut old_transactions = false;
            let mut transactions = Vec::<_>::new();
            let mut min_timestamp = u64::MAX;
            for tx in txs0 {
                let now = timestamp();
                // Transactions without durable nonce that are too old will be rejected by the cluster Don't bother
                // sending them.
                if let Some(tx_timestamp) = tx.1 {
                    if tx_timestamp < min_timestamp {
                        min_timestamp = tx_timestamp;
                    }
                    if now > tx_timestamp && now - tx_timestamp > 1000 * MAX_TX_QUEUE_AGE {
                        old_transactions = true;
                        continue;
                    }
                }
                transactions.push(tx.0);
            }

            if min_timestamp != u64::MAX {
                datapoint_info!(
                    "bench-tps-do_tx_transfers",
                    ("oldest-blockhash-age", timestamp() - min_timestamp, i64),
                );
            }

            // Record (signature → submit_slot) before sending for slot-latency tracking //sj
            let submit_slot = client
                .get_slot_with_commitment(CommitmentConfig::processed())
                .unwrap_or(0);
            {
                let mut pending = pending_map.write().unwrap();
                for tx in &transactions {
                    if !tx.signatures.is_empty() {
                        pending.insert(tx.signatures[0], submit_slot);
                    }
                }
            }

            if let Err(error) = client.send_batch(transactions) {
                warn!("send_batch_sync in do_tx_transfers failed: {}", error);
            }

            datapoint_info!(
                "bench-tps-do_tx_transfers",
                (
                    "time-elapsed-since-last-send",
                    timestamp() - last_sent_time,
                    i64
                ),
            );

            last_sent_time = timestamp();

            if old_transactions {
                let mut shared_txs_wl = shared_txs.write().expect("write lock in do_tx_transfers");
                shared_txs_wl.clear();
            }
            shared_tx_thread_count.fetch_add(-1, Ordering::Relaxed);
            let ttsc = total_tx_sent_count.fetch_add(tx_len, Ordering::Relaxed);
            
            // latencies.push(duration_as_ms(&transfer_start.elapsed()));
            // tpss.push(tx_len as f32 / duration_as_s(&transfer_start.elapsed()));
            {
                // let mut latencies_lock = latencies.unwrap();
                // latencies.push();
                
                latencies.write().unwrap().push(duration_as_ms(&transfer_start.elapsed()));

            }
            {
                // let mut tpss_lock = tpss.unwrap();
                tpss.write().unwrap().push(tx_len as f32 / duration_as_s(&transfer_start.elapsed()));
            }
            {
                // if(duration_as_s(&transfer_start.elapsed())%10==0){
                //     ttps.write().unwrap().push(tx_len as f32 / duration_as_s(&transfer_start.elapsed()));
                // }
                // if (transfer_start.elapsed() as u64) % 10 == 0 {
                //     let throughput = tx_len as f32 / elapsed_s as f32;
                //     ttps.write().unwrap().push(throughput);
                // }
                // let elapsed_s = duration_as_s(&transfer_start.elapsed());

                // Convert elapsed seconds to an integer to check modulo
                // if (duration_as_s(&start_time.elapsed()) as u64) % 10 == 0 {
                    // let throughput = tx_len as f32 / elapsed_s as f32;
                    // ttps.write().unwrap().push(throughput);
                    // ttps.write().unwrap().push(tx_len as f32 / duration_as_s(&transfer_start.elapsed()));
                    // ttps.write().unwrap().push(ttsc as u64);
                // }
            }
            // duration_as_ms(&transfer_start.elapsed()),
            // tx_len as f32 / duration_as_s(&transfer_start.elapsed()),

            info!(
                "Tx send done. {} ms {} tps",
                duration_as_ms(&transfer_start.elapsed()),
                tx_len as f32 / duration_as_s(&transfer_start.elapsed()),
            );



            datapoint_info!(
                "bench-tps-do_tx_transfers",
                ("duration", duration_as_us(&transfer_start.elapsed()), i64),
                ("count", tx_len, i64)
            );
        }
        if exit_signal.load(Ordering::Relaxed) {
            break;
        }
    }
}

fn compute_and_report_stats(
    maxes: &Arc<RwLock<Vec<(String, SampleStats)>>>,
    sample_period: u64,
    tx_send_elapsed: &Duration,
    total_tx_send_count: usize,
) {
    // Compute/report stats
    let mut max_of_maxes = 0.0;
    let mut max_tx_count = 0;
    let mut nodes_with_zero_tps = 0;
    let mut total_maxes = 0.0;
    info!(" Node address        |       Max TPS | Total Transactions");
    info!("---------------------+---------------+--------------------");

    for (sock, stats) in maxes.read().unwrap().iter() {
        let maybe_flag = match stats.txs {
            0 => "!!!!!",
            _ => "",
        };

        info!(
            "{:20} | {:13.2} | {} {}",
            sock, stats.tps, stats.txs, maybe_flag
        );

        if stats.tps == 0.0 {
            nodes_with_zero_tps += 1;
        }
        total_maxes += stats.tps;

        if stats.tps > max_of_maxes {
            max_of_maxes = stats.tps;
        }
        if stats.txs > max_tx_count {
            max_tx_count = stats.txs;
        }
    }

    if total_maxes > 0.0 {
        let num_nodes_with_tps = maxes.read().unwrap().len() - nodes_with_zero_tps;
        let average_max = total_maxes / num_nodes_with_tps as f32;
        info!(
            "\nAverage max TPS: {:.2}, {} nodes had 0 TPS",
            average_max, nodes_with_zero_tps
        );
    }

    let total_tx_send_count = total_tx_send_count as u64;
    let drop_rate = if total_tx_send_count > max_tx_count {
        (total_tx_send_count - max_tx_count) as f64 / total_tx_send_count as f64
    } else {
        0.0
    };
    info!(
        "\nHighest TPS: {:.2} sampling period {}s max transactions: {} clients: {} drop rate: {:.2}",
        max_of_maxes,
        sample_period,
        max_tx_count,
        maxes.read().unwrap().len(),
        drop_rate,
    );
    info!(
        "\tAverage TPS: {}",
        max_tx_count as f32 / duration_as_s(tx_send_elapsed)
    );
}

pub fn generate_and_fund_keypairs<T: 'static + BenchTpsClient + Send + Sync + ?Sized>(
    client: Arc<T>,
    funding_key: &Keypair,
    keypair_count: usize,
    lamports_per_account: u64,
    enable_padding: bool,
) -> Result<Vec<Keypair>> {
    let rent = client.get_minimum_balance_for_rent_exemption(0)?;
    let lamports_per_account = lamports_per_account + rent;

    info!("Creating {} keypairs...", keypair_count);
    let (mut keypairs, extra) = generate_keypairs(funding_key, keypair_count as u64);
    fund_keypairs(
        client,
        funding_key,
        &keypairs,
        extra,
        lamports_per_account,
        enable_padding,
    )?;

    // 'generate_keypairs' generates extra keys to be able to have size-aligned funding batches for fund_keys.
    keypairs.truncate(keypair_count);

    Ok(keypairs)
}

pub fn fund_keypairs<T: 'static + BenchTpsClient + Send + Sync + ?Sized>(
    client: Arc<T>,
    funding_key: &Keypair,
    keypairs: &[Keypair],
    extra: u64,
    lamports_per_account: u64,
    enable_padding: bool,
) -> Result<()> {
    let rent = client.get_minimum_balance_for_rent_exemption(0)?;
    info!("Get lamports...");

    // Sample the first keypair, to prevent lamport loss on repeated solana-bench-tps executions
    let first_key = keypairs[0].pubkey();
    let first_keypair_balance = client.get_balance(&first_key).unwrap_or(0);

    // Sample the last keypair, to check if funding was already completed
    let last_key = keypairs[keypairs.len() - 1].pubkey();
    let last_keypair_balance = client.get_balance(&last_key).unwrap_or(0);

    // Repeated runs will eat up keypair balances from transaction fees. In order to quickly
    //   start another bench-tps run without re-funding all of the keypairs, check if the
    //   keypairs still have at least 80% of the expected funds. That should be enough to
    //   pay for the transaction fees in a new run.
    let enough_lamports = 8 * lamports_per_account / 10;
    if first_keypair_balance < enough_lamports || last_keypair_balance < enough_lamports {
        let single_sig_message = Message::new_with_blockhash(
            &[Instruction::new_with_bytes(
                Pubkey::new_unique(),
                &[],
                vec![AccountMeta::new(Pubkey::new_unique(), true)],
            )],
            None,
            &client.get_latest_blockhash().unwrap(),
        );
        let max_fee = client.get_fee_for_message(&single_sig_message).unwrap();
        let extra_fees = extra * max_fee;
        let total_keypairs = keypairs.len() as u64 + 1; // Add one for funding keypair
        let total = lamports_per_account * total_keypairs + extra_fees;

        let funding_key_balance = client.get_balance(&funding_key.pubkey()).unwrap_or(0);
        info!(
            "Funding keypair balance: {} max_fee: {} lamports_per_account: {} extra: {} total: {}",
            funding_key_balance, max_fee, lamports_per_account, extra, total
        );

        if funding_key_balance < total + rent {
            error!(
                "funder has {}, needed {}",
                Sol(funding_key_balance),
                Sol(total)
            );
            let latest_blockhash = get_latest_blockhash(client.as_ref());
            if client
                .request_airdrop_with_blockhash(
                    &funding_key.pubkey(),
                    total + rent - funding_key_balance,
                    &latest_blockhash,
                )
                .is_err()
            {
                return Err(BenchTpsError::AirdropFailure);
            }
        }

        fund_keys(
            client,
            funding_key,
            keypairs,
            total,
            max_fee,
            lamports_per_account,
            get_transaction_loaded_accounts_data_size(enable_padding),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use {
        super::*,
        solana_runtime::{bank::Bank, bank_client::BankClient},
        solana_sdk::{
            commitment_config::CommitmentConfig,
            feature_set::FeatureSet,
            fee_calculator::FeeRateGovernor,
            genesis_config::{create_genesis_config, GenesisConfig},
            native_token::sol_to_lamports,
            nonce::State,
        },
    };

    fn bank_with_all_features(genesis_config: &GenesisConfig) -> Arc<Bank> {
        let mut bank = Bank::new_for_tests(genesis_config);
        bank.feature_set = Arc::new(FeatureSet::all_enabled());
        bank.wrap_with_bank_forks_for_tests().0
    }

    #[test]
    fn test_bench_tps_bank_client() {
        let (genesis_config, id) = create_genesis_config(sol_to_lamports(10_000.0));
        let bank = bank_with_all_features(&genesis_config);
        let client = Arc::new(BankClient::new_shared(bank));

        let config = Config {
            id,
            tx_count: 10,
            duration: Duration::from_secs(5),
            ..Config::default()
        };

        let keypair_count = config.tx_count * config.keypair_multiplier;
        let keypairs =
            generate_and_fund_keypairs(client.clone(), &config.id, keypair_count, 20, false)
                .unwrap();

        do_bench_tps(client, config, keypairs, None);
    }

    #[test]
    fn test_bench_tps_fund_keys() {
        let (genesis_config, id) = create_genesis_config(sol_to_lamports(10_000.0));
        let bank = bank_with_all_features(&genesis_config);
        let client = Arc::new(BankClient::new_shared(bank));
        let keypair_count = 20;
        let lamports = 20;
        let rent = client.get_minimum_balance_for_rent_exemption(0).unwrap();

        let keypairs =
            generate_and_fund_keypairs(client.clone(), &id, keypair_count, lamports, false)
                .unwrap();

        for kp in &keypairs {
            assert_eq!(
                client
                    .get_balance_with_commitment(&kp.pubkey(), CommitmentConfig::processed())
                    .unwrap(),
                lamports + rent
            );
        }
    }

    #[test]
    fn test_bench_tps_fund_keys_with_fees() {
        let (mut genesis_config, id) = create_genesis_config(sol_to_lamports(10_000.0));
        let fee_rate_governor = FeeRateGovernor::new(11, 0);
        genesis_config.fee_rate_governor = fee_rate_governor;
        let bank = bank_with_all_features(&genesis_config);
        let client = Arc::new(BankClient::new_shared(bank));
        let keypair_count = 20;
        let lamports = 20;
        let rent = client.get_minimum_balance_for_rent_exemption(0).unwrap();

        let keypairs =
            generate_and_fund_keypairs(client.clone(), &id, keypair_count, lamports, false)
                .unwrap();

        for kp in &keypairs {
            assert_eq!(client.get_balance(&kp.pubkey()).unwrap(), lamports + rent);
        }
    }

    #[test]
    fn test_bench_tps_create_durable_nonce() {
        let (genesis_config, id) = create_genesis_config(sol_to_lamports(10_000.0));
        let bank = bank_with_all_features(&genesis_config);
        let client = Arc::new(BankClient::new_shared(bank));
        let keypair_count = 10;
        let lamports = 10_000_000;

        let authority_keypairs =
            generate_and_fund_keypairs(client.clone(), &id, keypair_count, lamports, false)
                .unwrap();

        let nonce_keypairs = generate_durable_nonce_accounts(client.clone(), &authority_keypairs);

        let rent = client
            .get_minimum_balance_for_rent_exemption(State::size())
            .unwrap();
        for kp in &nonce_keypairs {
            assert_eq!(
                client
                    .get_balance_with_commitment(&kp.pubkey(), CommitmentConfig::processed())
                    .unwrap(),
                rent
            );
        }
        withdraw_durable_nonce_accounts(client, &authority_keypairs, &nonce_keypairs)
    }

    #[test]
    fn test_bench_tps_key_chunks_new() {
        let num_keypairs = 16;
        let chunk_size = 4;
        let keypairs = std::iter::repeat_with(Keypair::new)
            .take(num_keypairs)
            .collect::<Vec<_>>();

        let chunks = KeypairChunks::new(&keypairs, chunk_size);
        assert_eq!(
            chunks.source[0],
            &[&keypairs[0], &keypairs[1], &keypairs[2], &keypairs[3]]
        );
        assert_eq!(
            chunks.dest[0],
            &[&keypairs[4], &keypairs[5], &keypairs[6], &keypairs[7]]
        );
        assert_eq!(
            chunks.source[1],
            &[&keypairs[8], &keypairs[9], &keypairs[10], &keypairs[11]]
        );
        assert_eq!(
            chunks.dest[1],
            &[&keypairs[12], &keypairs[13], &keypairs[14], &keypairs[15]]
        );
    }

    #[test]
    fn test_bench_tps_key_chunks_new_with_conflict_groups() {
        let num_keypairs = 16;
        let chunk_size = 4;
        let num_conflict_groups = 2;
        let keypairs = std::iter::repeat_with(Keypair::new)
            .take(num_keypairs)
            .collect::<Vec<_>>();

        let chunks =
            KeypairChunks::new_with_conflict_groups(&keypairs, chunk_size, num_conflict_groups);
        assert_eq!(
            chunks.source[0],
            &[&keypairs[0], &keypairs[1], &keypairs[2], &keypairs[3]]
        );
        assert_eq!(
            chunks.dest[0],
            &[&keypairs[4], &keypairs[5], &keypairs[4], &keypairs[5]]
        );
        assert_eq!(
            chunks.source[1],
            &[&keypairs[8], &keypairs[9], &keypairs[10], &keypairs[11]]
        );
        assert_eq!(
            chunks.dest[1],
            &[&keypairs[12], &keypairs[13], &keypairs[12], &keypairs[13]]
        );
    }
}
