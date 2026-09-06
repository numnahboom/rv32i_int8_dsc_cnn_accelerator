`timescale 1ns/1ps
`default_nettype none

// Boundary-focused DS2 ledger sweep.  Groups on both sides of each 8-slot
// bank boundary are exercised with duplicate slices, mismatched context/
// owner/32-bit epoch tags, release, and same-slot reuse with a new tag.
module tb_ds12_stream_ds2_slot_ledger_sweep;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n;
    reg clear_slots;
    reg input_query_valid;
    reg [4:0] group_id;
    reg [1:0] query_context;
    reg query_owner;
    reg [31:0] query_epoch;
    reg [3:0] query_bit;
    reg stream_active;
    reg ingress_available;
    reg dw_valid;
    reg set_ready_valid;
    reg set_compute_valid;
    reg set_wait_valid;
    reg release_valid;

    wire [3:0] bank_input_ready;
    wire [3:0] bank_input_fire;
    wire [3:0] bank_input_tag_match;
    wire [2:0] bank_input_state [0:3];
    wire [3:0] bank_active_count [0:3];
    wire dw_ready = |bank_input_ready;
    wire dw_fire = |bank_input_fire;
    wire input_tag_match = |bank_input_tag_match;
    wire [1:0] active_bank = group_id[4:3];
    wire [2:0] active_slot = group_id[2:0];

    genvar b;
    generate
        for (b = 0; b < 4; b = b + 1) begin : gen_bank
            ds12_stream_ds2_slot_ledger_bank u_bank (
                .clk(clk), .rst_n(rst_n), .clear_slots(clear_slots),
                .input_query_valid(input_query_valid && (active_bank == b[1:0])),
                .input_query_slot(active_slot),
                .input_query_context(query_context),
                .input_query_owner(query_owner),
                .input_query_epoch(query_epoch),
                .input_query_bit(query_bit),
                .input_state(bank_input_state[b]),
                .input_context(), .input_owner(), .input_epoch(), .input_seen(),
                .input_slot_existing(), .input_tag_match(bank_input_tag_match[b]),
                .input_slice_available(),
                .stream_active(stream_active), .ingress_available(ingress_available),
                .dw_valid(dw_valid), .input_ready(bank_input_ready[b]),
                .input_fire(bank_input_fire[b]),
                .target_query_valid(1'b0), .target_query_slot(3'd0),
                .target_state(), .target_context(), .target_owner(), .target_epoch(),
                .active_count(bank_active_count[b]),
                .set_ready_valid(set_ready_valid && (active_bank == b[1:0])),
                .set_ready_slot(active_slot),
                .set_compute_valid(set_compute_valid && (active_bank == b[1:0])),
                .set_compute_slot(active_slot),
                .set_wait_valid(set_wait_valid && (active_bank == b[1:0])),
                .set_wait_slot(active_slot),
                .release_valid(release_valid && (active_bank == b[1:0])),
                .release_slot(active_slot)
            );
        end
    endgenerate

    integer errors;
    integer gi;
    integer si;
    integer groups [0:6];
    integer old_epoch;

    task automatic fail_check(input [8*80-1:0] message);
        begin
            errors = errors + 1;
            $display("LEDGER_SWEEP_FAIL %0s group=%0d slot=%0d state=%0d ready=%0d fire=%0d tag_eq=%0d", message, group_id, active_slot, bank_input_state[active_bank], dw_ready, dw_fire, input_tag_match);
        end
    endtask

    task automatic pulse_ready;
        begin
            set_ready_valid = 1'b1;
            @(posedge clk);
            #1;
            set_ready_valid = 1'b0;
        end
    endtask

    task automatic pulse_compute_wait_release;
        begin
            set_compute_valid = 1'b1;
            @(posedge clk);
            #1;
            set_compute_valid = 1'b0;
            set_wait_valid = 1'b1;
            @(posedge clk);
            #1;
            set_wait_valid = 1'b0;
            release_valid = 1'b1;
            @(posedge clk);
            #1;
            release_valid = 1'b0;
        end
    endtask

    initial begin
        groups[0] = 7;
        groups[1] = 8;
        groups[2] = 15;
        groups[3] = 16;
        groups[4] = 23;
        groups[5] = 24;
        groups[6] = 31;
        rst_n = 1'b0;
        clear_slots = 1'b0;
        input_query_valid = 1'b0;
        group_id = 5'd0;
        query_context = 2'd0;
        query_owner = 1'b0;
        query_epoch = 32'd0;
        query_bit = 4'd0;
        stream_active = 1'b0;
        ingress_available = 1'b0;
        dw_valid = 1'b0;
        set_ready_valid = 1'b0;
        set_compute_valid = 1'b0;
        set_wait_valid = 1'b0;
        release_valid = 1'b0;
        errors = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        stream_active = 1'b1;
        ingress_available = 1'b1;
        input_query_valid = 1'b1;
        clear_slots = 1'b1;
        @(posedge clk);
        #1;
        clear_slots = 1'b0;

        for (gi = 0; gi < 7; gi = gi + 1) begin
            group_id = groups[gi][4:0];
            query_context = groups[gi][1:0];
            query_owner = groups[gi][2];
            query_epoch = 32'd64 + groups[gi];

            // Fill all 16 slices.  This is the new_fire/fill_fire path and
            // crosses a bank boundary for every listed neighboring group.
            for (si = 0; si < 16; si = si + 1) begin
                query_bit = si[3:0];
                dw_valid = 1'b1;
                #1;
                if (!dw_ready || !dw_fire)
                    fail_check("fill_not_accepted");
                @(posedge clk);
                #1;
            end
            dw_valid = 1'b0;

            pulse_ready();
            if (bank_input_state[active_bank] !== 3'd2)
                fail_check("ready_state_missing");

            // A duplicate slice and a mismatched full tag must both be
            // rejected while the slot is READY.
            query_bit = 4'd0;
            dw_valid = 1'b1;
            #1;
            if (dw_ready || dw_fire)
                fail_check("duplicate_accepted");
            @(posedge clk);
            #1;
            query_epoch = query_epoch ^ 32'h8000_0000;
            #1;
            if (input_tag_match || dw_ready || dw_fire)
                fail_check("mismatched_tag_accepted");
            dw_valid = 1'b0;
            query_epoch = 32'd64 + groups[gi];

            // READY -> COMPUTE -> WAIT_OUT -> IDLE, then reuse this exact
            // local slot with a new context/owner/epoch tuple.
            pulse_compute_wait_release();
            if (bank_input_state[active_bank] !== 3'd0)
                fail_check("release_did_not_clear");

            query_context = query_context ^ 2'd1;
            query_owner = ~query_owner;
            query_epoch = query_epoch + 32'd4096;
            query_bit = 4'd0;
            dw_valid = 1'b1;
            #1;
            if (!dw_ready || !dw_fire || !input_tag_match)
                fail_check("release_reuse_not_accepted");
            @(posedge clk);
            #1;
            dw_valid = 1'b0;
        end

        clear_slots = 1'b1;
        @(posedge clk);
        #1;
        clear_slots = 1'b0;
        input_query_valid = 1'b0;
        for (si = 0; si < 4; si = si + 1)
            if (bank_active_count[si] !== 4'd0)
                fail_check("clear_active_count_nonzero");
        if (errors != 0)
            $fatal(1, "DS12 DS2 ledger sweep failed errors=%0d", errors);
        $display("DS12_DS2_LEDGER_SWEEP_PASS groups=7,8,15,16,23,24,31 duplicate=7 release_reuse=7");
        $finish(0);
    end
endmodule

`default_nettype wire
