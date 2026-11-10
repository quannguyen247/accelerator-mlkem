`timescale 1ns / 1ps

// Producer progress for one polynomial slot: number of complete 8-coefficient
// blocks and the epoch tag of the current contents. The producer's first write
// of a new object sets the epoch; consumers wait for (ep, fill > block).
module mlkem_slot_state (
    input wire clk,
    input wire rst_n,
    input wire clr,
    input wire first,
    input wire first_ep,
    input wire inc,
    output reg [5:0] fill,
    output reg ep
);

    always @(posedge clk) begin
        if (!rst_n || clr) begin
            fill <= 6'd0;
            ep <= 1'b0;
        end else if (first) begin
            ep <= first_ep;
            fill <= inc ? 6'd1 : 6'd0;
        end else if (inc) begin
            fill <= fill + 6'd1;
        end
    end

endmodule
