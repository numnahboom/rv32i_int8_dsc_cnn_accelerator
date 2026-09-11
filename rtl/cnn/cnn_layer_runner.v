`timescale 1ns/1ps
`default_nettype none

module cnn_layer_runner #(
    parameter MAX_CIN = 128,
    parameter MAX_COUT = 256,
    parameter MAX_DS_IN_H = 17,
    parameter MAX_DS_IN_W = 17,
    parameter SRAM_ADDR_WIDTH = 15,
    /* Compile-time DS PW datapath selector.  Default 0 preserves the
     * retained full-network implementation; an integration harness can set
     * this to 1 to exercise the unified64 output-stationary engine without
     * changing Stem/FC or the external runner ABI. */
    parameter USE_UNIFIED64_DS = 0,
    // Optional full-image 64-MAC Stem.  Zero keeps the retained legacy Stem
    // (including tiled Stem) byte-for-byte on its existing interfaces.
    parameter USE_UNIFIED64_STEM = 0,
    // One physical 64-MAC/four-lane RQ island shared by Stem and DS layers.
    parameter USE_SHARED_UNIFIED64 = 0,
    // Persistent DS PW row-feed candidate.  Default zero preserves the
    // existing unified64/legacy engines and their interfaces.
    parameter USE_PERSISTENT_DS = 0,
    // Compile-time-disabled retained DS1 integration hook.  Zero leaves the
    // existing phase-loader/tiled engine path structurally unchanged.
    parameter USE_DS1_RETAINED_ORCHESTRATOR = 0,
    // Physical-envelope-only selector.  The legacy DS engine is not
    // elaborated when this is set; retained DS1 remains the only supported DS
    // shape in that build.  Keep zero for the production/fullnet path.
    parameter USE_RETAINED_ONLY_DS = 0,
    // Group-published shared64 is a top-level DS backend.  In that build the
    // runner still owns Stem/GAP/FC, but its legacy DS engine is omitted so
    // the selected production image cannot carry two DS arithmetic planes.
    parameter USE_GROUP_SHARED64_DS = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [1023:0] desc_words,

    output reg         busy,
    output reg         done,
    output reg         error,

    output reg         mem_req_valid,
    output reg         mem_req_write,
    output reg  [31:0] mem_req_addr,
    output reg  [31:0] mem_req_wdata,
    input  wire        mem_req_ready,
    input  wire        mem_resp_valid,
    input  wire [31:0] mem_resp_rdata,

    output reg                         sram_input_rd_en,
    output reg  [SRAM_ADDR_WIDTH-1:0]  sram_input_rd_addr,
    input  wire                        sram_input_rd_valid,
    input  wire signed [7:0]           sram_input_rd_data,
    output reg                         sram_input_rd_word_en,
    output reg  [SRAM_ADDR_WIDTH-1:0]  sram_input_rd_word_addr,
    input  wire                        sram_input_rd_word_valid,
    input  wire [31:0]                 sram_input_rd_word_data,
    output reg                         sram_output_wr_en,
    output reg  [SRAM_ADDR_WIDTH-1:0]  sram_output_wr_addr,
    output reg  signed [7:0]           sram_output_wr_data,
    output reg                         sram_output_wr4_en,
    output reg  [SRAM_ADDR_WIDTH-1:0]  sram_output_wr4_addr,
    output reg  [31:0]                 sram_output_wr4_data,
    output reg  [3:0]                  sram_output_wr4_be
);
    localparam OP_CONV3X3_STEM = 32'd0;
    localparam OP_DS_BLOCK     = 32'd1;
    localparam OP_GAP          = 32'd2;
    localparam OP_FC           = 32'd3;

    localparam FLAG_SKIP_EXEC       = 0;
    localparam FLAG_INPUT_FROM_SRAM = 1;
    localparam FLAG_OUTPUT_TO_SRAM  = 2;
    localparam FLAG_TILED_DS_BLOCK  = 5;
    localparam FLAG_TILED_STEM      = FLAG_TILED_DS_BLOCK;
    // External non-tiled Stem/DS input is four NHWC bytes per memory word.
    localparam FLAG_PACKED_INPUT    = 6;
    // DS weights may be supplied as real contiguous four-byte words.  Bias,
    // multiplier, and shift phases remain one complete 32-bit transaction per
    // item; scalar mode (flag clear) is unchanged.
    localparam FLAG_PACKED_WEIGHTS  = 7;

    localparam PH_INPUT     = 4'd0;
    localparam PH_DW_WEIGHT = 4'd1;
    localparam PH_DW_BIAS   = 4'd2;
    localparam PH_DW_MUL    = 4'd3;
    localparam PH_DW_SHIFT  = 4'd4;
    localparam PH_PW_WEIGHT = 4'd5;
    localparam PH_PW_BIAS   = 4'd6;
    localparam PH_PW_MUL    = 4'd7;
    localparam PH_PW_SHIFT  = 4'd8;

    localparam DS_CFG_INPUT      = 4'd0;
    localparam DS_CFG_DW_WEIGHT  = 4'd1;
    localparam DS_CFG_DW_BIAS    = 4'd2;
    localparam DS_CFG_DW_MUL     = 4'd3;
    localparam DS_CFG_DW_SHIFT   = 4'd4;
    localparam DS_CFG_PW_WEIGHT  = 4'd5;
    localparam DS_CFG_PW_BIAS    = 4'd6;
    localparam DS_CFG_PW_MUL     = 4'd7;
    localparam DS_CFG_PW_SHIFT   = 4'd8;

    localparam ST_IDLE                = 5'd0;
    localparam ST_VALIDATE            = 5'd1;
    localparam ST_LOAD_SETUP          = 5'd2;
    localparam ST_READ_REQ            = 5'd3;
    localparam ST_READ_RESP           = 5'd4;
    localparam ST_ENGINE_START        = 5'd5;
    localparam ST_ENGINE_WAIT         = 5'd6;
    localparam ST_STORE_SETUP         = 5'd7;
    localparam ST_WRITE_REQ           = 5'd8;
    localparam ST_DONE                = 5'd9;
    localparam ST_ERROR               = 5'd10;
    localparam ST_TILED_INIT          = 5'd11;
    localparam ST_TILED_LOAD_SETUP    = 5'd12;
    localparam ST_TILED_LOAD_REQ      = 5'd13;
    localparam ST_TILED_LOAD_RESP     = 5'd14;
    localparam ST_TILED_ENGINE_START  = 5'd15;
    localparam ST_TILED_ENGINE_WAIT   = 5'd16;
    localparam ST_TILED_STORE_SETUP   = 5'd17;
    localparam ST_TILED_WRITE_REQ     = 5'd18;
    localparam ST_TILED_ADVANCE       = 5'd19;
    localparam ST_TILED_NEXT_WAIT     = 5'd20;
    localparam ST_TILED_START_WAIT    = 5'd21;
    localparam ST_STORE_PREFETCH      = 5'd22;
    localparam ST_TILED_STORE_PREFETCH = 5'd23;
    // Build the tiled input base address over separate cycles so the
    // tile-start/stride products do not feed the SRAM read-address register
    // through one cascaded arithmetic cone.
    localparam ST_TILED_ADDR_OFFSETS   = 5'd24;
    localparam ST_TILED_ADDR_BASES     = 5'd25;
    localparam ST_TILED_ADDR_INDEX     = 5'd26;
    // Split descriptor SRAM-span validation across registered states.  In
    // tiled mode the output count is a three-operand product, which must not
    // also feed the span comparison and phase-index enable in one cycle.
    localparam ST_VALIDATE_SPAN_COUNT  = 5'd27;
    localparam ST_VALIDATE_SPAN_RESULT = 5'd28;
    // Register descriptor-derived spatial areas before validation and output
    // span arithmetic.  This prevents the input-height/width products from
    // cascading directly into the area-times-channel products.
    localparam ST_CALC_SPATIAL         = 5'd29;
    localparam ST_TILED_LOAD_WORD_RESP  = 5'd30;
    // Split tile-input HxW and areaxC products across clock boundaries.
    // This removes the tile-scheduler cone from the tiled-load count path.
    localparam ST_TILED_LOAD_AREA       = 6'd31;
    localparam ST_TILED_LOAD_COUNT      = 6'd32;
    // Isolate phase-count arithmetic from phase-state control.  In
    // particular, DS input HxWxC must not feed the FSM enable directly.
    localparam ST_LOAD_COUNT_DECIDE     = 6'd33;
    // Form the tiled-store base over registered steps.  The tile scheduler
    // coordinates therefore only reach the address cursor during setup; the
    // active store loop is driven by row-base and fixed-stride registers.
    localparam ST_TILED_STORE_BASE_ADD  = 6'd34;
    localparam ST_TILED_STORE_BASE_MUL  = 6'd35;
    localparam ST_TILED_STORE_BASE_FINISH = 6'd36;
    // Issue the synchronous output-buffer read in its own cycle.  Keeping
    // the write-mode decision in a register removes store_channel_pos from
    // the BRAM EN path while preserving the one-read/one-write ordering.
    localparam ST_STORE_READ_ISSUE      = 6'd37;
    // Keep the external tiled-load address/valid register enable dependent
    // only on this dedicated issue state.  The previous look-ahead request
    // assignments lived in ST_TILED_LOAD_REQ/RESP, where channel-wrap and
    // padding predicates reached the mem_req_addr CE cone.
    localparam ST_TILED_LOAD_MEM_REQ    = 6'd38;
    // Complete descriptor span counts one registered product at a time.  The
    // extra valid state keeps the count-product result off the span predicate
    // and phase-control enables.
    localparam ST_VALIDATE_SPAN_VALID   = 6'd39;
    localparam ST_LOAD_COUNT_CALC       = 6'd40;
    localparam ST_DS1_RETAINED_START    = 6'd41;
    localparam ST_DS1_RETAINED_WAIT     = 6'd42;
    // Recompute halo metadata only when a committed request crosses to a
    // new pixel.  This is a bounded look-ahead bubble, not an every-element
    // wait state; channel runs remain fully pipelined.
    localparam ST_TILED_LOAD_LOOKAHEAD  = 6'd43;
    // A packed weight response is held here until the DS-side canonical
    // unpack queue can accept it.  The queue retires one byte per cycle, so
    // advancing the external word cursor before this handshake would drop
    // words whenever the queue is still draining.
    localparam ST_PACKED_WEIGHT_WAIT     = 6'd44;
    // Commit the halo-row product before adding one full input row.  Keeping
    // this successor-base add in its own setup cycle prevents
    // row_stride_reg -> (halo_row * stride + stride) from becoming one
    // cascaded DSP path into tiled_input_next_row_base_reg.
    localparam ST_TILED_ADDR_NEXT_BASE   = 6'd45;
    // Compute transaction-invariant tile increments after row_stride has
    // committed.  The tiled address walk then uses only registered adds;
    // no per-tile origin*stride multiply remains in the load setup.
    localparam ST_CALC_TILED_STEPS       = 6'd46;
    // Tiled-loader request classes are captured one position ahead of the
    // FSM.  Keeping the padding/word decision in flops prevents the cursor
    // increment and halo comparisons from feeding the request-state CE cone.
    localparam TILED_REQ_PADDING        = 2'd0;
    localparam TILED_REQ_SCALAR_SRAM    = 2'd1;
    localparam TILED_REQ_WORD_SRAM      = 2'd2;
    localparam TILED_REQ_EXTERNAL       = 2'd3;
    // The cursor successor is committed first; this state registers the
    // wide signed halo/eligibility metadata from that already-registered
    // successor.  It is used only at tile/pixel boundaries, never per item.
    localparam ST_TILED_LOAD_METADATA   = 6'd47;
    // Validation commits the output-span product in a separate state.  The
    // span predicates below consume only registered counts, rather than a
    // descriptor-derived product in the same control cycle.
    localparam ST_VALIDATE_OUTPUT_COUNT  = 6'd48;
    localparam integer OUT_BUFFER_DEPTH = 64 * MAX_COUT;
    localparam integer OUT_BUFFER_ADDR_WIDTH =
        (OUT_BUFFER_DEPTH <= 2) ? 1 : $clog2(OUT_BUFFER_DEPTH);
    localparam [32:0] SRAM_CAPACITY_BYTES = (33'd1 << SRAM_ADDR_WIDTH);

    reg [5:0] state;
    reg [31:0] op_type_reg;
    // Descriptor-local predecode avoids repeatedly comparing the 32-bit
    // opcode on feature-store data, enable, and word-eligibility paths.
    reg op_is_stem_reg;
    reg op_is_ds_reg;
    reg op_is_gap_reg;
    reg op_is_fc_reg;
    reg op_is_valid_reg;
    reg ds1_retained_mode_reg;
    // This is captured with the descriptor rather than recomputed from the
    // wide opcode in the FSM.  Tiled-vs-linear routing is a control invariant
    // for the whole transaction, so a registered bit is both sufficient and
    // keeps the opcode muxes off the state decode cone.
    reg op_is_tiled_reg;
    reg [3:0] op_last_phase_reg;
    reg [31:0] input_addr_reg;
    reg [31:0] output_addr_reg;
    reg [31:0] dw_weight_addr_reg;
    reg [31:0] dw_bias_addr_reg;
    reg [31:0] dw_mul_addr_reg;
    reg [31:0] dw_shift_addr_reg;
    reg [31:0] pw_weight_addr_reg;
    reg [31:0] pw_bias_addr_reg;
    reg [31:0] pw_mul_addr_reg;
    reg [31:0] pw_shift_addr_reg;
    reg [15:0] in_h_reg;
    reg [15:0] in_w_reg;
    reg [15:0] in_c_reg;
    reg [15:0] out_c_reg;
    reg [7:0] stride_reg;
    reg [7:0] pad_reg;
    reg signed [31:0] input_zero_point_reg;
    reg signed [31:0] dw_output_zero_point_reg;
    reg signed [31:0] pw_output_zero_point_reg;
    reg signed [31:0] dw_activation_min_reg;
    reg signed [31:0] dw_activation_max_reg;
    reg signed [31:0] pw_activation_min_reg;
    reg signed [31:0] pw_activation_max_reg;
    reg [31:0] flags_reg;
    reg [31:0] sram_input_count_reg;
    reg [31:0] sram_output_count_reg;
    // Output element count is descriptor-local and remains constant for the
    // transaction.  Registering the decoded count prevents the wide opcode
    // mux (and its inferred multiplier) from entering later FSM enables.
    reg [31:0] output_count_reg;
    reg [31:0] sram_input_count_seed_reg;
    reg [31:0] sram_input_count_factor_reg;
    reg [31:0] sram_output_count_seed_reg;
    reg [31:0] sram_output_count_factor_reg;
    // Valid descriptors constrain both span operands to 16 bits.  Keep the
    // multiply operands narrow so Vivado can use one 16x16 DSP instead of a
    // cascaded 32x32 implementation on the descriptor-validation cone.
    reg [15:0] sram_input_count_seed16_reg;
    reg [15:0] sram_input_count_factor16_reg;
    reg        sram_input_span_valid_reg;
    reg        sram_output_span_valid_reg;
    reg [13:0] conv_out_pixels_reg;
    reg [15:0] tiled_out_pixels_reg;
    reg        packed_word_valid;
    reg [31:0] packed_word_addr;
    reg [31:0] packed_word_data;
    reg [31:0] packed_weight_data_reg;
    reg [1:0]  packed_weight_byte_reg;

    reg [3:0] phase_idx;
    reg [31:0] phase_count;
    reg [31:0] phase_count_seed_reg;
    reg [31:0] phase_count_factor_reg;
    reg [31:0] phase_base_addr;
    reg [31:0] load_idx;
    reg [15:0] compact_load_y;
    reg [15:0] compact_load_x;
    reg [15:0] compact_load_channel;
    reg [15:0] pw_load_cout;
    reg [15:0] pw_load_cin;
    reg [31:0] store_idx;
    reg [31:0] store_count;
    reg [31:0] tiled_store_area_reg;
    reg        store_write_word_eligible_reg;
    reg        store_issue_word_eligible_reg;
    reg [OUT_BUFFER_ADDR_WIDTH-1:0] store_issue_addr_reg;
    reg [31:0] tiled_load_idx;
    reg [31:0] tiled_load_count;
    reg [15:0] tiled_input_area_reg;
    reg [7:0] tiled_load_y;
    reg [7:0] tiled_load_x;
    reg [15:0] tiled_load_channel;
    // Tiled channel wrap and four-lane eligibility use descriptor-local
    // thresholds.  Registering the subtracts once avoids rebuilding
    // channel+1/channel+4 carry chains in every successor metadata cone.
    reg [15:0] tiled_channel_last_reg;
    reg [15:0] tiled_channel_word_limit_reg;
    reg        tiled_channel_ge4_reg;
    // Registered flattened input address state for tiled external loads.
    // These are signed because the halo origin may be outside the image.
    reg signed [31:0] tiled_input_index_reg;
    reg signed [31:0] tiled_input_row_base_reg;
    // Keep the tile-row origin separate from the mutable current-row cursor.
    // The loader advances row_base while filling a tile; reusing that cursor
    // for the next tile would double-count the prior tile height.
    reg signed [31:0] tiled_input_tile_row_base_reg;
    // Precomputed base for the next tiled-input row. Keeping the row-stride
    // multiply and active-load recurrence in separate registered cones
    // prevents stride_reg -> row_base -> index_next from becoming one path.
    reg signed [31:0] tiled_input_next_row_base_reg;
    reg signed [31:0] tiled_input_col_base_reg;
    reg signed [31:0] tiled_input_tile_col_base_reg;
    // Tile-to-tile increments.  The scheduler walks a fixed 8x8 output tile
    // raster, so the next tile row/column origins advance by 8*stride input
    // positions.  Keeping these as registered values avoids multiplying the
    // halo origin by row_stride in the active tile setup path.
    (* DONT_TOUCH = "TRUE" *)
    reg signed [31:0] tiled_input_tile_row_step_reg;
    reg signed [31:0] tiled_input_tile_col_step_reg;
    reg signed [31:0] tiled_input_halo_step_reg;
    // Look-ahead metadata for the current cursor and the following cursor.
    // These registers are updated when a load is committed, so a response
    // can issue the next SRAM read without recomputing channel wrap/padding
    // in the same cycle as the FSM transition.
    reg        tiled_load_current_padding_reg;
    reg        tiled_load_next_padding_reg;
    // The successor cursor is a complete bundle.  Current state is held
    // stable from request issue through response; commit copies this bundle
    // into the current cursor and advances the successor using narrow c/x/y
    // arithmetic only.
    reg [7:0]  tiled_load_next_y_reg;
    reg [7:0]  tiled_load_next_x_reg;
    reg [15:0] tiled_load_next_channel_reg;
    reg signed [31:0] tiled_input_next_index_cursor_reg;
    reg signed [31:0] tiled_input_next_row_base_cursor_reg;
    reg signed [31:0] tiled_input_next_row_next_base_cursor_reg;
    reg signed [31:0] tiled_input_next_col_base_cursor_reg;
    reg        tiled_load_next_word_channel_ok_reg;
    reg        tiled_load_next_word_source_aligned_reg;
    reg [3:0]  tiled_load_next_word_lane_mask_reg;
    reg        tiled_load_next_pixel_end_reg;
    reg        tiled_load_next_word_pixel_end_reg;
    // Set for the first metadata fill of a tile.  Subsequent boundary
    // lookahead cycles already have a registered successor cursor.
    reg        tiled_load_prime_reg;
    // Word eligibility is a current-cursor attribute.  It is registered on
    // cursor commit so the FSM does not compare channel/address bits while
    // selecting the request state.
    // Registered request bundle.  Eligibility is consumed only from these
    // flops; it is no longer rebuilt from channel/pixel-end carry chains in
    // the request state's enable cone.
    reg        tiled_load_word_channel_ok_reg;
    reg        tiled_load_word_source_aligned_reg;
    reg [3:0]  tiled_load_word_lane_mask_reg;
    reg        tiled_load_current_pixel_end_reg;
    reg        tiled_load_current_word_pixel_end_reg;

`ifndef SYNTHESIS
    // Simulation-only lookahead contract checks.  These shadows are updated
    // at the same clock edge as the cursor task and checked on the following
    // edge, after the nonblocking cursor commit has become observable.
    integer sim_tiled_load_assert_errors;
    reg     sim_tiled_load_expect_next_padding_valid;
    reg     sim_tiled_load_expect_next_padding;
    reg     sim_tiled_load_expect_current_padding_valid;
    reg     sim_tiled_load_expect_current_padding;
    reg     sim_tiled_load_hold_valid;
    reg     sim_tiled_load_hold_current_padding;
    reg     sim_tiled_load_hold_next_padding;
    reg     sim_tiled_load_hold_word_channel_ok;
    reg     sim_tiled_load_hold_word_source_aligned;
    reg [3:0] sim_tiled_load_hold_word_lane_mask;
    reg     sim_tiled_load_hold_next_word_channel_ok;
    reg     sim_tiled_load_hold_next_word_source_aligned;
    reg [3:0] sim_tiled_load_hold_next_word_lane_mask;
    reg     sim_tiled_load_hold_current_pixel_end;
    reg     sim_tiled_load_hold_current_word_pixel_end;
    reg     sim_tiled_load_hold_next_pixel_end;
    reg     sim_tiled_load_hold_next_word_pixel_end;
    reg [7:0] sim_tiled_load_hold_y;
    reg [7:0] sim_tiled_load_hold_x;
    reg [15:0] sim_tiled_load_hold_channel;
    reg [7:0] sim_tiled_load_hold_next_y;
    reg [7:0] sim_tiled_load_hold_next_x;
    reg [15:0] sim_tiled_load_hold_next_channel;
    reg signed [31:0] sim_tiled_load_hold_index;
    reg signed [31:0] sim_tiled_load_hold_next_index;
    reg signed [31:0] sim_tiled_load_hold_row_base;
    reg signed [31:0] sim_tiled_load_hold_next_row_base;
    reg signed [31:0] sim_tiled_load_hold_next_row_next_base;
    reg signed [31:0] sim_tiled_load_hold_col_base;
    reg signed [31:0] sim_tiled_load_hold_next_col_base;
`endif
    // This transaction-invariant product is captured before tile traversal.
    // Keep the narrow state boundary visible to Vivado: otherwise the
    // row-base expression can be algebraically bypassed back to descriptor
    // bits, recreating a cross-state DSP cascade.
    (* DONT_TOUCH = "TRUE" *)
    reg signed [31:0] tiled_input_row_stride_reg;
    reg signed [31:0] tiled_input_halo_row_offset_reg;
    reg signed [31:0] tiled_input_halo_col_offset_reg;
    reg [7:0] tiled_store_y;
    reg [7:0] tiled_store_x;
    // Registered external tiled-store address progression.  Keeping the
    // current byte address in the store state removes the tile/global-index
    // multiply from the write-request timing path while preserving the
    // one-outstanding request and ready-stall protocol.
    reg [31:0] tiled_store_addr_current;
    reg [31:0] tiled_store_addr_row_base;
    reg [31:0] tiled_store_addr_col_base;
    reg [31:0] tiled_store_base_index_reg;
    reg [31:0] tiled_store_linear_index_reg;
    reg [31:0] tiled_store_addr_col_jump;
    reg [31:0] tiled_store_addr_row_jump;
    // Registered tiled-store cursor for the internal SRAM output port.  The
    // SRAM address is an element index (unlike the external byte address).
    reg [31:0] tiled_store_sram_addr_current;
    reg [31:0] tiled_store_sram_addr_row_base;
    reg [31:0] tiled_store_sram_addr_col_base;
    reg [31:0] tiled_store_sram_addr_col_jump;
    reg [31:0] tiled_store_sram_addr_row_jump;

    wire out_buffer_wr_en;
    wire [OUT_BUFFER_ADDR_WIDTH-1:0] out_buffer_wr_addr;
    wire signed [7:0] out_buffer_wr_data;
    wire out_buffer_wr_word_en;
    wire [OUT_BUFFER_ADDR_WIDTH-1:0] out_buffer_wr_word_addr;
    wire [31:0] out_buffer_wr_word_data;
    wire [3:0] out_buffer_wr_word_be;
    wire out_buffer_rd_en;
    wire [OUT_BUFFER_ADDR_WIDTH-1:0] out_buffer_rd_addr;
    wire signed [7:0] out_buffer_rd_data;
    wire out_buffer_rd_word_en;
    wire [OUT_BUFFER_ADDR_WIDTH-1:0] out_buffer_rd_word_addr;
    wire [31:0] out_buffer_rd_word_data;
    wire out_buffer_rd_word_valid;
    reg  [OUT_BUFFER_ADDR_WIDTH-1:0] store_outbuf_addr;
    reg  [15:0] store_channel_pos;
    wire [15:0] store_active_channels;
    wire [OUT_BUFFER_ADDR_WIDTH-1:0] store_outbuf_next_addr;
    wire store_word_eligible;
    wire store_next_word_eligible;
    wire [31:0] store_step;
    wire [OUT_BUFFER_ADDR_WIDTH-1:0] store_outbuf_after_step;
    wire [31:0] store_idx_after_step;

    reg stem_start;
    wire stem_busy;
    wire stem_done;
    wire stem_error;
    wire stem_cfg_ready;
    wire stem_out_wr_en;
    wire [5:0] stem_out_wr_pixel_idx;
    wire [3:0] stem_out_wr_channel_idx;
    wire signed [7:0] stem_out_wr_data_int8;
    wire legacy_stem_busy;
    wire legacy_stem_done;
    wire legacy_stem_error;
    wire legacy_stem_cfg_ready;
    wire legacy_stem_out_wr_en;
    wire [5:0] legacy_stem_out_wr_pixel_idx;
    wire [3:0] legacy_stem_out_wr_channel_idx;
    wire signed [7:0] legacy_stem_out_wr_data_int8;
    wire unified_stem_busy;
    wire unified_stem_done;
    wire unified_stem_error;
    wire unified_stem_cfg_ready;
    wire unified_stem_mem_req_valid;
    wire [31:0] unified_stem_mem_req_addr;
    wire unified_stem_mem_resp_ready;
    wire unified_stem_out_wr_valid;
    wire unified_stem_out_wr_ready;
    wire [9:0] unified_stem_out_wr_pixel_idx;
    wire [3:0] unified_stem_out_wr_channel_base;
    wire [31:0] unified_stem_out_wr_data;
    wire [3:0] unified_stem_out_wr_byte_en;
    wire [3:0] unified_stem_out_wr_epoch;
    wire unified_stem_cfg_valid;
    wire [1:0] unified_stem_cfg_target;
    wire unified_stem_mode;
    wire unified_stem_mem_req_ready;

    wire shared_stem_valid_in, shared_stem_ready_in;
    wire shared_stem_first_k, shared_stem_last_k;
    wire [7:0] shared_stem_k_idx;
    wire signed [63:0] shared_stem_act_vec;
    wire signed [127:0] shared_stem_wgt_vec16;
    wire [7:0] shared_stem_pixel_mask;
    wire [15:0] shared_stem_cout_mask;
    wire [10:0] shared_stem_pixel_base;
    wire [8:0] shared_stem_cout_base;
    wire signed [511:0] shared_stem_bias_vec;
    wire signed [511:0] shared_stem_multiplier_vec;
    wire [95:0] shared_stem_shift_vec;
    wire shared_stem_out_valid, shared_stem_out_ready;
    wire [10:0] shared_stem_out_pixel_idx;
    wire [8:0] shared_stem_out_channel_base;
    wire [3:0] shared_stem_out_lane_mask;
    wire signed [31:0] shared_stem_out_data;

    reg ds_start;
    wire ds_busy;
    wire ds_done;
    wire ds_out_wr_en;
    wire [5:0] ds_out_wr_pixel_idx;
    wire [7:0] ds_out_wr_channel_idx;
    wire signed [7:0] ds_out_wr_data_int8;
    wire ds_out_wr_vec4_en;
    wire [5:0] ds_out_wr_vec4_pixel_idx;
    wire [7:0] ds_out_wr_vec4_channel_idx;
    wire [31:0] ds_out_wr_vec4_data_int8;
    reg ds_cfg_wr_en;
    reg [3:0] ds_cfg_target;
    reg [15:0] ds_cfg_index;
    reg [31:0] ds_cfg_data;
    wire ds_cfg_ready;
    wire ds_cfg_weight_word_ready;
    wire ds_error;
    wire [31:0] ds_perf_total_cycles;
    wire [31:0] ds_perf_dw_cycles;
    wire [31:0] ds_perf_pw_cycles;
    wire [31:0] ds_perf_pw_issue_cycles;

    /* Optional retained DS1 runner boundary.  All wires are tied off in the
     * disabled generate branch, keeping the default production netlist on the
     * legacy path. */
    wire ds1_ret_start_valid;
    wire ds1_ret_start_ready;
    wire ds1_ret_source_word_en;
    wire [SRAM_ADDR_WIDTH-1:0] ds1_ret_source_word_addr;
    wire ds1_ret_output_word_en;
    wire [15:0] ds1_ret_output_word_addr;
    wire [31:0] ds1_ret_output_word_data;
    wire [3:0] ds1_ret_output_word_be;
    wire ds1_ret_done;
    wire ds1_ret_error;
    wire ds1_ret_busy;
    wire shared_ds_valid_in, shared_ds_ready_in;
    wire shared_ds_first_k, shared_ds_last_k;
    wire [7:0] shared_ds_k_idx;
    wire signed [63:0] shared_ds_act_vec;
    wire signed [127:0] shared_ds_wgt_vec16;
    wire [7:0] shared_ds_pixel_mask;
    wire [15:0] shared_ds_cout_mask;
    wire [10:0] shared_ds_pixel_base;
    wire [8:0] shared_ds_cout_base;
    wire signed [511:0] shared_ds_bias_vec;
    wire signed [511:0] shared_ds_multiplier_vec;
    wire [95:0] shared_ds_shift_vec;
    wire shared_ds_out_valid, shared_ds_out_ready;
    wire [10:0] shared_ds_out_pixel_idx;
    wire [8:0] shared_ds_out_channel_base;
    wire [3:0] shared_ds_out_lane_mask;
    wire signed [31:0] shared_ds_out_data;

    reg gap_start;
    wire gap_busy;
    wire gap_done;
    wire gap_cfg_ready;
    wire signed [7:0] gap_out_rd_data;

    reg fc_start;
    wire fc_busy;
    wire fc_done;
    wire fc_error;
    wire fc_cfg_ready;
    wire signed [7:0] fc_out_rd_data;

    reg aux_cfg_wr_en;
    reg [3:0] aux_cfg_target;
    reg [15:0] aux_cfg_index;
    reg [31:0] aux_cfg_data;
    reg aux_cfg_vec4_wr_en;
    reg [15:0] aux_cfg_vec4_index;
    reg [31:0] aux_cfg_vec4_data;
    reg ds_cfg_vec4_wr_en;
    reg [15:0] ds_cfg_vec4_index;
    reg [31:0] ds_cfg_vec4_data;
    reg ds_cfg_weight_word_wr_en;
    // 0 = DW linear byte stream, 1 = PW [Cout][Cin] linear byte stream.
    reg ds_cfg_weight_word_target;
    reg [15:0] ds_cfg_weight_word_index;
    reg [31:0] ds_cfg_weight_word_data;
    reg [3:0] ds_cfg_weight_word_be;

    reg tile_sched_start;
    reg tile_sched_next;
    wire tile_sched_valid;
    wire [7:0] sched_tile_h_start;
    wire [7:0] sched_tile_w_start;
    wire [7:0] sched_tile_h_size;
    wire [7:0] sched_tile_w_size;
    wire [7:0] sched_input_tile_h;
    wire [7:0] sched_input_tile_w;
    wire sched_is_last_tile;
    reg [7:0] tile_h_start_reg;
    reg [7:0] tile_w_start_reg;
    reg [7:0] tile_h_size_reg;
    reg [7:0] tile_w_size_reg;
    // Snapshot width for the tiled-store arithmetic cone.
    reg [7:0] tiled_store_out_w_reg;
    reg [7:0] tile_input_h_reg;
    reg [7:0] tile_input_w_reg;
    reg tile_is_last_reg;

    wire [31:0] desc_word0;
    wire [31:0] desc_word1;
    wire [31:0] desc_word2;
    wire [31:0] desc_word3;
    wire [31:0] desc_word4;
    wire [31:0] desc_word5;
    wire [31:0] desc_word6;
    wire [31:0] desc_word7;
    wire [31:0] desc_word8;
    wire [31:0] desc_word9;
    wire [31:0] desc_word10;
    wire [31:0] desc_word11;
    wire [31:0] desc_word12;
    wire [31:0] desc_word13;
    wire [31:0] desc_word14;
    wire [31:0] desc_word15;
    wire [31:0] desc_word16;
    wire [31:0] desc_word17;
    wire [31:0] desc_word18;

    wire [7:0] effective_stride;
    wire [3:0] conv_out_h;
    wire [3:0] conv_out_w;
    wire [7:0] store_byte_current;
    wire tiled_stem_mode;
    wire tiled_ds_mode;
    wire tiled_spatial_mode;
    wire packed_input_config_supported;
    wire packed_input_mode;
    wire packed_weight_config_supported;
    wire packed_weight_mode;
    wire [7:0] tiled_out_h;
    wire [7:0] tiled_out_w;
    wire [3:0] stem_engine_out_h;
    wire [3:0] stem_engine_out_w;
    wire [3:0] ds_engine_out_h;
    wire [3:0] ds_engine_out_w;
    assign desc_word0  = desc_words[(0*32) +: 32];
    assign desc_word1  = desc_words[(1*32) +: 32];
    assign desc_word2  = desc_words[(2*32) +: 32];
    assign desc_word3  = desc_words[(3*32) +: 32];
    assign desc_word4  = desc_words[(4*32) +: 32];
    assign desc_word5  = desc_words[(5*32) +: 32];
    assign desc_word6  = desc_words[(6*32) +: 32];
    assign desc_word7  = desc_words[(7*32) +: 32];
    assign desc_word8  = desc_words[(8*32) +: 32];
    assign desc_word9  = desc_words[(9*32) +: 32];
    assign desc_word10 = desc_words[(10*32) +: 32];
    assign desc_word11 = desc_words[(11*32) +: 32];
    assign desc_word12 = desc_words[(12*32) +: 32];
    assign desc_word13 = desc_words[(13*32) +: 32];
    assign desc_word14 = desc_words[(14*32) +: 32];
    assign desc_word15 = desc_words[(15*32) +: 32];
    assign desc_word16 = desc_words[(16*32) +: 32];
    assign desc_word17 = desc_words[(17*32) +: 32];
    assign desc_word18 = desc_words[(18*32) +: 32];

    /* The integration path is deliberately shape- and flag-specific.  Keep
     * this predicate exact so an enabled build cannot silently redirect any
     * other DS descriptor away from the established engine. */
    wire ds1_retained_desc_match =
        (USE_DS1_RETAINED_ORCHESTRATOR != 0) &&
        (desc_word0 == OP_DS_BLOCK) &&
        (desc_word11 == 32'h0020_0020) &&
        (desc_word12 == 32'h0020_0010) &&
        (desc_word13 == 32'h0000_0101) &&
        (desc_word18 == 32'h0000_0036);

    assign effective_stride = (stride_reg == 8'd0) ? 8'd1 : stride_reg;
    assign conv_out_h = calc_out_dim(in_h_reg, effective_stride);
    assign conv_out_w = calc_out_dim(in_w_reg, effective_stride);
    assign store_byte_current =
        (op_is_stem_reg || op_is_ds_reg)
        ? out_buffer_rd_data
        : (op_is_gap_reg
           ? gap_out_rd_data
           : (op_is_fc_reg
              ? fc_out_rd_data
              : 8'd0));
    assign unified_stem_mode = (USE_UNIFIED64_STEM || USE_SHARED_UNIFIED64) && op_is_stem_reg;
    // A unified Stem consumes the full 32x32 source image directly.  The
    // descriptor generated for the SRAM pipeline historically carries the
    // tiled bit for the legacy loader; mask it here so that this optional
    // implementation does not enter the tile scheduler or replay a full
    // image tile-by-tile.
    assign tiled_stem_mode = op_is_stem_reg && flags_reg[FLAG_TILED_STEM] &&
                             !unified_stem_mode;
    assign tiled_ds_mode = op_is_ds_reg && flags_reg[FLAG_TILED_DS_BLOCK];
    // The tiled selection is transaction-invariant and captured at start;
    // do not let the 32-bit opcode feed every tiled FSM enable.
    // Unified Stem consumes the complete 32x32 source image directly and
    // must bypass the legacy tiled runner FSM even when the descriptor keeps
    // its historical tiled/input-from-SRAM flag set.  DS retains the
    // descriptor-selected tiled path.
    assign tiled_spatial_mode = op_is_tiled_reg && !unified_stem_mode;
    assign packed_input_config_supported = flags_reg[FLAG_PACKED_INPUT] &&
                               !flags_reg[FLAG_INPUT_FROM_SRAM] &&
                               !tiled_spatial_mode &&
                               (op_is_stem_reg || op_is_ds_reg);
    assign packed_input_mode = packed_input_config_supported &&
                               (phase_idx == PH_INPUT);
    assign packed_weight_config_supported = flags_reg[FLAG_PACKED_WEIGHTS] &&
                                            op_is_ds_reg;
    assign packed_weight_mode = packed_weight_config_supported &&
                                ((phase_idx == PH_DW_WEIGHT) ||
                                 (phase_idx == PH_PW_WEIGHT));
    assign tiled_out_h = same_out_dim(in_h_reg, effective_stride);
    assign tiled_out_w = same_out_dim(in_w_reg, effective_stride);
    assign stem_engine_out_h = tiled_stem_mode ? tile_h_size_reg[3:0] : conv_out_h;
    assign stem_engine_out_w = tiled_stem_mode ? tile_w_size_reg[3:0] : conv_out_w;
    assign ds_engine_out_h = tiled_ds_mode ? tile_h_size_reg[3:0] : conv_out_h;
    assign ds_engine_out_w = tiled_ds_mode ? tile_w_size_reg[3:0] : conv_out_w;

    // The unified Stem uses the same scalar configuration phases as the
    // legacy engine, but its compact local ABI has only weight/bias/mul/shift
    // targets (the input is read from the external memory port at start).
    assign unified_stem_cfg_valid = aux_cfg_wr_en && op_is_stem_reg &&
                                    unified_stem_mode;
    // store_response_word already normalizes the unified Stem targets to
    // {weight,bias,multiplier,shift} = {0,1,2,3}.
    assign unified_stem_cfg_target = aux_cfg_target[1:0];
    assign unified_stem_mem_req_ready = unified_stem_mode &&
                                         (state == ST_ENGINE_WAIT) &&
                                         mem_req_valid && mem_req_ready;
    assign unified_stem_out_wr_ready = unified_stem_mode;
    assign stem_busy = unified_stem_mode ? unified_stem_busy : legacy_stem_busy;
    assign stem_done = unified_stem_mode ? unified_stem_done : legacy_stem_done;
    assign stem_error = unified_stem_mode ? unified_stem_error : legacy_stem_error;
    assign stem_cfg_ready = unified_stem_mode ? unified_stem_cfg_ready :
                                                legacy_stem_cfg_ready;
    assign stem_out_wr_en = unified_stem_mode ? 1'b0 :
                            legacy_stem_out_wr_en;
    assign stem_out_wr_pixel_idx = unified_stem_mode ? 6'd0 :
                                   legacy_stem_out_wr_pixel_idx;
    assign stem_out_wr_channel_idx = unified_stem_mode ? 4'd0 :
                                     legacy_stem_out_wr_channel_idx;
    assign stem_out_wr_data_int8 = unified_stem_mode ? 8'sd0 :
                                   legacy_stem_out_wr_data_int8;

    generate
        if (USE_UNIFIED64_STEM || USE_SHARED_UNIFIED64) begin : gen_unified64_stem
            stem_static_window_banks #(
                .IMAGE_H(32),
                .IMAGE_W(32),
                .OUT_H(32),
                .OUT_W(32),
                .EPOCH_WIDTH(4),
                .PACKED_INPUT(0),
                .SHARED_ARRAY(USE_SHARED_UNIFIED64)
            ) u_stem_unified64 (
                .clk(clk),
                .rst_n(rst_n),
                .cfg_valid(unified_stem_cfg_valid),
                .cfg_ready(unified_stem_cfg_ready),
                .cfg_target(unified_stem_cfg_target),
                .cfg_index(aux_cfg_index[8:0]),
                .cfg_data(aux_cfg_data),
                .start(stem_start),
                .source_base_addr(input_addr_reg),
                .input_zero_point(input_zero_point_reg[7:0]),
                .output_zero_point(dw_output_zero_point_reg),
                .activation_min(dw_activation_min_reg),
                .activation_max(dw_activation_max_reg),
                .start_epoch(4'd0),
                .busy(unified_stem_busy),
                .done(unified_stem_done),
                .error(unified_stem_error),
                .mem_req_valid(unified_stem_mem_req_valid),
                .mem_req_ready(unified_stem_mem_req_ready),
                .mem_req_addr(unified_stem_mem_req_addr),
                .mem_resp_valid(mem_resp_valid),
                .mem_resp_ready(unified_stem_mem_resp_ready),
                .mem_resp_data(mem_resp_rdata),
                .out_wr_valid(unified_stem_out_wr_valid),
                .out_wr_ready(unified_stem_out_wr_ready),
                .out_wr_pixel_idx(unified_stem_out_wr_pixel_idx),
                .out_wr_channel_base(unified_stem_out_wr_channel_base),
                .out_wr_data(unified_stem_out_wr_data),
                .out_wr_byte_en(unified_stem_out_wr_byte_en),
                .out_wr_epoch(unified_stem_out_wr_epoch),
                .metric_cycles(),
                .metric_source_req_count(),
                .metric_source_resp_count(),
                .metric_output_commit_count(),
                .metric_token_count(),
                .metric_mac_count(),
                .metric_compute_cycles(),
                .metric_config_writes(),
                .shared_valid_in(shared_stem_valid_in),
                .shared_ready_in(shared_stem_ready_in),
                .shared_first_k(shared_stem_first_k),
                .shared_last_k(shared_stem_last_k),
                .shared_k_idx(shared_stem_k_idx),
                .shared_act_vec(shared_stem_act_vec),
                .shared_wgt_vec16(shared_stem_wgt_vec16),
                .shared_pixel_mask(shared_stem_pixel_mask),
                .shared_cout_mask(shared_stem_cout_mask),
                .shared_pixel_base(shared_stem_pixel_base),
                .shared_cout_base(shared_stem_cout_base),
                .shared_bias_vec(shared_stem_bias_vec),
                .shared_multiplier_vec(shared_stem_multiplier_vec),
                .shared_shift_vec(shared_stem_shift_vec),
                .shared_out_valid(shared_stem_out_valid),
                .shared_out_ready(shared_stem_out_ready),
                .shared_out_pixel_idx(shared_stem_out_pixel_idx),
                .shared_out_channel_base(shared_stem_out_channel_base),
                .shared_out_lane_mask(shared_stem_out_lane_mask),
                .shared_out_data(shared_stem_out_data)
            );
        end else begin : gen_legacy_stem
            conv3x3_stem_engine_new u_stem_engine (
                .clk(clk),
                .rst_n(rst_n),
                .cfg_wr_en(aux_cfg_wr_en && op_is_stem_reg),
                .cfg_ready(legacy_stem_cfg_ready),
                .cfg_target(aux_cfg_target),
                .cfg_index(aux_cfg_index),
                .cfg_data(aux_cfg_data),
                .cfg_vec4_wr_en(aux_cfg_vec4_wr_en),
                .cfg_vec4_index(aux_cfg_vec4_index),
                .cfg_vec4_data(aux_cfg_vec4_data),
                .start(stem_start),
                .busy(legacy_stem_busy),
                .done(legacy_stem_done),
                .error(legacy_stem_error),
                .out_h(stem_engine_out_h),
                .out_w(stem_engine_out_w),
                .output_zero_point(dw_output_zero_point_reg),
                .activation_min(dw_activation_min_reg),
                .activation_max(dw_activation_max_reg),
                .out_wr_en(legacy_stem_out_wr_en),
                .out_wr_pixel_idx(legacy_stem_out_wr_pixel_idx),
                .out_wr_channel_idx(legacy_stem_out_wr_channel_idx),
                .out_wr_data_int8(legacy_stem_out_wr_data_int8)
            );
        end
    endgenerate

    /* The default branch is the production/fullnet legacy DS engine.  A
     * retained DS1 build is a mutually-exclusive physical variant: selecting
     * the retained orchestrator must omit the legacy instance at elaboration,
     * rather than merely leaving it idle behind a runtime mux.  Keep the
     * explicit retained-only knob as an equivalent envelope selector for
     * standalone implementation runs. */
    generate
        if ((USE_RETAINED_ONLY_DS == 0) &&
            (USE_GROUP_SHARED64_DS == 0) &&
            (USE_DS1_RETAINED_ORCHESTRATOR == 0)) begin : gen_legacy_ds_engine
            ds_block_tile_engine_new #(
                .MAX_CIN(MAX_CIN),
                .MAX_COUT(MAX_COUT),
                .MAX_IN_H(MAX_DS_IN_H),
                .MAX_IN_W(MAX_DS_IN_W),
                .USE_UNIFIED64(USE_UNIFIED64_DS || USE_SHARED_UNIFIED64),
                .USE_SHARED_ARRAY(USE_SHARED_UNIFIED64),
                .USE_PERSISTENT_FEED(USE_PERSISTENT_DS)
            ) u_ds_block_engine (
                .clk(clk),
                .rst_n(rst_n),
                .start(ds_start),
                .busy(ds_busy),
                .done(ds_done),
                .error(ds_error),
                .cfg_wr_en(ds_cfg_wr_en),
                .cfg_ready(ds_cfg_ready),
                .cfg_weight_word_ready(ds_cfg_weight_word_ready),
                .cfg_target(ds_cfg_target),
                .cfg_index(ds_cfg_index),
                .cfg_data(ds_cfg_data),
                .cfg_vec4_wr_en(ds_cfg_vec4_wr_en),
                .cfg_vec4_index(ds_cfg_vec4_index),
                .cfg_vec4_data(ds_cfg_vec4_data),
                .cfg_weight_word_wr_en(ds_cfg_weight_word_wr_en),
                .cfg_weight_word_target(ds_cfg_weight_word_target),
                .cfg_weight_word_index(ds_cfg_weight_word_index),
                .cfg_weight_word_data(ds_cfg_weight_word_data),
                .cfg_weight_word_be(ds_cfg_weight_word_be),
                .out_h(ds_engine_out_h),
                .out_w(ds_engine_out_w),
                .channels(in_c_reg[7:0]),
                .out_channels(out_c_reg),
                .stride(effective_stride[1:0]),
                .input_zero_point(input_zero_point_reg[7:0]),
                .dw_output_zero_point(dw_output_zero_point_reg),
                .dw_activation_min(dw_activation_min_reg),
                .dw_activation_max(dw_activation_max_reg),
                .pw_output_zero_point(pw_output_zero_point_reg),
                .pw_activation_min(pw_activation_min_reg),
                .pw_activation_max(pw_activation_max_reg),
                .out_wr_en(ds_out_wr_en),
                .out_wr_pixel_idx(ds_out_wr_pixel_idx),
                .out_wr_channel_idx(ds_out_wr_channel_idx),
                .out_wr_data_int8(ds_out_wr_data_int8),
                .out_wr_vec4_en(ds_out_wr_vec4_en),
                .out_wr_vec4_pixel_idx(ds_out_wr_vec4_pixel_idx),
                .out_wr_vec4_channel_idx(ds_out_wr_vec4_channel_idx),
                .out_wr_vec4_data_int8(ds_out_wr_vec4_data_int8),
                .perf_total_cycles(ds_perf_total_cycles),
                .perf_dw_cycles(ds_perf_dw_cycles),
                .perf_pw_cycles(ds_perf_pw_cycles),
                .perf_pw_issue_cycles(ds_perf_pw_issue_cycles),
                .shared_valid_in(shared_ds_valid_in),
                .shared_ready_in(shared_ds_ready_in),
                .shared_first_k(shared_ds_first_k),
                .shared_last_k(shared_ds_last_k),
                .shared_k_idx(shared_ds_k_idx),
                .shared_act_vec(shared_ds_act_vec),
                .shared_wgt_vec16(shared_ds_wgt_vec16),
                .shared_pixel_mask(shared_ds_pixel_mask),
                .shared_cout_mask(shared_ds_cout_mask),
                .shared_pixel_base(shared_ds_pixel_base),
                .shared_cout_base(shared_ds_cout_base),
                .shared_bias_vec(shared_ds_bias_vec),
                .shared_multiplier_vec(shared_ds_multiplier_vec),
                .shared_shift_vec(shared_ds_shift_vec),
                .shared_out_valid(shared_ds_out_valid),
                .shared_out_ready(shared_ds_out_ready),
                .shared_out_pixel_idx(shared_ds_out_pixel_idx),
                .shared_out_channel_base(shared_ds_out_channel_base),
                .shared_out_lane_mask(shared_ds_out_lane_mask),
                .shared_out_data(shared_ds_out_data)
            );
        end else begin : gen_retained_only_ds_no_legacy
            assign ds_busy = 1'b0;
            assign ds_done = 1'b0;
            assign ds_error = 1'b0;
            assign ds_cfg_ready = 1'b0;
            assign ds_cfg_weight_word_ready = 1'b0;
            assign ds_out_wr_en = 1'b0;
            assign ds_out_wr_pixel_idx = 6'd0;
            assign ds_out_wr_channel_idx = 8'd0;
            assign ds_out_wr_data_int8 = 8'sd0;
            assign ds_out_wr_vec4_en = 1'b0;
            assign ds_out_wr_vec4_pixel_idx = 6'd0;
            assign ds_out_wr_vec4_channel_idx = 8'd0;
            assign ds_out_wr_vec4_data_int8 = 32'd0;
            assign ds_perf_total_cycles = 32'd0;
            assign ds_perf_dw_cycles = 32'd0;
            assign ds_perf_pw_cycles = 32'd0;
            assign ds_perf_pw_issue_cycles = 32'd0;
        end
    endgenerate

    generate
        if (USE_DS1_RETAINED_ORCHESTRATOR != 0) begin : gen_ds1_retained_runner
            assign ds1_ret_start_valid =
                (state == ST_DS1_RETAINED_START) && ds1_retained_mode_reg;
            ds1_retained_runner_adapter #(
                .ADDR_WIDTH(24),
                .SRAM_ADDR_WIDTH(SRAM_ADDR_WIDTH),
                .MAX_CIN(MAX_CIN),
                .FIFO_DEPTH(8)
            ) u_ds1_retained_adapter (
                .clk(clk), .rst_n(rst_n),
                .layer_start_valid(ds1_ret_start_valid),
                .layer_start_ready(ds1_ret_start_ready),
                .input_base_addr(input_addr_reg[23:0]),
                .input_zero_point(input_zero_point_reg[7:0]),
                .config_write_en(ds_cfg_wr_en),
                .config_target(ds_cfg_target),
                .config_index(ds_cfg_index),
                .config_data(ds_cfg_data),
                .dw_output_zero_point(dw_output_zero_point_reg),
                .dw_activation_min(dw_activation_min_reg),
                .dw_activation_max(dw_activation_max_reg),
                .pw_output_zero_point(pw_output_zero_point_reg),
                .pw_activation_min(pw_activation_min_reg),
                .pw_activation_max(pw_activation_max_reg),
                .source_word_en(ds1_ret_source_word_en),
                .source_word_addr(ds1_ret_source_word_addr),
                .source_word_valid(sram_input_rd_word_valid),
                .source_word_data(sram_input_rd_word_data),
                .output_word_en(ds1_ret_output_word_en),
                .output_word_addr(ds1_ret_output_word_addr),
                .output_word_data(ds1_ret_output_word_data),
                .output_word_be(ds1_ret_output_word_be),
                .done(ds1_ret_done), .error(ds1_ret_error),
                .busy(ds1_ret_busy)
            );
        end else begin : gen_no_ds1_retained_runner
            assign ds1_ret_start_valid = 1'b0;
            assign ds1_ret_start_ready = 1'b0;
            assign ds1_ret_source_word_en = 1'b0;
            assign ds1_ret_source_word_addr = {SRAM_ADDR_WIDTH{1'b0}};
            assign ds1_ret_output_word_en = 1'b0;
            assign ds1_ret_output_word_addr = 16'd0;
            assign ds1_ret_output_word_data = 32'd0;
            assign ds1_ret_output_word_be = 4'd0;
            assign ds1_ret_done = 1'b0;
            assign ds1_ret_error = 1'b0;
            assign ds1_ret_busy = 1'b0;
        end
    endgenerate

    /* Shared unified64 arithmetic island.  Stem and DS front ends are both
     * present for the complete network, but their layer transactions are
     * mutually exclusive; a narrow mode-selected mux therefore feeds one
     * physical 64-MAC/four-lane-RQ instance. */
    wire shared_core_valid_in, shared_core_ready_in;
    wire shared_core_first_k, shared_core_last_k;
    wire [7:0] shared_core_k_idx;
    wire signed [63:0] shared_core_act_vec;
    wire signed [127:0] shared_core_wgt_vec16;
    wire [7:0] shared_core_pixel_mask;
    wire [15:0] shared_core_cout_mask;
    wire [10:0] shared_core_pixel_base;
    wire [8:0] shared_core_cout_base;
    wire signed [511:0] shared_core_bias_vec;
    wire signed [511:0] shared_core_multiplier_vec;
    wire [95:0] shared_core_shift_vec;
    wire shared_core_valid_out;
    wire [10:0] shared_core_out_pixel_idx;
    wire [8:0] shared_core_out_channel_base;
    wire [3:0] shared_core_out_lane_mask;
    wire signed [31:0] shared_core_out_data;
    generate
        if (USE_SHARED_UNIFIED64) begin : gen_shared_unified64_core
            assign shared_core_valid_in = op_is_stem_reg ? shared_stem_valid_in : shared_ds_valid_in;
            assign shared_stem_ready_in = op_is_stem_reg ? shared_core_ready_in : 1'b0;
            assign shared_ds_ready_in = op_is_ds_reg ? shared_core_ready_in : 1'b0;
            assign shared_core_first_k = op_is_stem_reg ? shared_stem_first_k : shared_ds_first_k;
            assign shared_core_last_k = op_is_stem_reg ? shared_stem_last_k : shared_ds_last_k;
            assign shared_core_k_idx = op_is_stem_reg ? shared_stem_k_idx : shared_ds_k_idx;
            assign shared_core_act_vec = op_is_stem_reg ? shared_stem_act_vec : shared_ds_act_vec;
            assign shared_core_wgt_vec16 = op_is_stem_reg ? shared_stem_wgt_vec16 : shared_ds_wgt_vec16;
            assign shared_core_pixel_mask = op_is_stem_reg ? shared_stem_pixel_mask : shared_ds_pixel_mask;
            assign shared_core_cout_mask = op_is_stem_reg ? shared_stem_cout_mask : shared_ds_cout_mask;
            assign shared_core_pixel_base = op_is_stem_reg ? shared_stem_pixel_base : shared_ds_pixel_base;
            assign shared_core_cout_base = op_is_stem_reg ? shared_stem_cout_base : shared_ds_cout_base;
            assign shared_core_bias_vec = op_is_stem_reg ? shared_stem_bias_vec : shared_ds_bias_vec;
            assign shared_core_multiplier_vec = op_is_stem_reg ? shared_stem_multiplier_vec : shared_ds_multiplier_vec;
            assign shared_core_shift_vec = op_is_stem_reg ? shared_stem_shift_vec : shared_ds_shift_vec;
            assign shared_stem_out_valid = shared_core_valid_out && op_is_stem_reg;
            assign shared_ds_out_valid = shared_core_valid_out && op_is_ds_reg;
            assign shared_stem_out_pixel_idx = shared_core_out_pixel_idx;
            assign shared_stem_out_channel_base = shared_core_out_channel_base;
            assign shared_stem_out_lane_mask = shared_core_out_lane_mask;
            assign shared_stem_out_data = shared_core_out_data;
            assign shared_ds_out_pixel_idx = shared_core_out_pixel_idx;
            assign shared_ds_out_channel_base = shared_core_out_channel_base;
            assign shared_ds_out_lane_mask = shared_core_out_lane_mask;
            assign shared_ds_out_data = shared_core_out_data;
            unified64_shared_compute_array u_shared_compute_array (
                .clk(clk), .rst_n(rst_n), .mode_stem(op_is_stem_reg),
                .valid_in(shared_core_valid_in), .ready_in(shared_core_ready_in),
                .first_k(shared_core_first_k), .last_k(shared_core_last_k),
                .k_idx(shared_core_k_idx), .act_vec(shared_core_act_vec),
                .wgt_vec16(shared_core_wgt_vec16),
                .pixel_mask(shared_core_pixel_mask), .cout_mask(shared_core_cout_mask),
                .pixel_base(shared_core_pixel_base), .cout_base(shared_core_cout_base),
                .bias_vec(shared_core_bias_vec), .multiplier_vec(shared_core_multiplier_vec),
                .shift_vec(shared_core_shift_vec),
                .output_zero_point_int32(op_is_stem_reg ? dw_output_zero_point_reg : pw_output_zero_point_reg),
                .activation_min_int32(op_is_stem_reg ? dw_activation_min_reg : pw_activation_min_reg),
                .activation_max_int32(op_is_stem_reg ? dw_activation_max_reg : pw_activation_max_reg),
                .ready_out(shared_stem_out_ready || shared_ds_out_ready),
                .valid_out(shared_core_valid_out), .out_pixel_idx(shared_core_out_pixel_idx),
                .out_channel_base(shared_core_out_channel_base),
                .out_lane_mask(shared_core_out_lane_mask), .out_data(shared_core_out_data),
                .busy(), .metric_token_count(), .metric_masked_mac_count(), .metric_commit_count()
            );
        end else begin : gen_no_shared_unified64_core
            assign shared_stem_ready_in = 1'b0;
            assign shared_ds_ready_in = 1'b0;
            assign shared_stem_out_valid = 1'b0;
            assign shared_ds_out_valid = 1'b0;
            assign shared_core_ready_in = 1'b0;
            assign shared_core_valid_out = 1'b0;
            assign shared_core_out_pixel_idx = 11'd0;
            assign shared_core_out_channel_base = 9'd0;
            assign shared_core_out_lane_mask = 4'd0;
            assign shared_core_out_data = 32'd0;
            assign shared_stem_out_pixel_idx = 11'd0;
            assign shared_stem_out_channel_base = 9'd0;
            assign shared_stem_out_lane_mask = 4'd0;
            assign shared_stem_out_data = 32'd0;
            assign shared_ds_out_pixel_idx = 11'd0;
            assign shared_ds_out_channel_base = 9'd0;
            assign shared_ds_out_lane_mask = 4'd0;
            assign shared_ds_out_data = 32'd0;
        end
    endgenerate

    tile_scheduler #(
        .TILE_H(8),
        .TILE_W(8)
    ) u_tile_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .start(tile_sched_start),
        .next(tile_sched_next),
        .out_h(tiled_out_h),
        .out_w(tiled_out_w),
        .stride(effective_stride[1:0]),
        .valid(tile_sched_valid),
        .tile_h_start(sched_tile_h_start),
        .tile_w_start(sched_tile_w_start),
        .tile_h_size(sched_tile_h_size),
        .tile_w_size(sched_tile_w_size),
        .input_tile_h(sched_input_tile_h),
        .input_tile_w(sched_input_tile_w),
        .is_last_tile(sched_is_last_tile)
    );

    gap_unit_new u_gap_unit (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_wr_en(aux_cfg_wr_en && op_is_gap_reg &&
                   (aux_cfg_target == PH_INPUT)),
        .cfg_ready(gap_cfg_ready),
        .cfg_index(aux_cfg_index),
        .cfg_data_int8(aux_cfg_data[7:0]),
        .start(gap_start),
        .busy(gap_busy),
        .done(gap_done),
        .out_rd_index(store_idx[7:0]),
        .out_rd_data(gap_out_rd_data)
    );

    fc_unit_new u_fc_unit (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_wr_en(aux_cfg_wr_en && op_is_fc_reg),
        .cfg_ready(fc_cfg_ready),
        .cfg_target(aux_cfg_target),
        .cfg_index(aux_cfg_index),
        .cfg_data(aux_cfg_data),
        .start(fc_start),
        .busy(fc_busy),
        .done(fc_done),
        .error(fc_error),
        .output_zero_point(pw_output_zero_point_reg),
        .activation_min(pw_activation_min_reg),
        .activation_max(pw_activation_max_reg),
        .out_rd_index(store_idx[3:0]),
        .out_rd_data(fc_out_rd_data)
    );

    cnn_out_buffer #(
        .DEPTH(OUT_BUFFER_DEPTH),
        .ADDR_WIDTH(OUT_BUFFER_ADDR_WIDTH)
    ) u_out_buffer (
        .clk(clk),
        .wr_en(out_buffer_wr_en),
        .wr_addr(out_buffer_wr_addr),
        .wr_data(out_buffer_wr_data),
        .rd_en(out_buffer_rd_en),
        .rd_addr(out_buffer_rd_addr),
        .rd_data(out_buffer_rd_data),
        .wr_word_en(out_buffer_wr_word_en),
        .wr_word_addr(out_buffer_wr_word_addr),
        .wr_word_data(out_buffer_wr_word_data),
        .wr_word_be(out_buffer_wr_word_be),
        .rd_word_en(out_buffer_rd_word_en),
        .rd_word_addr(out_buffer_rd_word_addr),
        .rd_word_data(out_buffer_rd_word_data),
        .rd_word_valid(out_buffer_rd_word_valid)
    );

    assign out_buffer_wr_en = stem_out_wr_en || ds_out_wr_en;
    assign out_buffer_wr_addr = stem_out_wr_en ?
        ((stem_out_wr_pixel_idx * MAX_COUT) + stem_out_wr_channel_idx) :
        ((ds_out_wr_pixel_idx * MAX_COUT) + ds_out_wr_channel_idx);
    assign out_buffer_wr_data = stem_out_wr_en ? stem_out_wr_data_int8 : ds_out_wr_data_int8;
    // Unified Stem commits four channels atomically, matching the existing
    // feature-bank word-write contract.  Legacy scalar Stem and DS writes
    // remain on their original paths; only one word producer is active for a
    // transaction.
    assign out_buffer_wr_word_en = (unified_stem_mode &&
                                    unified_stem_out_wr_valid) ||
                                   ds_out_wr_vec4_en;
    assign out_buffer_wr_word_addr = (unified_stem_mode &&
                                      unified_stem_out_wr_valid) ?
        ((unified_stem_out_wr_pixel_idx * MAX_COUT) +
         unified_stem_out_wr_channel_base) :
        ((ds_out_wr_vec4_pixel_idx * MAX_COUT) +
         ds_out_wr_vec4_channel_idx);
    assign out_buffer_wr_word_data = (unified_stem_mode &&
                                      unified_stem_out_wr_valid) ?
        unified_stem_out_wr_data : ds_out_wr_vec4_data_int8;
    assign out_buffer_wr_word_be = (unified_stem_mode &&
                                    unified_stem_out_wr_valid) ?
        unified_stem_out_wr_byte_en : 4'b1111;
    assign store_active_channels = op_is_stem_reg ?
                                   16'd16 : out_c_reg;
    assign store_outbuf_next_addr =
        ((store_channel_pos + 16'd1) >= store_active_channels) ?
        (store_outbuf_addr + MAX_COUT - store_active_channels + 16'd1) :
        (store_outbuf_addr + 1'b1);
    wire [31:0] store_sram_byte_addr_current = tiled_spatial_mode ?
                                                tiled_store_sram_addr_current :
                                                (output_addr_reg + store_idx);
    wire [15:0] store_channel_after_step =
        store_write_word_eligible_reg ?
            (((store_channel_pos + 16'd4) >= store_active_channels) ?
             16'd0 : (store_channel_pos + 16'd4)) :
            (((store_channel_pos + 16'd1) >= store_active_channels) ?
             16'd0 : (store_channel_pos + 16'd1));
    wire store_word_reaches_channel_end =
        store_write_word_eligible_reg &&
        ((store_channel_pos + 16'd4) >= store_active_channels);
    wire store_scalar_reaches_channel_end =
        (!store_write_word_eligible_reg) &&
        ((store_channel_pos + 16'd1) >= store_active_channels);
    wire [31:0] tiled_store_sram_addr_after_step =
        store_word_reaches_channel_end ?
         (((tiled_store_x + 8'd1) >= tile_w_size_reg) ?
         (tiled_store_sram_addr_row_base + tiled_store_sram_addr_row_jump) :
         (tiled_store_sram_addr_col_base + tiled_store_sram_addr_col_jump)) :
        store_scalar_reaches_channel_end ?
         (((tiled_store_x + 8'd1) >= tile_w_size_reg) ?
         (tiled_store_sram_addr_row_base + tiled_store_sram_addr_row_jump) :
         (tiled_store_sram_addr_col_base + tiled_store_sram_addr_col_jump)) :
         (tiled_store_sram_addr_current +
          (store_write_word_eligible_reg ? 32'd4 : 32'd1));
    wire [31:0] store_sram_byte_addr_after_step = tiled_spatial_mode ?
                                                   tiled_store_sram_addr_after_step :
                                                   (output_addr_reg + store_idx_after_step);
    assign store_word_eligible =
        flags_reg[FLAG_OUTPUT_TO_SRAM] &&
        op_is_ds_reg &&
        // store_count is exactly pixel_count*store_active_channels and the
        // cursor advances by whole channel groups, so channel position is a
        // sufficient remaining-count check.  Keeping store_idx out of this
        // predicate removes it from the output-buffer address cone.
        ((store_channel_pos + 16'd4) <= store_active_channels) &&
        (store_outbuf_addr[1:0] == 2'b00) &&
        (store_sram_byte_addr_current[1:0] == 2'b00);
    // The current write mode is captured when its synchronous read is
    // issued.  All write-side progression below uses that registered mode;
    // the raw predicate above is only used to seed the first item and the
    // next-item predicate is only sampled at the write boundary.
    assign store_step = store_write_word_eligible_reg ? 32'd4 : 32'd1;
    assign store_idx_after_step = store_idx + store_step;
    assign store_outbuf_after_step = store_write_word_eligible_reg ?
        (store_word_reaches_channel_end ?
         (store_outbuf_addr + MAX_COUT - store_active_channels + 16'd4) :
         (store_outbuf_addr + 16'd4)) : store_outbuf_next_addr;
    assign store_next_word_eligible =
        flags_reg[FLAG_OUTPUT_TO_SRAM] &&
        op_is_ds_reg &&
        ((store_channel_after_step + 16'd4) <= store_active_channels) &&
        (store_outbuf_after_step[1:0] == 2'b00) &&
        (store_sram_byte_addr_after_step[1:0] == 2'b00);
    wire store_read_active =
        (state == ST_STORE_READ_ISSUE);
    assign out_buffer_rd_addr =
        (state == ST_STORE_READ_ISSUE) ? store_issue_addr_reg :
        store_outbuf_addr;
    assign out_buffer_rd_word_addr = out_buffer_rd_addr;
    assign out_buffer_rd_word_en =
        op_is_ds_reg && store_read_active && store_issue_word_eligible_reg;
    assign out_buffer_rd_en =
        store_read_active &&
        (op_is_stem_reg ||
         (op_is_ds_reg && !store_issue_word_eligible_reg));

    function [3:0] calc_out_dim;
        input [15:0] in_dim;
        input [7:0] stride_value;
        reg [15:0] out_value;
        begin
            if (in_dim < 16'd3) begin
                calc_out_dim = 4'd0;
            end else if ((stride_value == 8'd0) || (stride_value == 8'd1)) begin
                calc_out_dim = (in_dim - 16'd2);
            end else if (stride_value == 8'd2) begin
                out_value = ((in_dim - 16'd3) >> 1) + 16'd1;
                calc_out_dim = out_value[3:0];
            end else begin
                calc_out_dim = 4'd0;
            end
        end
    endfunction

    function [7:0] same_out_dim;
        input [15:0] in_dim;
        input [7:0] stride_value;
        begin
            if (in_dim == 16'd0) begin
                same_out_dim = 8'd0;
            end else if ((stride_value == 8'd0) || (stride_value == 8'd1)) begin
                same_out_dim = in_dim[7:0];
            end else if (stride_value == 8'd2) begin
                same_out_dim = ((in_dim + 16'd1) >> 1);
            end else begin
                same_out_dim = 8'd0;
            end
        end
    endfunction

    function [31:0] conv_input_count;
        begin
            conv_input_count = {16'd0, in_h_reg} * {16'd0, in_w_reg} * {16'd0, in_c_reg};
        end
    endfunction

    // Descriptor phase counts are formed in two registered stages.  The
    // first stage deliberately contains at most the HxW product; the second
    // stage multiplies that registered value by the channel/constant factor.
    // This keeps the three-operand DS input count from becoming one DSP chain
    // into a control-register enable.
    function [31:0] phase_count_seed_for;
        input [31:0] op_type;
        input [3:0] phase;
        begin
            phase_count_seed_for = 32'd0;
            case (op_type)
                OP_CONV3X3_STEM: begin
                    case (phase)
                        PH_INPUT:     phase_count_seed_for =
                            {16'd0, in_h_reg} * {16'd0, in_w_reg};
                        PH_DW_WEIGHT: phase_count_seed_for = 32'd16;
                        PH_DW_BIAS:   phase_count_seed_for = 32'd16;
                        PH_DW_MUL:    phase_count_seed_for = 32'd16;
                        PH_DW_SHIFT:  phase_count_seed_for = 32'd16;
                        default:      phase_count_seed_for = 32'd0;
                    endcase
                end
                OP_DS_BLOCK: begin
                    case (phase)
                        PH_INPUT:     phase_count_seed_for =
                            {16'd0, in_h_reg} * {16'd0, in_w_reg};
                        PH_DW_WEIGHT: phase_count_seed_for =
                            flags_reg[FLAG_PACKED_WEIGHTS] ?
                            ((({16'd0, in_c_reg} * 32'd9) + 32'd3) >> 2) :
                            {16'd0, in_c_reg};
                        PH_DW_BIAS:   phase_count_seed_for = {16'd0, in_c_reg};
                        PH_DW_MUL:    phase_count_seed_for = {16'd0, in_c_reg};
                        PH_DW_SHIFT:  phase_count_seed_for = {16'd0, in_c_reg};
                        PH_PW_WEIGHT: phase_count_seed_for =
                            flags_reg[FLAG_PACKED_WEIGHTS] ?
                            ((({16'd0, out_c_reg} * {16'd0, in_c_reg}) + 32'd3) >> 2) :
                            {16'd0, out_c_reg};
                        PH_PW_BIAS:   phase_count_seed_for = {16'd0, out_c_reg};
                        PH_PW_MUL:    phase_count_seed_for = {16'd0, out_c_reg};
                        PH_PW_SHIFT:  phase_count_seed_for = {16'd0, out_c_reg};
                        default:      phase_count_seed_for = 32'd0;
                    endcase
                end
                OP_GAP: begin
                    phase_count_seed_for = (phase == PH_INPUT) ?
                                           32'd4096 : 32'd0;
                end
                OP_FC: begin
                    case (phase)
                        PH_INPUT:     phase_count_seed_for = 32'd256;
                        PH_PW_WEIGHT: phase_count_seed_for = 32'd2560;
                        PH_PW_BIAS:   phase_count_seed_for = 32'd10;
                        PH_PW_MUL:    phase_count_seed_for = 32'd10;
                        PH_PW_SHIFT:  phase_count_seed_for = 32'd10;
                        default:      phase_count_seed_for = 32'd0;
                    endcase
                end
                default: begin
                    phase_count_seed_for = 32'd0;
                end
            endcase
        end
    endfunction

    function [31:0] phase_count_factor_for;
        input [31:0] op_type;
        input [3:0] phase;
        begin
            phase_count_factor_for = 32'd0;
            case (op_type)
                OP_CONV3X3_STEM: begin
                    case (phase)
                        PH_INPUT:     phase_count_factor_for = 32'd3;
                        PH_DW_WEIGHT: phase_count_factor_for = 32'd27;
                        PH_DW_BIAS,
                        PH_DW_MUL,
                        PH_DW_SHIFT:  phase_count_factor_for = 32'd1;
                        default:      phase_count_factor_for = 32'd0;
                    endcase
                end
                OP_DS_BLOCK: begin
                    case (phase)
                        PH_INPUT:     phase_count_factor_for = {16'd0, in_c_reg};
                        PH_DW_WEIGHT: phase_count_factor_for =
                            flags_reg[FLAG_PACKED_WEIGHTS] ? 32'd1 : 32'd9;
                        PH_PW_WEIGHT: phase_count_factor_for =
                            flags_reg[FLAG_PACKED_WEIGHTS] ? 32'd1 :
                            {16'd0, in_c_reg};
                        PH_DW_BIAS,
                        PH_DW_MUL,
                        PH_DW_SHIFT,
                        PH_PW_BIAS,
                        PH_PW_MUL,
                        PH_PW_SHIFT:  phase_count_factor_for = 32'd1;
                        default:      phase_count_factor_for = 32'd0;
                    endcase
                end
                OP_GAP: phase_count_factor_for = (phase == PH_INPUT) ?
                                                  32'd1 : 32'd0;
                OP_FC: begin
                    case (phase)
                        PH_INPUT,
                        PH_PW_WEIGHT,
                        PH_PW_BIAS,
                        PH_PW_MUL,
                        PH_PW_SHIFT:  phase_count_factor_for = 32'd1;
                        default:      phase_count_factor_for = 32'd0;
                    endcase
                end
                default: begin
                    phase_count_factor_for = 32'd0;
                end
            endcase
        end
    endfunction

    function [31:0] phase_count_for;
        input [31:0] op_type;
        input [3:0] phase;
        begin
            phase_count_for = 32'd0;
            case (op_type)
                OP_CONV3X3_STEM: begin
                    case (phase)
                        PH_INPUT:     phase_count_for = {16'd0, in_h_reg} * {16'd0, in_w_reg} * 32'd3;
                        PH_DW_WEIGHT: phase_count_for = 32'd16 * 32'd27;
                        PH_DW_BIAS:   phase_count_for = 32'd16;
                        PH_DW_MUL:    phase_count_for = 32'd16;
                        PH_DW_SHIFT:  phase_count_for = 32'd16;
                        default:      phase_count_for = 32'd0;
                    endcase
                end
                OP_DS_BLOCK: begin
                    case (phase)
                        PH_INPUT:     phase_count_for = conv_input_count();
                        PH_DW_WEIGHT: phase_count_for = {16'd0, in_c_reg} * 32'd9;
                        PH_DW_BIAS:   phase_count_for = {16'd0, in_c_reg};
                        PH_DW_MUL:    phase_count_for = {16'd0, in_c_reg};
                        PH_DW_SHIFT:  phase_count_for = {16'd0, in_c_reg};
                        PH_PW_WEIGHT: phase_count_for = {16'd0, out_c_reg} * {16'd0, in_c_reg};
                        PH_PW_BIAS:   phase_count_for = {16'd0, out_c_reg};
                        PH_PW_MUL:    phase_count_for = {16'd0, out_c_reg};
                        PH_PW_SHIFT:  phase_count_for = {16'd0, out_c_reg};
                        default:      phase_count_for = 32'd0;
                    endcase
                end
                OP_GAP: begin
                    phase_count_for = (phase == PH_INPUT) ? 32'd4096 : 32'd0;
                end
                OP_FC: begin
                    case (phase)
                        PH_INPUT:     phase_count_for = 32'd256;
                        PH_PW_WEIGHT: phase_count_for = 32'd2560;
                        PH_PW_BIAS:   phase_count_for = 32'd10;
                        PH_PW_MUL:    phase_count_for = 32'd10;
                        PH_PW_SHIFT:  phase_count_for = 32'd10;
                        default:      phase_count_for = 32'd0;
                    endcase
                end
                default: begin
                    phase_count_for = 32'd0;
                end
            endcase
        end
    endfunction

    function [31:0] phase_addr_for;
        input [31:0] op_type;
        input [3:0] phase;
        begin
            phase_addr_for = 32'd0;
            case (op_type)
                OP_CONV3X3_STEM: begin
                    case (phase)
                        PH_INPUT:     phase_addr_for = input_addr_reg;
                        PH_DW_WEIGHT: phase_addr_for = dw_weight_addr_reg;
                        PH_DW_BIAS:   phase_addr_for = dw_bias_addr_reg;
                        PH_DW_MUL:    phase_addr_for = dw_mul_addr_reg;
                        PH_DW_SHIFT:  phase_addr_for = dw_shift_addr_reg;
                        default:      phase_addr_for = 32'd0;
                    endcase
                end
                OP_DS_BLOCK: begin
                    case (phase)
                        PH_INPUT:     phase_addr_for = input_addr_reg;
                        PH_DW_WEIGHT: phase_addr_for = dw_weight_addr_reg;
                        PH_DW_BIAS:   phase_addr_for = dw_bias_addr_reg;
                        PH_DW_MUL:    phase_addr_for = dw_mul_addr_reg;
                        PH_DW_SHIFT:  phase_addr_for = dw_shift_addr_reg;
                        PH_PW_WEIGHT: phase_addr_for = pw_weight_addr_reg;
                        PH_PW_BIAS:   phase_addr_for = pw_bias_addr_reg;
                        PH_PW_MUL:    phase_addr_for = pw_mul_addr_reg;
                        PH_PW_SHIFT:  phase_addr_for = pw_shift_addr_reg;
                        default:      phase_addr_for = 32'd0;
                    endcase
                end
                OP_GAP: begin
                    phase_addr_for = (phase == PH_INPUT) ? input_addr_reg : 32'd0;
                end
                OP_FC: begin
                    case (phase)
                        PH_INPUT:     phase_addr_for = input_addr_reg;
                        PH_PW_WEIGHT: phase_addr_for = pw_weight_addr_reg;
                        PH_PW_BIAS:   phase_addr_for = pw_bias_addr_reg;
                        PH_PW_MUL:    phase_addr_for = pw_mul_addr_reg;
                        PH_PW_SHIFT:  phase_addr_for = pw_shift_addr_reg;
                        default:      phase_addr_for = 32'd0;
                    endcase
                end
                default: begin
                    phase_addr_for = 32'd0;
                end
            endcase
        end
    endfunction

    function [3:0] last_phase_for;
        input [31:0] op_type;
        begin
            case (op_type)
                OP_CONV3X3_STEM: last_phase_for = PH_DW_SHIFT;
                OP_DS_BLOCK:     last_phase_for = PH_PW_SHIFT;
                OP_GAP:          last_phase_for = PH_INPUT;
                OP_FC:           last_phase_for = PH_PW_SHIFT;
                default:         last_phase_for = PH_INPUT;
            endcase
        end
    endfunction

    function [31:0] output_count_for;
        input [31:0] op_type;
        begin
            case (op_type)
                OP_CONV3X3_STEM: output_count_for = {18'd0, conv_out_pixels_reg} * 32'd16;
                OP_DS_BLOCK:     output_count_for = {18'd0, conv_out_pixels_reg} * {16'd0, out_c_reg};
                OP_GAP:          output_count_for = 32'd256;
                OP_FC:           output_count_for = 32'd10;
                default:         output_count_for = 32'd0;
            endcase
        end
    endfunction

    function [31:0] sram_output_count_for;
        input [31:0] op_type;
        begin
            if (tiled_spatial_mode) begin
                sram_output_count_for = {16'd0, tiled_out_pixels_reg} *
                                        {16'd0, out_c_reg};
            end else begin
                sram_output_count_for = output_count_for(op_type);
            end
        end
    endfunction

    function sram_span_valid;
        input [31:0] base_addr;
        input [31:0] element_count;
        reg [32:0] span_end_exclusive;
        begin
            span_end_exclusive =
                {1'b0, base_addr} + {1'b0, element_count};
            sram_span_valid =
                ({1'b0, base_addr} < SRAM_CAPACITY_BYTES) &&
                (span_end_exclusive <= SRAM_CAPACITY_BYTES);
        end
    endfunction

    function [SRAM_ADDR_WIDTH-1:0] sram_addr_for_index;
        input [31:0] base_addr;
        input [31:0] idx;
        begin
            sram_addr_for_index = base_addr + idx;
        end
    endfunction

    // Parameterized padding is evaluated only while filling the registered
    // current/successor metadata bundles.  The FSM itself consumes the
    // registered results.
    function tiled_input_is_padding_at;
        input [7:0] y;
        input [7:0] x;
        integer src_y;
        integer src_x;
        begin
            src_y = tiled_input_halo_row_offset_reg + y;
            src_x = tiled_input_halo_col_offset_reg + x;
            tiled_input_is_padding_at =
                (src_y < 0) || (src_x < 0) ||
                (src_y >= in_h_reg) || (src_x >= in_w_reg);
        end
    endfunction

    function [31:0] tiled_store_global_index_current;
        integer global_y;
        integer global_x;
        begin
            global_y = tile_h_start_reg + tiled_store_y;
            global_x = tile_w_start_reg + tiled_store_x;
            tiled_store_global_index_current =
                (((global_y * tiled_out_w) + global_x) * out_c_reg) +
                store_channel_pos;
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    function valid_config;
        begin
            valid_config = 1'b0;
            case (op_type_reg)
                OP_CONV3X3_STEM: begin
                    if (unified_stem_mode) begin
                        valid_config = (in_h_reg == 16'd32) &&
                                       (in_w_reg == 16'd32) &&
                                       (in_c_reg == 16'd3) &&
                                       (out_c_reg == 16'd16) &&
                                       (effective_stride == 8'd1) &&
                                       (pad_reg == 8'd1);
                    end else if (tiled_stem_mode) begin
                        valid_config = (in_h_reg >= 16'd1) && (in_h_reg <= 16'd32) &&
                                       (in_w_reg >= 16'd1) && (in_w_reg <= 16'd32) &&
                                       (in_c_reg == 16'd3) &&
                                       (out_c_reg == 16'd16) &&
                                       (effective_stride == 8'd1) &&
                                       (pad_reg == 8'd1) &&
                                       (tiled_out_pixels_reg != 16'd0);
                    end else begin
                        valid_config = (in_h_reg >= 16'd3) && (in_h_reg <= 16'd10) &&
                                       (in_w_reg >= 16'd3) && (in_w_reg <= 16'd10) &&
                                       (in_c_reg == 16'd3) &&
                                       (out_c_reg == 16'd16) &&
                                       (effective_stride == 8'd1) &&
                                       (pad_reg == 8'd1) &&
                                       (conv_out_pixels_reg <= 14'd64);
                    end
                end
                OP_DS_BLOCK: begin
                    if (tiled_ds_mode) begin
                        valid_config = (in_h_reg >= 16'd1) && (in_h_reg <= 16'd32) &&
                                       (in_w_reg >= 16'd1) && (in_w_reg <= 16'd32) &&
                                       (in_c_reg >= 16'd1) && (in_c_reg <= MAX_CIN) &&
                                       (out_c_reg >= 16'd1) && (out_c_reg <= MAX_COUT) &&
                                       ((effective_stride == 8'd1) || (effective_stride == 8'd2)) &&
                                       (pad_reg == 8'd1) &&
                                       (tiled_out_pixels_reg != 16'd0);
                    end else begin
                        valid_config = (in_h_reg >= 16'd3) && (in_h_reg <= MAX_DS_IN_H) &&
                                       (in_w_reg >= 16'd3) && (in_w_reg <= MAX_DS_IN_W) &&
                                       (in_c_reg >= 16'd1) && (in_c_reg <= MAX_CIN) &&
                                       (out_c_reg >= 16'd1) && (out_c_reg <= MAX_COUT) &&
                                       ((effective_stride == 8'd1) || (effective_stride == 8'd2)) &&
                                       (pad_reg == 8'd1) &&
                                       (conv_out_pixels_reg <= 14'd64);
                    end
                end
                OP_GAP: begin
                    valid_config = (in_h_reg == 16'd4) &&
                                   (in_w_reg == 16'd4) &&
                                   (in_c_reg == 16'd256) &&
                                   (out_c_reg == 16'd256) &&
                                   (effective_stride == 8'd1) &&
                                   (pad_reg == 8'd0);
                end
                OP_FC: begin
                    valid_config = (in_h_reg == 16'd1) &&
                                   (in_w_reg == 16'd1) &&
                                   (in_c_reg == 16'd256) &&
                                   (out_c_reg == 16'd10) &&
                                   (effective_stride == 8'd1) &&
                                   (pad_reg == 8'd0);
                end
                default: begin
                    valid_config = 1'b0;
                end
            endcase
        end
    endfunction

    /* verilator lint_off BLKSEQ */
    task store_stem_input;
        input [7:0] value;
        integer cfg_linear_index;
        begin
            cfg_linear_index =
                (compact_load_y * 10 * 3) +
                (compact_load_x * 3) +
                compact_load_channel;
            aux_cfg_wr_en <= 1'b1;
            aux_cfg_target <= PH_INPUT;
            aux_cfg_index <= cfg_linear_index[15:0];
            aux_cfg_data <= {{24{value[7]}}, value};
        end
    endtask

    task store_stem_tiled_input;
        input [7:0] value;
        integer cfg_linear_index;
        begin
            cfg_linear_index =
                (tiled_load_y * 10 * 3) +
                (tiled_load_x * 3) +
                tiled_load_channel;
            aux_cfg_wr_en <= 1'b1;
            aux_cfg_target <= PH_INPUT;
            aux_cfg_index <= cfg_linear_index[15:0];
            aux_cfg_data <= {{24{value[7]}}, value};
        end
    endtask

    task store_ds_input;
        input [7:0] value;
        integer cfg_linear_index;
        begin
            cfg_linear_index =
                (compact_load_y * MAX_DS_IN_W * MAX_CIN) +
                (compact_load_x * MAX_CIN) +
                compact_load_channel;
            ds_cfg_wr_en <= 1'b1;
            ds_cfg_target <= DS_CFG_INPUT;
            ds_cfg_index <= cfg_linear_index[15:0];
            ds_cfg_data <= {{24{value[7]}}, value};
        end
    endtask

    task store_ds_tiled_input;
        input [7:0] value;
        integer cfg_linear_index;
        begin
            cfg_linear_index =
                (tiled_load_y * MAX_DS_IN_W * MAX_CIN) +
                (tiled_load_x * MAX_CIN) +
                tiled_load_channel;
            ds_cfg_wr_en <= 1'b1;
            ds_cfg_target <= DS_CFG_INPUT;
            ds_cfg_index <= cfg_linear_index[15:0];
            ds_cfg_data <= {{24{value[7]}}, value};
        end
    endtask

    task store_stem_tiled_input_vec4;
        input [31:0] data;
        integer cfg_linear_index;
        begin
            cfg_linear_index =
                (tiled_load_y * 10 * 3) +
                (tiled_load_x * 3) + tiled_load_channel;
            aux_cfg_vec4_wr_en <= 1'b1;
            aux_cfg_vec4_index <= cfg_linear_index[15:0];
            aux_cfg_vec4_data <= data;
        end
    endtask

    task store_ds_tiled_input_vec4;
        input [31:0] data;
        integer cfg_linear_index;
        begin
            cfg_linear_index =
                (tiled_load_y * MAX_DS_IN_W * MAX_CIN) +
                (tiled_load_x * MAX_CIN) + tiled_load_channel;
            ds_cfg_vec4_wr_en <= 1'b1;
            ds_cfg_vec4_index <= cfg_linear_index[15:0];
            ds_cfg_vec4_data <= data;
        end
    endtask

    // Capture metadata for the current cursor.  This is the only place that
    // evaluates the wide signed halo comparisons for the current bundle.
    // The request FSM consumes the registered result and never recomputes it.
    task capture_tiled_load_metadata;
        input [7:0] y;
        input [7:0] x;
        input [15:0] channel;
        input [31:0] input_index;
        reg [31:0] source_byte_addr;
        begin
            source_byte_addr = input_addr_reg + input_index;
            tiled_load_current_padding_reg <=
                tiled_input_is_padding_at(y, x);
            tiled_load_word_channel_ok_reg <=
                tiled_channel_ge4_reg &&
                (channel <= tiled_channel_word_limit_reg) &&
                (channel[3:0] <= 4'd12);
            tiled_load_word_source_aligned_reg <=
                (source_byte_addr[1:0] == 2'b00);
            tiled_load_word_lane_mask_reg <=
                ((tiled_channel_ge4_reg &&
                  (channel <= tiled_channel_word_limit_reg)) &&
                 (channel[3:0] <= 4'd12)) ? 4'b1111 : 4'b0000;
            tiled_load_current_pixel_end_reg <=
                (channel >= tiled_channel_last_reg);
            tiled_load_current_word_pixel_end_reg <=
                !tiled_channel_ge4_reg ||
                (channel >= tiled_channel_word_limit_reg);
        end
    endtask

    // Build a scalar successor from the current cursor.  Only the narrow
    // cursor increments are performed here; padding and word eligibility are
    // registered later from the successor bundle.
    task prepare_tiled_load_successor_scalar;
        reg [7:0] next_y;
        reg [7:0] next_x;
        reg [15:0] next_channel;
        reg signed [31:0] next_index;
        reg signed [31:0] next_row_base;
        reg signed [31:0] next_row_next_base;
        reg signed [31:0] next_col_base;
        begin
            next_y = tiled_load_y;
            next_x = tiled_load_x;
            next_channel = tiled_load_channel;
            next_index = tiled_input_index_reg;
            next_row_base = tiled_input_row_base_reg;
            next_row_next_base = tiled_input_next_row_base_reg;
            next_col_base = tiled_input_col_base_reg;
            if (tiled_load_channel >= tiled_channel_last_reg) begin
                next_channel = 16'd0;
                if ((tiled_load_x + 8'd1) >= tile_input_w_reg) begin
                    next_x = 8'd0;
                    next_y = tiled_load_y + 8'd1;
                    next_row_base = tiled_input_next_row_base_reg;
                    next_row_next_base = tiled_input_next_row_base_reg +
                                         tiled_input_row_stride_reg;
                    next_col_base = tiled_input_tile_col_base_reg;
                    next_index = tiled_input_next_row_base_reg +
                                 tiled_input_tile_col_base_reg;
                end else begin
                    next_x = tiled_load_x + 8'd1;
                    next_col_base = tiled_input_col_base_reg + in_c_reg;
                    next_index = tiled_input_index_reg + 32'sd1;
                end
            end else begin
                next_channel = tiled_load_channel + 16'd1;
                next_index = tiled_input_index_reg + 32'sd1;
            end
            tiled_load_next_y_reg <= next_y;
            tiled_load_next_x_reg <= next_x;
            tiled_load_next_channel_reg <= next_channel;
            tiled_input_next_index_cursor_reg <= next_index;
            tiled_input_next_row_base_cursor_reg <= next_row_base;
            tiled_input_next_row_next_base_cursor_reg <= next_row_next_base;
            tiled_input_next_col_base_cursor_reg <= next_col_base;
        end
    endtask

    // Build a vector successor from the current cursor.  This is selected
    // only for a fully eligible word, so a word can never cross a pixel/row
    // or the logical channel tail.
    task prepare_tiled_load_successor_vec4;
        reg [7:0] next_y;
        reg [7:0] next_x;
        reg [15:0] next_channel;
        reg signed [31:0] next_index;
        reg signed [31:0] next_row_base;
        reg signed [31:0] next_row_next_base;
        reg signed [31:0] next_col_base;
        begin
            next_y = tiled_load_y;
            next_x = tiled_load_x;
            next_channel = tiled_load_channel;
            next_index = tiled_input_index_reg;
            next_row_base = tiled_input_row_base_reg;
            next_row_next_base = tiled_input_next_row_base_reg;
            next_col_base = tiled_input_col_base_reg;
            if (!tiled_channel_ge4_reg ||
                (tiled_load_channel >= tiled_channel_word_limit_reg)) begin
                next_channel = 16'd0;
                if ((tiled_load_x + 8'd1) >= tile_input_w_reg) begin
                    next_x = 8'd0;
                    next_y = tiled_load_y + 8'd1;
                    next_row_base = tiled_input_next_row_base_reg;
                    next_row_next_base = tiled_input_next_row_base_reg +
                                         tiled_input_row_stride_reg;
                    next_col_base = tiled_input_tile_col_base_reg;
                    next_index = tiled_input_next_row_base_reg +
                                 tiled_input_tile_col_base_reg;
                end else begin
                    next_x = tiled_load_x + 8'd1;
                    next_col_base = tiled_input_col_base_reg + in_c_reg;
                    next_index = tiled_input_index_reg + 32'sd4;
                end
            end else begin
                next_channel = tiled_load_channel + 16'd4;
                next_index = tiled_input_index_reg + 32'sd4;
            end
            tiled_load_next_y_reg <= next_y;
            tiled_load_next_x_reg <= next_x;
            tiled_load_next_channel_reg <= next_channel;
            tiled_input_next_index_cursor_reg <= next_index;
            tiled_input_next_row_base_cursor_reg <= next_row_base;
            tiled_input_next_row_next_base_cursor_reg <= next_row_next_base;
            tiled_input_next_col_base_cursor_reg <= next_col_base;
        end
    endtask

    // This is the independent metadata stage.  Its inputs are the
    // registered successor cursor, so the old current channel cannot feed a
    // halo/eligibility compare in the request-state cycle.  At a pixel
    // boundary the committed current cursor has just crossed into the new
    // pixel, so refresh its padding from the registered current y/x here as
    // well; the successor padding remains a separate next-pixel attribute.
    task capture_tiled_load_next_metadata;
        reg [31:0] source_byte_addr;
        begin
            source_byte_addr = input_addr_reg +
                               tiled_input_next_index_cursor_reg;
            tiled_load_current_padding_reg <=
                tiled_input_is_padding_at(tiled_load_y, tiled_load_x);
            tiled_load_next_padding_reg <=
                tiled_input_is_padding_at(tiled_load_next_y_reg,
                                          tiled_load_next_x_reg);
            tiled_load_next_word_channel_ok_reg <=
                tiled_channel_ge4_reg &&
                (tiled_load_next_channel_reg <= tiled_channel_word_limit_reg) &&
                (tiled_load_next_channel_reg[3:0] <= 4'd12);
            tiled_load_next_word_source_aligned_reg <=
                (source_byte_addr[1:0] == 2'b00);
            tiled_load_next_word_lane_mask_reg <=
                ((tiled_channel_ge4_reg &&
                  (tiled_load_next_channel_reg <= tiled_channel_word_limit_reg)) &&
                 (tiled_load_next_channel_reg[3:0] <= 4'd12)) ?
                4'b1111 : 4'b0000;
            tiled_load_next_pixel_end_reg <=
                (tiled_load_next_channel_reg >= tiled_channel_last_reg);
            tiled_load_next_word_pixel_end_reg <=
                !tiled_channel_ge4_reg ||
                (tiled_load_next_channel_reg >= tiled_channel_word_limit_reg);
        end
    endtask

    // Commit one consumed item.  The current bundle becomes the previously
    // prepared successor.  The following successor is advanced from that
    // registered bundle; only c/x/y and address cursors are incremented in
    // this task.  When a pixel boundary is crossed, the separate metadata
    // state below refreshes the wide signed halo predicates.
    task advance_tiled_load_position;
        input item_ends_pixel;
        reg [7:0] next2_y;
        reg [7:0] next2_x;
        reg [15:0] next2_channel;
        reg signed [31:0] next2_index;
        reg signed [31:0] next2_row_base;
        reg signed [31:0] next2_row_next_base;
        reg signed [31:0] next2_col_base;
        reg [31:0] next2_source_byte_addr;
        reg use_vec4;
        begin
`ifndef SYNTHESIS
            // The successor padding is a pixel attribute.  Record the exact
            // value that must be visible after this cursor commit so a
            // channel-only step cannot accidentally rebuild it from the
            // changing channel/x/y arithmetic.
            if (item_ends_pixel) begin
                sim_tiled_load_expect_current_padding_valid <= 1'b1;
                sim_tiled_load_expect_current_padding <=
                    tiled_load_next_padding_reg;
            end else begin
                sim_tiled_load_expect_next_padding_valid <= 1'b1;
                sim_tiled_load_expect_next_padding <=
                    tiled_load_next_padding_reg;
            end
`endif
            tiled_load_y <= tiled_load_next_y_reg;
            tiled_load_x <= tiled_load_next_x_reg;
            tiled_load_channel <= tiled_load_next_channel_reg;
            tiled_input_index_reg <= tiled_input_next_index_cursor_reg;
            tiled_input_row_base_reg <= tiled_input_next_row_base_cursor_reg;
            tiled_input_next_row_base_reg <=
                tiled_input_next_row_next_base_cursor_reg;
            tiled_input_col_base_reg <= tiled_input_next_col_base_cursor_reg;
            // Padding is a pixel attribute.  Keep the current pixel's
            // registered value through scalar/vector channel steps and only
            // commit the previously prepared successor value at a pixel
            // boundary.  The boundary lookahead metadata state then refreshes
            // the new current pixel and its successor from registered y/x.
            if (item_ends_pixel) begin
                tiled_load_current_padding_reg <= tiled_load_next_padding_reg;
            end
            tiled_load_word_channel_ok_reg <=
                tiled_load_next_word_channel_ok_reg;
            tiled_load_word_source_aligned_reg <=
                tiled_load_next_word_source_aligned_reg;
            tiled_load_word_lane_mask_reg <=
                tiled_load_next_word_lane_mask_reg;
            tiled_load_current_pixel_end_reg <=
                tiled_load_next_pixel_end_reg;
            tiled_load_current_word_pixel_end_reg <=
                tiled_load_next_word_pixel_end_reg;

            // The next item is vectorized only if its registered bundle is
            // non-padding and fully word-eligible.  In particular, the
            // address alignment and the low-nibble lane bound are checked
            // before selecting the four-byte cursor step.
            use_vec4 = !tiled_load_next_padding_reg &&
                       flags_reg[FLAG_INPUT_FROM_SRAM] &&
                       tiled_load_next_word_channel_ok_reg &&
                       tiled_load_next_word_source_aligned_reg &&
                       (tiled_load_next_word_lane_mask_reg == 4'b1111);
            next2_y = tiled_load_next_y_reg;
            next2_x = tiled_load_next_x_reg;
            next2_channel = tiled_load_next_channel_reg;
            next2_index = tiled_input_next_index_cursor_reg;
            next2_row_base = tiled_input_next_row_base_cursor_reg;
            next2_row_next_base = tiled_input_next_row_next_base_cursor_reg;
            next2_col_base = tiled_input_next_col_base_cursor_reg;
            if (use_vec4) begin
                if (!tiled_channel_ge4_reg ||
                    (tiled_load_next_channel_reg >= tiled_channel_word_limit_reg)) begin
                    next2_channel = 16'd0;
                    if ((tiled_load_next_x_reg + 8'd1) >= tile_input_w_reg) begin
                        next2_x = 8'd0;
                        next2_y = tiled_load_next_y_reg + 8'd1;
                        next2_row_base =
                            tiled_input_next_row_next_base_cursor_reg;
                        next2_row_next_base =
                            tiled_input_next_row_next_base_cursor_reg +
                            tiled_input_row_stride_reg;
                        next2_col_base = tiled_input_tile_col_base_reg;
                        next2_index =
                            tiled_input_next_row_next_base_cursor_reg +
                            tiled_input_tile_col_base_reg;
                    end else begin
                        next2_x = tiled_load_next_x_reg + 8'd1;
                        next2_col_base =
                            tiled_input_next_col_base_cursor_reg + in_c_reg;
                        next2_index =
                            tiled_input_next_index_cursor_reg + 32'sd4;
                    end
                end else begin
                    next2_channel = tiled_load_next_channel_reg + 16'd4;
                    next2_index =
                        tiled_input_next_index_cursor_reg + 32'sd4;
                end
            end else if (tiled_load_next_channel_reg >= tiled_channel_last_reg) begin
                next2_channel = 16'd0;
                if ((tiled_load_next_x_reg + 8'd1) >= tile_input_w_reg) begin
                    next2_x = 8'd0;
                    next2_y = tiled_load_next_y_reg + 8'd1;
                    next2_row_base = tiled_input_next_row_next_base_cursor_reg;
                    next2_row_next_base =
                        tiled_input_next_row_next_base_cursor_reg +
                        tiled_input_row_stride_reg;
                    next2_col_base = tiled_input_tile_col_base_reg;
                    next2_index = tiled_input_next_row_next_base_cursor_reg +
                                  tiled_input_tile_col_base_reg;
                end else begin
                    next2_x = tiled_load_next_x_reg + 8'd1;
                    next2_col_base =
                        tiled_input_next_col_base_cursor_reg + in_c_reg;
                    next2_index =
                        tiled_input_next_index_cursor_reg + 32'sd1;
                end
            end else begin
                next2_channel = tiled_load_next_channel_reg + 16'd1;
                next2_index = tiled_input_next_index_cursor_reg + 32'sd1;
            end
            tiled_load_next_y_reg <= next2_y;
            tiled_load_next_x_reg <= next2_x;
            tiled_load_next_channel_reg <= next2_channel;
            tiled_input_next_index_cursor_reg <= next2_index;
            tiled_input_next_row_base_cursor_reg <= next2_row_base;
            tiled_input_next_row_next_base_cursor_reg <= next2_row_next_base;
            tiled_input_next_col_base_cursor_reg <= next2_col_base;
            if (!item_ends_pixel) begin
                next2_source_byte_addr = input_addr_reg + next2_index;
                // Padding is invariant across channels within the pixel;
                // leave next_padding frozen until the boundary metadata
                // state evaluates the registered successor pixel.
                tiled_load_next_word_channel_ok_reg <=
                    tiled_channel_ge4_reg &&
                    (next2_channel <= tiled_channel_word_limit_reg) &&
                    (next2_channel[3:0] <= 4'd12);
                tiled_load_next_word_source_aligned_reg <=
                    (next2_source_byte_addr[1:0] == 2'b00);
                tiled_load_next_word_lane_mask_reg <=
                    ((tiled_channel_ge4_reg &&
                      (next2_channel <= tiled_channel_word_limit_reg)) &&
                     (next2_channel[3:0] <= 4'd12)) ?
                    4'b1111 : 4'b0000;
                tiled_load_next_pixel_end_reg <=
                    (next2_channel >= tiled_channel_last_reg);
                tiled_load_next_word_pixel_end_reg <=
                    !tiled_channel_ge4_reg ||
                    (next2_channel >= tiled_channel_word_limit_reg);
            end
        end
    endtask

    task advance_tiled_store_position;
        begin
            if ((store_channel_pos + 16'd1) >= store_active_channels) begin
                store_channel_pos <= 16'd0;
                if ((tiled_store_x + 8'd1) >= tile_w_size_reg) begin
                    tiled_store_x <= 8'd0;
                    tiled_store_y <= tiled_store_y + 8'd1;
                end else begin
                    tiled_store_x <= tiled_store_x + 8'd1;
                end
            end else begin
                store_channel_pos <= store_channel_pos + 16'd1;
            end
        end
    endtask

    task store_pw_weight;
        input [7:0] value;
        integer cfg_linear_index;
        begin
            cfg_linear_index = (pw_load_cout * MAX_CIN) + pw_load_cin;
            ds_cfg_wr_en <= 1'b1;
            ds_cfg_target <= DS_CFG_PW_WEIGHT;
            ds_cfg_index <= cfg_linear_index[15:0];
            ds_cfg_data <= {{24{value[7]}}, value};
        end
    endtask

    task store_ds_weight_word;
        input [3:0] phase;
        input [31:0] word_index;
        input [31:0] data;
        integer total_bytes;
        integer remaining_bytes;
        begin
            total_bytes = (phase == PH_DW_WEIGHT) ?
                          (in_c_reg * 9) : (in_c_reg * out_c_reg);
            remaining_bytes = total_bytes - (word_index * 4);
            ds_cfg_weight_word_wr_en <= 1'b1;
            ds_cfg_weight_word_target <= (phase == PH_PW_WEIGHT);
            ds_cfg_weight_word_index <= word_index[15:0];
            ds_cfg_weight_word_data <= data;
            // Tail bytes are explicitly disabled.  This is important for a
            // packed DW channel's 9-tap boundary and for PW Cin/Cout tails:
            // no padded byte may alias the next software allocation.
            if (remaining_bytes >= 4)
                ds_cfg_weight_word_be <= 4'b1111;
            else if (remaining_bytes == 3)
                ds_cfg_weight_word_be <= 4'b0111;
            else if (remaining_bytes == 2)
                ds_cfg_weight_word_be <= 4'b0011;
            else if (remaining_bytes == 1)
                ds_cfg_weight_word_be <= 4'b0001;
            else
                ds_cfg_weight_word_be <= 4'b0000;
        end
    endtask

    task advance_compact_load_position;
        input [3:0] phase;
        begin
            if ((phase == PH_INPUT) &&
                (op_is_stem_reg || op_is_ds_reg)) begin
                if ((compact_load_channel + 16'd1) >= in_c_reg) begin
                    compact_load_channel <= 16'd0;
                    if ((compact_load_x + 16'd1) >= in_w_reg) begin
                        compact_load_x <= 16'd0;
                        compact_load_y <= compact_load_y + 16'd1;
                    end else begin
                        compact_load_x <= compact_load_x + 16'd1;
                    end
                end else begin
                    compact_load_channel <= compact_load_channel + 16'd1;
                end
            end else if ((phase == PH_PW_WEIGHT) && op_is_ds_reg) begin
                if ((pw_load_cin + 16'd1) >= in_c_reg) begin
                    pw_load_cin <= 16'd0;
                    pw_load_cout <= pw_load_cout + 16'd1;
                end else begin
                    pw_load_cin <= pw_load_cin + 16'd1;
                end
            end
        end
    endtask

    task store_response_word;
        input [3:0] phase;
        input [31:0] idx;
        input [31:0] data;
        begin
            case (op_type_reg)
                OP_CONV3X3_STEM: begin
                    case (phase)
                        PH_INPUT: begin
                            // Unified Stem owns the full-image source read;
                            // its input phase is intentionally absent from
                            // the configuration stream.  Legacy Stem still
                            // receives the compact input tile here.
                            if (!unified_stem_mode)
                                store_stem_input(data[7:0]);
                        end
                        PH_DW_WEIGHT,
                        PH_DW_BIAS,
                        PH_DW_MUL,
                        PH_DW_SHIFT: begin
                            aux_cfg_wr_en <= 1'b1;
                            aux_cfg_target <= unified_stem_mode ?
                                              (phase - PH_DW_WEIGHT) : phase;
                            aux_cfg_index <= idx[15:0];
                            aux_cfg_data <= data;
                        end
                        default: begin end
                    endcase
                end
                OP_DS_BLOCK: begin
                    case (phase)
                        PH_INPUT:     store_ds_input(data[7:0]);
                        PH_DW_WEIGHT: begin
                            if (packed_weight_mode) begin
                                store_ds_weight_word(phase, idx, data);
                            end else begin
                                ds_cfg_wr_en <= 1'b1;
                                ds_cfg_target <= DS_CFG_DW_WEIGHT;
                                ds_cfg_index <= idx[15:0];
                                ds_cfg_data <= data;
                            end
                        end
                        PH_DW_BIAS: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_DW_BIAS;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        PH_DW_MUL: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_DW_MUL;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        PH_DW_SHIFT: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_DW_SHIFT;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        PH_PW_WEIGHT: begin
                            if (packed_weight_mode)
                                store_ds_weight_word(phase, idx, data);
                            else
                                store_pw_weight(data[7:0]);
                        end
                        PH_PW_BIAS: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_PW_BIAS;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        PH_PW_MUL: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_PW_MUL;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        PH_PW_SHIFT: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_PW_SHIFT;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        default: begin end
                    endcase
                end
                OP_GAP: begin
                    if (phase == PH_INPUT) begin
                        aux_cfg_wr_en <= 1'b1;
                        aux_cfg_target <= PH_INPUT;
                        aux_cfg_index <= idx[15:0];
                        aux_cfg_data <= data;
                    end
                end
                OP_FC: begin
                    case (phase)
                        PH_INPUT,
                        PH_PW_WEIGHT,
                        PH_PW_BIAS,
                        PH_PW_MUL,
                        PH_PW_SHIFT: begin
                            aux_cfg_wr_en <= 1'b1;
                            aux_cfg_target <= phase;
                            aux_cfg_index <= idx[15:0];
                            aux_cfg_data <= data;
                        end
                        default: begin end
                    endcase
                end
                default: begin end
            endcase
        end
    endtask
    /* verilator lint_on BLKSEQ */

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            mem_req_valid <= 1'b0;
            mem_req_write <= 1'b0;
            mem_req_addr <= 32'd0;
            mem_req_wdata <= 32'd0;
            sram_input_rd_en <= 1'b0;
            sram_input_rd_addr <= {SRAM_ADDR_WIDTH{1'b0}};
            sram_input_rd_word_en <= 1'b0;
            sram_input_rd_word_addr <= {SRAM_ADDR_WIDTH{1'b0}};
            sram_output_wr_en <= 1'b0;
            sram_output_wr_addr <= {SRAM_ADDR_WIDTH{1'b0}};
            sram_output_wr_data <= 8'sd0;
            sram_output_wr4_en <= 1'b0;
            sram_output_wr4_addr <= {SRAM_ADDR_WIDTH{1'b0}};
            sram_output_wr4_data <= 32'd0;
            sram_output_wr4_be <= 4'd0;
            stem_start <= 1'b0;
            ds_start <= 1'b0;
            ds_cfg_wr_en <= 1'b0;
            ds_cfg_target <= 4'd0;
            ds_cfg_index <= 16'd0;
            ds_cfg_data <= 32'd0;
            aux_cfg_wr_en <= 1'b0;
            aux_cfg_target <= 4'd0;
            aux_cfg_index <= 16'd0;
            aux_cfg_data <= 32'd0;
            aux_cfg_vec4_wr_en <= 1'b0;
            aux_cfg_vec4_index <= 16'd0;
            aux_cfg_vec4_data <= 32'd0;
            ds_cfg_vec4_wr_en <= 1'b0;
            ds_cfg_vec4_index <= 16'd0;
            ds_cfg_vec4_data <= 32'd0;
            ds_cfg_weight_word_wr_en <= 1'b0;
            ds_cfg_weight_word_target <= 1'b0;
            ds_cfg_weight_word_index <= 16'd0;
            ds_cfg_weight_word_data <= 32'd0;
            ds_cfg_weight_word_be <= 4'd0;
            gap_start <= 1'b0;
            fc_start <= 1'b0;
            tile_sched_start <= 1'b0;
            tile_sched_next <= 1'b0;
            tile_h_start_reg <= 8'd0;
            tile_w_start_reg <= 8'd0;
            tile_h_size_reg <= 8'd0;
            tile_w_size_reg <= 8'd0;
            tiled_store_out_w_reg <= 8'd0;
            tile_input_h_reg <= 8'd0;
            tile_input_w_reg <= 8'd0;
            tile_is_last_reg <= 1'b0;
            phase_idx <= 4'd0;
            phase_count <= 32'd0;
            phase_count_seed_reg <= 32'd0;
            phase_count_factor_reg <= 32'd0;
            phase_base_addr <= 32'd0;
            sram_input_count_reg <= 32'd0;
            sram_output_count_reg <= 32'd0;
            output_count_reg <= 32'd0;
            sram_input_count_seed_reg <= 32'd0;
            sram_input_count_factor_reg <= 32'd0;
            sram_output_count_seed_reg <= 32'd0;
            sram_output_count_factor_reg <= 32'd0;
            sram_input_count_seed16_reg <= 16'd0;
            sram_input_count_factor16_reg <= 16'd0;
            sram_input_span_valid_reg <= 1'b0;
            sram_output_span_valid_reg <= 1'b0;
            conv_out_pixels_reg <= 14'd0;
            tiled_out_pixels_reg <= 16'd0;
            load_idx <= 32'd0;
            compact_load_y <= 16'd0;
            compact_load_x <= 16'd0;
            compact_load_channel <= 16'd0;
            pw_load_cout <= 16'd0;
            pw_load_cin <= 16'd0;
            store_idx <= 32'd0;
            store_count <= 32'd0;
            tiled_store_area_reg <= 32'd0;
            store_write_word_eligible_reg <= 1'b0;
            store_issue_word_eligible_reg <= 1'b0;
            store_issue_addr_reg <= {OUT_BUFFER_ADDR_WIDTH{1'b0}};
            store_outbuf_addr <= {OUT_BUFFER_ADDR_WIDTH{1'b0}};
            store_channel_pos <= 16'd0;
            tiled_load_idx <= 32'd0;
            tiled_load_count <= 32'd0;
            tiled_input_area_reg <= 16'd0;
            tiled_load_y <= 8'd0;
            tiled_load_x <= 8'd0;
            tiled_load_channel <= 16'd0;
            tiled_channel_last_reg <= 16'd0;
            tiled_channel_word_limit_reg <= 16'd0;
            tiled_channel_ge4_reg <= 1'b0;
            tiled_input_index_reg <= 32'sd0;
            tiled_input_row_base_reg <= 32'sd0;
            tiled_input_tile_row_base_reg <= 32'sd0;
            tiled_input_next_row_base_reg <= 32'sd0;
            tiled_input_col_base_reg <= 32'sd0;
            tiled_input_tile_col_base_reg <= 32'sd0;
            tiled_input_tile_row_step_reg <= 32'sd0;
            tiled_input_tile_col_step_reg <= 32'sd0;
            tiled_input_halo_step_reg <= 32'sd0;
            tiled_load_current_padding_reg <= 1'b0;
            tiled_load_next_padding_reg <= 1'b0;
            tiled_load_next_y_reg <= 8'd0;
            tiled_load_next_x_reg <= 8'd0;
            tiled_load_next_channel_reg <= 16'd0;
            tiled_input_next_index_cursor_reg <= 32'sd0;
            tiled_input_next_row_base_cursor_reg <= 32'sd0;
            tiled_input_next_row_next_base_cursor_reg <= 32'sd0;
            tiled_input_next_col_base_cursor_reg <= 32'sd0;
            tiled_load_next_word_channel_ok_reg <= 1'b0;
            tiled_load_next_word_source_aligned_reg <= 1'b0;
            tiled_load_next_word_lane_mask_reg <= 4'd0;
            tiled_load_next_pixel_end_reg <= 1'b0;
            tiled_load_next_word_pixel_end_reg <= 1'b0;
            tiled_load_prime_reg <= 1'b0;
            tiled_load_word_channel_ok_reg <= 1'b0;
            tiled_load_word_source_aligned_reg <= 1'b0;
            tiled_load_word_lane_mask_reg <= 4'd0;
            tiled_load_current_pixel_end_reg <= 1'b0;
            tiled_load_current_word_pixel_end_reg <= 1'b0;
            tiled_input_row_stride_reg <= 32'sd0;
            tiled_input_halo_row_offset_reg <= 32'sd0;
            tiled_input_halo_col_offset_reg <= 32'sd0;
            tiled_store_y <= 8'd0;
            tiled_store_x <= 8'd0;
            tiled_store_addr_current <= 32'd0;
            tiled_store_addr_row_base <= 32'd0;
            tiled_store_addr_col_base <= 32'd0;
            tiled_store_base_index_reg <= 32'd0;
            tiled_store_linear_index_reg <= 32'd0;
            tiled_store_addr_col_jump <= 32'd0;
            tiled_store_addr_row_jump <= 32'd0;
            tiled_store_sram_addr_current <= 32'd0;
            tiled_store_sram_addr_row_base <= 32'd0;
            tiled_store_sram_addr_col_base <= 32'd0;
            tiled_store_sram_addr_col_jump <= 32'd0;
            tiled_store_sram_addr_row_jump <= 32'd0;
            op_type_reg <= 32'd0;
            op_is_stem_reg <= 1'b0;
            op_is_ds_reg <= 1'b0;
            op_is_gap_reg <= 1'b0;
            op_is_fc_reg <= 1'b0;
            op_is_valid_reg <= 1'b0;
            ds1_retained_mode_reg <= 1'b0;
            op_is_tiled_reg <= 1'b0;
            op_last_phase_reg <= PH_INPUT;
            input_addr_reg <= 32'd0;
            output_addr_reg <= 32'd0;
            dw_weight_addr_reg <= 32'd0;
            dw_bias_addr_reg <= 32'd0;
            dw_mul_addr_reg <= 32'd0;
            dw_shift_addr_reg <= 32'd0;
            pw_weight_addr_reg <= 32'd0;
            pw_bias_addr_reg <= 32'd0;
            pw_mul_addr_reg <= 32'd0;
            pw_shift_addr_reg <= 32'd0;
            in_h_reg <= 16'd0;
            in_w_reg <= 16'd0;
            in_c_reg <= 16'd0;
            out_c_reg <= 16'd0;
            stride_reg <= 8'd1;
            pad_reg <= 8'd0;
            input_zero_point_reg <= 32'sd0;
            dw_output_zero_point_reg <= 32'sd0;
            pw_output_zero_point_reg <= 32'sd0;
            dw_activation_min_reg <= -32'sd128;
            dw_activation_max_reg <= 32'sd127;
            pw_activation_min_reg <= -32'sd128;
            pw_activation_max_reg <= 32'sd127;
            flags_reg <= 32'd0;
            packed_word_valid <= 1'b0;
            packed_word_addr <= 32'd0;
            packed_word_data <= 32'd0;
            packed_weight_data_reg <= 32'd0;
            packed_weight_byte_reg <= 2'd0;
`ifndef SYNTHESIS
            sim_tiled_load_assert_errors <= 0;
            sim_tiled_load_expect_next_padding_valid <= 1'b0;
            sim_tiled_load_expect_next_padding <= 1'b0;
            sim_tiled_load_expect_current_padding_valid <= 1'b0;
            sim_tiled_load_expect_current_padding <= 1'b0;
            sim_tiled_load_hold_valid <= 1'b0;
            sim_tiled_load_hold_current_padding <= 1'b0;
            sim_tiled_load_hold_next_padding <= 1'b0;
            sim_tiled_load_hold_word_channel_ok <= 1'b0;
            sim_tiled_load_hold_word_source_aligned <= 1'b0;
            sim_tiled_load_hold_word_lane_mask <= 4'd0;
            sim_tiled_load_hold_next_word_channel_ok <= 1'b0;
            sim_tiled_load_hold_next_word_source_aligned <= 1'b0;
            sim_tiled_load_hold_next_word_lane_mask <= 4'd0;
            sim_tiled_load_hold_current_pixel_end <= 1'b0;
            sim_tiled_load_hold_current_word_pixel_end <= 1'b0;
            sim_tiled_load_hold_next_pixel_end <= 1'b0;
            sim_tiled_load_hold_next_word_pixel_end <= 1'b0;
            sim_tiled_load_hold_y <= 8'd0;
            sim_tiled_load_hold_x <= 8'd0;
            sim_tiled_load_hold_channel <= 16'd0;
            sim_tiled_load_hold_next_y <= 8'd0;
            sim_tiled_load_hold_next_x <= 8'd0;
            sim_tiled_load_hold_next_channel <= 16'd0;
            sim_tiled_load_hold_index <= 32'sd0;
            sim_tiled_load_hold_next_index <= 32'sd0;
            sim_tiled_load_hold_row_base <= 32'sd0;
            sim_tiled_load_hold_next_row_base <= 32'sd0;
            sim_tiled_load_hold_next_row_next_base <= 32'sd0;
            sim_tiled_load_hold_col_base <= 32'sd0;
            sim_tiled_load_hold_next_col_base <= 32'sd0;
`endif
        end else begin
            done <= 1'b0;
            stem_start <= 1'b0;
            ds_start <= 1'b0;
            ds_cfg_wr_en <= 1'b0;
            aux_cfg_wr_en <= 1'b0;
            aux_cfg_vec4_wr_en <= 1'b0;
            ds_cfg_vec4_wr_en <= 1'b0;
            ds_cfg_weight_word_wr_en <= 1'b0;
            gap_start <= 1'b0;
            fc_start <= 1'b0;
            sram_input_rd_en <= 1'b0;
            sram_input_rd_word_en <= 1'b0;
            sram_output_wr_en <= 1'b0;
            sram_output_wr4_en <= 1'b0;
            tile_sched_start <= 1'b0;
            tile_sched_next <= 1'b0;

`ifndef SYNTHESIS
            // The task records expected post-commit values one edge before
            // they become observable.  Check them here, before the next FSM
            // action can modify the bundle again.
            if (sim_tiled_load_expect_next_padding_valid) begin
                if (tiled_load_next_padding_reg !==
                    sim_tiled_load_expect_next_padding) begin
                    sim_tiled_load_assert_errors <=
                        sim_tiled_load_assert_errors + 1;
                    $display("TILED_LOAD_ASSERT next_padding_changed_within_channel state=%0d expected=%b actual=%b",
                             state, sim_tiled_load_expect_next_padding,
                             tiled_load_next_padding_reg);
                    $fatal(1);
                end
                sim_tiled_load_expect_next_padding_valid <= 1'b0;
            end
            if (sim_tiled_load_expect_current_padding_valid) begin
                if (tiled_load_current_padding_reg !==
                    sim_tiled_load_expect_current_padding) begin
                    sim_tiled_load_assert_errors <=
                        sim_tiled_load_assert_errors + 1;
                    $display("TILED_LOAD_ASSERT current_padding_not_successor_on_pixel_wrap state=%0d expected=%b actual=%b",
                             state, sim_tiled_load_expect_current_padding,
                             tiled_load_current_padding_reg);
                    $fatal(1);
                end
                sim_tiled_load_expect_current_padding_valid <= 1'b0;
            end

            // External request acceptance and both response waits are
            // intentionally non-mutating.  Snapshot the whole registered
            // cursor/metadata bundle and compare it on each stalled edge.
            if (sim_tiled_load_hold_valid) begin
                if ((tiled_load_current_padding_reg !==
                     sim_tiled_load_hold_current_padding) ||
                    (tiled_load_next_padding_reg !==
                     sim_tiled_load_hold_next_padding) ||
                    (tiled_load_word_channel_ok_reg !==
                     sim_tiled_load_hold_word_channel_ok) ||
                    (tiled_load_word_source_aligned_reg !==
                     sim_tiled_load_hold_word_source_aligned) ||
                    (tiled_load_word_lane_mask_reg !==
                     sim_tiled_load_hold_word_lane_mask) ||
                    (tiled_load_next_word_channel_ok_reg !==
                     sim_tiled_load_hold_next_word_channel_ok) ||
                    (tiled_load_next_word_source_aligned_reg !==
                     sim_tiled_load_hold_next_word_source_aligned) ||
                    (tiled_load_next_word_lane_mask_reg !==
                     sim_tiled_load_hold_next_word_lane_mask) ||
                    (tiled_load_current_pixel_end_reg !==
                     sim_tiled_load_hold_current_pixel_end) ||
                    (tiled_load_current_word_pixel_end_reg !==
                     sim_tiled_load_hold_current_word_pixel_end) ||
                    (tiled_load_next_pixel_end_reg !==
                     sim_tiled_load_hold_next_pixel_end) ||
                    (tiled_load_next_word_pixel_end_reg !==
                     sim_tiled_load_hold_next_word_pixel_end) ||
                    (tiled_load_y !== sim_tiled_load_hold_y) ||
                    (tiled_load_x !== sim_tiled_load_hold_x) ||
                    (tiled_load_channel !== sim_tiled_load_hold_channel) ||
                    (tiled_load_next_y_reg !== sim_tiled_load_hold_next_y) ||
                    (tiled_load_next_x_reg !== sim_tiled_load_hold_next_x) ||
                    (tiled_load_next_channel_reg !==
                     sim_tiled_load_hold_next_channel) ||
                    (tiled_input_index_reg !== sim_tiled_load_hold_index) ||
                    (tiled_input_next_index_cursor_reg !==
                     sim_tiled_load_hold_next_index) ||
                    (tiled_input_row_base_reg !==
                     sim_tiled_load_hold_row_base) ||
                    (tiled_input_next_row_base_reg !==
                     sim_tiled_load_hold_next_row_base) ||
                    (tiled_input_next_row_next_base_cursor_reg !==
                     sim_tiled_load_hold_next_row_next_base) ||
                    (tiled_input_col_base_reg !==
                     sim_tiled_load_hold_col_base) ||
                    (tiled_input_next_col_base_cursor_reg !==
                     sim_tiled_load_hold_next_col_base)) begin
                    sim_tiled_load_assert_errors <=
                        sim_tiled_load_assert_errors + 1;
                    $display("TILED_LOAD_ASSERT lookahead_changed_while_stalled state=%0d",
                             state);
                    $fatal(1);
                end
                sim_tiled_load_hold_valid <= 1'b0;
            end

            if ((state == ST_TILED_LOAD_MEM_REQ && mem_req_valid &&
                 !mem_req_ready) ||
                (state == ST_TILED_LOAD_RESP &&
                 ((flags_reg[FLAG_INPUT_FROM_SRAM] &&
                   !sram_input_rd_valid) ||
                  (!flags_reg[FLAG_INPUT_FROM_SRAM] &&
                   !mem_resp_valid))) ||
                (state == ST_TILED_LOAD_WORD_RESP &&
                 !sram_input_rd_word_valid)) begin
                sim_tiled_load_hold_valid <= 1'b1;
                sim_tiled_load_hold_current_padding <=
                    tiled_load_current_padding_reg;
                sim_tiled_load_hold_next_padding <=
                    tiled_load_next_padding_reg;
                sim_tiled_load_hold_word_channel_ok <=
                    tiled_load_word_channel_ok_reg;
                sim_tiled_load_hold_word_source_aligned <=
                    tiled_load_word_source_aligned_reg;
                sim_tiled_load_hold_word_lane_mask <=
                    tiled_load_word_lane_mask_reg;
                sim_tiled_load_hold_next_word_channel_ok <=
                    tiled_load_next_word_channel_ok_reg;
                sim_tiled_load_hold_next_word_source_aligned <=
                    tiled_load_next_word_source_aligned_reg;
                sim_tiled_load_hold_next_word_lane_mask <=
                    tiled_load_next_word_lane_mask_reg;
                sim_tiled_load_hold_current_pixel_end <=
                    tiled_load_current_pixel_end_reg;
                sim_tiled_load_hold_current_word_pixel_end <=
                    tiled_load_current_word_pixel_end_reg;
                sim_tiled_load_hold_next_pixel_end <=
                    tiled_load_next_pixel_end_reg;
                sim_tiled_load_hold_next_word_pixel_end <=
                    tiled_load_next_word_pixel_end_reg;
                sim_tiled_load_hold_y <= tiled_load_y;
                sim_tiled_load_hold_x <= tiled_load_x;
                sim_tiled_load_hold_channel <= tiled_load_channel;
                sim_tiled_load_hold_next_y <= tiled_load_next_y_reg;
                sim_tiled_load_hold_next_x <= tiled_load_next_x_reg;
                sim_tiled_load_hold_next_channel <=
                    tiled_load_next_channel_reg;
                sim_tiled_load_hold_index <= tiled_input_index_reg;
                sim_tiled_load_hold_next_index <=
                    tiled_input_next_index_cursor_reg;
                sim_tiled_load_hold_row_base <= tiled_input_row_base_reg;
                sim_tiled_load_hold_next_row_base <=
                    tiled_input_next_row_base_reg;
                sim_tiled_load_hold_next_row_next_base <=
                    tiled_input_next_row_next_base_cursor_reg;
                sim_tiled_load_hold_col_base <= tiled_input_col_base_reg;
                sim_tiled_load_hold_next_col_base <=
                    tiled_input_next_col_base_cursor_reg;
            end
`endif

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        error <= 1'b0;
                        op_type_reg <= desc_word0;
                        op_is_stem_reg <= (desc_word0 == OP_CONV3X3_STEM);
                        op_is_ds_reg <= (desc_word0 == OP_DS_BLOCK);
                        op_is_gap_reg <= (desc_word0 == OP_GAP);
                        op_is_fc_reg <= (desc_word0 == OP_FC);
                        op_is_valid_reg <= (desc_word0 == OP_CONV3X3_STEM) ||
                                           (desc_word0 == OP_DS_BLOCK) ||
                                           (desc_word0 == OP_GAP) ||
                                           (desc_word0 == OP_FC);
                        ds1_retained_mode_reg <= ds1_retained_desc_match;
                        op_is_tiled_reg <=
                            ((desc_word0 == OP_CONV3X3_STEM) ||
                             (desc_word0 == OP_DS_BLOCK)) &&
                            desc_word18[FLAG_TILED_DS_BLOCK] &&
                            !(USE_UNIFIED64_STEM &&
                              (desc_word0 == OP_CONV3X3_STEM));
                        case (desc_word0)
                            OP_CONV3X3_STEM: op_last_phase_reg <= PH_DW_SHIFT;
                            OP_DS_BLOCK:     op_last_phase_reg <= PH_PW_SHIFT;
                            OP_GAP:          op_last_phase_reg <= PH_INPUT;
                            OP_FC:           op_last_phase_reg <= PH_PW_SHIFT;
                            default:         op_last_phase_reg <= PH_INPUT;
                        endcase
                        input_addr_reg <= desc_word1;
                        output_addr_reg <= desc_word2;
                        dw_weight_addr_reg <= desc_word3;
                        dw_bias_addr_reg <= desc_word4;
                        dw_mul_addr_reg <= desc_word5;
                        dw_shift_addr_reg <= desc_word6;
                        pw_weight_addr_reg <= desc_word7;
                        pw_bias_addr_reg <= desc_word8;
                        pw_mul_addr_reg <= desc_word9;
                        pw_shift_addr_reg <= desc_word10;
                        in_h_reg <= desc_word11[15:0];
                        in_w_reg <= desc_word11[31:16];
                        in_c_reg <= desc_word12[15:0];
                        out_c_reg <= desc_word12[31:16];
                        stride_reg <= desc_word13[7:0];
                        pad_reg <= desc_word13[15:8];
                        input_zero_point_reg <= desc_word14;
                        dw_output_zero_point_reg <= desc_word15;
                        pw_output_zero_point_reg <= desc_word16;
                        dw_activation_min_reg <= {{24{desc_word17[7]}}, desc_word17[7:0]};
                        dw_activation_max_reg <= {{24{desc_word17[15]}}, desc_word17[15:8]};
                        pw_activation_min_reg <= {{24{desc_word17[23]}}, desc_word17[23:16]};
                        pw_activation_max_reg <= {{24{desc_word17[31]}}, desc_word17[31:24]};
                        flags_reg <= desc_word18;
                        state <= ST_CALC_SPATIAL;
                    end
                end

                ST_CALC_SPATIAL: begin
                    conv_out_pixels_reg <= conv_out_h * conv_out_w;
                    tiled_out_pixels_reg <= tiled_out_h * tiled_out_w;
                    tiled_input_row_stride_reg <=
                        $signed({16'd0, in_w_reg}) *
                        $signed({16'd0, in_c_reg});
                    state <= ST_CALC_TILED_STEPS;
                end

                ST_CALC_TILED_STEPS: begin
                    // The tile scheduler advances by eight output positions
                    // in each raster direction.  Stride is valid only as 1
                    // or 2 for tiled DS (and 1 for tiled Stem), so shifts
                    // express the increments without introducing another
                    // multiplier into the tile setup cone.
                    tiled_channel_last_reg <=
                        (in_c_reg == 16'd0) ? 16'd0 : (in_c_reg - 16'd1);
                    tiled_channel_word_limit_reg <=
                        (in_c_reg >= 16'd4) ? (in_c_reg - 16'd4) : 16'd0;
                    tiled_channel_ge4_reg <= (in_c_reg >= 16'd4);
                    tiled_input_halo_step_reg <=
                        $signed({24'd0, effective_stride}) <<< 3;
                    tiled_input_tile_row_step_reg <=
                        tiled_input_row_stride_reg <<<
                        ((effective_stride == 8'd2) ? 4 : 3);
                    tiled_input_tile_col_step_reg <=
                        $signed({16'd0, in_c_reg}) <<<
                        ((effective_stride == 8'd2) ? 4 : 3);
                    state <= ST_VALIDATE;
                end

                ST_VALIDATE: begin
                    if (flags_reg[FLAG_SKIP_EXEC]) begin
                        state <= ST_DONE;
                    end else if (flags_reg[FLAG_PACKED_INPUT] &&
                                 !packed_input_config_supported) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else if (flags_reg[FLAG_PACKED_WEIGHTS] &&
                                 !packed_weight_config_supported) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else if (flags_reg[FLAG_PACKED_WEIGHTS] &&
                                 ((dw_weight_addr_reg[1:0] != 2'b00) ||
                                  (pw_weight_addr_reg[1:0] != 2'b00))) begin
                        // Packed descriptors name a word-addressed region;
                        // reject an unaligned base instead of silently
                        // changing the software layout at the bus boundary.
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else if (!valid_config()) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else begin
                        // Keep the output-count product out of the span
                        // comparison/phase-enable cone.  These values are
                        // descriptor-local and are consumed only below.
                        sram_input_count_reg <=
                            32'd0;
                        sram_input_count_seed_reg <=
                            phase_count_seed_for(op_type_reg, PH_INPUT);
                        sram_input_count_factor_reg <=
                            phase_count_factor_for(op_type_reg, PH_INPUT);
                        sram_input_count_seed16_reg <=
                            phase_count_seed_for(op_type_reg, PH_INPUT);
                        sram_input_count_factor16_reg <=
                            phase_count_factor_for(op_type_reg, PH_INPUT);
                        /* Stage the output-span operands here, then commit
                         * their product in ST_VALIDATE_OUTPUT_COUNT.  This
                         * keeps in_w/in_h -> area -> channel arithmetic out
                         * of the span-validity/control enable cone and gives
                         * both SRAM bounds checking and writeback the same
                         * committed 32-bit count. */
                        if (op_is_tiled_reg) begin
                            sram_output_count_seed_reg <=
                                {16'd0, tiled_out_pixels_reg};
                            sram_output_count_factor_reg <=
                                {16'd0, out_c_reg};
                        end else if (op_is_stem_reg) begin
                            if (unified_stem_mode) begin
                                sram_output_count_seed_reg <= 32'd1024;
                                sram_output_count_factor_reg <= 32'd16;
                            end else begin
                                sram_output_count_seed_reg <=
                                    {18'd0, conv_out_pixels_reg};
                                sram_output_count_factor_reg <= 32'd16;
                            end
                        end else if (op_is_ds_reg) begin
                            sram_output_count_seed_reg <=
                                {18'd0, conv_out_pixels_reg};
                            sram_output_count_factor_reg <=
                                {16'd0, out_c_reg};
                        end else if (op_is_gap_reg) begin
                            sram_output_count_seed_reg <= 32'd256;
                            sram_output_count_factor_reg <= 32'd1;
                        end else if (op_is_fc_reg) begin
                            sram_output_count_seed_reg <= 32'd10;
                            sram_output_count_factor_reg <= 32'd1;
                        end else begin
                            sram_output_count_seed_reg <= 32'd0;
                            sram_output_count_factor_reg <= 32'd0;
                        end
                        state <= ST_VALIDATE_SPAN_COUNT;
                    end
                end

                ST_VALIDATE_SPAN_COUNT: begin
                    // Complete the input span count from the registered
                    // HxW seed.  This intentionally leaves no three-operand
                    // product on the path into the control compare below.
                    sram_input_count_reg <=
                        sram_input_count_seed16_reg *
                        sram_input_count_factor16_reg;
                    state <= ST_VALIDATE_OUTPUT_COUNT;
                end

                ST_VALIDATE_OUTPUT_COUNT: begin
                    /* One registered 32-bit product is shared by the SRAM
                     * span checker and the normal output-store loop. */
                    sram_output_count_reg <=
                        sram_output_count_seed_reg *
                        sram_output_count_factor_reg;
                    output_count_reg <=
                        sram_output_count_seed_reg *
                        sram_output_count_factor_reg;
                    state <= ST_VALIDATE_SPAN_VALID;
                end

                ST_VALIDATE_SPAN_VALID: begin
                    sram_input_span_valid_reg <= sram_span_valid(
                        input_addr_reg, sram_input_count_reg
                    );
                    sram_output_span_valid_reg <= sram_span_valid(
                        output_addr_reg, sram_output_count_reg
                    );
                    state <= ST_VALIDATE_SPAN_RESULT;
                end

                ST_VALIDATE_SPAN_RESULT: begin
                    if ((flags_reg[FLAG_INPUT_FROM_SRAM] &&
                         !sram_input_span_valid_reg) ||
                        (flags_reg[FLAG_OUTPUT_TO_SRAM] &&
                         !sram_output_span_valid_reg)) begin
                        // SRAM ports intentionally expose only
                        // SRAM_ADDR_WIDTH address bits.  Reject a descriptor
                        // whose logical tensor would otherwise alias through
                        // silent high-bit truncation or end-of-bank wraparound.
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else begin
                        phase_idx <= ((tiled_spatial_mode || unified_stem_mode) ?
                                      PH_DW_WEIGHT : PH_INPUT);
                        state <= ST_LOAD_SETUP;
                    end
                end

                ST_LOAD_SETUP: begin
                    // A request belongs to exactly one load phase.  Clear both
                    // the bus request and the packed-word cache at ownership
                    // transfer so a response from the prior phase cannot be
                    // mistaken for the first request of this phase.
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    packed_word_valid <= 1'b0;
                    // Register the seed and factor separately.  In the DS
                    // input case the seed is HxW and the factor is C; the
                    // only multiply feeding phase_count is therefore the
                    // single registered second-stage product below.
                    phase_count_seed_reg <=
                        phase_count_seed_for(op_type_reg, phase_idx);
                    phase_count_factor_reg <=
                        phase_count_factor_for(op_type_reg, phase_idx);
                    phase_base_addr <= phase_addr_for(op_type_reg, phase_idx);
                    load_idx <= 32'd0;
                    if (phase_idx == PH_INPUT) begin
                        compact_load_y <= 16'd0;
                        compact_load_x <= 16'd0;
                        compact_load_channel <= 16'd0;
                    end
                    if (phase_idx == PH_PW_WEIGHT) begin
                        pw_load_cout <= 16'd0;
                        pw_load_cin <= 16'd0;
                    end
                    // Keep the DS packed target aligned with the phase while
                    // the canonical unpack queue reports readiness.
                    ds_cfg_weight_word_target <=
                        (phase_idx == PH_PW_WEIGHT);
                    state <= ST_LOAD_COUNT_CALC;
                end

                ST_LOAD_COUNT_CALC: begin
                    // The registered seed/factor product is a single-stage
                    // arithmetic cone and is isolated from the phase FSM
                    // enable by ST_LOAD_COUNT_DECIDE.
                    phase_count <= phase_count_seed_reg *
                                   phase_count_factor_reg;
                    state <= ST_LOAD_COUNT_DECIDE;
                end

                ST_LOAD_COUNT_DECIDE: begin
                    if (phase_count == 32'd0) begin
                        if (phase_idx == op_last_phase_reg) begin
                            state <= ds1_retained_mode_reg ? ST_DS1_RETAINED_START :
                                     (tiled_spatial_mode ? ST_TILED_INIT : ST_ENGINE_START);
                        end else begin
                            phase_idx <= phase_idx + 4'd1;
                            state <= ST_LOAD_SETUP;
                        end
                    end else begin
                        state <= ST_READ_REQ;
                    end
                end

                ST_READ_REQ: begin
                    if ((phase_idx == PH_INPUT) && flags_reg[FLAG_INPUT_FROM_SRAM]) begin
                        mem_req_valid <= 1'b0;
                        mem_req_write <= 1'b0;
                        sram_input_rd_en <= 1'b1;
                        sram_input_rd_addr <= sram_addr_for_index(phase_base_addr, load_idx);
                        state <= ST_READ_RESP;
                    end else if (packed_input_mode) begin
                        // Packed input requests are aligned word reads.  A
                        // cached response supplies the other three byte lanes
                        // without issuing another external transaction.
                        if (packed_word_valid &&
                            (packed_word_addr ==
                             ((phase_base_addr + load_idx) & 32'hffff_fffc))) begin
                            store_response_word(
                                phase_idx, load_idx,
                                (packed_word_data >>
                                 ((load_idx[1:0]) * 8)));
                            if ((load_idx + 32'd1) >= phase_count) begin
                                state <= (phase_idx == op_last_phase_reg) ?
                                         ST_ENGINE_START : ST_LOAD_SETUP;
                                if (phase_idx != op_last_phase_reg)
                                    phase_idx <= phase_idx + 4'd1;
                            end else begin
                                load_idx <= load_idx + 32'd1;
                                advance_compact_load_position(phase_idx);
                                state <= ST_READ_REQ;
                            end
                        end else begin
                            mem_req_valid <= 1'b1;
                            mem_req_write <= 1'b0;
                            mem_req_addr <= (phase_base_addr + load_idx) &
                                            32'hffff_fffc;
                            mem_req_wdata <= 32'd0;
                            if (mem_req_valid && mem_req_ready) begin
                                mem_req_valid <= 1'b0;
                                state <= ST_READ_RESP;
                            end
                        end
                    end else if (packed_weight_mode) begin
                        // Each packed weight request consumes one complete
                        // external word.  Unlike packed input, load_idx is
                        // already a word index, so no byte-lane cache or
                        // scalar replay is involved.
                        mem_req_valid <= 1'b1;
                        mem_req_write <= 1'b0;
                        mem_req_addr <= phase_base_addr + (load_idx << 2);
                        mem_req_wdata <= 32'd0;
                        if (mem_req_valid && mem_req_ready) begin
                            mem_req_valid <= 1'b0;
                            state <= ST_READ_RESP;
                        end
                    end else begin
                        mem_req_valid <= 1'b1;
                        mem_req_write <= 1'b0;
                        mem_req_addr <= phase_base_addr + (load_idx << 2);
                        mem_req_wdata <= 32'd0;
                        if (mem_req_valid && mem_req_ready) begin
                            mem_req_valid <= 1'b0;
                            state <= ST_READ_RESP;
                        end
                    end
                end

                ST_READ_RESP: begin
                    if ((phase_idx == PH_INPUT) && flags_reg[FLAG_INPUT_FROM_SRAM]) begin
                        if (sram_input_rd_valid) begin
                            store_response_word(
                                phase_idx,
                                load_idx,
                                {{24{sram_input_rd_data[7]}}, sram_input_rd_data}
                            );
                            if ((load_idx + 32'd1) >= phase_count) begin
                                if (phase_idx == op_last_phase_reg) begin
                                    state <= ds1_retained_mode_reg ? ST_DS1_RETAINED_START :
                                             (tiled_spatial_mode ? ST_TILED_INIT : ST_ENGINE_START);
                                end else begin
                                    phase_idx <= phase_idx + 4'd1;
                                    state <= ST_LOAD_SETUP;
                                end
                            end else begin
                                load_idx <= load_idx + 32'd1;
                                advance_compact_load_position(phase_idx);
                                // The feature SRAM has a fixed one-cycle
                                // synchronous read contract.  Launch the next
                                // read directly while consuming this response;
                                // no additional request-setup state is needed.
                                sram_input_rd_en <= 1'b1;
                                sram_input_rd_addr <= sram_addr_for_index(
                                    phase_base_addr,
                                    load_idx + 32'd1
                                );
                                state <= ST_READ_RESP;
                            end
                        end
                    end else if (mem_resp_valid) begin
                        // Consume the outstanding request before changing
                        // phase; ST_LOAD_SETUP owns creation of the next one.
                        mem_req_valid <= 1'b0;
                        if (packed_weight_mode) begin
                            // The DS packed loader has a one-entry unpack
                            // queue.  Hold the external response until that
                            // queue is ready instead of advancing load_idx
                            // and allowing the next response to overwrite it.
                            packed_weight_data_reg <= mem_resp_rdata;
                            packed_weight_byte_reg <= 2'd0;
                            state <= ST_PACKED_WEIGHT_WAIT;
                        end else begin
                        if (packed_input_mode) begin
                            packed_word_valid <= 1'b1;
                            packed_word_addr <= (phase_base_addr + load_idx) &
                                                32'hffff_fffc;
                            packed_word_data <= mem_resp_rdata;
                        end
                        store_response_word(
                            phase_idx, load_idx,
                            packed_input_mode ?
                            (mem_resp_rdata >> ((load_idx[1:0]) * 8)) :
                            mem_resp_rdata);
                        if ((load_idx + 32'd1) >= phase_count) begin
                            if (phase_idx == op_last_phase_reg) begin
                                state <= ds1_retained_mode_reg ? ST_DS1_RETAINED_START :
                                         (tiled_spatial_mode ? ST_TILED_INIT : ST_ENGINE_START);
                            end else begin
                                phase_idx <= phase_idx + 4'd1;
                                state <= ST_LOAD_SETUP;
                            end
                        end else begin
                            load_idx <= load_idx + 32'd1;
                            advance_compact_load_position(phase_idx);
                            if (!packed_input_mode && !packed_weight_mode) begin
                                // Preserve the scalar lookahead path.  Packed
                                // requests are issued only by ST_READ_REQ so
                                // their word address cannot cross a phase.
                                mem_req_valid <= 1'b1;
                                mem_req_write <= 1'b0;
                                mem_req_addr <= phase_base_addr +
                                                ((load_idx + 32'd1) << 2);
                                mem_req_wdata <= 32'd0;
                            end
                            state <= ST_READ_REQ;
                        end
                        end
                    end
                end

                ST_PACKED_WEIGHT_WAIT: begin
                    // cfg_weight_word_ready includes both the DS idle
                    // condition and the PW canonical-store queue state.
                    // The response data remains registered until accepted.
                    if (phase_idx == PH_DW_WEIGHT) begin
                        // DW's canonical store is the existing scalar
                        // parameter array.  Retire the packed response into
                        // that port one byte per cycle; this keeps the
                        // 32-bit packed data off the wide DW write mux while
                        // retaining one external request per four bytes.
                        if (ds_cfg_ready) begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_DW_WEIGHT;
                            ds_cfg_index <= (load_idx * 32'd4) +
                                            packed_weight_byte_reg;
                            ds_cfg_data <= {
                                {24{packed_weight_data_reg[
                                    (packed_weight_byte_reg * 8) + 7]}},
                                packed_weight_data_reg[
                                    (packed_weight_byte_reg * 8) +: 8]
                            };
                            if (packed_weight_byte_reg == 2'd3) begin
                                packed_weight_byte_reg <= 2'd0;
                                if ((load_idx + 32'd1) >= phase_count) begin
                                    if (phase_idx == op_last_phase_reg) begin
                                        state <= ds1_retained_mode_reg ?
                                                 ST_DS1_RETAINED_START :
                                                 (tiled_spatial_mode ?
                                                  ST_TILED_INIT :
                                                  ST_ENGINE_START);
                                    end else begin
                                        phase_idx <= phase_idx + 4'd1;
                                        state <= ST_LOAD_SETUP;
                                    end
                                end else begin
                                    load_idx <= load_idx + 32'd1;
                                    state <= ST_READ_REQ;
                                end
                            end else begin
                                packed_weight_byte_reg <=
                                    packed_weight_byte_reg + 2'd1;
                            end
                        end
                    end else if (ds_cfg_weight_word_ready) begin
                        store_ds_weight_word(
                            phase_idx, load_idx, packed_weight_data_reg);
                        if ((load_idx + 32'd1) >= phase_count) begin
                            if (phase_idx == op_last_phase_reg) begin
                                state <= ds1_retained_mode_reg ?
                                         ST_DS1_RETAINED_START :
                                         (tiled_spatial_mode ?
                                          ST_TILED_INIT : ST_ENGINE_START);
                            end else begin
                                phase_idx <= phase_idx + 4'd1;
                                state <= ST_LOAD_SETUP;
                            end
                        end else begin
                            load_idx <= load_idx + 32'd1;
                            advance_compact_load_position(phase_idx);
                            state <= ST_READ_REQ;
                        end
                    end
                end

                ST_ENGINE_START: begin
                    // Transfer ownership of the external memory bus to the
                    // unified Stem.  Its source loader runs after start and
                    // is bridged through the runner's existing one-request
                    // interface; no new top-level memory contract is
                    // exposed.
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    if (op_is_stem_reg) begin
                        stem_start <= 1'b1;
                    end else if (op_is_ds_reg) begin
                        ds_start <= 1'b1;
                    end else if (op_is_gap_reg) begin
                        gap_start <= 1'b1;
                    end else if (op_is_fc_reg) begin
                        fc_start <= 1'b1;
                    end else begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end
                    if (op_is_valid_reg) begin
                        state <= ST_ENGINE_WAIT;
                    end
                end

                ST_ENGINE_WAIT: begin
                    if (unified_stem_mode) begin
                        // The unified engine holds its request until the
                        // runner has registered it on the shared bus.  The
                        // ready pulse is then formed from the registered
                        // external request, preserving valid/address
                        // stability under arbitrary mem_req_ready stalls.
                        if (!mem_req_valid && unified_stem_mem_req_valid) begin
                            mem_req_valid <= 1'b1;
                            mem_req_write <= 1'b0;
                            mem_req_addr <= unified_stem_mem_req_addr;
                            mem_req_wdata <= 32'd0;
                        end else if (mem_req_valid && mem_req_ready) begin
                            mem_req_valid <= 1'b0;
                            mem_req_write <= 1'b0;
                        end
                    end
                    if ((op_is_stem_reg &&
                         stem_done && stem_error) ||
                        (op_is_ds_reg &&
                         ds_done && ds_error) ||
                        (op_is_fc_reg &&
                         fc_done && fc_error)) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else if ((op_is_stem_reg && stem_done) ||
                        (op_is_ds_reg && ds_done) ||
                        (op_is_gap_reg && gap_done) ||
                        (op_is_fc_reg && fc_done)) begin
                        state <= ST_STORE_SETUP;
                    end
                end

                ST_DS1_RETAINED_START: begin
                    /* All DW/PW scalar phases have already crossed the
                     * runner's normal parameter bus.  The optional adapter
                     * now repacks those cached values and starts the retained
                     * DS1 layer. */
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    if (ds1_ret_start_valid && ds1_ret_start_ready)
                        state <= ST_DS1_RETAINED_WAIT;
                end

                ST_DS1_RETAINED_WAIT: begin
                    /* The retained source side is the existing synchronous
                     * feature-SRAM word port.  Its request is accepted every
                     * cycle and the one-cycle response is returned directly
                     * to the adapter. */
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    sram_input_rd_word_en <= ds1_ret_source_word_en;
                    sram_input_rd_word_addr <= ds1_ret_source_word_addr;
                    if (ds1_ret_output_word_en) begin
                        sram_output_wr4_en <= 1'b1;
                        sram_output_wr4_addr <=
                            output_addr_reg + ds1_ret_output_word_addr;
                        sram_output_wr4_data <= ds1_ret_output_word_data;
                        sram_output_wr4_be <= ds1_ret_output_word_be;
                    end
                    if (ds1_ret_error) begin
                        error <= 1'b1;
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else if (ds1_ret_done) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                ST_STORE_SETUP: begin
                    store_count <= output_count_reg;
                    store_idx <= 32'd0;
                    store_outbuf_addr <= {OUT_BUFFER_ADDR_WIDTH{1'b0}};
                    store_channel_pos <= 16'd0;
                    store_write_word_eligible_reg <= 1'b0;
                    store_issue_word_eligible_reg <= 1'b0;
                    store_issue_addr_reg <= {OUT_BUFFER_ADDR_WIDTH{1'b0}};
                    if (output_count_reg == 32'd0) begin
                        state <= ST_DONE;
                    end else if (op_is_stem_reg || op_is_ds_reg) begin
                        state <= ST_STORE_PREFETCH;
                    end else begin
                        state <= ST_WRITE_REQ;
                    end
                end

                ST_STORE_PREFETCH: begin
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    // Seed the registered read/write bundle.  The actual
                    // synchronous BRAM read is issued in the following
                    // state, keeping its enable independent of the live
                    // channel-position arithmetic.
                    store_write_word_eligible_reg <= store_word_eligible;
                    store_issue_word_eligible_reg <= store_word_eligible;
                    store_issue_addr_reg <= store_outbuf_addr;
                    state <= ST_STORE_READ_ISSUE;
                end

                ST_STORE_READ_ISSUE: begin
                    // cnn_out_buffer has one-cycle synchronous read latency.
                    // The write state consumes the data captured by this
                    // issue cycle.  A single common issue state serves both
                    // tiled and non-tiled stores.
                    state <= tiled_spatial_mode ? ST_TILED_WRITE_REQ :
                                                   ST_WRITE_REQ;
                end

                ST_WRITE_REQ: begin
                    if (flags_reg[FLAG_OUTPUT_TO_SRAM]) begin
                        mem_req_valid <= 1'b0;
                        mem_req_write <= 1'b0;
                        if (store_write_word_eligible_reg) begin
                            sram_output_wr4_en <= 1'b1;
                            sram_output_wr4_addr <= store_sram_byte_addr_current[SRAM_ADDR_WIDTH-1:0];
                            sram_output_wr4_data <= out_buffer_rd_word_data;
                            sram_output_wr4_be <= 4'b1111;
                        end else begin
                            sram_output_wr_en <= 1'b1;
                            sram_output_wr_addr <= sram_addr_for_index(output_addr_reg, store_idx);
                            sram_output_wr_data <= store_byte_current;
                        end
                        if ((store_idx_after_step) >= store_count) begin
                            state <= ST_DONE;
                        end else begin
                            store_idx <= store_idx_after_step;
                            store_outbuf_addr <= store_outbuf_after_step;
                            // Prepare the next read bundle at the same edge
                            // that advances the write cursor.  The issue
                            // state then supplies the next BRAM data word.
                            store_write_word_eligible_reg <=
                                store_next_word_eligible;
                            store_issue_word_eligible_reg <=
                                store_next_word_eligible;
                            store_issue_addr_reg <= store_outbuf_after_step;
                            state <= ST_STORE_READ_ISSUE;
                            if (store_write_word_eligible_reg) begin
                                if ((store_channel_pos + 16'd4) >= store_active_channels)
                                    store_channel_pos <= 16'd0;
                                else
                                    store_channel_pos <= store_channel_pos + 16'd4;
                            end else if ((store_channel_pos + 16'd1) >= store_active_channels) begin
                                store_channel_pos <= 16'd0;
                            end else begin
                                store_channel_pos <= store_channel_pos + 16'd1;
                            end
                        end
                    end else begin
                        if (!mem_req_valid) begin
                            mem_req_valid <= 1'b1;
                            mem_req_write <= 1'b1;
                            mem_req_addr <= output_addr_reg + (store_idx << 2);
                            mem_req_wdata <= {{24{store_byte_current[7]}}, store_byte_current};
                        end else if (mem_req_ready) begin
                            mem_req_valid <= 1'b0;
                            mem_req_write <= 1'b0;
                        if ((store_idx + 32'd1) >= store_count) begin
                            state <= ST_DONE;
                        end else begin
                            store_idx <= store_idx + 32'd1;
                            store_outbuf_addr <= store_outbuf_next_addr;
                            // External stores are scalar, but use the same
                            // registered read bundle so the output-buffer
                            // BRAM enable never depends on channel position.
                            store_write_word_eligible_reg <= 1'b0;
                            store_issue_word_eligible_reg <= 1'b0;
                            store_issue_addr_reg <= store_outbuf_next_addr;
                            state <= ST_STORE_READ_ISSUE;
                            if ((store_channel_pos + 16'd1) >= store_active_channels) begin
                                store_channel_pos <= 16'd0;
                            end else begin
                                store_channel_pos <= store_channel_pos + 16'd1;
                            end
                            end
                        end
                    end
                end

                ST_TILED_INIT: begin
                    tile_sched_start <= 1'b1;
                    tiled_load_idx <= 32'd0;
                    tiled_load_count <= 32'd0;
                    tiled_input_area_reg <= 16'd0;
                    tiled_load_y <= 8'd0;
                    tiled_load_x <= 8'd0;
                    tiled_load_channel <= 16'd0;
                    state <= ST_TILED_START_WAIT;
                end

                ST_TILED_START_WAIT: begin
                    state <= ST_TILED_LOAD_SETUP;
                end

                ST_TILED_LOAD_SETUP: begin
                    if (tile_sched_valid) begin
                        tile_h_start_reg <= sched_tile_h_start;
                        tile_w_start_reg <= sched_tile_w_start;
                        tile_h_size_reg <= sched_tile_h_size;
                        tile_w_size_reg <= sched_tile_w_size;
                        tiled_store_out_w_reg <= tiled_out_w;
                        tile_input_h_reg <= sched_input_tile_h;
                        tile_input_w_reg <= sched_input_tile_w;
                        tile_is_last_reg <= sched_is_last_tile;
                        tiled_load_idx <= 32'd0;
                        tiled_load_y <= 8'd0;
                        tiled_load_x <= 8'd0;
                        tiled_load_channel <= 16'd0;
                        state <= ST_TILED_LOAD_AREA;
                    end else begin
                        state <= ST_TILED_LOAD_SETUP;
                    end
                end

                ST_TILED_LOAD_AREA: begin
                    tiled_input_area_reg <= {8'd0, tile_input_h_reg} *
                                            {8'd0, tile_input_w_reg};
                    state <= ST_TILED_LOAD_COUNT;
                end

                ST_TILED_LOAD_COUNT: begin
                    tiled_load_count <= {16'd0, tiled_input_area_reg} *
                                        {16'd0, in_c_reg};
                    state <= ST_TILED_ADDR_OFFSETS;
                end

                ST_TILED_ADDR_OFFSETS: begin
                    // The scheduler emits a row-major raster.  Initialize
                    // the first tile at the -1 halo and advance only when a
                    // complete eight-output tile row/column is crossed.
                    // This preserves signed padding coordinates while
                    // replacing origin_y*stride/origin_x*stride with
                    // registered recurrence adds.
                    if (tile_h_start_reg == 8'd0) begin
                        tiled_input_halo_row_offset_reg <= -32'sd1;
                    end else if (tile_w_start_reg == 8'd0) begin
                        tiled_input_halo_row_offset_reg <=
                            tiled_input_halo_row_offset_reg +
                            tiled_input_halo_step_reg;
                    end
                    if (tile_w_start_reg == 8'd0) begin
                        tiled_input_halo_col_offset_reg <= -32'sd1;
                    end else begin
                        tiled_input_halo_col_offset_reg <=
                            tiled_input_halo_col_offset_reg +
                            tiled_input_halo_step_reg;
                    end
                    state <= ST_TILED_ADDR_BASES;
                end

                ST_TILED_ADDR_BASES: begin
                    // row_base is advanced once per local input row while a
                    // tile is loaded, so it is not a stable tile origin at
                    // the next setup.  Advance the dedicated origin only at
                    // a new tile row, then reload the mutable cursor for
                    // every tile column in that row.
                    if (tile_w_start_reg == 8'd0) begin
                        if (tile_h_start_reg == 8'd0) begin
                            tiled_input_tile_row_base_reg <=
                                -tiled_input_row_stride_reg;
                            tiled_input_row_base_reg <=
                                -tiled_input_row_stride_reg;
                        end else begin
                            tiled_input_tile_row_base_reg <=
                                tiled_input_tile_row_base_reg +
                                tiled_input_tile_row_step_reg;
                            tiled_input_row_base_reg <=
                                tiled_input_tile_row_base_reg +
                                tiled_input_tile_row_step_reg;
                        end
                    end else begin
                        tiled_input_row_base_reg <=
                            tiled_input_tile_row_base_reg;
                    end
                    if (tile_w_start_reg == 8'd0) begin
                        tiled_input_tile_col_base_reg <=
                            -$signed({16'd0, in_c_reg});
                    end else begin
                        tiled_input_tile_col_base_reg <=
                            tiled_input_tile_col_base_reg +
                            tiled_input_tile_col_step_reg;
                    end
                    state <= ST_TILED_ADDR_NEXT_BASE;
                end

                ST_TILED_ADDR_NEXT_BASE: begin
                    tiled_input_next_row_base_reg <= tiled_input_row_base_reg +
                                                     tiled_input_row_stride_reg;
                    state <= ST_TILED_ADDR_INDEX;
                end

                ST_TILED_ADDR_INDEX: begin
                    tiled_input_col_base_reg <= tiled_input_tile_col_base_reg;
                    tiled_input_index_reg <= tiled_input_row_base_reg +
                                             tiled_input_tile_col_base_reg;
                    capture_tiled_load_metadata(
                        tiled_load_y,
                        tiled_load_x,
                        tiled_load_channel,
                        tiled_input_row_base_reg +
                        tiled_input_tile_col_base_reg
                    );
                    if (tiled_load_count == 32'd0) begin
                        state <= ST_TILED_ENGINE_START;
                    end else begin
                        // Prime the successor cursor from the registered
                        // current bundle.  The metadata stage below then
                        // evaluates padding/eligibility from that successor
                        // register, keeping the wide compare off the cursor
                        // commit/request path.
                        tiled_load_prime_reg <= 1'b1;
                        state <= ST_TILED_LOAD_LOOKAHEAD;
                    end
                end

                ST_TILED_LOAD_REQ: begin
                    if (tiled_load_current_padding_reg) begin
                        if (tiled_stem_mode) begin
                            store_stem_tiled_input(input_zero_point_reg[7:0]);
                        end else begin
                            store_ds_tiled_input(input_zero_point_reg[7:0]);
                        end
                        if ((tiled_load_idx + 32'd1) >= tiled_load_count) begin
                            state <= ST_TILED_ENGINE_START;
                        end else begin
                            tiled_load_idx <= tiled_load_idx + 32'd1;
                            advance_tiled_load_position(
                                tiled_load_current_pixel_end_reg
                            );
                            // Look through the padding run boundary.  A real
                            // next element can be pre-armed immediately; a
                            // padded next element remains local to this state
                            // and must not create a memory transaction.
                            if (tiled_load_current_pixel_end_reg) begin
                                state <= ST_TILED_LOAD_LOOKAHEAD;
                            end else if (!tiled_load_next_padding_reg) begin
                                if (flags_reg[FLAG_INPUT_FROM_SRAM]) begin
                                    if (tiled_load_next_word_channel_ok_reg &&
                                        tiled_load_next_word_source_aligned_reg &&
                                        (tiled_load_next_word_lane_mask_reg == 4'b1111)) begin
                                        sram_input_rd_word_en <= 1'b1;
                                        sram_input_rd_word_addr <= sram_addr_for_index(
                                            input_addr_reg,
                                            tiled_input_next_index_cursor_reg
                                        );
                                        state <= ST_TILED_LOAD_WORD_RESP;
                                    end else begin
                                        sram_input_rd_en <= 1'b1;
                                        sram_input_rd_addr <= sram_addr_for_index(
                                            input_addr_reg,
                                            tiled_input_next_index_cursor_reg
                                        );
                                        state <= ST_TILED_LOAD_RESP;
                                    end
                                end else begin
                                    state <= ST_TILED_LOAD_MEM_REQ;
                                end
                            end
                        end
                    end else if (flags_reg[FLAG_INPUT_FROM_SRAM]) begin
                        mem_req_valid <= 1'b0;
                        mem_req_write <= 1'b0;
                        if (tiled_load_word_channel_ok_reg &&
                            tiled_load_word_source_aligned_reg &&
                            (tiled_load_word_lane_mask_reg == 4'b1111)) begin
                            sram_input_rd_word_en <= 1'b1;
                            sram_input_rd_word_addr <= sram_addr_for_index(
                                input_addr_reg, tiled_input_index_reg);
                            state <= ST_TILED_LOAD_WORD_RESP;
                        end else begin
                            sram_input_rd_en <= 1'b1;
                            sram_input_rd_addr <= sram_addr_for_index(
                                input_addr_reg,
                                tiled_input_index_reg
                            );
                            state <= ST_TILED_LOAD_RESP;
                        end
                    end else begin
                        // External requests are issued from a separate state
                        // so this state's padding/channel decision cannot
                        // become the enable for mem_req_addr_reg.
                        state <= ST_TILED_LOAD_MEM_REQ;
                    end
                end

                ST_TILED_LOAD_MEM_REQ: begin
                    // Keep one outstanding external read.  The address is
                    // formed only after the cursor has been registered by
                    // the preceding response, and the dedicated state makes
                    // its register CE independent of tiled_load_channel.
                    if (!mem_req_valid) begin
                        mem_req_valid <= 1'b1;
                        mem_req_write <= 1'b0;
                        mem_req_addr <= input_addr_reg +
                                        (tiled_input_index_reg << 2);
                        mem_req_wdata <= 32'd0;
                    end else if (mem_req_ready) begin
                        mem_req_valid <= 1'b0;
                        mem_req_write <= 1'b0;
                        state <= ST_TILED_LOAD_RESP;
                    end
                end

                ST_TILED_LOAD_RESP: begin
                    if (flags_reg[FLAG_INPUT_FROM_SRAM]) begin
                        if (sram_input_rd_valid) begin
                            if (tiled_stem_mode) begin
                                store_stem_tiled_input(sram_input_rd_data[7:0]);
                            end else begin
                                store_ds_tiled_input(sram_input_rd_data[7:0]);
                            end
                            if ((tiled_load_idx + 32'd1) >= tiled_load_count) begin
                                state <= ST_TILED_ENGINE_START;
                            end else begin
                                tiled_load_idx <= tiled_load_idx + 32'd1;
                                advance_tiled_load_position(
                                    tiled_load_current_pixel_end_reg
                                );
                                if (tiled_load_current_pixel_end_reg) begin
                                    state <= ST_TILED_LOAD_LOOKAHEAD;
                                end else if (tiled_load_next_padding_reg) begin
                                    state <= ST_TILED_LOAD_REQ;
                                end else if (tiled_load_next_word_channel_ok_reg &&
                                             tiled_load_next_word_source_aligned_reg &&
                                             (tiled_load_next_word_lane_mask_reg == 4'b1111)) begin
                                    sram_input_rd_word_en <= 1'b1;
                                    sram_input_rd_word_addr <= sram_addr_for_index(
                                        input_addr_reg,
                                        tiled_input_next_index_cursor_reg
                                    );
                                    state <= ST_TILED_LOAD_WORD_RESP;
                                end else begin
                                    sram_input_rd_en <= 1'b1;
                                    sram_input_rd_addr <= sram_addr_for_index(
                                        input_addr_reg,
                                        tiled_input_next_index_cursor_reg
                                    );
                                    state <= ST_TILED_LOAD_RESP;
                                end
                            end
                        end
                    end else if (mem_resp_valid) begin
                        if (tiled_stem_mode) begin
                            store_stem_tiled_input(mem_resp_rdata[7:0]);
                        end else begin
                            store_ds_tiled_input(mem_resp_rdata[7:0]);
                        end
                        if ((tiled_load_idx + 32'd1) >= tiled_load_count) begin
                            state <= ST_TILED_ENGINE_START;
                        end else begin
                            tiled_load_idx <= tiled_load_idx + 32'd1;
                            advance_tiled_load_position(
                                tiled_load_current_pixel_end_reg
                            );
                            if (tiled_load_current_pixel_end_reg) begin
                                state <= ST_TILED_LOAD_LOOKAHEAD;
                            end else if (!tiled_load_next_padding_reg) begin
                                state <= ST_TILED_LOAD_MEM_REQ;
                            end else begin
                                    state <= ST_TILED_LOAD_REQ;
                            end
                        end
                    end
                end

                ST_TILED_LOAD_WORD_RESP: begin
                    if (sram_input_rd_word_valid) begin
                        if (tiled_stem_mode) begin
                            store_stem_tiled_input_vec4(sram_input_rd_word_data);
                        end else begin
                            store_ds_tiled_input_vec4(sram_input_rd_word_data);
                        end
                        if ((tiled_load_idx + 32'd4) >= tiled_load_count) begin
                            // Do not advance the cursor beyond the tile tail;
                            // no successor exists after the final vector.
                            state <= ST_TILED_ENGINE_START;
                        end else begin
                            tiled_load_idx <= tiled_load_idx + 32'd4;
                            advance_tiled_load_position(
                                tiled_load_current_word_pixel_end_reg
                            );
                            if (tiled_load_current_word_pixel_end_reg) begin
                                state <= ST_TILED_LOAD_LOOKAHEAD;
                            end else if (tiled_load_next_padding_reg) begin
                                state <= ST_TILED_LOAD_REQ;
                            end else if (tiled_load_next_word_channel_ok_reg &&
                                         tiled_load_next_word_source_aligned_reg &&
                                         (tiled_load_next_word_lane_mask_reg == 4'b1111)) begin
                                sram_input_rd_word_en <= 1'b1;
                                sram_input_rd_word_addr <= sram_addr_for_index(
                                    input_addr_reg,
                                    tiled_input_next_index_cursor_reg
                                );
                                state <= ST_TILED_LOAD_WORD_RESP;
                            end else begin
                                sram_input_rd_en <= 1'b1;
                                sram_input_rd_addr <= sram_addr_for_index(
                                    input_addr_reg,
                                    tiled_input_next_index_cursor_reg
                                );
                                state <= ST_TILED_LOAD_RESP;
                            end
                        end
                    end
                end

                ST_TILED_LOAD_LOOKAHEAD: begin
                    if (tiled_load_prime_reg) begin
                        tiled_load_prime_reg <= 1'b0;
                        if (!tiled_load_current_padding_reg &&
                            flags_reg[FLAG_INPUT_FROM_SRAM] &&
                            tiled_load_word_channel_ok_reg &&
                            tiled_load_word_source_aligned_reg &&
                            (tiled_load_word_lane_mask_reg == 4'b1111)) begin
                            if ((tiled_load_idx + 32'd4) >= tiled_load_count) begin
                                // The first vector is also the tile tail;
                                // leave the successor bundle invalid rather
                                // than manufacturing a post-tile cursor.
                                state <= ST_TILED_LOAD_REQ;
                            end else begin
                                prepare_tiled_load_successor_vec4();
                                state <= ST_TILED_LOAD_METADATA;
                            end
                        end else begin
                            if ((tiled_load_idx + 32'd1) >= tiled_load_count) begin
                                // Likewise for a one-element tile or scalar
                                // tail: no successor is needed after the
                                // final legal cursor.
                                state <= ST_TILED_LOAD_REQ;
                            end else begin
                                prepare_tiled_load_successor_scalar();
                                state <= ST_TILED_LOAD_METADATA;
                            end
                        end
                    end else begin
                        // Pixel/word-boundary lookahead has a registered
                        // successor cursor already.  Register only its wide
                        // signed halo and word metadata here.
                        capture_tiled_load_next_metadata();
                        state <= ST_TILED_LOAD_REQ;
                    end
                end

                ST_TILED_LOAD_METADATA: begin
                    capture_tiled_load_next_metadata();
                    state <= ST_TILED_LOAD_REQ;
                end

                ST_TILED_ENGINE_START: begin
                    if (tiled_stem_mode) begin
                        stem_start <= 1'b1;
                    end else begin
                        ds_start <= 1'b1;
                    end
                    state <= ST_TILED_ENGINE_WAIT;
                end

                ST_TILED_ENGINE_WAIT: begin
                    if ((tiled_stem_mode && stem_done && stem_error) ||
                        (tiled_ds_mode && ds_done && ds_error)) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else if ((tiled_stem_mode && stem_done) ||
                                 (tiled_ds_mode && ds_done)) begin
                        state <= ST_TILED_STORE_SETUP;
                    end
                end

                ST_TILED_STORE_SETUP: begin
                    /* Commit the spatial partial product first.  The final
                     * channel product is registered in BASE_FINISH below,
                     * so the store-count path is never a three-operand DSP
                     * cascade from tile_h/tile_w to the write-loop compare. */
                    tiled_store_area_reg <= {24'd0, tile_h_size_reg} *
                                            {24'd0, tile_w_size_reg};
                    store_idx <= 32'd0;
                    store_outbuf_addr <= {OUT_BUFFER_ADDR_WIDTH{1'b0}};
                    store_channel_pos <= 16'd0;
                    tiled_store_y <= 8'd0;
                    tiled_store_x <= 8'd0;
                    // The active cursor starts from row_base and is advanced
                    // only with fixed strides.  Capture the simple strides in
                    // this setup handshake; the tile-dependent base itself is
                    // formed below over registered arithmetic stages.
                    tiled_store_addr_col_jump <=
                        ({16'd0, out_c_reg} << 2);
                    tiled_store_addr_row_jump <=
                        (({16'd0, tiled_store_out_w_reg} * {16'd0, out_c_reg}) << 2);
                    tiled_store_sram_addr_col_jump <=
                        {16'd0, out_c_reg};
                    tiled_store_sram_addr_row_jump <=
                        ({16'd0, tiled_store_out_w_reg} * {16'd0, out_c_reg});
                    tiled_store_base_index_reg <=
                        {24'd0, tile_h_start_reg} *
                        {24'd0, tiled_store_out_w_reg};
                    if ((tile_h_size_reg == 8'd0) ||
                        (tile_w_size_reg == 8'd0) ||
                        (out_c_reg == 16'd0)) begin
                        state <= ST_TILED_ADVANCE;
                    end else begin
                        state <= ST_TILED_STORE_BASE_ADD;
                    end
                end

                ST_TILED_STORE_BASE_ADD: begin
                    tiled_store_base_index_reg <= tiled_store_base_index_reg +
                                                  {24'd0, tile_w_start_reg};
                    state <= ST_TILED_STORE_BASE_MUL;
                end

                ST_TILED_STORE_BASE_MUL: begin
                    tiled_store_linear_index_reg <= tiled_store_base_index_reg *
                                                   {16'd0, out_c_reg};
                    state <= ST_TILED_STORE_BASE_FINISH;
                end

                ST_TILED_STORE_BASE_FINISH: begin
                    store_count <= tiled_store_area_reg *
                                   {16'd0, out_c_reg};
                    tiled_store_addr_row_base <= output_addr_reg +
                                                 (tiled_store_linear_index_reg << 2);
                    tiled_store_addr_col_base <= output_addr_reg +
                                                 (tiled_store_linear_index_reg << 2);
                    tiled_store_addr_current <= output_addr_reg +
                                                (tiled_store_linear_index_reg << 2);
                    tiled_store_sram_addr_row_base <= output_addr_reg +
                                                      tiled_store_linear_index_reg;
                    tiled_store_sram_addr_col_base <= output_addr_reg +
                                                      tiled_store_linear_index_reg;
                    tiled_store_sram_addr_current <= output_addr_reg +
                                                     tiled_store_linear_index_reg;
                    state <= ST_TILED_STORE_PREFETCH;
                end

                ST_TILED_STORE_PREFETCH: begin
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    // Capture the first internal-SRAM address before entering
                    // the write loop; subsequent writes use only cursor adds.
                    sram_output_wr_addr <= tiled_store_sram_addr_current;
                    store_write_word_eligible_reg <= store_word_eligible;
                    store_issue_word_eligible_reg <= store_word_eligible;
                    store_issue_addr_reg <= store_outbuf_addr;
                    state <= ST_STORE_READ_ISSUE;
                end

                ST_TILED_WRITE_REQ: begin
                    if (flags_reg[FLAG_OUTPUT_TO_SRAM]) begin
                        mem_req_valid <= 1'b0;
                        mem_req_write <= 1'b0;
                        if (store_write_word_eligible_reg) begin
                            sram_output_wr4_en <= 1'b1;
                            sram_output_wr4_addr <= tiled_store_sram_addr_current[SRAM_ADDR_WIDTH-1:0];
                            sram_output_wr4_data <= out_buffer_rd_word_data;
                            sram_output_wr4_be <= 4'b1111;
                        end else begin
                            sram_output_wr_en <= 1'b1;
                            sram_output_wr_addr <= tiled_store_sram_addr_current;
                            sram_output_wr_data <= store_byte_current;
                        end
                        if (store_idx_after_step >= store_count) begin
                            state <= ST_TILED_ADVANCE;
                        end else begin
                            store_idx <= store_idx_after_step;
                            store_outbuf_addr <= store_outbuf_after_step;
                            store_write_word_eligible_reg <=
                                store_next_word_eligible;
                            store_issue_word_eligible_reg <=
                                store_next_word_eligible;
                            store_issue_addr_reg <= store_outbuf_after_step;
                            state <= ST_STORE_READ_ISSUE;
                            if (store_write_word_eligible_reg) begin
                                if ((store_channel_pos + 16'd4) >= store_active_channels) begin
                                    store_channel_pos <= 16'd0;
                                    if ((tiled_store_x + 8'd1) >= tile_w_size_reg) begin
                                        tiled_store_x <= 8'd0;
                                        tiled_store_y <= tiled_store_y + 8'd1;
                                        tiled_store_sram_addr_row_base <=
                                            tiled_store_sram_addr_row_base +
                                            tiled_store_sram_addr_row_jump;
                                        tiled_store_sram_addr_col_base <=
                                            tiled_store_sram_addr_row_base +
                                            tiled_store_sram_addr_row_jump;
                                        tiled_store_sram_addr_current <=
                                            tiled_store_sram_addr_row_base +
                                            tiled_store_sram_addr_row_jump;
                                    end else begin
                                        tiled_store_x <= tiled_store_x + 8'd1;
                                        tiled_store_sram_addr_col_base <=
                                            tiled_store_sram_addr_col_base +
                                            tiled_store_sram_addr_col_jump;
                                        tiled_store_sram_addr_current <=
                                            tiled_store_sram_addr_col_base +
                                            tiled_store_sram_addr_col_jump;
                                    end
                                end else begin
                                    store_channel_pos <= store_channel_pos + 16'd4;
                                    tiled_store_sram_addr_current <=
                                        tiled_store_sram_addr_current + 32'd4;
                                end
                            end else begin
                                if ((store_channel_pos + 16'd1) >= store_active_channels) begin
                                    if ((tiled_store_x + 8'd1) >= tile_w_size_reg) begin
                                        tiled_store_sram_addr_row_base <=
                                            tiled_store_sram_addr_row_base +
                                            tiled_store_sram_addr_row_jump;
                                        tiled_store_sram_addr_col_base <=
                                            tiled_store_sram_addr_row_base +
                                            tiled_store_sram_addr_row_jump;
                                        tiled_store_sram_addr_current <=
                                            tiled_store_sram_addr_row_base +
                                            tiled_store_sram_addr_row_jump;
                                    end else begin
                                        tiled_store_sram_addr_col_base <=
                                            tiled_store_sram_addr_col_base +
                                            tiled_store_sram_addr_col_jump;
                                        tiled_store_sram_addr_current <=
                                            tiled_store_sram_addr_col_base +
                                            tiled_store_sram_addr_col_jump;
                                    end
                                end else begin
                                    tiled_store_sram_addr_current <=
                                        tiled_store_sram_addr_current + 32'd1;
                                end
                                advance_tiled_store_position();
                            end
                        end
                    end else begin
                        if (!mem_req_valid) begin
                            mem_req_valid <= 1'b1;
                            mem_req_write <= 1'b1;
                            mem_req_addr <= tiled_store_addr_current;
                            mem_req_wdata <= {{24{store_byte_current[7]}}, store_byte_current};
                        end else if (mem_req_ready) begin
                            mem_req_valid <= 1'b0;
                            mem_req_write <= 1'b0;
                            if ((store_idx + 32'd1) >= store_count) begin
                                state <= ST_TILED_ADVANCE;
                            end else begin
                                store_idx <= store_idx + 32'd1;
                                store_outbuf_addr <= store_outbuf_next_addr;
                                store_write_word_eligible_reg <= 1'b0;
                                store_issue_word_eligible_reg <= 1'b0;
                                store_issue_addr_reg <= store_outbuf_next_addr;
                                state <= ST_STORE_READ_ISSUE;
                                if ((store_channel_pos + 16'd1) >= store_active_channels) begin
                                    if ((tiled_store_x + 8'd1) >= tile_w_size_reg) begin
                                        tiled_store_addr_row_base <=
                                            tiled_store_addr_row_base +
                                            tiled_store_addr_row_jump;
                                        tiled_store_addr_col_base <=
                                            tiled_store_addr_row_base +
                                            tiled_store_addr_row_jump;
                                        tiled_store_addr_current <=
                                            tiled_store_addr_row_base +
                                            tiled_store_addr_row_jump;
                                    end else begin
                                        tiled_store_addr_col_base <=
                                            tiled_store_addr_col_base +
                                            tiled_store_addr_col_jump;
                                        tiled_store_addr_current <=
                                            tiled_store_addr_col_base +
                                            tiled_store_addr_col_jump;
                                    end
                                end else begin
                                    tiled_store_addr_current <=
                                        tiled_store_addr_current + 32'd4;
                                end
                                advance_tiled_store_position();
                            end
                        end
                    end
                end

                ST_TILED_ADVANCE: begin
                    if (tile_is_last_reg) begin
                        state <= ST_DONE;
                    end else begin
                        tile_sched_next <= 1'b1;
                        state <= ST_TILED_NEXT_WAIT;
                    end
                end

                ST_TILED_NEXT_WAIT: begin
                    state <= ST_TILED_LOAD_SETUP;
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    sram_input_rd_en <= 1'b0;
                    sram_output_wr_en <= 1'b0;
                    tile_sched_start <= 1'b0;
                    tile_sched_next <= 1'b0;
                    state <= ST_IDLE;
                end

                ST_ERROR: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    sram_input_rd_en <= 1'b0;
                    sram_output_wr_en <= 1'b0;
                    tile_sched_start <= 1'b0;
                    tile_sched_next <= 1'b0;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

module cnn_out_buffer #(
    parameter DEPTH = 16384,
    parameter ADDR_WIDTH = 14
) (
    input  wire                      clk,
    input  wire                      wr_en,
    input  wire [ADDR_WIDTH-1:0]     wr_addr,
    input  wire signed [7:0]         wr_data,
    input  wire                      rd_en,
    input  wire [ADDR_WIDTH-1:0]     rd_addr,
    output wire signed [7:0]         rd_data,

    input  wire                      wr_word_en,
    input  wire [ADDR_WIDTH-1:0]     wr_word_addr,
    input  wire [31:0]               wr_word_data,
    input  wire [3:0]                wr_word_be,
        input  wire                      rd_word_en,
        input  wire [ADDR_WIDTH-1:0]     rd_word_addr,
        output wire [31:0]                rd_word_data,
        output reg                       rd_word_valid
);
    localparam WORD_ADDR_WIDTH = (ADDR_WIDTH > 2) ? (ADDR_WIDTH - 2) : 1;
    localparam WORD_DEPTH = (DEPTH + 3) / 4;
    wire scalar_write = wr_en;
    wire word_write = wr_word_en || scalar_write;
    wire [ADDR_WIDTH-1:0] write_byte_addr = wr_word_en ? wr_word_addr : wr_addr;
    wire [WORD_ADDR_WIDTH-1:0] write_word_addr = write_byte_addr[ADDR_WIDTH-1:2];
    wire [31:0] scalar_write_data = ({24'd0, wr_data} << (write_byte_addr[1:0] * 8));
    wire [31:0] write_data_i = wr_word_en ? wr_word_data : scalar_write_data;
    wire [3:0] write_be_i = wr_word_en ? wr_word_be : (4'b0001 << write_byte_addr[1:0]);
    wire [ADDR_WIDTH-1:0] read_byte_addr = rd_word_en ? rd_word_addr : rd_addr;
    wire [WORD_ADDR_WIDTH-1:0] read_word_addr = read_byte_addr[ADDR_WIDTH-1:2];
    reg [1:0] rd_lane_d;
`ifdef SYNTHESIS
    wire [31:0] rd_data_word;

    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(WORD_ADDR_WIDTH),
        .ADDR_WIDTH_B(WORD_ADDR_WIDTH),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8),
        .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(DEPTH * 8),
        .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(32),
        .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(32),
        .WRITE_MODE_B("read_first")
    ) u_output_memory (
        .clka(clk),
        .ena(word_write),
        .wea(word_write ? write_be_i : 4'b0000),
        .addra(write_word_addr),
        .dina(write_data_i),
        .injectsbiterra(1'b0),
        .injectdbiterra(1'b0),
        .clkb(clk),
        .rstb(1'b0),
        .enb(rd_en || rd_word_en),
        .regceb(1'b1),
        .addrb(read_word_addr),
        .doutb(rd_data_word),
        .sbiterrb(),
        .dbiterrb(),
        .sleep(1'b0)
    );

    assign rd_word_data = rd_data_word;
    assign rd_data = $signed(rd_data_word[(rd_lane_d * 8) +: 8]);
`else
    reg [31:0] mem [0:WORD_DEPTH-1];
    reg [31:0] rd_data_word_reg;

    integer init_i;
    initial begin
        /* verilator lint_off BLKSEQ */
        for (init_i = 0; init_i < WORD_DEPTH; init_i = init_i + 1) begin
            mem[init_i] = 32'd0;
        end
        rd_data_word_reg = 32'd0;
        /* verilator lint_on BLKSEQ */
    end

    always @(posedge clk) begin
        if (word_write) begin
            if (write_be_i[0]) mem[write_word_addr][7:0] <= write_data_i[7:0];
            if (write_be_i[1]) mem[write_word_addr][15:8] <= write_data_i[15:8];
            if (write_be_i[2]) mem[write_word_addr][23:16] <= write_data_i[23:16];
            if (write_be_i[3]) mem[write_word_addr][31:24] <= write_data_i[31:24];
        end
        if (rd_en || rd_word_en) begin
            rd_data_word_reg <= mem[read_word_addr];
        end
    end

    assign rd_word_data = rd_data_word_reg;
    assign rd_data = $signed(rd_data_word_reg[(rd_lane_d * 8) +: 8]);
`endif

    always @(posedge clk) begin
        if (rd_en || rd_word_en) begin
            rd_lane_d <= rd_word_en ? rd_word_addr[1:0] : rd_addr[1:0];
        end
        rd_word_valid <= rd_word_en;
    end
endmodule

`default_nettype wire
