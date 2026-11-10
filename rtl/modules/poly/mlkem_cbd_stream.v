`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// Sequential SamplePolyCBD over PRF bytes held in a 64-bit word memory.
// Produces one coefficient per pop; refills from a prefetched word. Words are
// fetched only once written (avail), so consumption may start right behind
// the writer.
module mlkem_cbd_stream (
    input wire clk,
    input wire rst_n,
    input wire init,
    input wire eta3,
    input wire [4:0] avail,
    output wire [4:0] rd_addr,
    input wire [63:0] rd_data,
    input wire pop,
    output reg val_v,
    output reg [11:0] val
);

    reg [4:0] wptr;
    reg [63:0] nxt;
    reg nxt_v;
    reg [67:0] sr;
    reg [6:0] cnt;

    wire [6:0] need = eta3 ? 7'd6 : 7'd4;
    wire refill = (cnt < need);
    wire can = !refill || nxt_v;
    wire take = (!val_v || pop) && can;

    reg [67:0] ins;
    always @(*) begin
        case (cnt[2:0])
            3'd0: ins = {4'd0, nxt};
            3'd1: ins = {3'd0, nxt, 1'b0};
            3'd2: ins = {2'd0, nxt, 2'b0};
            3'd3: ins = {1'b0, nxt, 3'b0};
            3'd4: ins = {nxt, 4'b0};
            default: ins = {nxt[62:0], 5'b0};
        endcase
    end

    wire [67:0] sr_f = refill ? (sr | ins) : sr;
    wire [6:0] cnt_f = refill ? cnt + 7'd64 : cnt;

    wire [1:0] x = eta3 ? (sr_f[0] + sr_f[1] + sr_f[2]) : (sr_f[0] + sr_f[1]);
    wire [1:0] y = eta3 ? (sr_f[3] + sr_f[4] + sr_f[5]) : (sr_f[2] + sr_f[3]);
    wire [11:0] coef = (x >= y) ? {10'd0, x - y} : 12'd3329 - {10'd0, y - x};

    assign rd_addr = wptr;

    always @(posedge clk) begin
        if (!rst_n || init) begin
            wptr <= 5'd0;
            nxt_v <= 1'b0;
            cnt <= 7'd0;
            sr <= 68'd0;
            val_v <= 1'b0;
        end else begin
            if (take) begin
                val <= coef;
                val_v <= 1'b1;
                sr <= eta3 ? (sr_f >> 6) : (sr_f >> 4);
                cnt <= cnt_f - need;
            end else if (pop) begin
                val_v <= 1'b0;
            end
            if (take && refill)
                nxt_v <= 1'b0;
            if ((!nxt_v || (take && refill)) && (wptr < avail)) begin
                nxt <= rd_data;
                nxt_v <= 1'b1;
                wptr <= wptr + 5'd1;
            end
        end
    end

endmodule
