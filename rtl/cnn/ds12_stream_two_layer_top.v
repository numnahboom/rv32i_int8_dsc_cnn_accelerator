`timescale 1ns/1ps
`default_nettype none

// DS1->DS2 integration boundary.  This is deliberately a thin top-level
// interconnect: there is exactly one activation-store instance here.  The
// layer engines are clients of the transaction ports (rather than owning a
// private copy of the activation memory), which makes the bank/epoch fence
// observable at the system boundary and keeps this candidate suitable for
// isolated OOC synthesis.
module ds12_stream_two_layer_top #(
    parameter integer LINE_WORDS = 2048
) (
    input wire clk, input wire rst_n,
    input wire start,
    input wire ds1_start_valid, input wire ds1_start_bank,
    input wire [31:0] ds1_start_epoch, input wire [31:0] ds1_start_words,
    output wire ds1_start_ready,
    input wire ds1_write_valid, output wire ds1_write_ready,
    input wire ds1_write_bank, input wire [31:0] ds1_write_epoch,
    input wire [31:0] ds1_write_addr, input wire [31:0] ds1_write_data,
    input wire [3:0] ds1_write_be, input wire ds1_write_last,
    input wire ds1_commit_valid, input wire ds1_commit_bank,
    input wire [31:0] ds1_commit_epoch, output wire ds1_commit_ready,
    input wire ds2_start_valid, input wire ds2_start_bank,
    input wire [31:0] ds2_start_epoch, input wire [31:0] ds2_start_words,
    output wire ds2_start_ready,
    input wire ds2_write_valid, output wire ds2_write_ready,
    input wire ds2_write_bank, input wire [31:0] ds2_write_epoch,
    input wire [31:0] ds2_write_addr, input wire [31:0] ds2_write_data,
    input wire [3:0] ds2_write_be, input wire ds2_write_last,
    input wire ds2_commit_valid, input wire ds2_commit_bank,
    input wire [31:0] ds2_commit_epoch, output wire ds2_commit_ready,
    input wire read_req_valid, output wire read_req_ready,
    input wire read_req_bank, input wire [31:0] read_req_epoch,
    input wire [31:0] read_req_addr, output wire read_resp_valid,
    input wire read_resp_ready, output wire [127:0] read_resp_data,
    output wire read_resp_bank, output wire [31:0] read_resp_epoch,
    output wire [31:0] read_resp_addr,
    output wire ds1_done, output wire ds2_done, output wire done,
    output wire error, output wire [7:0] error_code,
    output wire [1:0] bank0_state, output wire [1:0] bank1_state,
    output wire [31:0] bank0_epoch, output wire [31:0] bank1_epoch,
    output wire active_read_bank, output wire [31:0] active_read_epoch,
    output wire active_write, output wire active_write_bank,
    output wire [31:0] write_epoch_active, output wire [31:0] write_count,
    output wire [31:0] write_expected_words, output wire write_last_seen,
    output wire atomic_swap
);
    // Admission is phase owned.  This is important when DS2 prefetch is
    // driven by a second engine: a valid on that interface must not steal the
    // single store before DS1 has published its result.  The phase advances
    // only on accepted start/commit handshakes (never merely on valid).
    localparam [2:0] PH_IDLE=3'd0, PH_DS1=3'd1, PH_DS1_COMMIT=3'd2,
                     PH_DS2=3'd3, PH_DS2_COMMIT=3'd4;
    reg [2:0] phase;
    wire ds1_phase = (phase == PH_IDLE) || (phase == PH_DS1);
    wire ds2_phase = (phase == PH_DS2);
    wire start_valid = (ds1_phase && ds1_start_valid) ||
                       (ds2_phase && ds2_start_valid);
    wire start_bank = ds2_phase ? ds2_start_bank : ds1_start_bank;
    wire [31:0] start_epoch = ds2_phase ? ds2_start_epoch : ds1_start_epoch;
    wire [31:0] start_words = ds2_phase ? ds2_start_words : ds1_start_words;
    wire w_valid = (ds1_phase && ds1_write_valid) ||
                   (ds2_phase && ds2_write_valid);
    wire w_bank  = ds2_phase ? ds2_write_bank : ds1_write_bank;
    wire [31:0] w_epoch = ds2_phase ? ds2_write_epoch : ds1_write_epoch;
    wire [31:0] w_addr  = ds2_phase ? ds2_write_addr : ds1_write_addr;
    wire [31:0] w_data  = ds2_phase ? ds2_write_data : ds1_write_data;
    wire [3:0] w_be = ds2_phase ? ds2_write_be : ds1_write_be;
    wire w_last = ds2_phase ? ds2_write_last : ds1_write_last;
    wire commit_valid = ((phase == PH_DS1) && ds1_commit_valid) ||
                        ((phase == PH_DS2) && ds2_commit_valid);
    wire commit_bank = (phase == PH_DS2) ? ds2_commit_bank : ds1_commit_bank;
    wire [31:0] commit_epoch = (phase == PH_DS2) ? ds2_commit_epoch : ds1_commit_epoch;
    wire start_ready, write_ready, commit_ready, commit_done;
    wire write_resp_valid;

    ds12_stream_dual_vector_activation_store #(.LINE_WORDS(LINE_WORDS))
    shared_store (
      .clk(clk), .rst_n(rst_n),
      .layer_start_valid(start_valid), .layer_start_ready(start_ready),
      .layer_start_bank(start_bank), .layer_start_epoch(start_epoch),
      .layer_start_expected_words(start_words),
      .write_valid(w_valid), .write_ready(write_ready), .write_bank(w_bank),
      .write_epoch(w_epoch), .write_addr(w_addr), .write_data(w_data),
      .write_be(w_be), .write_last(w_last), .write_resp_valid(write_resp_valid),
      .write_resp_ready(1'b1), .write_resp_bank(), .write_resp_epoch(),
      .write_resp_addr(), .layer_end_valid(commit_valid),
      .layer_end_ready(commit_ready), .layer_end_bank(commit_bank),
      .layer_end_epoch(commit_epoch), .commit_valid(1'b0), .commit_ready(),
      .commit_bank(1'b0), .commit_epoch(32'd0), .commit_done(commit_done),
      .layer_end_done(), .atomic_swap(atomic_swap),
      .read_req_valid(read_req_valid), .read_req_ready(read_req_ready),
      .read_req_bank(read_req_bank), .read_req_epoch(read_req_epoch),
      .read_req_addr(read_req_addr), .read_resp_valid(read_resp_valid),
      .read_resp_ready(read_resp_ready), .read_resp_data(read_resp_data),
      .read_resp_bank(read_resp_bank), .read_resp_epoch(read_resp_epoch),
      .read_resp_addr(read_resp_addr), .bank0_state(bank0_state),
      .bank1_state(bank1_state), .bank0_epoch(bank0_epoch),
      .bank1_epoch(bank1_epoch), .active_read_bank(active_read_bank),
      .active_read_epoch(active_read_epoch), .active_write(active_write),
      .active_write_bank(active_write_bank), .write_epoch_active(write_epoch_active),
      .write_count(write_count), .write_expected_words(write_expected_words),
      .write_last_seen(write_last_seen), .error(error), .error_code(error_code)
    );
    assign ds1_start_ready = start_ready && (phase == PH_IDLE);
    assign ds2_start_ready = start_ready && (phase == PH_DS2);
    assign ds1_write_ready = write_ready && ds1_phase;
    assign ds2_write_ready = write_ready && ds2_phase;
    assign ds1_commit_ready = commit_ready && (phase == PH_DS1);
    assign ds2_commit_ready = commit_ready && (phase == PH_DS2);
    reg ds1_done_r, ds2_done_r;
    assign ds1_done = ds1_done_r;
    assign ds2_done = ds2_done_r;
    assign done = ds1_done_r || ds2_done_r;
    always @(posedge clk) begin
      if (!rst_n) begin ds1_done_r <= 1'b0; ds2_done_r <= 1'b0; phase <= PH_IDLE; end
      else begin
        if (phase == PH_IDLE && ds1_start_valid && ds1_start_ready)
          phase <= PH_DS1;
        if (phase == PH_DS1 && ds1_commit_valid && ds1_commit_ready)
          phase <= PH_DS1_COMMIT;
        if (phase == PH_DS1_COMMIT && commit_done) begin
          ds1_done_r <= 1'b1;
          phase <= PH_DS2;
        end
        if (phase == PH_DS2 && ds2_start_valid && ds2_start_ready)
          phase <= PH_DS2;
        if (phase == PH_DS2 && ds2_commit_valid && ds2_commit_ready)
          phase <= PH_DS2_COMMIT;
        if (phase == PH_DS2_COMMIT && commit_done) begin
          ds2_done_r <= 1'b1;
          phase <= PH_IDLE;
        end
      end
    end
    // start is retained as an integration-visible run marker; clients own
    // the exact DS1/DS2 engine sequencing and transaction counts.
    wire unused_start = start;
endmodule
`default_nettype wire
