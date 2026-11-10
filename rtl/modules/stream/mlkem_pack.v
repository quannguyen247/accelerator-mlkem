`timescale 1ns / 1ps

// d-byte blocks to 64-bit words. A block is appended only when fewer than
// eight bytes remain after the current emit, so placement needs an 8-way
// shift. The output word is the registered buffer head (stable under stall).
module mlkem_pack (
    input wire clk,
    input wire rst_n,
    input wire clr,
    input wire [3:0] db,
    input wire in_valid,
    input wire [95:0] in_raw,
    output wire in_ready,
    output wire out_valid,
    output wire [63:0] out_data,
    input wire out_ready
);

    reg [191:0] buf_r;
    reg [4:0] nb;

    assign out_valid = (nb >= 5'd8);
    assign out_data = buf_r[63:0];
    wire emit = out_valid && out_ready;
    wire [4:0] nb_e = emit ? nb - 5'd8 : nb;
    wire [191:0] buf_e = emit ? {64'd0, buf_r[191:64]} : buf_r;
    assign in_ready = (nb_e < 5'd8);
    wire take = in_valid && in_ready;
    wire [191:0] ins = {96'd0, in_raw} << {nb_e[2:0], 3'b000};

    always @(posedge clk) begin
        if (!rst_n || clr) begin
            buf_r <= 192'd0;
            nb <= 5'd0;
        end else begin
            buf_r <= take ? (buf_e | ins) : buf_e;
            nb <= take ? nb_e + {1'b0, db} : nb_e;
        end
    end

endmodule
