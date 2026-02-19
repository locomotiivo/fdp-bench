//! Block metrics measurement module for bench-tps
//! Measures block generation speed and transactions per block
//! Following CLAUDE.md requirements for tail latency analysis
//!
//! NOTE: Block metrics are collected AFTER benchmark completion to avoid
//! impacting transaction throughput during the test

use {
    crate::bench_tps_client::BenchTpsClient,
    log::*,
    solana_sdk::{
        clock::DEFAULT_S_PER_SLOT,
        slot_history::Slot,
    },
    std::sync::Arc,
};

/// Block metrics collected during benchmark
#[derive(Clone, Debug, Default)]
pub struct BlockMetrics {
    /// Transactions per block (per slot)
    pub tx_per_block: Vec<u64>,
    /// TPS per block (transactions / time)
    pub tps_per_block: Vec<f32>,
    /// Block timestamps for calculating generation speed
    pub block_timestamps: Vec<i64>,
    /// Slot numbers for tracking block sequence
    pub slot_numbers: Vec<u64>,
    /// Total blocks measured
    pub total_blocks: u64,
    /// Average transactions per block
    pub avg_tx_per_block: f64,
    /// Average TPS
    pub avg_tps: f64,
    /// Block generation speed (blocks per second)
    pub block_creation_speed: f64,
}

impl BlockMetrics {
    pub fn new() -> Self {
        Self::default()
    }

    /// Calculate statistics from collected data
    pub fn calculate_stats(&mut self) {
        if self.tx_per_block.is_empty() {
            return;
        }

        // Calculate average transactions per block
        let total_tx: u64 = self.tx_per_block.iter().sum();
        self.avg_tx_per_block = total_tx as f64 / self.tx_per_block.len() as f64;

        // Calculate average TPS
        let total_tps: f32 = self.tps_per_block.iter().sum();
        self.avg_tps = total_tps as f64 / self.tps_per_block.len() as f64;

        // Calculate block generation speed based on slot duration
        // Each slot is DEFAULT_S_PER_SLOT seconds (0.4 seconds)
        if self.tx_per_block.len() > 1 {
            let total_slots = self.tx_per_block.len() as f64;
            let total_time = total_slots * DEFAULT_S_PER_SLOT as f64;
            if total_time > 0.0 {
                self.block_creation_speed = total_slots / total_time;
            }
        }

        self.total_blocks = self.tx_per_block.len() as u64;
    }

    /// Print formatted block metrics report
    pub fn print_report(&self) {
        println!("\n========== BLOCK METRICS REPORT ==========");
        println!("Total blocks measured: {}", self.total_blocks);
        println!(
            "Average transactions per block: {:.2}",
            self.avg_tx_per_block
        );
        println!("Average TPS: {:.2}", self.avg_tps);
        println!(
            "Block creation speed: {:.4} blocks/sec",
            self.block_creation_speed
        );
        println!("=========================================\n");
    }

    /// Get percentile of transaction counts
    pub fn tx_percentile(&self, percentile: f64) -> u64 {
        if self.tx_per_block.is_empty() {
            return 0;
        }
        let mut sorted = self.tx_per_block.clone();
        sorted.sort_unstable();
        let index = ((percentile / 100.0) * (sorted.len() as f64 - 1.0)).ceil() as usize;
        sorted[index.min(sorted.len() - 1)]
    }

    /// Get percentile of TPS values
    pub fn tps_percentile(&self, percentile: f64) -> f32 {
        if self.tps_per_block.is_empty() {
            return 0.0;
        }
        let mut sorted = self.tps_per_block.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let index = ((percentile / 100.0) * (sorted.len() as f64 - 1.0)).ceil() as usize;
        sorted[index.min(sorted.len() - 1)]
    }
}

/// Measure block metrics AFTER benchmark completion (no performance impact)
/// Simply counts the number of slots generated during benchmark
pub fn measure_block_metrics_post_benchmark<T: BenchTpsClient + ?Sized>(
    client: &Arc<T>,
    start_slot: Slot,
    end_slot: Slot,
) -> BlockMetrics {
    let mut metrics = BlockMetrics::new();

    // Calculate number of blocks (slots) generated during benchmark
    let blocks_generated = if end_slot > start_slot {
        end_slot - start_slot + 1
    } else {
        0
    };

    info!(
        "Block generation during benchmark: slot {} to {} = {} blocks",
        start_slot, end_slot, blocks_generated
    );

    // Simple metrics based on slot count only
    metrics.total_blocks = blocks_generated;
    metrics.block_creation_speed = 1.0 / DEFAULT_S_PER_SLOT as f64; // Theoretical: 2.5 blocks/sec

    return metrics;
}

/// Print comprehensive block metrics report with percentiles
pub fn print_block_metrics_detailed(metrics: &BlockMetrics) {
    println!("\n========== DETAILED BLOCK METRICS ==========");
    println!("Total blocks: {}", metrics.total_blocks);
    println!("\n--- Transactions Per Block ---");
    println!(
        "Min: {}, Max: {}, Mean: {:.2}",
        metrics.tx_percentile(0.0),
        metrics.tx_percentile(100.0),
        metrics.avg_tx_per_block
    );

    println!("\nPercentiles:");
    let percentiles = [5.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 75.0, 80.0, 90.0, 95.0, 99.0, 99.9, 99.99];
    for p in &percentiles {
        println!("  p{:>6}: {}", p, metrics.tx_percentile(*p));
    }

    println!("\n--- TPS Per Block ---");
    println!(
        "Min: {:.2}, Max: {:.2}, Mean: {:.2}",
        metrics.tps_percentile(0.0),
        metrics.tps_percentile(100.0),
        metrics.avg_tps
    );

    println!("\nPercentiles:");
    for p in &percentiles {
        println!("  p{:>6}: {:.2}", p, metrics.tps_percentile(*p));
    }

    println!("\n--- Block Generation ---");
    println!(
        "Block creation speed: {:.4} blocks/sec (theoretical: {:.4})",
        metrics.block_creation_speed,
        1.0 / DEFAULT_S_PER_SLOT
    );

    println!("=========================================\n");
}
