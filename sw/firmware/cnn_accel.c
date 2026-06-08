#include "cnn_accel.h"

#ifndef CNN_ACCEL_USE_CUSTOM
#define CNN_ACCEL_USE_CUSTOM 1
#endif

#ifndef CNN_ACCEL_MMIO_BASE
#define CNN_ACCEL_MMIO_BASE 0x30000000u
#endif

#define CNN_MMIO_DESC_BASE  (*(volatile uint32_t *)(CNN_ACCEL_MMIO_BASE + 0x00u))
#define CNN_MMIO_LAYER_NUM  (*(volatile uint32_t *)(CNN_ACCEL_MMIO_BASE + 0x04u))
#define CNN_MMIO_CMD        (*(volatile uint32_t *)(CNN_ACCEL_MMIO_BASE + 0x08u))
#define CNN_MMIO_STATUS     (*(volatile uint32_t *)(CNN_ACCEL_MMIO_BASE + 0x0cu))
#define CNN_MMIO_STAT       (*(volatile uint32_t *)(CNN_ACCEL_MMIO_BASE + 0x10u))

void cnn_accel_start(uint32_t desc_base, uint32_t layer_num)
{
#if CNN_ACCEL_USE_CUSTOM
    __asm__ volatile (".insn r 0x0b, 0, 0, x0, %0, %1"
                      :
                      : "r"(desc_base), "r"(layer_num)
                      : "memory");
#else
    CNN_MMIO_DESC_BASE = desc_base;
    CNN_MMIO_LAYER_NUM = layer_num;
    CNN_MMIO_CMD = CNN_CMD_START;
#endif
}

uint32_t cnn_accel_poll(void)
{
#if CNN_ACCEL_USE_CUSTOM
    uint32_t status;
    __asm__ volatile (".insn r 0x0b, 1, 0, %0, x0, x0"
                      : "=r"(status)
                      :
                      : "memory");
    return status;
#else
    return CNN_MMIO_STATUS;
#endif
}

uint32_t cnn_accel_stat(void)
{
#if CNN_ACCEL_USE_CUSTOM
    uint32_t stat;
    __asm__ volatile (".insn r 0x0b, 2, 0, %0, x0, x0"
                      : "=r"(stat)
                      :
                      : "memory");
    return stat;
#else
    return CNN_MMIO_STAT;
#endif
}

cnn_status_t cnn_accel_get_status(void)
{
    uint32_t raw = cnn_accel_poll();
    cnn_status_t status;

    status.busy = (raw & CNN_STATUS_BUSY_MASK) ? 1u : 0u;
    status.done = (raw & CNN_STATUS_DONE_MASK) ? 1u : 0u;
    status.error = (raw & CNN_STATUS_ERROR_MASK) ? 1u : 0u;
    status.current_layer = (raw & CNN_STATUS_CURRENT_LAYER_MASK) >> CNN_STATUS_CURRENT_LAYER_SHIFT;
    status.cycle_count = cnn_accel_stat();

    return status;
}

void cnn_accel_wait_done(void)
{
    uint32_t status;
    do {
        status = cnn_accel_poll();
    } while ((status & (CNN_STATUS_DONE_MASK | CNN_STATUS_ERROR_MASK)) == 0u);
}

int cnn_argmax_int8(const volatile int8_t *logits, int len)
{
    int best_idx = 0;
    int8_t best_val = -128;
    int i;

    if (len <= 0) {
        return -1;
    }

    best_val = logits[0];
    for (i = 1; i < len; i++) {
        if (logits[i] > best_val) {
            best_val = logits[i];
            best_idx = i;
        }
    }
    return best_idx;
}
