`timescale 1ns / 1ps
`include "ntt_defs.vh"

module ntt_ram_dual #(
    parameter DEPTH = 256,
    parameter ADDR_WIDTH = 8,
    // 1: the write ports are registered behind the bank steering, so the RAM
    // pins are driven by flip-flops and a write lands one cycle later.
    // 0 (default): a write lands in the cycle it is presented.
    parameter WR_REG = 0
)(
    input wire clk,
    // Every port takes the bank of its address (the parity of the full
    // address), supplied by the caller so it can come from a register, and
    // the word inside the bank (the address without its top bit).
    input wire we0,
    input wire bank_wr0,
    input wire [ADDR_WIDTH-2:0] addr_wr0,
    input wire [11:0] din0,
    input wire we1,
    input wire bank_wr1,
    input wire [ADDR_WIDTH-2:0] addr_wr1,
    input wire [11:0] din1,
    input wire bank_rd0,
    input wire [ADDR_WIDTH-2:0] addr_rd0,
    input wire bank_rd1,
    input wire [ADDR_WIDTH-2:0] addr_rd1,
    output wire [11:0] dout0,
    output wire [11:0] dout1
);

    reg [11:0] bank0 [0:127];
    reg [11:0] bank1 [0:127];

    // Bank steering: the two write ports never address the same bank.
    wire write_to_bank0 = (we0 && (bank_wr0 == 1'b0)) || (we1 && (bank_wr1 == 1'b0));
    wire [6:0] addr_wr_bank0 = (we0 && (bank_wr0 == 1'b0)) ? addr_wr0 : addr_wr1;
    wire [11:0] din_bank0 = (we0 && (bank_wr0 == 1'b0)) ? din0 : din1;

    wire write_to_bank1 = (we0 && (bank_wr0 == 1'b1)) || (we1 && (bank_wr1 == 1'b1));
    wire [6:0] addr_wr_bank1 = (we0 && (bank_wr0 == 1'b1)) ? addr_wr0 : addr_wr1;
    wire [11:0] din_bank1 = (we0 && (bank_wr0 == 1'b1)) ? din0 : din1;

    wire wr_bank0;
    wire [6:0] wa_bank0;
    wire [11:0] wd_bank0;
    wire wr_bank1;
    wire [6:0] wa_bank1;
    wire [11:0] wd_bank1;

    generate
        if (WR_REG != 0) begin : g_wr_reg
            reg wr_bank0_reg, wr_bank1_reg;
            reg [6:0] wa_bank0_reg, wa_bank1_reg;
            reg [11:0] wd_bank0_reg, wd_bank1_reg;
            always @(posedge clk) begin
                wr_bank0_reg <= write_to_bank0;
                wa_bank0_reg <= addr_wr_bank0;
                wd_bank0_reg <= din_bank0;
                wr_bank1_reg <= write_to_bank1;
                wa_bank1_reg <= addr_wr_bank1;
                wd_bank1_reg <= din_bank1;
            end
            assign wr_bank0 = wr_bank0_reg;
            assign wa_bank0 = wa_bank0_reg;
            assign wd_bank0 = wd_bank0_reg;
            assign wr_bank1 = wr_bank1_reg;
            assign wa_bank1 = wa_bank1_reg;
            assign wd_bank1 = wd_bank1_reg;
        end else begin : g_wr_comb
            assign wr_bank0 = write_to_bank0;
            assign wa_bank0 = addr_wr_bank0;
            assign wd_bank0 = din_bank0;
            assign wr_bank1 = write_to_bank1;
            assign wa_bank1 = addr_wr_bank1;
            assign wd_bank1 = din_bank1;
        end
    endgenerate

    always @(posedge clk) begin
        if (wr_bank0) begin
            bank0[wa_bank0] <= wd_bank0;
        end
    end

    always @(posedge clk) begin
        if (wr_bank1) begin
            bank1[wa_bank1] <= wd_bank1;
        end
    end

    assign dout0 = (bank_rd0 == 1'b0) ? bank0[addr_rd0] : bank1[addr_rd0];
    assign dout1 = (bank_rd1 == 1'b0) ? bank0[addr_rd1] : bank1[addr_rd1];

endmodule
