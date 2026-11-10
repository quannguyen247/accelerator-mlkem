`timescale 1ns / 1ps

// Fixed-latency register delay line (no reset; pair it with a reset valid line).
module mlkem_delay #(
    parameter W = 1,
    parameter D = 1
)(
    input wire clk,
    input wire [W-1:0] d,
    output wire [W-1:0] q
);

    generate
        if (D == 0) begin : g_wire
            assign q = d;
        end else begin : g_regs
            reg [W-1:0] sr [0:D-1];
            integer i;
            always @(posedge clk) begin
                sr[0] <= d;
                for (i = 1; i < D; i = i + 1)
                    sr[i] <= sr[i-1];
            end
            assign q = sr[D-1];
        end
    endgenerate

endmodule
