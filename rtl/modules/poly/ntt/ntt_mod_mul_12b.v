`timescale 1ns / 1ps
`include "ntt_defs.vh"

(* use_dsp = "no" *) module ntt_mod_mul_12b (
    input wire clk,
    input wire [11:0] a_i,
    input wire [11:0] b_i,
    output reg [11:0] r_o
);

    // Stage 1: operands. b (the twiddle) comes straight from a register, so
    // its triple is formed here and the product needs no multiplier array.
    reg [11:0] a_reg, b_reg;
    reg [13:0] b3_reg;

    // Stage 2: radix-4 partial products a[2j+1:2j] * b, summed three by three
    wire [13:0] pp0, pp1, pp2, pp3, pp4, pp5;
    wire [17:0] sum_lo;
    wire [17:0] sum_hi;
    reg [17:0] sum_lo_reg;
    reg [17:0] sum_hi_reg;

    // Stage 3: product
    wire [23:0] t_comb;
    reg [23:0] t_reg;

    // Stages 4 and 5: two 8-bit Montgomery steps (together the 16-bit
    // reduction, t * 2^-16 mod q). As q = 1 mod 256, a step is
    //   (t + m q) / 256 with m = 256 - t[7:0]  =  (t >> 8) + q - 13 t[7:0],
    // a table of the low byte plus one two-input add (no wide multi-operand
    // adder). t1 < 2^16, t2 < 3512 < 2q; the result equals the R = 2^16
    // reduction for every t <= (q - 1)^2 (checked exhaustively).
    reg [15:0] t1_reg;
    reg [11:0] t2_reg;
    wire [12:0] sub_val;
    wire [11:0] reduced_comb;

    // Partial product digit * b for digit = 0..3
    function [13:0] radix4_pp;
        input [1:0] digit;
        input [11:0] b;
        input [13:0] b3;
        begin
            case (digit)
                2'd0: radix4_pp = 14'd0;
                2'd1: radix4_pp = {2'b00, b};
                2'd2: radix4_pp = {1'b0, b, 1'b0};
                default: radix4_pp = b3;
            endcase
        end
    endfunction

    // Registered operands break the INTT subtract -> multiply path.
    // Six-cycle latency: operands, partial sums, product, two Montgomery
    // steps, canonical result.
    always @(posedge clk) begin
        a_reg <= a_i;
        b_reg <= b_i;
        b3_reg <= {2'b00, b_i} + {1'b0, b_i, 1'b0};
    end

    assign pp0 = radix4_pp(a_reg[1:0], b_reg, b3_reg);
    assign pp1 = radix4_pp(a_reg[3:2], b_reg, b3_reg);
    assign pp2 = radix4_pp(a_reg[5:4], b_reg, b3_reg);
    assign pp3 = radix4_pp(a_reg[7:6], b_reg, b3_reg);
    assign pp4 = radix4_pp(a_reg[9:8], b_reg, b3_reg);
    assign pp5 = radix4_pp(a_reg[11:10], b_reg, b3_reg);

    // Two three-input adders, then (next stage) one two-input adder
    assign sum_lo = {4'd0, pp0} + {2'd0, pp1, 2'd0} + {pp2, 4'd0};
    assign sum_hi = {4'd0, pp3} + {2'd0, pp4, 2'd0} + {pp5, 4'd0};

    always @(posedge clk) begin
        sum_lo_reg <= sum_lo;
        sum_hi_reg <= sum_hi;
    end

    assign t_comb = {6'd0, sum_lo_reg} + {sum_hi_reg, 6'd0};

    always @(posedge clk) begin
        t_reg <= t_comb;
    end

    // q - 13 x for a byte x (14 .. 3329), a table in LUTs
    (* rom_style = "distributed" *) reg [11:0] kq [0:255];
    integer ki;
    initial begin
        for (ki = 0; ki < 256; ki = ki + 1)
            kq[ki] = 12'd3329 - 13 * ki;
    end

    always @(posedge clk) begin
        t1_reg <= t_reg[23:8] + {4'd0, kq[t_reg[7:0]]};
        t2_reg <= {4'd0, t1_reg[15:8]} + kq[t1_reg[7:0]];
    end

    assign sub_val = {1'b0, t2_reg} - 13'd3329;
    assign reduced_comb = sub_val[12] ? t2_reg : sub_val[11:0];

    always @(posedge clk) begin
        r_o <= reduced_comb;
    end

endmodule
