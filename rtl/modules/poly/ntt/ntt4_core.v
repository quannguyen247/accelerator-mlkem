`timescale 1ns / 1ps
`include "ntt_defs.vh"

// Four-butterfly NTT / INTT core (ML-KEM, q = 3329, 256 coefficients).
//
// Memory: four LUTRAM banks of 64 x 12 bits. Coefficient i lives in bank
// (i[1:0] + i[3:2] + i[5:4] + i[7:6]) mod 4 at word i[7:2]. Every group
// {b, b + L, b + 2L, b + 3L} with L a power of four and the base-4 digit of b
// at L equal to zero then covers the four banks, rotated by bank(b), so one
// group is read and one written per cycle without conflict.
//
// Passes (64 groups each, one group per cycle):
//   NTT  (Cooley-Tukey): layers 128+64 (L = 64), 32+16 (L = 16), 8+4 (L = 4),
//                        2 (L = 1, first stage only)
//   INTT (Gentleman-Sande): layer 2 (L = 1, second stage only), 4+8 (L = 4),
//                        16+32 (L = 16), 64+128 (L = 64)
// Stage pairings: A = (x0, x2), (x1, x3) with one twiddle; B = (x0, x1),
// (x2, x3) with two twiddles. NTT runs A then B, INTT runs B then A. The
// butterflies and the twiddle table are those of ntt_core_top, so the results
// equal ntt_core_top with INTT_SCALE = 0 (INTT result = 128 x inverse).
// A pass starts right after the previous one has issued its 64 groups, or 5
// cycles later between the L = 64 and L = 16 passes: every group then reads
// its coefficients at least 21 cycles after the previous pass issued them,
// so the write-back has landed (no read-after-write hazard).
//
// External port (core idle): group m = coefficients 4m .. 4m + 3, coefficient
// 4m + t in bits [12t +: 12].
//   write: ext_we / ext_waddr / ext_din, lands one cycle later
//   read:  ext_raddr, ext_dout valid in the next cycle (registered)
// A read and a write of the same group in one cycle return the old value.
module ntt4_core (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire mode,                     // 0: NTT, 1: INTT
    input wire ext_we,
    input wire [5:0] ext_waddr,
    input wire [47:0] ext_din,
    input wire [5:0] ext_raddr,
    output reg [47:0] ext_dout,
    output wire busy,
    output reg done
);

    localparam integer BF_LAT = 9;       // ntt_butterfly valid_i -> valid_o
    // Group issue (cycle c) to the write-back register input (cycle c + 20):
    // address register, read register, two butterfly stages.
    localparam integer WB_DLY = 1 + 2 * BF_LAT;

    // Rotation of a group base: sum of the base-4 digits mod 4
    function [1:0] bank_of;
        input [7:0] i;
        begin
            bank_of = i[1:0] + i[3:2] + i[5:4] + i[7:6];
        end
    endfunction

    // -------------------------------------------------------------------
    // Pass control
    reg run;
    reg mode_r;
    reg [1:0] pass;
    reg [6:0] g;                         // group counter, g >= 64: pass issued
    reg [5:0] pend;                      // groups issued, not yet written
    wire issue = run && !g[6];
    wire wb_v;                           // write-back of one group this cycle

    // Pass parameters: q = log4(L), single-stage passes
    reg [1:0] q;
    reg single;
    always @(*) begin
        if (!mode_r) begin
            q = 2'd3 - pass;             // 64, 16, 4, 1
            single = (pass == 2'd3);
        end else begin
            q = pass;                    // 1, 4, 16, 64
            single = (pass == 2'd0);
        end
    end

    assign busy = run;

    // Last cycle of a pass before the next one issues: 5 idle cycles after
    // the L = 64 pass (NTT) or before it (INTT).
    wire gap5 = mode_r ? (pass == 2'd2) : (pass == 2'd0);
    wire [6:0] g_last = gap5 ? 7'd68 : 7'd63;

    always @(posedge clk) begin
        if (!rst_n) begin
            run <= 1'b0;
            mode_r <= 1'b0;
            pass <= 2'd0;
            g <= 7'd0;
            pend <= 6'd0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            pend <= pend + {5'd0, issue} - {5'd0, wb_v};
            if (!run) begin
                if (start) begin
                    run <= 1'b1;
                    mode_r <= mode;
                    pass <= 2'd0;
                    g <= 7'd0;
                end
            end else if (pass != 2'd3) begin
                if (g == g_last) begin
                    pass <= pass + 2'd1;
                    g <= 7'd0;
                end else begin
                    g <= g + 7'd1;
                end
            end else if (issue) begin
                g <= g + 7'd1;
            end else if (pend == 6'd0) begin
                // Last pass issued and written back
                run <= 1'b0;
                done <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------
    // Issue (cycle c): group base, bank rotation, word addresses, twiddles
    reg [7:0] b_c;
    reg [5:0] hb_c;                      // b / (4L)
    always @(*) begin
        case (q)
            2'd0: begin b_c = {g[5:0], 2'b00};          hb_c = g[5:0]; end
            2'd1: begin b_c = {g[5:2], 2'b00, g[1:0]};   hb_c = {2'd0, g[5:2]}; end
            2'd2: begin b_c = {g[5:4], 2'b00, g[3:0]};   hb_c = {4'd0, g[5:4]}; end
            default: begin b_c = {2'b00, g[5:0]};        hb_c = 6'd0; end
        endcase
    end

    reg [7:0] step_c;                    // L
    always @(*) begin
        case (q)
            2'd0: step_c = 8'd1;
            2'd1: step_c = 8'd4;
            2'd2: step_c = 8'd16;
            default: step_c = 8'd64;
        endcase
    end

    // Twiddle indices. CT: zA = 64/L + hb, zB = 128/L + 2 hb.
    // GS: zA = 128 - 128/L + hb, zB = 128 - 256/L + 2 hb.
    reg [6:0] za_c, zb_c;
    always @(*) begin
        if (!mode_r) begin
            za_c = (7'd64 >> (2 * q)) + {1'b0, hb_c};
            zb_c = ((q == 2'd0) ? 7'd0 : (8'd128 >> (2 * q))) + {hb_c, 1'b0};
        end else begin
            za_c = (8'd128 - (8'd128 >> (2 * q))) + {1'b0, hb_c};
            zb_c = (8'd128 - (9'd256 >> (2 * q))) + {hb_c, 1'b0};
        end
    end

    // Word address per bank: bank k holds element (k - bank(b)) mod 4
    wire [1:0] r_c = bank_of(b_c);
    reg [5:0] ra_c [0:3];
    reg [1:0] el;
    reg [7:0] ei;
    integer t;
    always @(*) begin
        for (t = 0; t < 4; t = t + 1) begin
            el = t[1:0] - r_c;
            ei = b_c + el * step_c;
            ra_c[t] = ei[7:2];
        end
    end

    // Cycle c + 1: registered bank addresses, rotation, twiddle indices
    reg v1;
    reg [1:0] r1;
    reg [5:0] ra1 [0:3];
    reg [6:0] za1, zb1;
    reg single1;
    always @(posedge clk) begin
        if (!rst_n)
            v1 <= 1'b0;
        else
            v1 <= issue;
        single1 <= single;
        r1 <= r_c;
        za1 <= za_c;
        zb1 <= zb_c;
        for (t = 0; t < 4; t = t + 1)
            ra1[t] <= ra_c[t];
    end

    // -------------------------------------------------------------------
    // Banks
    reg [5:0] bk_ra [0:3];
    wire [11:0] bk_rd [0:3];
    reg bk_we [0:3];
    reg [5:0] bk_wa [0:3];
    reg [11:0] bk_wd [0:3];

    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_bank
            (* ram_style = "distributed" *) reg [11:0] mem [0:63];
            always @(posedge clk) begin
                if (bk_we[k])
                    mem[bk_wa[k]] <= bk_wd[k];
            end
            assign bk_rd[k] = mem[bk_ra[k]];
        end
    endgenerate

    wire [1:0] ext_rr = bank_of({ext_raddr, 2'b00});
    always @(*) begin
        for (t = 0; t < 4; t = t + 1)
            bk_ra[t] = run ? ra1[t] : ext_raddr;
    end

    // External read data, registered
    always @(posedge clk) begin
        for (t = 0; t < 4; t = t + 1)
            ext_dout[12*t +: 12] <= bk_rd[(ext_rr + t) % 4];
    end

    // Cycle c + 2: operands and twiddles
    reg v2;
    reg [11:0] x2 [0:3];
    wire [11:0] za_d, zb0_d, zb1_d;
    reg [11:0] za2, zb02, zb12;
    ntt_twiddle_rom u_rom_a (.addr(za1), .is_inv(mode_r), .d_out(za_d));
    // zB is always even (both stage bases and 2 hb are even), so the two
    // B twiddles come from half tables: even entries and odd entries.
    `include "ntt_funcs.vh"
    (* rom_style = "distributed" *) reg [11:0] rom_b0 [0:127];
    (* rom_style = "distributed" *) reg [11:0] rom_b1 [0:127];
    integer ri;
    initial begin
        for (ri = 0; ri < 128; ri = ri + 1) begin
            rom_b0[ri] = ntt_twiddle_u({ri[5:0], 1'b0}, ri[6]);
            rom_b1[ri] = ntt_twiddle_u({ri[5:0], 1'b1}, ri[6]);
        end
    end
    assign zb0_d = rom_b0[{mode_r, zb1[6:1]}];
    assign zb1_d = rom_b1[{mode_r, zb1[6:1]}];
    always @(posedge clk) begin
        if (!rst_n)
            v2 <= 1'b0;
        else
            v2 <= v1 && run;
        for (t = 0; t < 4; t = t + 1)
            x2[t] <= bk_rd[(r1 + t) % 4];
        za2 <= za_d;
        zb02 <= zb0_d;
        zb12 <= zb1_d;
    end

    // -------------------------------------------------------------------
    // Butterfly stages. Stage 1: NTT pairing A (zA), INTT pairing B (zB0, zB1).
    // Stage 2: NTT pairing B, INTT pairing A. A single-layer pass bypasses
    // stage 2 (NTT) or stage 1 (INTT) through a delay line.
    // Passes overlap in the pipeline, so the single-layer flag travels with
    // the group: to stage 1 output (c + 11) and stage 2 output (c + 20).
    wire single_s1, single_s2;
    mlkem_delay #(.W(1), .D(BF_LAT + 1)) u_dsg1 (.clk(clk), .d(single1), .q(single_s1));
    mlkem_delay #(.W(1), .D(2 * BF_LAT + 1)) u_dsg2 (.clk(clk), .d(single1), .q(single_s2));
    wire s1_bypass = mode_r && single_s1;
    wire s2_bypass = !mode_r && single_s2;

    // Stage 1 inputs
    wire [11:0] s1a_a = x2[0];
    wire [11:0] s1a_b = mode_r ? x2[1] : x2[2];
    wire [11:0] s1b_a = mode_r ? x2[2] : x2[1];
    wire [11:0] s1b_b = x2[3];
    wire [11:0] s1a_z = mode_r ? zb02 : za2;
    wire [11:0] s1b_z = mode_r ? zb12 : za2;

    wire s1a_v, s1b_v_unused;
    wire [11:0] s1a_o0, s1a_o1, s1b_o0, s1b_o1;
    ntt_butterfly u_bf1a (
        .clk(clk), .rst_n(rst_n), .mode(mode_r), .is_scale(1'b0),
        .a_i(s1a_a), .b_i(s1a_b), .zeta_i(s1a_z), .valid_i(v2),
        .valid_o(s1a_v), .out0(s1a_o0), .out1(s1a_o1));
    ntt_butterfly u_bf1b (
        .clk(clk), .rst_n(rst_n), .mode(mode_r), .is_scale(1'b0),
        .a_i(s1b_a), .b_i(s1b_b), .zeta_i(s1b_z), .valid_i(v2),
        .valid_o(s1b_v_unused), .out0(s1b_o0), .out1(s1b_o1));

    // Stage 1 outputs in group order
    wire [47:0] x2_bus = {x2[3], x2[2], x2[1], x2[0]};
    wire [47:0] x2_dly;
    mlkem_delay #(.W(48), .D(BF_LAT)) u_dx2 (.clk(clk), .d(x2_bus), .q(x2_dly));
    wire [11:0] y [0:3];
    assign y[0] = s1_bypass ? x2_dly[11:0]  : s1a_o0;
    assign y[1] = s1_bypass ? x2_dly[23:12] : (mode_r ? s1a_o1 : s1b_o0);
    assign y[2] = s1_bypass ? x2_dly[35:24] : (mode_r ? s1b_o0 : s1a_o1);
    assign y[3] = s1_bypass ? x2_dly[47:36] : s1b_o1;

    // Stage 2 twiddles
    wire [35:0] z_dly;
    mlkem_delay #(.W(36), .D(BF_LAT)) u_dz (.clk(clk), .d({zb12, zb02, za2}), .q(z_dly));
    wire [11:0] za_s2 = z_dly[11:0];
    wire [11:0] zb0_s2 = z_dly[23:12];
    wire [11:0] zb1_s2 = z_dly[35:24];

    wire [11:0] s2a_a = y[0];
    wire [11:0] s2a_b = mode_r ? y[2] : y[1];
    wire [11:0] s2b_a = mode_r ? y[1] : y[2];
    wire [11:0] s2b_b = y[3];
    wire [11:0] s2a_z = mode_r ? za_s2 : zb0_s2;
    wire [11:0] s2b_z = mode_r ? za_s2 : zb1_s2;

    wire s2a_v, s2b_v_unused;
    wire [11:0] s2a_o0, s2a_o1, s2b_o0, s2b_o1;
    ntt_butterfly u_bf2a (
        .clk(clk), .rst_n(rst_n), .mode(mode_r), .is_scale(1'b0),
        .a_i(s2a_a), .b_i(s2a_b), .zeta_i(s2a_z), .valid_i(s1a_v),
        .valid_o(s2a_v), .out0(s2a_o0), .out1(s2a_o1));
    ntt_butterfly u_bf2b (
        .clk(clk), .rst_n(rst_n), .mode(mode_r), .is_scale(1'b0),
        .a_i(s2b_a), .b_i(s2b_b), .zeta_i(s2b_z), .valid_i(s1a_v),
        .valid_o(s2b_v_unused), .out0(s2b_o0), .out1(s2b_o1));

    wire [47:0] y_bus = {y[3], y[2], y[1], y[0]};
    wire [47:0] y_dly;
    mlkem_delay #(.W(48), .D(BF_LAT)) u_dy (.clk(clk), .d(y_bus), .q(y_dly));
    wire [11:0] w [0:3];
    assign w[0] = s2_bypass ? y_dly[11:0]  : s2a_o0;
    assign w[1] = s2_bypass ? y_dly[23:12] : (mode_r ? s2b_o0 : s2a_o1);
    assign w[2] = s2_bypass ? y_dly[35:24] : (mode_r ? s2a_o1 : s2b_o0);
    assign w[3] = s2_bypass ? y_dly[47:36] : s2b_o1;
    assign wb_v = s2a_v;

    // Write-back addresses and rotation, delayed from cycle c + 1
    wire [25:0] wa_dly;
    mlkem_delay #(.W(26), .D(WB_DLY)) u_dwa (.clk(clk),
        .d({r1, ra1[3], ra1[2], ra1[1], ra1[0]}), .q(wa_dly));
    wire [1:0] r_wb = wa_dly[25:24];

    // Registered bank write ports: write-back while running, else external
    wire [1:0] ext_wr = bank_of({ext_waddr, 2'b00});
    always @(posedge clk) begin
        for (t = 0; t < 4; t = t + 1) begin
            if (run) begin
                bk_we[t] <= wb_v;
                bk_wa[t] <= wa_dly[6*t +: 6];
                bk_wd[t] <= w[(t + 4 - r_wb) % 4];
            end else begin
                bk_we[t] <= ext_we;
                bk_wa[t] <= ext_waddr;
                bk_wd[t] <= ext_din[12*((t + 4 - ext_wr) % 4) +: 12];
            end
        end
    end

endmodule
