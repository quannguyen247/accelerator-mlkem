`timescale 1ns / 1ps
`include "ntt_defs.vh"

(* use_dsp = "no" *) module ntt_agu #(
    // 1: while start is low the address register follows idle_addr, so an
    // access of the caller shares the register and needs no mux behind it.
    // 0 (default): the register holds its value while start is low.
    parameter IDLE_ADDR = 0
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [7:0] len,
    input wire [7:0] pos,
    input wire [7:0] block_idx,
    input wire [7:0] idle_addr,
    output reg [7:0] addr_a,
    output reg [7:0] addr_b,
    // Bank (parity) of addr_a. addr_b = addr_a + len lies in the other bank.
    output reg bank_a
);

    // Block base = block_idx * (2 * len), low 8 bits. len is a power of two,
    // so the product is a shift selected by the set bit of len (a one-hot
    // mux instead of a multiplier). len = 128 shifts everything out.
    reg [7:0] block_base;
    integer i;

    always @(*) begin
        block_base = 8'd0;
        for (i = 0; i < 7; i = i + 1) begin
            if (len[i]) begin
                block_base = block_base | (block_idx << (i + 1));
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            addr_a <= 8'd0;
            addr_b <= 8'd0;
            bank_a <= 1'b0;
        end else begin
            if (start) begin
                addr_a <= block_base + pos;
                addr_b <= block_base + pos + len;
                // block_base (a multiple of 2 * len) and pos (below len)
                // share no bits, so the parity of the sum is their XOR.
                bank_a <= ^{block_base, pos};
            end else if (IDLE_ADDR != 0) begin
                addr_a <= idle_addr;
                bank_a <= ^idle_addr;
            end
        end
    end

endmodule
