`default_nettype none

/* verilator lint_off WIDTH */

module cnn_image_ram #(
    parameter DEPTH = 784,
    parameter DATA_WIDTH = 8,
    parameter HEX_FILE = "cnn_image.hex"
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         read_en,
    input  wire [31:0]                  addr,
    output reg                          data_valid,
    output reg  signed [DATA_WIDTH-1:0] data
);
    reg signed [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    initial begin
        $readmemh(HEX_FILE, mem);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            data_valid <= 1'b0;
            data       <= {DATA_WIDTH{1'b0}};
        end else begin
            data_valid <= read_en && (addr < DEPTH);

            if (read_en && (addr < DEPTH)) begin
                data <= mem[addr];
            end else begin
                data <= {DATA_WIDTH{1'b0}};
            end
        end
    end
endmodule

/* verilator lint_on WIDTH */
`default_nettype wire
