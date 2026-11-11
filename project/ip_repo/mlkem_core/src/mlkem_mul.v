`timescale 1ns / 1ps

// LUT multiplier, p = a * b (low WP bits).
//   STAGES = 2: three partial products (digits of at most ceil(WB/3) bits),
//               then one three-input add.
//   STAGES = 3: four partial products (digits of at most ceil(WB/4) bits),
//               then two two-input adds, then one; for operands whose
//               three-digit form would need digits wider than four bits.
(* use_dsp = "no" *)
module mlkem_mul #(
    parameter WA = 12,
    parameter WB = 12,
    parameter WP = WA + WB,
    parameter STAGES = 2
)(
    input wire clk,
    input wire [WA-1:0] a,
    input wire [WB-1:0] b,
    output reg [WP-1:0] p
);

    generate
        if (STAGES == 3) begin : g_s3
            localparam W0 = (WB + 3) / 4;
            localparam W1 = (WB + 2) / 4;
            localparam W2 = (WB + 1) / 4;
            localparam W3 = WB - W0 - W1 - W2;
            // Bits of p3 and of s23 that reach the WP kept bits
            localparam P3W = (WP - W0 - W1 - W2 < WA + W3) ? WP - W0 - W1 - W2 : WA + W3;
            localparam S23W = (WP - W0 - W1 < WA + W2 + W3) ? WP - W0 - W1 : WA + W2 + W3;

            reg [WA+W0-1:0] p0;
            reg [WA+W1-1:0] p1;
            reg [WA+W2-1:0] p2;
            reg [P3W-1:0] p3;
            reg [WA+W0+W1-1:0] s01;
            reg [S23W-1:0] s23;

            wire [WA+WB-1:0] e01 = s01;
            wire [WA+WB-1:0] e23 = s23;
            wire [WA+WB-1:0] sum = e01 + (e23 << (W0 + W1));

            always @(posedge clk) begin
                p0 <= a * b[W0-1:0];
                p1 <= a * b[W0+W1-1:W0];
                p2 <= a * b[W0+W1+W2-1:W0+W1];
                p3 <= a * b[WB-1:W0+W1+W2];
                s01 <= {{W1{1'b0}}, p0} + ({{W0{1'b0}}, p1} << W0);
                s23 <= {{(WA+W2+W3-(WA+W2)){1'b0}}, p2} + ({{(WA+W2+W3-P3W){1'b0}}, p3} << W2);
                p <= sum[WP-1:0];
            end
        end else begin : g_s2
            localparam W0 = (WB + 2) / 3;
            localparam W1 = (WB + 1) / 3;
            localparam W2 = WB - W0 - W1;
            localparam P2W = (WP - W0 - W1 < WA + W2) ? WP - W0 - W1 : WA + W2;

            reg [WA+W0-1:0] p0;
            reg [WA+W1-1:0] p1;
            reg [P2W-1:0] p2;

            wire [WA+WB-1:0] s0 = p0;
            wire [WA+WB-1:0] s1 = p1;
            wire [WA+WB-1:0] s2 = p2;
            wire [WA+WB-1:0] sum = s0 + (s1 << W0) + (s2 << (W0 + W1));

            always @(posedge clk) begin
                p0 <= a * b[W0-1:0];
                p1 <= a * b[W0+W1-1:W0];
                p2 <= a * b[WB-1:W0+W1];
                p <= sum[WP-1:0];
            end
        end
    endgenerate

endmodule
