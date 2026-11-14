`timescale 1ns / 1ps

// Compress_d(x) = round(2^d * x / q) mod 2^d for canonical x, three stages.
// HI = 1 serves d in {10, 11}; HI = 0 serves d in {1, 4, 5}; HI = 2 serves
// all five (shared lanes; offsets checked exhaustively for every x < q). The constants
// are checked exhaustively by mlkem_gen.py (COMPRESS_CONSTS).
module mlkem_compress #(
    parameter HI = 1
)(
    input wire clk,
    input wire [11:0] x,
    input wire [3:0] d,
    output reg [10:0] y
);

    localparam KW = (HI != 0) ? 18 : 9;
    localparam [KW-1:0] K = (HI != 0) ? 18'd161271 : 9'd315;

    wire [12+KW-1:0] p;
    reg [3:0] d1, d2;

    generate
        if (HI == 2) begin : g_csd
            // x * 161271 = x * (2^17 + 2^15 - 2^11 - 2^9 - 2^3 - 1), two
            // registered partial sums (same two-cycle latency as mlkem_mul)
            reg [29:0] pa, pb;
            reg [29:0] pr;
            always @(posedge clk) begin
                pa <= ({18'd0, x} << 17) + ({18'd0, x} << 15) - ({18'd0, x} << 11);
                pb <= ({18'd0, x} << 9) + ({18'd0, x} << 3) + {18'd0, x};
                pr <= pa - pb;
            end
            assign p = pr;
        end else begin : g_mul
            mlkem_mul #(.WA(12), .WB(KW)) u_mul (.clk(clk), .a(x), .b(K), .p(p));
        end
    endgenerate

    always @(posedge clk) begin
        d1 <= d;
        d2 <= d1;
    end

    generate
        if (HI == 2) begin : g_all
            wire [30:0] s11 = {1'b0, p} + 31'd131032;
            wire [30:0] s10 = {1'b0, p} + 31'd262065;
            wire [30:0] s5 = {1'b0, p} + 31'd8388608;
            wire [30:0] s4 = {1'b0, p} + 31'd16777216;
            wire [30:0] s1 = {1'b0, p} + 31'd134217728;
            always @(posedge clk) begin
                case (d2)
                    4'd11: y <= s11[28:18];
                    4'd10: y <= {1'b0, s10[28:19]};
                    4'd1: y <= {10'd0, s1[28]};
                    4'd4: y <= {7'd0, s4[28:25]};
                    default: y <= {6'd0, s5[28:24]};
                endcase
            end
        end else if (HI) begin : g_hi
            wire [30:0] s11 = {1'b0, p} + 31'd131032;
            wire [30:0] s10 = {1'b0, p} + 31'd262065;
            always @(posedge clk)
                y <= (d2 == 4'd11) ? {s11[28:18]} : {1'b0, s10[28:19]};
        end else begin : g_lo
            wire [21:0] s1 = {1'b0, p} + 22'd262144;
            wire [21:0] s4 = {1'b0, p} + 22'd32768;
            wire [21:0] s5 = {1'b0, p} + 22'd16384;
            always @(posedge clk) begin
                case (d2)
                    4'd1: y <= {10'd0, s1[19]};
                    4'd4: y <= {7'd0, s4[19:16]};
                    default: y <= {6'd0, s5[19:15]};
                endcase
            end
        end
    endgenerate

endmodule
