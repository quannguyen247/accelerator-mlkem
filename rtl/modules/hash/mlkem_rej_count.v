`timescale 1ns / 1ps

// Number of SampleNTT candidates below q in a full SHAKE128 block (112
// candidates), four registered stages. Lets the hash engine decide at the
// squeeze handshake whether this block finishes the polynomial.
module mlkem_rej_count (
    input wire clk,
    input wire [1343:0] blk,
    output reg [6:0] cnt
);

    reg [111:0] ok;
    reg [2:0] pc7 [0:15];
    reg [3:0] part [0:7];
    integer i, g;

    // Number of accepted candidates in a group of 7
    function [2:0] count7;
        input [6:0] flags;
        integer n;
        begin
            count7 = 3'd0;
            for (n = 0; n < 7; n = n + 1)
                count7 = count7 + {2'd0, flags[n]};
        end
    endfunction

    always @(posedge clk) begin
        for (i = 0; i < 56; i = i + 1) begin
            ok[2*i] <= ({blk[24*i+11 -: 4], blk[24*i +: 8]} < 12'd3329);
            ok[2*i+1] <= ({blk[24*i+16 +: 8], blk[24*i+12 +: 4]} < 12'd3329);
        end
        for (g = 0; g < 16; g = g + 1)
            pc7[g] <= count7(ok[7*g +: 7]);
        for (g = 0; g < 8; g = g + 1)
            part[g] <= {1'b0, pc7[2*g]} + {1'b0, pc7[2*g+1]};
        cnt <= {3'd0, part[0]} + {3'd0, part[1]} + {3'd0, part[2]} + {3'd0, part[3]} +
               {3'd0, part[4]} + {3'd0, part[5]} + {3'd0, part[6]} + {3'd0, part[7]};
    end

endmodule
