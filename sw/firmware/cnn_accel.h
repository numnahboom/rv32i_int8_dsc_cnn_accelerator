#ifndef CNN_ACCEL_H
#define CNN_ACCEL_H

#include <stdint.h>

#define CNN_CMD_START 0u
#define CNN_CMD_POLL  1u
#define CNN_CMD_STAT  2u

#define CNN_STATUS_BUSY_MASK          (1u << 0)
#define CNN_STATUS_DONE_MASK          (1u << 1)
#define CNN_STATUS_ERROR_MASK         (1u << 2)
#define CNN_STATUS_CURRENT_LAYER_MASK (0xfu << 4)
#define CNN_STATUS_CURRENT_LAYER_SHIFT 4u

typedef struct cnn_status_t {
    uint32_t busy;
    uint32_t done;
    uint32_t error;
    uint32_t current_layer;
    uint32_t cycle_count;
} cnn_status_t;

void cnn_accel_start(uint32_t desc_base, uint32_t layer_num);
uint32_t cnn_accel_poll(void);
uint32_t cnn_accel_stat(void);
cnn_status_t cnn_accel_get_status(void);
void cnn_accel_wait_done(void);
int cnn_argmax_int8(const volatile int8_t *logits, int len);

#endif
