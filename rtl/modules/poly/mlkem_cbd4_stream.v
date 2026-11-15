`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// SamplePolyCBD over PRF bytes held in a 64-bit word memory, four
// coefficients per pop (coefficient j of a pop in val[12j +: 12]). Refills
// from a prefetched word; words are fetched only once written (avail), so
// consumption may start right behind the writer.
// A pop takes 16 bits (eta = 2) or 24 bits (eta = 3), so a refill only ever
// lands at bit offset 0, 8 or 16 of the shift register.
module mlkem_cbd4_stream (
    input wire clk,
    input wire rst_n,
    input wire init,
    input wire eta3,
    input wire [4:0] avail,
    output wire [4:0] rd_addr,
    input wire [63:0] rd_data,
    input wire pop,
    output reg val_v,
    output reg [47:0] val
);

    reg [4:0] wptr;
    reg [63:0] nxt;
    reg nxt_v;
    reg [87:0] sr;
    reg [6:0] cnt;

    wire [6:0] need = eta3 ? 7'd24 : 7'd16;
    // refill == (cnt < need), registered with cnt: it selects the 88-bit
    // insert. eta3 changes only between the load and the unload, each of
    // which starts with init.
    reg refill_q;
    wire refill = refill_q;
    wire can = !refill || nxt_v;
    wire take = (!val_v || pop) && can;

    reg [87:0] ins;
    always @(*) begin
        case (cnt[4:3])
            2'd0: ins = {24'd0, nxt};
            2'd1: ins = {16'd0, nxt, 8'd0};
            default: ins = {8'd0, nxt, 16'd0};
        endcase
    end

    wire [87:0] sr_f = refill ? (sr | ins) : sr;
    wire [6:0] cnt_f = refill ? cnt + 7'd64 : cnt;

    reg [47:0] coef;
    integer j;
    reg [1:0] x, y;
    always @(*) begin
        for (j = 0; j < 4; j = j + 1) begin
            if (eta3) begin
                x = sr_f[6*j] + sr_f[6*j+1] + sr_f[6*j+2];
                y = sr_f[6*j+3] + sr_f[6*j+4] + sr_f[6*j+5];
            end else begin
                x = sr_f[4*j] + sr_f[4*j+1];
                y = sr_f[4*j+2] + sr_f[4*j+3];
            end
            coef[12*j +: 12] = (x >= y) ? {10'd0, x - y} : 12'd3329 - {10'd0, y - x};
        end
    end

    assign rd_addr = wptr;
    // Prefetch: the next word is read once written, into an empty register or
    // as the current one is used. The data register has no reset (nxt_v
    // qualifies it), so init does not reach its enable.
    wire fetch = (!nxt_v || (take && refill)) && (wptr < avail);
    always @(posedge clk)
        if (fetch)
            nxt <= rd_data;

    always @(posedge clk) begin
        if (!rst_n || init) begin
            wptr <= 5'd0;
            nxt_v <= 1'b0;
            cnt <= 7'd0;
            refill_q <= 1'b1;
            sr <= 88'd0;
            val_v <= 1'b0;
        end else begin
            if (take) begin
                val <= coef;
                val_v <= 1'b1;
                sr <= eta3 ? (sr_f >> 24) : (sr_f >> 16);
                cnt <= cnt_f - need;
                refill_q <= (cnt_f - need < need);
            end else if (pop) begin
                val_v <= 1'b0;
            end
            if (take && refill)
                nxt_v <= 1'b0;
            if (fetch) begin
                nxt_v <= 1'b1;
                wptr <= wptr + 5'd1;
            end
        end
    end

endmodule
