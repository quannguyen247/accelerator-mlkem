`timescale 1ns / 1ps

// SampleNTT rejection sampler and matrix store. A captured SHAKE128 block is
// scanned 12 bytes (8 candidates) per cycle; accepted values are compacted
// into consecutive coefficient positions of the current slot. Slot s of the
// store holds A[r][j] with s = 4r + j.
module mlkem_sampler (
    input wire clk,
    input wire rst_n,
    input wire kill,
    input wire clr,

    input wire blk_load,
    input wire blk_new,
    input wire [3:0] blk_slot,
    input wire [1343:0] cap,
    output wire busy,
    output reg [8:0] count,

    input wire [2:0] rde_slot,
    input wire [2:0] rdo_slot,
    input wire [4:0] rd_blk,
    output wire [95:0] rde_data,
    output wire [95:0] rdo_data,
    output wire [16*6-1:0] fill
);

    reg [3:0] slot;
    reg [3:0] chunk;
    reg scan;
    reg [95:0] ch_a;
    reg va, vb, vr;
    // Stage B: candidates and their acceptance
    reg [8*12-1:0] cand_b;
    reg [7:0] ok_b;
    // Stage R: ranks of the accepted candidates and their number
    reg [8*12-1:0] cand_r;
    reg [7:0] ok_r;
    reg [8*3-1:0] rank_r;
    reg [3:0] total_r;
    reg [5:0] fill_r [0:15];
    // Stage C: per-bank candidate select, registered
    reg vc;
    reg [8:0] cnt_c;
    reg [3:0] slot_c;
    reg [7:0] hit_c;
    reg [8*3-1:0] sel_c;
    reg [8*8-1:0] waddr_c;
    reg [8*12-1:0] cand_c;
    // Stage D: registered RAM write ports and the count they complete. Every
    // bank of each half has its own port register; a bank that is not
    // written in the cycle (other half, or no candidate for it) holds address
    // and data zero, so no address register is shared between banks.
    reg vd;
    reg [8:0] cnt_d;
    reg [3:0] slot_d;
    reg [7:0] we_e_q, we_o_q;
    reg [8*8-1:0] waddr_e_q, waddr_o_q;
    reg [8*12-1:0] wdata_e_q, wdata_o_q;

    assign busy = scan || va || vb || vr || vc || vd;

    // Stage A: 12-byte chunk
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            scan <= 1'b0;
            chunk <= 4'd0;
            va <= 1'b0;
        end else begin
            va <= scan;
            if (blk_load) begin
                scan <= 1'b1;
                chunk <= 4'd0;
            end else if (scan) begin
                chunk <= chunk + 4'd1;
                if (chunk == 4'd13)
                    scan <= 1'b0;
            end
        end
        ch_a <= cap[chunk*96 +: 96];
    end

    // Stage B: candidates and acceptance
    integer i, c;
    reg [11:0] cnd [0:7];
    always @(*) begin
        for (c = 0; c < 4; c = c + 1) begin
            cnd[2*c] = {ch_a[24*c+11 -: 4], ch_a[24*c +: 8]};
            cnd[2*c+1] = {ch_a[24*c+16 +: 8], ch_a[24*c+12 +: 4]};
        end
    end

    always @(posedge clk) begin
        if (!rst_n || kill)
            vb <= 1'b0;
        else
            vb <= va;
        for (i = 0; i < 8; i = i + 1) begin
            cand_b[12*i +: 12] <= cnd[i];
            ok_b[i] <= (cnd[i] < 12'd3329);
        end
    end

    // Stage R: rank of a candidate = accepted candidates in front of it
    reg [8*3-1:0] rank;
    reg [3:0] run;
    always @(*) begin
        run = 4'd0;
        for (c = 0; c < 8; c = c + 1) begin
            rank[3*c +: 3] = run[2:0];
            if (ok_b[c])
                run = run + 4'd1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n || kill)
            vr <= 1'b0;
        else
            vr <= vb;
        cand_r <= cand_b;
        ok_r <= ok_b;
        rank_r <= rank;
        total_r <= run;
    end

    // Stage C: compacting write into eight banks. Bank m takes the accepted
    // candidate of rank m - count (mod 8); its index is registered here and
    // the value is selected in stage D.
    // Rows of one parity share a half: slot {r, j} -> half r[0], word {r[1], j, blk}.
    reg [7:0] hit;
    reg [8*3-1:0] sel;
    reg [8*8-1:0] waddr;
    reg [2:0] want;
    reg [8:0] pos;
    integer m, r;
    always @(*) begin
        hit = 8'd0;
        sel = 24'd0;
        waddr = {8{slot[3], slot[1:0], 5'd0}};
        for (m = 0; m < 8; m = m + 1) begin
            want = m[2:0] - count[2:0];
            pos = count + {6'd0, want};
            waddr[8*m +: 8] = {slot[3], slot[1:0], pos[7:3]};
            for (r = 0; r < 8; r = r + 1) begin
                if (vr && ok_r[r] && rank_r[3*r +: 3] == want && !pos[8]) begin
                    hit[m] = 1'b1;
                    sel[3*m +: 3] = r[2:0];
                end
            end
        end
    end

    wire [9:0] cnt_sum = {1'b0, count} + {6'd0, total_r};
    wire [8:0] cnt_next = (cnt_sum >= 10'd256) ? 9'd256 : cnt_sum[8:0];

    // Value of each bank, and the half of the block (odd rows: slot bit 2)
    integer d;
    reg [8*12-1:0] wdata_c;
    always @(*) begin
        for (d = 0; d < 8; d = d + 1)
            wdata_c[12*d +: 12] = cand_c[sel_c[3*d +: 3]*12 +: 12];
    end
    wire odd_c = slot_c[2];

    always @(posedge clk) begin
        if (!rst_n || kill) begin
            vc <= 1'b0;
            vd <= 1'b0;
            hit_c <= 8'd0;
            we_e_q <= 8'd0;
            we_o_q <= 8'd0;
        end else begin
            vc <= vr;
            vd <= vc;
            hit_c <= hit;
            we_e_q <= odd_c ? 8'd0 : hit_c;
            we_o_q <= odd_c ? hit_c : 8'd0;
        end
        sel_c <= sel;
        waddr_c <= waddr;
        cand_c <= cand_r;
        cnt_c <= cnt_next;
        slot_c <= slot;
        for (d = 0; d < 8; d = d + 1) begin
            waddr_e_q[8*d +: 8] <= (!odd_c && hit_c[d]) ? waddr_c[8*d +: 8] : 8'd0;
            waddr_o_q[8*d +: 8] <= (odd_c && hit_c[d]) ? waddr_c[8*d +: 8] : 8'd0;
            wdata_e_q[12*d +: 12] <= (!odd_c && hit_c[d]) ? wdata_c[12*d +: 12] : 12'd0;
            wdata_o_q[12*d +: 12] <= (odd_c && hit_c[d]) ? wdata_c[12*d +: 12] : 12'd0;
        end
        cnt_d <= cnt_c;
        slot_d <= slot_c;
    end

    always @(posedge clk) begin
        if (!rst_n || kill) begin
            count <= 9'd0;
            slot <= 4'd0;
        end else if (blk_load && blk_new) begin
            count <= 9'd0;
            slot <= blk_slot;
        end else if (vr) begin
            count <= cnt_next;
        end
    end

    genvar s;
    generate
        for (s = 0; s < 16; s = s + 1) begin : g_fill
            always @(posedge clk) begin
                if (!rst_n || clr)
                    fill_r[s] <= 6'd0;
                else if (vd && slot_d == s)
                    fill_r[s] <= cnt_d[8:3];
            end
            assign fill[6*s +: 6] = fill_r[s];
        end
    endgenerate

    mlkem_poly_ram #(.W(12), .AW(8)) u_amem_even (
        .clk(clk),
        .we(we_e_q),
        .waddr(waddr_e_q),
        .wdata(wdata_e_q),
        .raddr({rde_slot, rd_blk}),
        .rdata(rde_data)
    );

    mlkem_poly_ram #(.W(12), .AW(8)) u_amem_odd (
        .clk(clk),
        .we(we_o_q),
        .waddr(waddr_o_q),
        .wdata(wdata_o_q),
        .raddr({rdo_slot, rd_blk}),
        .rdata(rdo_data)
    );

endmodule
