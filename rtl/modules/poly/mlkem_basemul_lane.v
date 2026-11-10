`timescale 1ns / 1ps

// One coefficient-pair lane of the multiply-accumulate unit.
// Accumulates c0 = a0*b0 + a1*b1*gamma and c1 = a0*b1 + a1*b0 over the
// terms of one group (in_last marks the final term), then returns
// (c0, c1) * 2^-16 mod q.
// g is gamma * 2^16 mod q, so the inner Montgomery step stays exact.
// Lazy reduction is safe for up to four accumulated terms (sum < q * 2^16).
module mlkem_basemul_lane (
    input wire clk,
    input wire rst_n,

    // Operands (one term per cycle)
    input wire in_valid,
    input wire in_last,
    input wire [11:0] a0,
    input wire [11:0] a1,
    input wire [11:0] b0,
    input wire [11:0] b1,
    input wire [11:0] g,

    // Reduced sum of the group
    output wire out_valid,
    output wire [11:0] r0,
    output wire [11:0] r1
);

    // Stages from the operands to the accumulator input
    localparam LAT_ACC = 10;

    // Stage 1: operands and Karatsuba sums.
    // Kept per lane: the two row groups share their V operands, and merging
    // these registers would put both groups' multipliers on one fanout net.
    (* keep = "true" *) reg [11:0] a0_reg, a1_reg, b0_reg, b1_reg;
    (* keep = "true" *) reg [12:0] sa_reg, sb_reg;
    reg [11:0] g_reg;

    // Stage 3: products
    wire [23:0] m00;
    wire [23:0] m11;
    wire [25:0] mk;

    // Stage 9: a1*b1*gamma and the aligned products
    wire [11:0] t7;
    wire [11:0] g7;
    wire [23:0] z9;
    wire [23:0] m00_9;
    wire [23:0] m11_9;
    wire [25:0] mk_9;

    // Stage 10: one term of each sum
    reg [24:0] c0_reg;
    reg [24:0] c1_reg;

    // Valid / last flags travelling with the term
    reg [LAT_ACC-1:0] valid_sr;
    reg [LAT_ACC-1:0] last_sr;

    // Accumulator. The strobes are registered one stage ahead and kept per
    // lane, so the adder carry chain drives the registers directly and the
    // enable / clear nets stay inside the lane.
    (* keep = "true" *) reg acc_en_reg;
    (* keep = "true" *) reg acc_clr_reg;
    reg [27:0] acc0_reg, acc1_reg;
    reg [27:0] sum0_reg, sum1_reg;
    reg sum_valid_reg;
    reg [3:0] out_valid_sr;

    wire [27:0] acc0_next = acc0_reg + {3'd0, c0_reg};
    wire [27:0] acc1_next = acc1_reg + {3'd0, c1_reg};

    mlkem_mul #(.WA(12), .WB(12)) u_m00 (.clk(clk), .a(a0_reg), .b(b0_reg), .p(m00));
    mlkem_mul #(.WA(12), .WB(12)) u_m11 (.clk(clk), .a(a1_reg), .b(b1_reg), .p(m11));
    mlkem_mul #(.WA(13), .WB(13)) u_mk  (.clk(clk), .a(sa_reg), .b(sb_reg), .p(mk));

    mlkem_montred u_red_m11 (.clk(clk), .t({4'd0, m11}), .r(t7));
    mlkem_delay #(.W(12), .D(6)) u_dg (.clk(clk), .d(g_reg), .q(g7));
    mlkem_mul #(.WA(12), .WB(12)) u_mz (.clk(clk), .a(t7), .b(g7), .p(z9));

    mlkem_delay #(.W(24), .D(6)) u_d00 (.clk(clk), .d(m00), .q(m00_9));
    mlkem_delay #(.W(24), .D(6)) u_d11 (.clk(clk), .d(m11), .q(m11_9));
    mlkem_delay #(.W(26), .D(6)) u_dk  (.clk(clk), .d(mk), .q(mk_9));

    mlkem_montred u_red0 (.clk(clk), .t(sum0_reg), .r(r0));
    mlkem_montred u_red1 (.clk(clk), .t(sum1_reg), .r(r1));

    // Operand and term registers
    always @(posedge clk) begin
        a0_reg <= a0;
        a1_reg <= a1;
        b0_reg <= b0;
        b1_reg <= b1;
        g_reg <= g;
        sa_reg <= a0 + a1;
        sb_reg <= b0 + b1;
        c0_reg <= {1'b0, m00_9} + {1'b0, z9};
        c1_reg <= mk_9 - {2'b0, m00_9} - {2'b0, m11_9};
    end

    // Flag pipeline update
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_sr <= {LAT_ACC{1'b0}};
            acc_en_reg <= 1'b0;
            acc_clr_reg <= 1'b1;
            sum_valid_reg <= 1'b0;
            out_valid_sr <= 4'd0;
        end else begin
            valid_sr <= {valid_sr[LAT_ACC-2:0], in_valid};
            acc_en_reg <= valid_sr[LAT_ACC-2];
            acc_clr_reg <= valid_sr[LAT_ACC-2] && last_sr[LAT_ACC-2];
            sum_valid_reg <= valid_sr[LAT_ACC-1] && last_sr[LAT_ACC-1];
            out_valid_sr <= {out_valid_sr[2:0], sum_valid_reg};
        end
        last_sr <= {last_sr[LAT_ACC-2:0], in_last};
    end

    // Accumulator update: the last term leaves the accumulator at zero, so the
    // first term of the next group needs no bypass in front of the adder.
    always @(posedge clk) begin
        if (acc_clr_reg) begin
            acc0_reg <= 28'd0;
            acc1_reg <= 28'd0;
        end else if (acc_en_reg) begin
            acc0_reg <= acc0_next;
            acc1_reg <= acc1_next;
        end
        sum0_reg <= acc0_next;
        sum1_reg <= acc1_next;
    end

    assign out_valid = out_valid_sr[3];

endmodule
