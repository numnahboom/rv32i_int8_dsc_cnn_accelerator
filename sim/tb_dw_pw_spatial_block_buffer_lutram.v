/* Reuse the complete protocol/tail/stall regression with only the DUT type
 * redirected to the LUTRAM candidate. */
`define dw_pw_spatial_block_buffer dw_pw_spatial_block_buffer_lutram
`include "tb_dw_pw_spatial_block_buffer.v"
