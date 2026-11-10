`timescale 1ns / 1ps

// Eight-bank coefficient memory in distributed RAM. Coefficient n of a
// polynomial lives in bank n % 8 at word n / 8, so one read returns a block of
// eight consecutive coefficients while each bank accepts its own write.
module mlkem_poly_ram #(
    parameter W = 12,
    parameter AW = 5
)(
    input wire clk,
    input wire [7:0] we,
    input wire [8*AW-1:0] waddr,
    input wire [8*W-1:0] wdata,
    input wire [AW-1:0] raddr,
    output wire [8*W-1:0] rdata
);

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : g_bank
            (* ram_style = "distributed" *) reg [W-1:0] mem [0:(1<<AW)-1];
            always @(posedge clk) begin
                if (we[b])
                    mem[waddr[b*AW +: AW]] <= wdata[b*W +: W];
            end
            assign rdata[b*W +: W] = mem[raddr];
        end
    endgenerate

endmodule
