`default_nettype none

/* verilator lint_off WIDTH */

module line_buffer #(
    parameter IMG_W = 28,
    parameter IMG_H = 28,
    parameter PIXEL_WIDTH = 8
) (
    input  wire                             clk,
    input  wire                             rst_n,
    input  wire                             clear,
    input  wire                             pixel_valid,
    input  wire signed [PIXEL_WIDTH-1:0]    pixel_in,
    output wire                             pixel_ready,
    output reg                              col_valid,
    output reg                              window_valid,
    output reg  signed [3*PIXEL_WIDTH-1:0]  pixels_col,
    output reg                              frame_done
);
    reg [31:0] row;
    reg [31:0] col;

    reg signed [PIXEL_WIDTH-1:0] line0 [0:IMG_W-1];
    reg signed [PIXEL_WIDTH-1:0] line1 [0:IMG_W-1];

    wire accept;
    wire last_col;
    wire last_row;

    assign pixel_ready = 1'b1;
    assign accept      = pixel_valid && pixel_ready;
    assign last_col    = (col == IMG_W - 1);
    assign last_row    = (row == IMG_H - 1);

    always @(posedge clk) begin
        if (!rst_n || clear) begin
            row          <= 32'd0;
            col          <= 32'd0;
            col_valid    <= 1'b0;
            window_valid <= 1'b0;
            pixels_col   <= {(3*PIXEL_WIDTH){1'b0}};
            frame_done   <= 1'b0;
        end else begin
            col_valid    <= 1'b0;
            window_valid <= 1'b0;
            frame_done   <= 1'b0;
            pixels_col   <= {(3*PIXEL_WIDTH){1'b0}};

            if (accept) begin
                pixels_col <= {pixel_in, line0[col], line1[col]};

                col_valid    <= (row >= 32'd2);
                window_valid <= (row >= 32'd2) && (col >= 32'd2);
                frame_done   <= last_row && last_col;

                line1[col] <= line0[col];
                line0[col] <= pixel_in;

                if (last_col) begin
                    col <= 32'd0;
                    if (last_row) begin
                        row <= 32'd0;
                    end else begin
                        row <= row + 32'd1;
                    end
                end else begin
                    col <= col + 32'd1;
                end
            end
        end
    end
endmodule

/* verilator lint_on WIDTH */
`default_nettype wire
