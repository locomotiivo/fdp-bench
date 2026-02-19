#include <libxnvme.h>
#include <queue>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

#define BUF_SIZE (1 << 20)
#define MAX_NR_QUEUE 128

#define print_sungjin(member) printf("%s %lu\n", (#member), (uint64_t)(member));

// Management Operation codes for FEMU
enum NvmeIomsMo {
    NVME_IOMS_MO_NOP = 0x0,
    NVME_IOMS_MO_RUH_UPDATE = 0x1,
    NVME_IOMS_MO_SUNGJIN = 0x2,           // Original: print stats + reset
    NVME_IOMS_MO_SUNGJIN_READONLY = 0x10, // New: print stats only (no reset)
};

struct nvme_fdp_ruh_status_desc {
    uint16_t pid;
    uint16_t ruhid;
    uint32_t earutr;
    uint64_t ruamw;
    uint8_t rsvd16[16];
};

struct nvme_fdp_ruh_status {
    uint8_t rsvd0[14];
    uint16_t nruhsd;
    struct nvme_fdp_ruh_status_desc ruhss[16];
};

void async_cb(struct xnvme_cmd_ctx *ctx, void *cb_arg) {
    printf("hello i am async cb\n");
    struct xnvme_queue *xqueue;
    xqueue = (struct xnvme_queue *)cb_arg;
    if (xnvme_cmd_ctx_cpl_status(ctx)) {
        xnvme_cmd_ctx_pr(ctx, XNVME_PR_DEF);
    }
    xnvme_queue_put_cmd_ctx(xqueue, ctx);
}

void print_usage(const char *prog_name) {
    fprintf(stderr, "FEMU FDP Statistics Tool\n\n");
    fprintf(stderr, "Usage: %s <device> [--reset|--read-only]\n\n", prog_name);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  --reset      Print stats and reset all counters (default)\n");
    fprintf(stderr, "  --read-only  Print stats without resetting counters\n\n");
    fprintf(stderr, "Examples:\n");
    fprintf(stderr, "  %s /dev/nvme0n1 --reset\n", prog_name);
    fprintf(stderr, "  %s /dev/nvme0n1 --read-only\n", prog_name);
    fprintf(stderr, "  %s /dev/nvme0n1\n", prog_name);
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) {
        print_usage(argv[0]);
        return 1;
    }

    const char *device = argv[1];
    uint8_t mo = NVME_IOMS_MO_SUNGJIN;  // Default: reset mode
    const char *mode_str = "RESET";

    // Parse optional flag
    if (argc == 3) {
        if (strcmp(argv[2], "--reset") == 0) {
            mo = NVME_IOMS_MO_SUNGJIN;
            mode_str = "RESET";
        } else if (strcmp(argv[2], "--read-only") == 0) {
            mo = NVME_IOMS_MO_SUNGJIN_READONLY;
            mode_str = "READ-ONLY";
        } else if (strcmp(argv[2], "-h") == 0 || strcmp(argv[2], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Error: Unknown option '%s'\n\n", argv[2]);
            print_usage(argv[0]);
            return 1;
        }
    }

    printf("=== FEMU FDP Statistics ===\n");
    printf("Device: %s\n", device);
    printf("Mode: %s (MO=0x%x)\n", mode_str, mo);
    printf("===========================\n\n");

    struct xnvme_opts opts = xnvme_opts_default();
    struct xnvme_dev *dev_ = nullptr;
    const struct xnvme_geo *geo_ = nullptr;
    struct xnvme_queue *queues_[MAX_NR_QUEUE];
    const unsigned int qdepth = MAX_NR_QUEUE;
    std::queue<struct xnvme_queue *> xnvme_queues_;
    struct xnvme_cmd_ctx *xnvme_ctx;
    struct xnvme_queue *xqueue;

    opts.async = "io_uring";
    // opts.async = "emu";
    opts.direct = 0;
    int err;

    // Open device
    dev_ = xnvme_dev_open(device, &opts);
    if (!dev_) {
        fprintf(stderr, "Error: Failed to open device '%s'\n", device);
        fprintf(stderr, "Hint: Try running with sudo, or check if the device exists.\n");
        fprintf(stderr, "Hint: You can verify with: xnvme info %s\n", device);
        xnvme_cli_perr("xnvme_dev_open()", errno);
        return 1;
    }
    printf("Device opened successfully\n");

    geo_ = xnvme_dev_get_geo(dev_);
    printf("Device geometry retrieved\n");
    print_sungjin(xnvme_dev_get_geo);

    // Initialize queues
    for (int i = 0; i < MAX_NR_QUEUE; i++) {
        queues_[i] = nullptr;
        err = xnvme_queue_init(dev_, qdepth, 0, &queues_[i]);
        if (err) {
            fprintf(stderr, "Error: Failed to initialize queue %d\n", i);
            xnvme_dev_close(dev_);
            return 1;
        }
        xnvme_queues_.push(queues_[i]);
    }
    printf("Queues initialized\n");

    // Allocate buffer
    void *buf = xnvme_buf_alloc(dev_, BUF_SIZE);
    if (!buf) {
        fprintf(stderr, "Error: Failed to allocate buffer\n");
        for (int i = 0; i < MAX_NR_QUEUE; i++) {
            xnvme_queue_term(queues_[i]);
        }
        xnvme_dev_close(dev_);
        return 1;
    }

    // Get command context
    xqueue = xnvme_queues_.front();
    xnvme_queues_.pop();
    xnvme_ctx = xnvme_queue_get_cmd_ctx(xqueue);
    xnvme_ctx->async.cb = async_cb;
    xnvme_ctx->async.cb_arg = reinterpret_cast<void *>(xqueue);
    xnvme_ctx->dev = dev_;

    uint64_t nsid = xnvme_dev_get_nsid(dev_);
    printf("NSID: %lu\n", nsid);

    struct nvme_fdp_ruh_status ruh_status;
    uint16_t mos = 1;

    // Send management command with selected mode
    printf("\nSending IO Management Send command (MO=0x%x)...\n", mo);
    err = xnvme_nvm_mgmt_send(xnvme_ctx, nsid, mo, mos, &ruh_status, sizeof(nvme_fdp_ruh_status));
    if (err) {
        fprintf(stderr, "Warning: xnvme_nvm_mgmt_send returned error: %d\n", err);
        fprintf(stderr, "This may be expected if using read-only mode without FEMU patch.\n");
    }

    // Drain the queue
    err = xnvme_queue_drain(xqueue);
    if (err < 0) {
        fprintf(stderr, "Warning: Failed to drain queue: %d\n", err);
    }

    printf("\n=== Command Complete ===\n");
    printf("Stats have been printed to FEMU output (check dmesg/journalctl)\n");
    if (mo == NVME_IOMS_MO_SUNGJIN) {
        printf("Counters have been RESET\n");
    } else {
        printf("Counters remain UNCHANGED (read-only mode)\n");
    }

    // Print RUH status info if available
    if (ruh_status.nruhsd > 0) {
        printf("\n=== RUH Status ===\n");
        printf("Number of RUH Status Descriptors: %d\n", ruh_status.nruhsd);
        printf("PID  RUHID  EARUTR  RUAMW\n");
        printf("---  -----  ------  -----\n");
        for (int i = 0; i < ruh_status.nruhsd && i < 16; i++) {
            printf("%3d  %5d  %6d  %5ld\n",
                   ruh_status.ruhss[i].pid,
                   ruh_status.ruhss[i].ruhid,
                   ruh_status.ruhss[i].earutr,
                   ruh_status.ruhss[i].ruamw);
        }
    }

    // Cleanup
    xnvme_buf_free(dev_, buf);
    for (int i = 0; i < MAX_NR_QUEUE; i++) {
        err = xnvme_queue_term(queues_[i]);
        if (err) {
            fprintf(stderr, "Warning: Failed to terminate queue %d\n", i);
        }
    }
    xnvme_dev_close(dev_);

    printf("\nDone.\n");
    return 0;
}
