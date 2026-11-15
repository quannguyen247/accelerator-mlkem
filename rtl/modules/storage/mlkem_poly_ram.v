`timescale 1ns / 1ps

// Eight-bank coefficient memory in distributed RAM. Coefficient n of a
// polynomial lives in bank n % 8 at word n / 8, so one read returns a block of
// eight consecutive coefficients while each bank accepts its own write.
//   RREG = 0  rdata is the block at raddr (asynchronous read)
//   RREG = 1  the read address is registered here (taken while ra_en) and
//             rdata is the block at that address: a one-cycle read whose
//             address comes from a register beside the memory, not from the
//             reader's logic.
module mlkem_poly_ram #(
    parameter W = 12,
    parameter AW = 5,
    parameter RREG = 0
)(
    input wire clk,
    input wire [7:0] we,
    input wire [8*AW-1:0] waddr,
    input wire [8*W-1:0] wdata,
    input wire ra_en,
    input wire [AW-1:0] raddr,
    output wire [8*W-1:0] rdata
);

    wire [AW-1:0] ra;
    generate
        if (RREG) begin : g_ra
            // kept: memories read at the same address must not share it
            (* keep = "true" *) reg [AW-1:0] ra_q;
            always @(posedge clk)
                if (ra_en)
                    ra_q <= raddr;
            assign ra = ra_q;
        end else begin : g_ra_none
            assign ra = raddr;
        end
    endgenerate

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : g_bank
            (* ram_style = "distributed" *) reg [W-1:0] mem [0:(1<<AW)-1];
            always @(posedge clk) begin
                if (we[b])
                    mem[waddr[b*AW +: AW]] <= wdata[b*W +: W];
            end
            assign rdata[b*W +: W] = mem[ra];
        end
    endgenerate

endmodule
