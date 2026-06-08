#ifndef MODEL_DESC_H
#define MODEL_DESC_H

#include <stdint.h>
#include <stddef.h>
#include "model_weights.h"
#include "model_quant.h"

#define OP_CONV3X3_STEM 0u
#define OP_DS_BLOCK     1u
#define OP_GAP          2u
#define OP_FC           3u

#define EDGE_DSC_NET_C10_LAYER_NUM 9u

#define MODEL_FLAG_INPUT_FROM_SRAM    (1u << 1)
#define MODEL_FLAG_OUTPUT_TO_SRAM     (1u << 2)
#define MODEL_FLAG_SRAM_SWAP_ON_DONE  (1u << 4)
#define MODEL_FLAG_TILED_DS_BLOCK     (1u << 5)
#define MODEL_FLAG_TILED_STEM         MODEL_FLAG_TILED_DS_BLOCK

#define MODEL_SRAM_BASE 0u
#define MODEL_RELU_MIN  0
#define MODEL_RELU_MAX  127

typedef struct {
    uint32_t op_type;
    uint32_t input_addr;
    uint32_t output_addr;
    uint32_t dw_weight_addr;
    uint32_t dw_bias_addr;
    uint32_t dw_mul_addr;
    uint32_t dw_shift_addr;
    uint32_t pw_weight_addr;
    uint32_t pw_bias_addr;
    uint32_t pw_mul_addr;
    uint32_t pw_shift_addr;
    uint16_t in_h;
    uint16_t in_w;
    uint16_t in_c;
    uint16_t out_c;
    uint8_t stride;
    uint8_t pad;
    uint8_t activation_dw;
    uint8_t activation_pw;
    int32_t input_zero_point;
    int32_t dw_output_zero_point;
    int32_t pw_output_zero_point;
    int8_t dw_activation_min;
    int8_t dw_activation_max;
    int8_t pw_activation_min;
    int8_t pw_activation_max;
    uint32_t flags;
    uint32_t reserved[13];
} ds_block_desc_t;

typedef char model_desc_must_be_128_bytes[(sizeof(ds_block_desc_t) == 128u) ? 1 : -1];

static ds_block_desc_t g_model_desc[EDGE_DSC_NET_C10_LAYER_NUM];
static volatile int32_t g_model_logits_words[10];

static uint32_t model_addr(const void *ptr)
{
    return (uint32_t)(uintptr_t)ptr;
}

static void model_clear_desc(ds_block_desc_t *desc)
{
    uint32_t *words = (uint32_t *)desc;
    size_t i;

    for (i = 0; i < 32u; i++) {
        words[i] = 0u;
    }
}

static void model_set_relu6(ds_block_desc_t *desc)
{
    desc->dw_activation_min = (int8_t)MODEL_RELU_MIN;
    desc->dw_activation_max = (int8_t)MODEL_RELU_MAX;
    desc->pw_activation_min = (int8_t)MODEL_RELU_MIN;
    desc->pw_activation_max = (int8_t)MODEL_RELU_MAX;
}

static void model_set_stem_desc(
    ds_block_desc_t *desc,
    uint32_t input_addr,
    uint32_t output_addr,
    uint32_t weight_addr,
    uint32_t bias_addr,
    uint32_t mul_addr,
    uint32_t shift_addr
)
{
    model_clear_desc(desc);
    desc->op_type = OP_CONV3X3_STEM;
    desc->input_addr = input_addr;
    desc->output_addr = output_addr;
    desc->dw_weight_addr = weight_addr;
    desc->dw_bias_addr = bias_addr;
    desc->dw_mul_addr = mul_addr;
    desc->dw_shift_addr = shift_addr;
    desc->in_h = 32u;
    desc->in_w = 32u;
    desc->in_c = 3u;
    desc->out_c = 16u;
    desc->stride = 1u;
    desc->pad = 1u;
    desc->input_zero_point = g_model_input_zero_point;
    desc->dw_output_zero_point = g_stem_output_zero_point;
    model_set_relu6(desc);
    desc->flags = MODEL_FLAG_TILED_STEM |
                  MODEL_FLAG_OUTPUT_TO_SRAM |
                  MODEL_FLAG_SRAM_SWAP_ON_DONE;
}

static void model_set_ds_desc(
    ds_block_desc_t *desc,
    uint16_t in_h,
    uint16_t in_w,
    uint16_t in_c,
    uint16_t out_c,
    uint8_t stride,
    int32_t input_zero_point,
    int32_t dw_output_zero_point,
    int32_t pw_output_zero_point,
    uint32_t dw_weight_addr,
    uint32_t dw_bias_addr,
    uint32_t dw_mul_addr,
    uint32_t dw_shift_addr,
    uint32_t pw_weight_addr,
    uint32_t pw_bias_addr,
    uint32_t pw_mul_addr,
    uint32_t pw_shift_addr
)
{
    model_clear_desc(desc);
    desc->op_type = OP_DS_BLOCK;
    desc->input_addr = MODEL_SRAM_BASE;
    desc->output_addr = MODEL_SRAM_BASE;
    desc->dw_weight_addr = dw_weight_addr;
    desc->dw_bias_addr = dw_bias_addr;
    desc->dw_mul_addr = dw_mul_addr;
    desc->dw_shift_addr = dw_shift_addr;
    desc->pw_weight_addr = pw_weight_addr;
    desc->pw_bias_addr = pw_bias_addr;
    desc->pw_mul_addr = pw_mul_addr;
    desc->pw_shift_addr = pw_shift_addr;
    desc->in_h = in_h;
    desc->in_w = in_w;
    desc->in_c = in_c;
    desc->out_c = out_c;
    desc->stride = stride;
    desc->pad = 1u;
    desc->input_zero_point = input_zero_point;
    desc->dw_output_zero_point = dw_output_zero_point;
    desc->pw_output_zero_point = pw_output_zero_point;
    model_set_relu6(desc);
    desc->flags = MODEL_FLAG_TILED_DS_BLOCK |
                  MODEL_FLAG_INPUT_FROM_SRAM |
                  MODEL_FLAG_OUTPUT_TO_SRAM |
                  MODEL_FLAG_SRAM_SWAP_ON_DONE;
}

static void model_set_gap_desc(ds_block_desc_t *desc)
{
    model_clear_desc(desc);
    desc->op_type = OP_GAP;
    desc->input_addr = MODEL_SRAM_BASE;
    desc->output_addr = MODEL_SRAM_BASE;
    desc->in_h = 4u;
    desc->in_w = 4u;
    desc->in_c = 256u;
    desc->out_c = 256u;
    desc->flags = MODEL_FLAG_INPUT_FROM_SRAM |
                  MODEL_FLAG_OUTPUT_TO_SRAM |
                  MODEL_FLAG_SRAM_SWAP_ON_DONE;
}

static void model_set_fc_desc(ds_block_desc_t *desc)
{
    model_clear_desc(desc);
    desc->op_type = OP_FC;
    desc->input_addr = MODEL_SRAM_BASE;
    desc->output_addr = model_addr((const void *)g_model_logits_words);
    desc->pw_weight_addr = model_addr(g_fc_weight_words);
    desc->pw_bias_addr = model_addr(g_fc_bias);
    desc->pw_mul_addr = model_addr(g_fc_mul);
    desc->pw_shift_addr = model_addr(g_fc_shift_words);
    desc->in_h = 1u;
    desc->in_w = 1u;
    desc->in_c = 256u;
    desc->out_c = 10u;
    desc->pw_output_zero_point = g_fc_output_zero_point;
    desc->pw_activation_min = (int8_t)-128;
    desc->pw_activation_max = (int8_t)127;
    desc->flags = MODEL_FLAG_INPUT_FROM_SRAM;
}

static void edgedscnet_c10_init_desc(void)
{
    edgedscnet_c10_init_payload();

    model_set_stem_desc(
        &g_model_desc[0],
        model_addr(g_model_input_image_words),
        MODEL_SRAM_BASE,
        model_addr(g_stem_weight_words),
        model_addr(g_stem_bias),
        model_addr(g_stem_mul),
        model_addr(g_stem_shift_words)
    );

    model_set_ds_desc(&g_model_desc[1], 32u, 32u, 16u, 32u, 1u,
                      g_ds1_input_zero_point, g_ds1_dw_output_zero_point,
                      g_ds1_pw_output_zero_point,
                      model_addr(g_ds1_dw_weight_words), model_addr(g_ds1_dw_bias),
                      model_addr(g_ds1_dw_mul), model_addr(g_ds1_dw_shift_words),
                      model_addr(g_ds1_pw_weight_words), model_addr(g_ds1_pw_bias),
                      model_addr(g_ds1_pw_mul), model_addr(g_ds1_pw_shift_words));

    model_set_ds_desc(&g_model_desc[2], 32u, 32u, 32u, 64u, 2u,
                      g_ds2_input_zero_point, g_ds2_dw_output_zero_point,
                      g_ds2_pw_output_zero_point,
                      model_addr(g_ds2_dw_weight_words), model_addr(g_ds2_dw_bias),
                      model_addr(g_ds2_dw_mul), model_addr(g_ds2_dw_shift_words),
                      model_addr(g_ds2_pw_weight_words), model_addr(g_ds2_pw_bias),
                      model_addr(g_ds2_pw_mul), model_addr(g_ds2_pw_shift_words));

    model_set_ds_desc(&g_model_desc[3], 16u, 16u, 64u, 64u, 1u,
                      g_ds3_input_zero_point, g_ds3_dw_output_zero_point,
                      g_ds3_pw_output_zero_point,
                      model_addr(g_ds3_dw_weight_words), model_addr(g_ds3_dw_bias),
                      model_addr(g_ds3_dw_mul), model_addr(g_ds3_dw_shift_words),
                      model_addr(g_ds3_pw_weight_words), model_addr(g_ds3_pw_bias),
                      model_addr(g_ds3_pw_mul), model_addr(g_ds3_pw_shift_words));

    model_set_ds_desc(&g_model_desc[4], 16u, 16u, 64u, 128u, 2u,
                      g_ds4_input_zero_point, g_ds4_dw_output_zero_point,
                      g_ds4_pw_output_zero_point,
                      model_addr(g_ds4_dw_weight_words), model_addr(g_ds4_dw_bias),
                      model_addr(g_ds4_dw_mul), model_addr(g_ds4_dw_shift_words),
                      model_addr(g_ds4_pw_weight_words), model_addr(g_ds4_pw_bias),
                      model_addr(g_ds4_pw_mul), model_addr(g_ds4_pw_shift_words));

    model_set_ds_desc(&g_model_desc[5], 8u, 8u, 128u, 128u, 1u,
                      g_ds5_input_zero_point, g_ds5_dw_output_zero_point,
                      g_ds5_pw_output_zero_point,
                      model_addr(g_ds5_dw_weight_words), model_addr(g_ds5_dw_bias),
                      model_addr(g_ds5_dw_mul), model_addr(g_ds5_dw_shift_words),
                      model_addr(g_ds5_pw_weight_words), model_addr(g_ds5_pw_bias),
                      model_addr(g_ds5_pw_mul), model_addr(g_ds5_pw_shift_words));

    model_set_ds_desc(&g_model_desc[6], 8u, 8u, 128u, 256u, 2u,
                      g_ds6_input_zero_point, g_ds6_dw_output_zero_point,
                      g_ds6_pw_output_zero_point,
                      model_addr(g_ds6_dw_weight_words), model_addr(g_ds6_dw_bias),
                      model_addr(g_ds6_dw_mul), model_addr(g_ds6_dw_shift_words),
                      model_addr(g_ds6_pw_weight_words), model_addr(g_ds6_pw_bias),
                      model_addr(g_ds6_pw_mul), model_addr(g_ds6_pw_shift_words));

    model_set_gap_desc(&g_model_desc[7]);
    model_set_fc_desc(&g_model_desc[8]);
}

#endif
