`timescale 1ns/1ps
`default_nettype none
// 125 MHz, phase-aligned physical/core clock path for the D4 prototype.
// Generic simulation retains a 1:1 clock and models MMCM startup lock delay.
module d4_fullnet_clocking (
    input wire clk_in,
    input wire external_reset_n,
    output wire core_clk,
    output wire core_reset_n,
    output wire locked,
    output wire operational
);
`ifdef D4_USE_XILINX_CLOCKING
    wire clk_ibuf;
    wire clkfbout;
    wire clkfb_buf;
    wire clkout0;
    wire mmcm_locked;

    IBUF u_clk_input (.I(clk_in), .O(clk_ibuf));
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(8.000),
        .CLKFBOUT_PHASE(0.000),
        .CLKIN1_PERIOD(8.000),
        .CLKOUT0_DIVIDE_F(8.000),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKOUT0_PHASE(0.000),
        .DIVCLK_DIVIDE(1),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKFBOUT(clkfbout), .CLKFBOUTB(),
        .CLKOUT0(clkout0), .CLKOUT0B(),
        .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED(mmcm_locked),
        .CLKFBIN(clkfb_buf), .CLKIN1(clk_ibuf),
        .PWRDWN(1'b0), .RST(~external_reset_n)
    );
    BUFG u_clk_feedback (.I(clkfbout), .O(clkfb_buf));
    BUFG u_clk_core (.I(clkout0), .O(core_clk));
    assign locked = mmcm_locked;
`else
    localparam integer LOCK_DELAY_CYCLES = 8;
    reg [3:0] lock_count = 4'd0;
    reg sim_locked = 1'b0;

    assign core_clk = clk_in;
    assign locked = sim_locked;

    always @(posedge clk_in or negedge external_reset_n) begin
        if (!external_reset_n) begin
            lock_count <= 4'd0;
            sim_locked <= 1'b0;
        end else if (!sim_locked) begin
            if (lock_count == LOCK_DELAY_CYCLES-1) begin
                sim_locked <= 1'b1;
            end else begin
                lock_count <= lock_count + 1'b1;
            end
        end
    end
`endif

    // LOCKED only participates in the downstream reset path.  MMCM reset is
    // driven solely by the external reset; release takes two core-clock edges.
    wire downstream_reset_request_n = external_reset_n & locked;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg [1:0] reset_release_sync = 2'b00;
    always @(posedge core_clk or negedge downstream_reset_request_n) begin
        if (!downstream_reset_request_n)
            reset_release_sync <= 2'b00;
        else
            reset_release_sync <= {reset_release_sync[0], 1'b1};
    end
    assign core_reset_n = reset_release_sync[1];
    assign operational = core_reset_n;
endmodule
`default_nettype wire
