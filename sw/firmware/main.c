#include <stdint.h>
#include "cnn_accel.h"
#include "model_desc.h"

volatile int cnn_demo_prediction;
volatile uint32_t cnn_demo_status;
volatile uint32_t cnn_demo_cycle_count;

static int model_argmax_logits_words(void)
{
    int best_idx = 0;
    int8_t best_val = (int8_t)(g_model_logits_words[0] & 0xff);
    int i;

    for (i = 1; i < 10; i++) {
        int8_t value = (int8_t)(g_model_logits_words[i] & 0xff);
        if (value > best_val) {
            best_val = value;
            best_idx = i;
        }
    }
    return best_idx;
}

int main(void)
{
    edgedscnet_c10_init_desc();

    cnn_accel_start((uint32_t)(uintptr_t)g_model_desc, EDGE_DSC_NET_C10_LAYER_NUM);
    cnn_accel_wait_done();

    cnn_demo_status = cnn_accel_poll();
    cnn_demo_cycle_count = cnn_accel_stat();
    cnn_demo_prediction = model_argmax_logits_words();

    while (1) {
    }
    return 0;
}
