// High I/O Churn Contract for FDP Benchmarking
// 
// Strategy: Maximize small I/O operations that cannot be compressed/compacted together.
// Each transaction updates multiple small objects with unique, random-looking data.
//
// Why this works for WAF:
// 1. Small objects = many keys in RocksDB = more LSM compaction
// 2. Frequent updates = key overwrites = page invalidation = GC work
// 3. Unique data per update = no compression benefit
// 4. Spread across many objects = hot/cold mixing

module io_churn::io_churn {
    use sui::clock::{Self, Clock};
    use sui::hash;
    
    // Constants for blob sizes
    const BLOB_SIZE: u64 = 4096;  // 4KB per blob - matches page size
    
    // Error codes
    const ENotOwner: u64 = 0;
    
    /// Large blob object (~4KB) - for high disk throughput testing
    /// Each update writes 4KB of unique data
    public struct LargeBlob has key, store {
        id: UID,
        owner: address,
        version: u64,
        // 4KB of data - vector<u8> with pseudo-random content
        data: vector<u8>,
        checksum: u256,
    }
    
    /// Small counter object (~100 bytes) - the "hot" data that gets updated
    /// Each update invalidates the previous version
    public struct MicroCounter has key, store {
        id: UID,
        owner: address,
        value: u64,
        // Add some extra fields to make object size consistent
        nonce: u64,        // Changes each update (prevents dedup)
        checksum: u256,    // Derived from value+nonce (makes data unique)
        last_update: u64,  // Timestamp
    }
    
    /// Batch container - holds references to multiple counters for batch ops
    public struct CounterBatch has key {
        id: UID,
        owner: address,
        counter_ids: vector<address>,  // Track created counters
        batch_size: u64,
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // OBJECT CREATION - Creates many small objects
    // ═══════════════════════════════════════════════════════════════════
    
    /// Create a single micro counter (owned)
    public fun create_counter(ctx: &mut TxContext): MicroCounter {
        let sender = tx_context::sender(ctx);
        let nonce = tx_context::epoch(ctx);
        MicroCounter {
            id: object::new(ctx),
            owner: sender,
            value: 0,
            nonce,
            checksum: compute_checksum(0, nonce),
            last_update: 0,
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // LARGE BLOB OPERATIONS - For high disk throughput (4KB per object)
    // ═══════════════════════════════════════════════════════════════════
    
    /// Generate pseudo-random data based on seed
    fun generate_blob_data(seed: u64, size: u64): vector<u8> {
        let mut data = vector::empty<u8>();
        let mut i = 0u64;
        let mut state = seed;
        while (i < size) {
            // Simple LCG-like PRNG for each byte
            state = ((state * 1103515245 + 12345) % 2147483648);
            vector::push_back(&mut data, ((state % 256) as u8));
            i = i + 1;
        };
        data
    }
    
    /// Create a 4KB blob object
    public fun create_blob(ctx: &mut TxContext): LargeBlob {
        let sender = tx_context::sender(ctx);
        let seed = tx_context::epoch(ctx);
        let data = generate_blob_data(seed, BLOB_SIZE);
        LargeBlob {
            id: object::new(ctx),
            owner: sender,
            version: 0,
            data,
            checksum: compute_checksum(0, seed),
        }
    }
    
    /// Create and transfer a blob
    public entry fun create_blob_and_transfer(ctx: &mut TxContext) {
        let blob = create_blob(ctx);
        transfer::transfer(blob, tx_context::sender(ctx));
    }
    
    /// Create multiple blobs in a batch - for initial setup
    public entry fun create_blob_batch(count: u64, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        let mut i = 0;
        while (i < count) {
            let blob = create_blob(ctx);
            transfer::transfer(blob, sender);
            i = i + 1;
        };
    }
    
    /// Update blob with new 4KB of pseudo-random data
    /// This is the KEY function - writes 4KB per call
    public entry fun update_blob(blob: &mut LargeBlob, ctx: &TxContext) {
        blob.version = blob.version + 1;
        let seed = tx_context::epoch(ctx) + blob.version;
        blob.data = generate_blob_data(seed, BLOB_SIZE);
        blob.checksum = compute_checksum(blob.version, seed);
    }
    
    /// Update blob with custom seed for more entropy
    public entry fun update_blob_entropy(blob: &mut LargeBlob, entropy: u64, ctx: &TxContext) {
        blob.version = blob.version + 1;
        let seed = tx_context::epoch(ctx) ^ entropy ^ blob.version;
        blob.data = generate_blob_data(seed, BLOB_SIZE);
        blob.checksum = compute_checksum(blob.version, seed);
    }
    
    /// Read blob and return checksum - forces disk read if not cached
    /// Academic basis: Read operations force block cache misses → disk I/O
    /// This is a "view" operation that touches all 4KB of data
    public fun read_blob_checksum(blob: &LargeBlob): u256 {
        // Compute checksum over entire data vector to force read
        let mut sum: u256 = 0;
        let len = vector::length(&blob.data);
        let mut i = 0;
        while (i < len) {
            sum = sum + (*vector::borrow(&blob.data, i) as u256);
            i = i + 64; // Sample every 64 bytes (still touches all pages)
        };
        sum ^ blob.checksum
    }

    /// Read and verify blob - entry point for read operations
    /// Returns nothing but forces the read to happen
    public entry fun read_blob(blob: &LargeBlob) {
        // Touch the data to force read from storage
        let _ = read_blob_checksum(blob);
    }

    /// Mixed read-write: read one blob, update another
    /// Academic basis: Mixed workloads stress both read and write paths
    public entry fun read_update_blob(
        read_blob: &LargeBlob,
        write_blob: &mut LargeBlob,
        ctx: &TxContext
    ) {
        // Force read
        let read_checksum = read_blob_checksum(read_blob);
        // Update with entropy from read
        write_blob.version = write_blob.version + 1;
        let seed = tx_context::epoch(ctx) ^ (read_checksum as u64) ^ write_blob.version;
        write_blob.data = generate_blob_data(seed, BLOB_SIZE);
        write_blob.checksum = compute_checksum(write_blob.version, seed);
    }

    /// Delete blob - for append-delete workload patterns
    /// Academic basis: Deletes create tombstones → compaction work
    public entry fun delete_blob(blob: LargeBlob) {
        let LargeBlob { id, owner: _, version: _, data: _, checksum: _ } = blob;
        object::delete(id);
    }

    /// Create multiple counters in a single PTB - creates N small objects
    public entry fun create_batch(count: u64, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        let mut i = 0;
        while (i < count) {
            let counter = create_counter(ctx);
            transfer::transfer(counter, sender);
            i = i + 1;
        };
    }
    
    /// Create a shared counter (for contention testing)
    public entry fun create_shared(ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        let nonce = tx_context::epoch(ctx);
        transfer::share_object(MicroCounter {
            id: object::new(ctx),
            owner: sender,
            value: 0,
            nonce,
            checksum: compute_checksum(0, nonce),
            last_update: 0,
        });
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // OBJECT UPDATES - The key to high WAF
    // ═══════════════════════════════════════════════════════════════════
    
    /// Increment counter with unique data (prevents compression)
    public entry fun increment(counter: &mut MicroCounter, clock: &Clock) {
        counter.value = counter.value + 1;
        counter.nonce = counter.nonce + clock::timestamp_ms(clock);
        counter.checksum = compute_checksum(counter.value, counter.nonce);
        counter.last_update = clock::timestamp_ms(clock);
    }
    
    /// Increment without clock (simpler, still unique via epoch)
    public entry fun increment_simple(counter: &mut MicroCounter, ctx: &TxContext) {
        counter.value = counter.value + 1;
        counter.nonce = counter.nonce + tx_context::epoch(ctx) + counter.value;
        counter.checksum = compute_checksum(counter.value, counter.nonce);
        counter.last_update = tx_context::epoch(ctx);
    }
    
    /// Set value with entropy injection
    public entry fun set_value(
        counter: &mut MicroCounter, 
        value: u64, 
        entropy: u64,
        ctx: &TxContext
    ) {
        assert!(counter.owner == tx_context::sender(ctx), ENotOwner);
        counter.value = value;
        counter.nonce = entropy ^ tx_context::epoch(ctx);
        counter.checksum = compute_checksum(value, counter.nonce);
        counter.last_update = tx_context::epoch(ctx);
    }
    
    /// Batch increment multiple counters in single TX
    /// This is the KEY function - updates many objects per transaction
    public entry fun batch_increment_2(
        c1: &mut MicroCounter,
        c2: &mut MicroCounter,
        ctx: &TxContext
    ) {
        let epoch = tx_context::epoch(ctx);
        
        c1.value = c1.value + 1;
        c1.nonce = c1.nonce + epoch + 1;
        c1.checksum = compute_checksum(c1.value, c1.nonce);
        c1.last_update = epoch;
        
        c2.value = c2.value + 1;
        c2.nonce = c2.nonce + epoch + 2;
        c2.checksum = compute_checksum(c2.value, c2.nonce);
        c2.last_update = epoch;
    }
    
    public entry fun batch_increment_4(
        c1: &mut MicroCounter,
        c2: &mut MicroCounter,
        c3: &mut MicroCounter,
        c4: &mut MicroCounter,
        ctx: &TxContext
    ) {
        let epoch = tx_context::epoch(ctx);
        
        c1.value = c1.value + 1;
        c1.nonce = c1.nonce + epoch + 1;
        c1.checksum = compute_checksum(c1.value, c1.nonce);
        c1.last_update = epoch;
        
        c2.value = c2.value + 1;
        c2.nonce = c2.nonce + epoch + 2;
        c2.checksum = compute_checksum(c2.value, c2.nonce);
        c2.last_update = epoch;
        
        c3.value = c3.value + 1;
        c3.nonce = c3.nonce + epoch + 3;
        c3.checksum = compute_checksum(c3.value, c3.nonce);
        c3.last_update = epoch;
        
        c4.value = c4.value + 1;
        c4.nonce = c4.nonce + epoch + 4;
        c4.checksum = compute_checksum(c4.value, c4.nonce);
        c4.last_update = epoch;
    }
    
    /// Batch increment 8 counters - maximum throughput per CLI call
    public entry fun batch_increment_8(
        c1: &mut MicroCounter,
        c2: &mut MicroCounter,
        c3: &mut MicroCounter,
        c4: &mut MicroCounter,
        c5: &mut MicroCounter,
        c6: &mut MicroCounter,
        c7: &mut MicroCounter,
        c8: &mut MicroCounter,
        ctx: &TxContext
    ) {
        let epoch = tx_context::epoch(ctx);
        
        c1.value = c1.value + 1;
        c1.nonce = c1.nonce + epoch + 1;
        c1.checksum = compute_checksum(c1.value, c1.nonce);
        c1.last_update = epoch;
        
        c2.value = c2.value + 1;
        c2.nonce = c2.nonce + epoch + 2;
        c2.checksum = compute_checksum(c2.value, c2.nonce);
        c2.last_update = epoch;
        
        c3.value = c3.value + 1;
        c3.nonce = c3.nonce + epoch + 3;
        c3.checksum = compute_checksum(c3.value, c3.nonce);
        c3.last_update = epoch;
        
        c4.value = c4.value + 1;
        c4.nonce = c4.nonce + epoch + 4;
        c4.checksum = compute_checksum(c4.value, c4.nonce);
        c4.last_update = epoch;
        
        c5.value = c5.value + 1;
        c5.nonce = c5.nonce + epoch + 5;
        c5.checksum = compute_checksum(c5.value, c5.nonce);
        c5.last_update = epoch;
        
        c6.value = c6.value + 1;
        c6.nonce = c6.nonce + epoch + 6;
        c6.checksum = compute_checksum(c6.value, c6.nonce);
        c6.last_update = epoch;
        
        c7.value = c7.value + 1;
        c7.nonce = c7.nonce + epoch + 7;
        c7.checksum = compute_checksum(c7.value, c7.nonce);
        c7.last_update = epoch;
        
        c8.value = c8.value + 1;
        c8.nonce = c8.nonce + epoch + 8;
        c8.checksum = compute_checksum(c8.value, c8.nonce);
        c8.last_update = epoch;
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════
    
    /// Compute a checksum that makes each object state unique
    /// This prevents RocksDB from compressing/deduping the data
    fun compute_checksum(value: u64, nonce: u64): u256 {
        let mut data = vector::empty<u8>();
        
        // Pack value bytes
        let mut v = value;
        let mut i = 0;
        while (i < 8) {
            vector::push_back(&mut data, ((v & 0xff) as u8));
            v = v >> 8;
            i = i + 1;
        };
        
        // Pack nonce bytes
        let mut n = nonce;
        i = 0;
        while (i < 8) {
            vector::push_back(&mut data, ((n & 0xff) as u8));
            n = n >> 8;
            i = i + 1;
        };
        
        // Hash to get unique checksum
        let hash_bytes = hash::keccak256(&data);
        bytes_to_u256(hash_bytes)
    }
    
    /// Convert 32 bytes to u256
    fun bytes_to_u256(bytes: vector<u8>): u256 {
        let mut result: u256 = 0;
        let mut i = 0;
        while (i < 32 && i < vector::length(&bytes)) {
            result = (result << 8) | (*vector::borrow(&bytes, i) as u256);
            i = i + 1;
        };
        result
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════
    
    public fun value(counter: &MicroCounter): u64 { counter.value }
    public fun nonce(counter: &MicroCounter): u64 { counter.nonce }
    public fun owner(counter: &MicroCounter): address { counter.owner }
}
