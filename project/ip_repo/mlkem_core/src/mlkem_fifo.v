`timescale 1ns / 1ps

// First-word-fall-through FIFO in distributed RAM. Decouples the hash engine
// from the input (ek, c) and output (KeyGen ek) streams. The pointers carry a
// wrap bit, so a push or pop only increments one pointer.
// The write port is registered: an accepted push is written one cycle later,
// so the memory's write enable, address and data come from flip-flops.
// Full is a registered flag on the words accepted (wptr): it rises when one
// free word is left, one cycle after the level got there, so at most one more
// push arrives and the FIFO never overflows. Empty is a registered flag on
// the words written (wptr_wr), exact: both sides see a flip-flop instead of
// a pointer compare.
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
    reg [AW:0] wptr;                // words accepted
    reg [AW:0] wptr_wr;             // words written
    reg [AW:0] rptr;

    // Registered write port
    reg wr_q;
    reg [W-1:0] din_q;

    // Words accepted, the "at most one free word" flag and the empty flag
    wire [AW:0] level = wptr - rptr;
    reg full_reg;
    reg empty_reg;

    wire do_push = push && !full_reg;
    wire do_pop = pop && !empty_reg;
    wire last_word = ((rptr + 1'b1) == wptr_wr);

    always @(posedge clk) begin
        din_q <= din;
        if (wr_q)
            mem[wptr_wr[AW-1:0]] <= din_q;
    end

    always @(posedge clk) begin
        if (!rst_n || clr) begin
            wptr <= {(AW+1){1'b0}};
            wptr_wr <= {(AW+1){1'b0}};
            rptr <= {(AW+1){1'b0}};
            wr_q <= 1'b0;
            full_reg <= 1'b0;
            empty_reg <= 1'b1;
        end else begin
            wr_q <= do_push;
            full_reg <= (level >= (1 << AW) - 1);
            if (wr_q)
                empty_reg <= 1'b0;
            else if (do_pop)
                empty_reg <= last_word;
            if (do_push)
                wptr <= wptr + 1'b1;
            if (wr_q)
                wptr_wr <= wptr_wr + 1'b1;
            if (do_pop)
                rptr <= rptr + 1'b1;
        end
    end

    assign full = full_reg;
    assign empty = empty_reg;
    assign dout = mem[rptr[AW-1:0]];

endmodule
