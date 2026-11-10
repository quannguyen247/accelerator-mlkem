`timescale 1ns / 1ps

// First-word-fall-through FIFO in distributed RAM. Decouples the hash engine
// from the input (ek, c) and output (KeyGen ek) streams. Empty comes from
// pointers with a wrap bit, so a push or pop only increments one pointer.
// Full is a registered flag: it rises when one free word is left, one cycle
// after the level got there, so at most one more push arrives and the FIFO
// never overflows. Producers see a flip-flop instead of a pointer compare.
module mlkem_fifo #(
    parameter W = 64,
    parameter AW = 8
)(
    input wire clk,
    input wire rst_n,
    input wire clr,
    input wire push,
    input wire [W-1:0] din,
    output wire full,
    input wire pop,
    output wire [W-1:0] dout,
    output wire empty
);

    (* ram_style = "distributed" *) reg [W-1:0] mem [0:(1<<AW)-1];
    reg [AW:0] wptr;
    reg [AW:0] rptr;

    // Words stored, and the "at most one free word" flag
    wire [AW:0] level = wptr - rptr;
    reg full_reg;

    wire do_push = push && !full_reg;
    wire do_pop = pop && !empty;

    always @(posedge clk) begin
        if (do_push)
            mem[wptr[AW-1:0]] <= din;
    end

    always @(posedge clk) begin
        if (!rst_n || clr) begin
            wptr <= {(AW+1){1'b0}};
            rptr <= {(AW+1){1'b0}};
            full_reg <= 1'b0;
        end else begin
            full_reg <= (level >= (1 << AW) - 1);
            if (do_push)
                wptr <= wptr + 1'b1;
            if (do_pop)
                rptr <= rptr + 1'b1;
        end
    end

    assign full = full_reg;
    assign empty = (wptr == rptr);
    assign dout = mem[rptr[AW-1:0]];

endmodule
