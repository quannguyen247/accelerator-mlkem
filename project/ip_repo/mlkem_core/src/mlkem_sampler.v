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
    reg va, vb;
    reg [8*12-1:0] cand_b;
    reg [7:0] ok_b;
    reg [8*3-1:0] rank_b;
    reg [3:0] total_b;
    reg [5:0] fill_r [0:15];
    // Stage D: registered RAM write port and the count it completes.
    reg vc;
    reg [8:0] cnt_c;
    reg [3:0] slot_c;
    reg [7:0] we_q;
    reg [8*8-1:0] waddr_q;
    reg [8*12-1:0] wdata_q;

    assign busy = scan || va || vb || vc;

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

    // Stage B: candidates, acceptance and ranks
    integer i;
    reg [11:0] cnd [0:7];
    reg [3:0] run;
    always @(*) begin
        for (i = 0; i < 4; i = i + 1) begin
            cnd[2*i] = {ch_a[24*i+11 -: 4], ch_a[24*i +: 8]};
            cnd[2*i+1] = {ch_a[24*i+16 +: 8], ch_a[24*i+12 +: 4]};
        end
    end

    always @(posedge clk) begin
        if (!rst_n || kill)
            vb <= 1'b0;
        else
            vb <= va;
        run = 4'd0;
        for (i = 0; i < 8; i = i + 1) begin
            cand_b[12*i +: 12] <= cnd[i];
            ok_b[i] <= (cnd[i] < 12'd3329);
            rank_b[3*i +: 3] <= run[2:0];
            if (cnd[i] < 12'd3329)
                run = run + 4'd1;
        end
        total_b <= run;
    end

    // Stage C: compacting write into eight banks
    // Rows of one parity share a half: slot {r, j} -> half r[0], word {r[1], j, blk}.
    reg [7:0] we;
    reg [8*8-1:0] waddr;
    reg [8*12-1:0] wdata;
    reg [2:0] want;
    reg [8:0] pos;
    integer m;
    always @(*) begin
        we = 8'd0;
        waddr = {8{slot[3], slot[1:0], 5'd0}};
        wdata = 96'd0;
        for (m = 0; m < 8; m = m + 1) begin
            want = m[2:0] - count[2:0];
            pos = count + {6'd0, want};
            waddr[8*m +: 8] = {slot[3], slot[1:0], pos[7:3]};
            for (i = 0; i < 8; i = i + 1) begin
                if (vb && ok_b[i] && rank_b[3*i +: 3] == want && !pos[8]) begin
                    we[m] = 1'b1;
                    wdata[12*m +: 12] = cand_b[12*i +: 12];
                end
            end
        end
    end

    wire [9:0] cnt_sum = {1'b0, count} + {6'd0, total_b};
    wire [8:0] cnt_next = (cnt_sum >= 10'd256) ? 9'd256 : cnt_sum[8:0];

    always @(posedge clk) begin
        if (!rst_n || kill) begin
            vc <= 1'b0;
            we_q <= 8'd0;
        end else begin
            vc <= vb;
            we_q <= we;
        end
        waddr_q <= waddr;
        wdata_q <= wdata;
        cnt_c <= cnt_next;
        slot_c <= slot;
    end

    always @(posedge clk) begin
        if (!rst_n || kill) begin
            count <= 9'd0;
            slot <= 4'd0;
        end else if (blk_load && blk_new) begin
            count <= 9'd0;
            slot <= blk_slot;
        end else if (vb) begin
            count <= cnt_next;
        end
    end

    genvar s;
    generate
        for (s = 0; s < 16; s = s + 1) begin : g_fill
            always @(posedge clk) begin
                if (!rst_n || clr)
                    fill_r[s] <= 6'd0;
                else if (vc && slot_c == s)
                    fill_r[s] <= cnt_c[8:3];
            end
            assign fill[6*s +: 6] = fill_r[s];
        end
    endgenerate

    mlkem_poly_ram #(.W(12), .AW(8)) u_amem_even (
        .clk(clk),
        .we(slot_c[2] ? 8'd0 : we_q),
        .waddr(waddr_q),
        .wdata(wdata_q),
        .raddr({rde_slot, rd_blk}),
        .rdata(rde_data)
    );

    mlkem_poly_ram #(.W(12), .AW(8)) u_amem_odd (
        .clk(clk),
        .we(slot_c[2] ? we_q : 8'd0),
        .waddr(waddr_q),
        .wdata(wdata_q),
        .raddr({rdo_slot, rd_blk}),
        .rdata(rdo_data)
    );

endmodule
