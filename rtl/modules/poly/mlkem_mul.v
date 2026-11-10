`timescale 1ns / 1ps

// Two-stage LUT multiplier: three narrow partial products, then one
// three-input add (balances the two stages).
(* use_dsp = "no" *)
module mlkem_mul #(
    parameter WA = 12,
    parameter WB = 12
)(
    input wire clk,
    input wire [WA-1:0] a,
    input wire [WB-1:0] b,
    output reg [WA+WB-1:0] p
);

    localparam W0 = WB / 3;
    localparam W1 = WB / 3;
    localparam W2 = WB - W0 - W1;

    reg [WA+W0-1:0] p0;
    reg [WA+W1-1:0] p1;
    reg [WA+W2-1:0] p2;

    always @(posedge clk) begin
        p0 <= a * b[W0-1:0];
        p1 <= a * b[W0+W1-1:W0];
        p2 <= a * b[WB-1:W0+W1];
        p <= {{(WB-W0){1'b0}}, p0} + ({{(WB-W1){1'b0}}, p1} << W0) + ({{(WB-W2){1'b0}}, p2} << (W0 + W1));
    end

endmodule
