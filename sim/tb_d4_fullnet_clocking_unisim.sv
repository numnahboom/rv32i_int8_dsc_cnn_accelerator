`timescale 1ns/1ps
module tb_d4_fullnet_clocking_unisim;
    reg clk_in=0;
    reg run_clk=1;
    reg rst_n=0;
    wire core_clk,core_reset_n,locked,operational;
    wire ready_qualified=operational;
    integer core_edges=0;
    integer spin;
    integer edges_at_lock;
    time edge_time, period_ns;

    always #4 begin
        if(run_clk) clk_in=~clk_in;
        else clk_in=0;
    end
    always @(posedge core_clk) core_edges=core_edges+1;

    d4_fullnet_clocking dut (
        .clk_in(clk_in),.external_reset_n(rst_n),.core_clk(core_clk),
        .core_reset_n(core_reset_n),.locked(locked),.operational(operational)
    );

    task automatic wait_for_lock;
        integer n;
        begin
            n=0;
            while(locked!==1'b1 && n<50000) begin #1; n=n+1; end
            if(locked!==1'b1) $fatal(1,"MMCM_LOCK_TIMEOUT reset_n=%0b",rst_n);
            #1;
        end
    endtask

    task automatic wait_for_operational;
        integer n;
        begin
            n=0;
            while(operational!==1'b1 && n<100) begin
                @(posedge core_clk); #1; n=n+1;
            end
            if(operational!==1'b1) $fatal(1,"DOWNSTREAM_RESET_RELEASE_TIMEOUT");
            if(core_edges-edges_at_lock<2)
                $fatal(1,"RESET_RELEASE_TOO_EARLY edges=%0d",core_edges-edges_at_lock);
            if(ready_qualified!==1'b1) $fatal(1,"READY_MASK_NOT_RELEASED");
        end
    endtask

    initial begin
        // Allow startup/reset logic to settle while the external reset is low.
        repeat(5) @(posedge clk_in);
        #1;
        if(locked!==1'b0 || core_reset_n!==1'b0 || operational!==1'b0 || ready_qualified!==1'b0)
            $fatal(1,"RESET_STATE locked=%b core_reset_n=%b operational=%b",locked,core_reset_n,operational);

        rst_n=1;
        repeat(3) @(posedge clk_in);
        #1;
        if(locked!==1'b0 || operational!==1'b0 || ready_qualified!==1'b0)
            $fatal(1,"LOCK_OR_READY_WAS_NOT_DELAYED");
        wait_for_lock();
        if(core_reset_n!==1'b0 || operational!==1'b0 || ready_qualified!==1'b0)
            $fatal(1,"READY_EXPOSED_BEFORE_RESET_SYNCHRONIZER");
        edges_at_lock=core_edges;
        wait_for_operational();

        @(posedge core_clk); edge_time=$time;
        @(posedge core_clk); period_ns=$time-edge_time;
        if(period_ns!=8) $fatal(1,"BAD_CORE_PERIOD_NS period=%0t",period_ns);
        $display("D4_CLOCKING_NATIVE_LOCK_PASS period_ns=%0t startup_edges=%0d",period_ns,core_edges-edges_at_lock);

        // External reset asserts the downstream reset immediately and resets
        // the MMCM itself; readiness remains masked until lock and two edges.
        @(negedge clk_in); rst_n=0; #1;
        if(core_reset_n!==1'b0 || operational!==1'b0 || ready_qualified!==1'b0)
            $fatal(1,"EXTERNAL_RESET_DID_NOT_MASK_READY");
        for(spin=0;spin<5000 && locked!==1'b0;spin=spin+1) #1;
        if(locked!==1'b0) $fatal(1,"MMCM_LOCK_DID_NOT_DROP_ON_EXTERNAL_RESET");
        repeat(4) @(posedge clk_in);
        rst_n=1;
        wait_for_lock();
        if(core_reset_n!==1'b0 || operational!==1'b0) $fatal(1,"RESET_RELEASED_WITHOUT_CLOCK_EDGES");
        edges_at_lock=core_edges;
        wait_for_operational();
        $display("D4_CLOCKING_EXTERNAL_RESET_RELOCK_PASS edges=%0d",core_edges-edges_at_lock);

        // The native UNISIM model should detect a stopped reference clock and
        // drop LOCKED.  Reset is then required before it can lock again.
        @(negedge clk_in); run_clk=0;
        for(spin=0;spin<5000 && locked!==1'b0;spin=spin+1) #1;
        if(locked!==1'b0) $fatal(1,"MMCM_DID_NOT_LOSE_LOCK_AFTER_INPUT_STOP");
        #1;
        if(core_reset_n!==1'b0 || operational!==1'b0 || ready_qualified!==1'b0)
            $fatal(1,"LOCK_LOSS_DID_NOT_ASSERT_DOWNSTREAM_RESET");
        $display("D4_CLOCKING_INPUT_STOP_LOSS_PASS");

        run_clk=1;
        repeat(8) @(posedge clk_in);
        if(locked!==1'b0)
            $fatal(1,"UNEXPECTED_RELOCK_WITHOUT_EXTERNAL_RESET");
        rst_n=0;
        repeat(4) @(posedge clk_in);
        rst_n=1;
        wait_for_lock();
        edges_at_lock=core_edges;
        wait_for_operational();
        $display("D4_CLOCKING_INPUT_RESTART_RELOCK_PASS edges=%0d",core_edges-edges_at_lock);
        $display("D4_CLOCKING_UNISIM_PASS");
        $finish;
    end
endmodule
