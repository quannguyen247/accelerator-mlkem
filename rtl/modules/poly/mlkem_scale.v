`timescale 1ns / 1ps

// r = x * 2^e mod q = MontRed(x * (2^(e+16) mod q)) for the PMAC results,
// six stages (shift-add product: 2, MontRed: 4):
//   kg = 1  e = 16: 2^32 mod q = 1353 = 1281 + 72
//   kg = 0  e = 9:  2^25 mod q = 1441 = 1281 + 160
module mlkem_scale (
    input wire clk,
    input wire kg,
    input wire [11:0] x,
    output wire [11:0] r
);

    reg [22:0] pa, pb, p;
    always @(posedge clk) begin
        pa <= ({11'd0, x} << 10) + ({11'd0, x} << 8) + {11'd0, x};
        pb <= kg ? (({11'd0, x} << 6) + ({11'd0, x} << 3)) :
                   (({11'd0, x} << 7) + ({11'd0, x} << 5));
        p <= pa + pb;
    end

    mlkem_montred u_red (.clk(clk), .t({5'd0, p}), .r(r));

endmodule
