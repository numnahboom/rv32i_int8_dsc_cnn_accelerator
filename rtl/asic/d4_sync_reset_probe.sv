// Small reset-policy experiment, not part of the network datapath.
module d4_sync_reset_probe(input clk,rst_n,start,valid,
                           output reg [9:0] index,output reg active);
    always @(posedge clk) begin
        if(!rst_n) begin index<=0;active<=0;end
        else if(!active) begin
            if(start) begin index<=0;active<=1;end
        end else if(valid && index!=1023) index<=index+1;
    end
endmodule
