`timescale 1ns / 1ps
`include "ntt_defs.vh"

module ntt_butterfly (
    input wire clk,
    input wire rst_n,
    input wire mode,
    input wire is_scale,
    input wire [11:0] a_i,
    input wire [11:0] b_i,
    input wire [11:0] zeta_i,
    input wire valid_i,
    output reg valid_o,
    output reg [11:0] out0,
    output reg [11:0] out1
);

    `include "ntt_funcs.vh"

    localparam [13:0] Q14 = `NTT_Q;
    localparam [11:0] Q12 = `NTT_Q;

    reg [11:0] a_st1;
    reg [11:0] b_st1;
    reg [11:0] zeta_st1;
    reg valid_st1;
    reg is_scale_st1;

    reg [11:0] a_st2, a_st3, a_st4, a_st5;
    reg [11:0] b_st2, b_st3, b_st4, b_st5;
    reg valid_st2, valid_st3, valid_st4, valid_st5;
    reg is_scale_st2, is_scale_st3, is_scale_st4, is_scale_st5;
    reg [11:0] a_st6, b_st6;
    reg valid_st6, is_scale_st6;
    reg [11:0] a_st7, b_st7;
    reg valid_st7, is_scale_st7;

    // Stage 8: both candidates of each modular add and subtract, so the
    // output stage only selects by a sign bit.
    //   out0: x + y and x + y - q, (x, y) = (a, b) for the INTT, else (a, m)
    //   out1: a - m and a - m + q (NTT)
    reg [11:0] s0_st8;              // a + y, used only when below q
    reg [13:0] r0_st8;
    reg [12:0] d1_st8;
    reg [11:0] e1_st8;
    reg [11:0] m_st8;
    reg valid_st8, is_scale_st8;

    wire [11:0] mul_a_in = is_scale_st1 ? a_st1 :
                         (mode ? ntt_mod_sub(a_st1, b_st1) : b_st1);

    wire [11:0] mod_mul_out;

    wire [11:0] y_st7;
    wire [11:0] out0_comb;
    wire [11:0] out1_comb;

    ntt_mod_mul_12b u_mul (
        .clk(clk),
        .a_i(mul_a_in),
        .b_i(zeta_st1),
        .r_o(mod_mul_out)
    );

    // Operands are canonical (below q), so one conditional correction is enough.
    assign y_st7 = mode ? b_st7 : mod_mul_out;
    assign out0_comb = is_scale_st8 ? m_st8 : (r0_st8[13] ? s0_st8 : r0_st8[11:0]);
    assign out1_comb = is_scale_st8 ? 12'd0 : (mode ? m_st8 : (d1_st8[12] ? e1_st8 : d1_st8[11:0]));

    always @(posedge clk) begin
        if (!rst_n) begin
            a_st1 <= 12'd0;
            b_st1 <= 12'd0;
            zeta_st1 <= 12'd0;
            valid_st1 <= 1'b0;
            is_scale_st1 <= 1'b0;
        end else begin
            // Operand isolation during input loading / idle. Use clock enables,
            // never a fabric-gated clock. Valid control still advances each cycle.
            if (valid_i) begin
                a_st1 <= a_i;
                b_st1 <= b_i;
                zeta_st1 <= zeta_i;
            end
            valid_st1 <= valid_i;
            is_scale_st1 <= is_scale;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            a_st2 <= 12'd0;
            b_st2 <= 12'd0;
            valid_st2 <= 1'b0;
            is_scale_st2 <= 1'b0;

            a_st3 <= 12'd0;
            b_st3 <= 12'd0;
            valid_st3 <= 1'b0;
            is_scale_st3 <= 1'b0;

            a_st4 <= 12'd0;
            b_st4 <= 12'd0;
            valid_st4 <= 1'b0;
            is_scale_st4 <= 1'b0;

            a_st5 <= 12'd0;
            b_st5 <= 12'd0;
            valid_st5 <= 1'b0;
            is_scale_st5 <= 1'b0;
            a_st6 <= 12'd0;
            b_st6 <= 12'd0;
            valid_st6 <= 1'b0;
            is_scale_st6 <= 1'b0;
            a_st7 <= 12'd0;
            b_st7 <= 12'd0;
            valid_st7 <= 1'b0;
            is_scale_st7 <= 1'b0;
            valid_st8 <= 1'b0;
            is_scale_st8 <= 1'b0;
        end else begin
            a_st2 <= a_st1;
            b_st2 <= b_st1;
            valid_st2 <= valid_st1;
            is_scale_st2 <= is_scale_st1;

            a_st3 <= a_st2;
            b_st3 <= b_st2;
            valid_st3 <= valid_st2;
            is_scale_st3 <= is_scale_st2;

            a_st4 <= a_st3;
            b_st4 <= b_st3;
            valid_st4 <= valid_st3;
            is_scale_st4 <= is_scale_st3;

            a_st5 <= a_st4;
            b_st5 <= b_st4;
            valid_st5 <= valid_st4;
            is_scale_st5 <= is_scale_st4;
            a_st6 <= a_st5;
            b_st6 <= b_st5;
            valid_st6 <= valid_st5;
            is_scale_st6 <= is_scale_st5;
            a_st7 <= a_st6;
            b_st7 <= b_st6;
            valid_st7 <= valid_st6;
            is_scale_st7 <= is_scale_st6;
            valid_st8 <= valid_st7;
            is_scale_st8 <= is_scale_st7;
        end
    end

    always @(posedge clk) begin
        s0_st8 <= a_st7 + y_st7;
        r0_st8 <= {2'b00, a_st7} + {2'b00, y_st7} - Q14;
        d1_st8 <= {1'b0, a_st7} - {1'b0, mod_mul_out};
        e1_st8 <= a_st7 + Q12 - mod_mul_out;
        m_st8 <= mod_mul_out;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_o <= 1'b0;
            out0 <= 12'd0;
            out1 <= 12'd0;
        end else begin
            valid_o <= valid_st8;
            out0 <= out0_comb;
            out1 <= out1_comb;
        end
    end

endmodule
