`timescale 1ns / 1ps

// Single-port distributed RAM of DEPTH 64-bit words with one write enable per
// byte lane: synchronous write, asynchronous read at the same address.
module mlkem_buf_ram #(
    parameter DEPTH = 592,
    parameter AW = 10
)(
    input wire clk,
    input wire [7:0] we,
    input wire [AW-1:0] addr,
    input wire [63:0] wdata,
    output wire [63:0] rdata
);

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : g_lane
            (* ram_style = "distributed" *) reg [7:0] mem [0:DEPTH-1];
            always @(posedge clk)
                if (we[b])
                    mem[addr] <= wdata[8*b +: 8];
            assign rdata[8*b +: 8] = mem[addr];
        end
    endgenerate

endmodule
