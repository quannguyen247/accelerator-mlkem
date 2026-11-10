`timescale 1ns / 1ps

// Number of SampleNTT candidates below q in a full SHAKE128 block (112
// candidates), three registered stages. Lets the hash engine decide at the
// squeeze handshake whether this block finishes the polynomial.
module mlkem_rej_count (
    input wire clk,
    input wire [1343:0] blk,
    output reg [6:0] cnt
);

    reg [111:0] ok;
    reg [3:0] part [0:7];
    integer i, g;
    reg [3:0] acc;
    reg [6:0] tot;

    always @(posedge clk) begin
        for (i = 0; i < 56; i = i + 1) begin
            ok[2*i] <= ({blk[24*i+11 -: 4], blk[24*i +: 8]} < 12'd3329);
            ok[2*i+1] <= ({blk[24*i+16 +: 8], blk[24*i+12 +: 4]} < 12'd3329);
        end
        for (g = 0; g < 8; g = g + 1) begin
            acc = 4'd0;
            for (i = 0; i < 14; i = i + 1)
                acc = acc + ok[14*g + i];
            part[g] <= acc;
        end
        tot = 7'd0;
        for (g = 0; g < 8; g = g + 1)
            tot = tot + part[g];
        cnt <= tot;
    end

endmodule
