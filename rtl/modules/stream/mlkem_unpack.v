`timescale 1ns / 1ps

// 64-bit words to d-byte blocks (8 values of d bits = d bytes). A three-word
// window with a byte offset needs only an 8-way shift; every segment is a
// whole number of words and blocks, so the window is empty at boundaries.
module mlkem_unpack (
    input wire clk,
    input wire rst_n,
    input wire clr,

    // Bytes per block (d)
    input wire [3:0] db,

    // Word input
    input wire in_valid,
    input wire [63:0] in_data,
    output wire in_ready,

    // Block output
    input wire out_en,
    output wire out_valid,
    output wire [95:0] out_raw,
    output reg [95:0] out_vals
);

    // Window: word_cnt_reg valid words, the block starts at byte offset_reg
    reg [63:0] w0_reg, w1_reg, w2_reg;
    reg [1:0] word_cnt_reg;
    reg [2:0] offset_reg;

    wire [191:0] window = {w2_reg, w1_reg, w0_reg};

    // A block fits when its end offset lies inside the valid words
    wire [4:0] end_offset = {2'd0, offset_reg} + {1'b0, db};
    wire block_fits = (word_cnt_reg > end_offset[4:3]) ||
                      ((word_cnt_reg == end_offset[4:3]) && (end_offset[2:0] == 3'd0));
    wire [1:0] drop = out_valid ? end_offset[4:3] : 2'd0;

    // A full window always holds a whole block (24 - 7 >= 12 bytes), so it
    // frees a word exactly when a block leaves and its end offset wraps:
    // in_ready needs no block_fits compare in front of it.
    wire window_full = (word_cnt_reg == 2'd3);
    wire full_drops = out_en && (end_offset[4:3] != 2'd0);

    // A new word goes behind the valid words; the shift follows.
    wire take = in_valid && in_ready;
    wire [63:0] e0 = (take && word_cnt_reg == 2'd0) ? in_data : w0_reg;
    wire [63:0] e1 = (take && word_cnt_reg == 2'd1) ? in_data : w1_reg;
    wire [63:0] e2 = (take && word_cnt_reg == 2'd2) ? in_data : w2_reg;
    wire [63:0] e3 = (take && window_full) ? in_data : 64'd0;

    // Window update
    always @(posedge clk) begin
        if (!rst_n || clr) begin
            word_cnt_reg <= 2'd0;
            offset_reg <= 3'd0;
            w0_reg <= 64'd0;
            w1_reg <= 64'd0;
            w2_reg <= 64'd0;
        end else begin
            if (out_valid)
                offset_reg <= end_offset[2:0];
            word_cnt_reg <= word_cnt_reg - drop + {1'b0, take};
            case (drop)
                2'd0: begin
                    w0_reg <= e0;
                    w1_reg <= e1;
                    w2_reg <= e2;
                end
                2'd1: begin
                    w0_reg <= e1;
                    w1_reg <= e2;
                    w2_reg <= e3;
                end
                default: begin
                    w0_reg <= e2;
                    w1_reg <= e3;
                    w2_reg <= 64'd0;
                end
            endcase
        end
    end

    // Block fields widened to 12 bits
    integer i;
    always @(*) begin
        out_vals = 96'd0;
        for (i = 0; i < 8; i = i + 1) begin
            case (db)
                4'd12: out_vals[12*i +: 12] = out_raw[12*i +: 12];
                4'd11: out_vals[12*i +: 12] = {1'b0, out_raw[11*i +: 11]};
                4'd10: out_vals[12*i +: 12] = {2'b0, out_raw[10*i +: 10]};
                4'd5:  out_vals[12*i +: 12] = {7'b0, out_raw[5*i +: 5]};
                default: out_vals[12*i +: 12] = {8'b0, out_raw[4*i +: 4]};
            endcase
        end
    end

    assign in_ready = !window_full || full_drops;
    assign out_valid = out_en && block_fits;
    assign out_raw = window >> {offset_reg, 3'b000};

endmodule
