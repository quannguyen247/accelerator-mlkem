`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// Polynomial multiply-accumulate unit: out[r] = sum_j M[r][j] o V[j] * 2^-16.
// Rows are processed in pairs (r0 = 2p, r1 = 2p + 1) that share the V[j]
// block read: one basemul lane per row handles one quarter of an
// 8-coefficient block of each row per cycle. The matrix store is split by
// row parity, so the two matrix reads never collide. Each block is taken
// in four quarters (two coefficients of each row per cycle, 4/cycle in all):
// a group covers one quarter-block, and the four quarter results are merged
// into one block write. A pair with a single row (the last ENC/KG pair for
// an odd row count, the DEC row) uses both lanes on two quarters of that row. Each step issues only
// when its operand blocks exist (producer fill/epoch), so the unit overlaps
// with the sampler, the NTT unloads and the input decoder.
//   KG  : t^[r] - e^[r] = A[r][j] o (s^ * 2^16)[j]    pair order   -> T store
//         (e^ is added by the output encoder, so no row waits for its bias)
//   ENC : u^[r] = A[r][j] o y^[j], v^ = t^[j] o y^[j]  column order -> lanes 4..8
//   DEC : w^    = s^[j] o u'^[j]                                     -> lane 8
module mlkem_pmac (
    input wire clk,
    input wire rst_n,

    // Request control
    input wire kill,
    input wire go,
    input wire [1:0] op,
    input wire [2:0] k,
    output wire busy,

    // Matrix store (even / odd rows)
    output wire [2:0] ae_slot,
    output wire [2:0] ao_slot,
    output wire [4:0] a_blk,
    input wire [95:0] ae_rdata,
    input wire [95:0] ao_rdata,
    input wire [16*6-1:0] a_fill,

    // S, T stores and vector buffers: *_blk is the stage-0 block, registered
    // by the memories (stage 1); *_rdata is the block of slot *_slot.
    // S store
    output wire [1:0] s_slot,
    output wire [4:0] s_blk,
    input wire [95:0] s_rdata,
    input wire [4*6-1:0] s_fill,

    // T store
    output wire [1:0] t_slot,
    output wire [4:0] t_blk,
    input wire [95:0] t_rdata,
    input wire [4*6-1:0] t_fill,

    // Vector operand (vector lane buffers)
    output wire [1:0] v_slot,
    output wire [4:0] v_blk,
    input wire [95:0] v_rdata,
    input wire [4*6-1:0] v_fill,
    input wire [3:0] v_ep,

    // Results, one registered strobe per destination. Port 0 carries the
    // even row of a pair, port 1 the odd row:
    //   wr_t_en[r]     T store slot r (KeyGen)
    //   wr_lane_en[l]  buffer of lane l = 4..7 (ENC row l - 4)
    //   wr_lane_en[8]  buffer of lane 8 (ENC row k, DEC), from port wr8_p1
    //                  with epoch wr8_ep
    output reg [3:0] wr_t_en,
    output reg [8:4] wr_lane_en,
    output reg wr8_p1,
    output reg wr8_ep,
    output reg [4:0] wr_blk,
    output reg wr_first,            // wr_blk == 0
    output reg [95:0] wr0_data,
    output reg [95:0] wr1_data
);

    `include "mlkem_funcs.vh"

    localparam SCALE_LAT = 6;               // mlkem_scale
    localparam LANE_LAT = 15 + SCALE_LAT;   // stage 2 to the scaled results
    localparam DRAIN = 21 + SCALE_LAT;

    reg running;
    reg job;
    reg [1:0] kind;
    reg [7:0] bp [0:2];       // next quarter-block of each row pair (128 = finished)
    reg [1:0] cur;            // pair of the group in progress
    reg in_grp;
    reg [2:0] j;
    reg [8:0] groups;         // completed (pair, quarter-block) groups of the job
    reg [4:0] drain;

    wire [2:0] rows = (kind == `MLKEM_PJ_KG) ? k : (kind == `MLKEM_PJ_ENC) ? k + 3'd1 : 3'd1;
    reg [1:0] last_p;               // ceil(rows / 2) - 1, constant during a job
    always @(posedge clk)
        last_p <= rows[2:1] - {1'b0, ~rows[0]};
    wire [8:0] total = {last_p + 2'd1, 7'd0};
    // Re-encryption job of a Decaps request, and k - 1: registered, they
    // change only with the job kind (the start-up hold covers the delay).
    reg v_e;
    reg [2:0] km1_reg;
    always @(posedge clk) begin
        v_e <= (kind == `MLKEM_PJ_ENC) && (op == `MLKEM_OP_DECAPS);
        km1_reg <= k - 3'd1;
    end
    wire to_t = (kind == `MLKEM_PJ_KG);

    // A group (one block of both rows of a pair, all k terms) is started only
    // when every operand block it needs exists; fills only grow, so the group
    // then runs k cycles without a stall. Ready pairs are taken in a fixed
    // order: lowest first (t^ and c1 stream out in row order), except the
    // Decaps re-encryption, which only compares: highest first, so the v row
    // (a single-row pair for even k, both lanes) is done first and its INTT
    // runs on one engine while the other engine waits for the u rows.
    //
    // Readiness pipeline (fills only grow, so older answers are conservative):
    //   1. the operand fills of every pair and term are registered,
    //   2. their compare with the pair's next block (bp) and the block after
    //      it (bp1) is registered (rdy_q, rdyn_q),
    //   3. the pair and block of the next group are chosen and registered
    //      (nxt_*) in the last term of a group or while no group runs, so a
    //      group starts from registers alone.
    // After a pair finishes a group its "block after" answer applies for one
    // cycle (inc_q).

    // Per-job pair constants, registered. Rows of pair q are 2q and 2q + 1.
    reg [1:0] ms0_q [0:2];
    reg [1:0] ms1_q [0:2];
    reg [2:0] g1_q;
    reg [2:0] qv_q;
    integer q, jj, qr, vj;
    always @(posedge clk) begin
        for (qr = 0; qr < 3; qr = qr + 1) begin
            ms0_q[qr] <= (kind == `MLKEM_PJ_KG) ? `MLKEM_MS_A : (kind == `MLKEM_PJ_DEC) ? `MLKEM_MS_S :
                         (2 * qr == k) ? `MLKEM_MS_T : `MLKEM_MS_A;
            ms1_q[qr] <= ((kind == `MLKEM_PJ_ENC) && (2 * qr + 1 == k)) ? `MLKEM_MS_T : `MLKEM_MS_A;
            g1_q[qr] <= (2 * qr + 1 < rows);
            qv_q[qr] <= (qr <= last_p);
        end
    end

    // 1. Operand fills of pair q, term jj (index 4q + jj): even row (f0),
    //    odd row (f1) and vector (fv). Terms beyond k and the missing odd
    //    row read as complete (63, above every block index).
    reg [12*6-1:0] f0_q;
    reg [12*6-1:0] f1_q;
    reg [5:0] fv_q [0:3];
    always @(posedge clk) begin
        for (qr = 0; qr < 3; qr = qr + 1) begin
            for (vj = 0; vj < 4; vj = vj + 1) begin
                f0_q[(4 * qr + vj) * 6 +: 6] <= (vj >= k) ? 6'd63 :
                                     (ms0_q[qr] == `MLKEM_MS_A) ? a_fill[((8 * qr + vj) % 16) * 6 +: 6] :
                                     (ms0_q[qr] == `MLKEM_MS_S) ? s_fill[vj * 6 +: 6] : t_fill[vj * 6 +: 6];
                f1_q[(4 * qr + vj) * 6 +: 6] <= ((vj >= k) || !g1_q[qr]) ? 6'd63 :
                                     (ms1_q[qr] == `MLKEM_MS_A) ? a_fill[((8 * qr + 4 + vj) % 16) * 6 +: 6] :
                                     t_fill[vj * 6 +: 6];
            end
        end
        for (vj = 0; vj < 4; vj = vj + 1)
            fv_q[vj] <= (vj >= k) ? 6'd63 : (v_ep[vj] == v_e) ? v_fill[vj * 6 +: 6] : 6'd0;
    end

    // 2. Readiness of block bp[q] and of block bp1[q] = bp[q] + 1
    reg [7:0] bp1 [0:2];
    reg [2:0] rdy_cur, rdy_nxt;     // combinational
    reg [2:0] rdy_q, rdyn_q;        // registered
    reg [2:0] inc_q;                // bp[q] advanced in the previous cycle
    reg ok0, ok1;
    always @(*) begin
        for (q = 0; q < 3; q = q + 1) begin
            ok0 = qv_q[q];
            ok1 = qv_q[q];
            for (jj = 0; jj < 4; jj = jj + 1) begin
                if (!(f0_q[(4 * q + jj) * 6 +: 6] > bp[q][7:2]) || !(f1_q[(4 * q + jj) * 6 +: 6] > bp[q][7:2]) || !(fv_q[jj] > bp[q][7:2]))
                    ok0 = 1'b0;
                if (!(f0_q[(4 * q + jj) * 6 +: 6] > bp1[q][7:2]) || !(f1_q[(4 * q + jj) * 6 +: 6] > bp1[q][7:2]) || !(fv_q[jj] > bp1[q][7:2]))
                    ok1 = 1'b0;
            end
            rdy_cur[q] = ok0;
            rdy_nxt[q] = ok1;
        end
    end

    always @(posedge clk) begin
        rdy_q <= rdy_cur;
        rdyn_q <= rdy_nxt;
    end

    // 3. Next group: pair nxt_p, block nxt_b (valid with nxt_v).
    //    In the last term of a group the running pair offers its next block;
    //    a running group that is not in its last term offers nothing.
    reg [1:0] hold;                 // registered readiness settles after a (re)start
    reg [7:0] b_grp;                // quarter-block of the group in progress
    reg jlast;                      // the term in progress is the group's last (j == k - 1)
    reg [2:0] cur_oh;               // one-hot of cur
    reg g1_cur;                     // g1_q[cur]
    reg [7:0] bp_nx, bp1_nx;        // bp, bp1 of cur after the group
    reg [1:0] c0, c1, c2;           // pair order of the next start
    reg nxt_v;
    reg [1:0] nxt_p;
    reg [7:0] nxt_b;

    reg [2:0] avail;
    reg mid_any;
    reg [7:0] bsrc [0:2];
    integer a;
    always @(*) begin
        // A started block is finished first: its quarters follow each other
        // directly in the same pair (the output holds three quarters).
        mid_any = in_grp ? (b_grp[1:0] != (g1_cur ? 2'd3 : 2'd2)) : ((bp[0][1:0] != 2'd0) || (bp[1][1:0] != 2'd0) || (bp[2][1:0] != 2'd0));
        for (a = 0; a < 3; a = a + 1) begin
            if (in_grp)
                avail[a] = jlast && (cur_oh[a] ? rdyn_q[a] : (!mid_any && rdy_q[a]));
            else
                avail[a] = (!mid_any || (bp[a][1:0] != 2'd0)) && (inc_q[a] ? rdyn_q[a] : rdy_q[a]);
            bsrc[a] = (in_grp && cur_oh[a]) ? b_grp + (g1_q[a] ? 8'd1 : 8'd2) : bp[a];
        end
    end
    wire nxt_any = avail[c0] || avail[c1] || avail[c2];
    wire [1:0] nxt_sel = avail[c0] ? c0 : avail[c1] ? c1 : c2;

    wire issue = running && (drain == 5'd0) && (hold == 2'd0) && (in_grp || nxt_v);
    wire start = issue && !in_grp;
    wire [1:0] p = in_grp ? cur : nxt_p;
    wire [7:0] b = in_grp ? b_grp : nxt_b;
    wire last_j = jlast;

    // Pair order: ascending, or descending for the re-encryption (see above)
    function [5:0] pair_order;
        input f_desc;
        input [1:0] f_last_p;
        reg [1:0] o0, o1, o2;
        begin
            o0 = f_desc ? f_last_p : 2'd0;
            o1 = f_desc ? ((f_last_p != 2'd0) ? f_last_p - 2'd1 : 2'd0) : ((f_last_p != 2'd0) ? 2'd1 : 2'd0);
            o2 = f_desc ? 2'd0 : f_last_p;
            pair_order = {o2, o1, o0};
        end
    endfunction

    wire [2:0] r0 = {p, 1'b0};
    wire [2:0] r1 = {p, 1'b1};
    wire g1 = (r1 < rows);
    wire [1:0] msrc0 = (kind == `MLKEM_PJ_KG) ? `MLKEM_MS_A :
                       (kind == `MLKEM_PJ_DEC) ? `MLKEM_MS_S :
                       (r0 == k) ? `MLKEM_MS_T : `MLKEM_MS_A;
    wire [1:0] msrc1 = ((kind == `MLKEM_PJ_ENC) && (r1 == k)) ? `MLKEM_MS_T : `MLKEM_MS_A;

    assign busy = running || (drain != 5'd0);

    // A new job (go, or the Decaps re-encryption) starts from settled readiness.
    wire restart = go || ((drain == 5'd1) && (op == `MLKEM_OP_DECAPS) && !job);
    wire [5:0] order_nx = pair_order(v_e, last_p);
    always @(posedge clk) begin
        c0 <= order_nx[1:0];
        c1 <= order_nx[3:2];
        c2 <= order_nx[5:4];
    end

    integer z;
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            running <= 1'b0;
            job <= 1'b0;
            kind <= `MLKEM_PJ_KG;
            in_grp <= 1'b0;
            j <= 3'd0;
            jlast <= 1'b0;
            groups <= 9'd0;
            drain <= 5'd0;
            hold <= 2'd0;
            inc_q <= 3'd0;
            nxt_v <= 1'b0;
            for (z = 0; z < 3; z = z + 1) begin
                bp[z] <= 8'd0;
                bp1[z] <= 8'd1;
            end
        end else begin
            inc_q <= 3'd0;
            if (hold != 2'd0)
                hold <= hold - 2'd1;
            // The next group is chosen from settled readiness only.
            nxt_v <= running && (hold == 2'd0) && !restart && nxt_any;
            nxt_p <= nxt_sel;
            nxt_b <= bsrc[nxt_sel];
            if (drain != 5'd0) begin
                drain <= drain - 5'd1;
                if (drain == 5'd1 && op == `MLKEM_OP_DECAPS && !job) begin
                    job <= 1'b1;
                    kind <= `MLKEM_PJ_ENC;
                    running <= 1'b1;
                    groups <= 9'd0;
                    hold <= 2'd3;
                    for (z = 0; z < 3; z = z + 1) begin
                        bp[z] <= 8'd0;
                        bp1[z] <= 8'd1;
                    end
                end
            end
            if (go) begin
                hold <= 2'd3;
                running <= 1'b1;
                job <= 1'b0;
                kind <= (op == `MLKEM_OP_KEYGEN) ? `MLKEM_PJ_KG :
                        (op == `MLKEM_OP_ENCAPS) ? `MLKEM_PJ_ENC : `MLKEM_PJ_DEC;
                in_grp <= 1'b0;
                j <= 3'd0;
                jlast <= 1'b0;
                groups <= 9'd0;
                for (z = 0; z < 3; z = z + 1) begin
                    bp[z] <= 8'd0;
                    bp1[z] <= 8'd1;
                end
            end else if (issue) begin
                if (start) begin
                    cur <= nxt_p;
                    cur_oh <= 3'b001 << nxt_p;
                    g1_cur <= g1_q[nxt_p];
                    b_grp <= nxt_b;
                    bp_nx <= nxt_b + (g1_q[nxt_p] ? 8'd1 : 8'd2);
                    bp1_nx <= nxt_b + (g1_q[nxt_p] ? 8'd2 : 8'd4);
                end
                if (last_j) begin
                    in_grp <= 1'b0;
                    j <= 3'd0;
                    jlast <= 1'b0;
                    bp[cur] <= bp_nx;
                    bp1[cur] <= bp1_nx;
                    inc_q[cur] <= 1'b1;
                    groups <= groups + (g1_cur ? 9'd1 : 9'd2);
                    if (groups + (g1_cur ? 9'd1 : 9'd2) == total) begin
                        running <= 1'b0;
                        drain <= DRAIN;
                    end
                end else begin
                    in_grp <= 1'b1;
                    j <= j + 3'd1;
                    jlast <= (j + 3'd1 == km1_reg);
                end
            end
        end
    end

    // Stage 1: registered read addresses (the S, T and vector memories
    // register b[7:2] themselves, so their copy equals blk1)
    reg v1, g1_1, last1;
    reg [1:0] h1;
    reg [4:0] blk1;
    reg [1:0] p1;
    reg [1:0] j1;
    reg [1:0] ms0_1;
    reg [1:0] ms1_1;
    always @(posedge clk) begin
        if (!rst_n || kill)
            v1 <= 1'b0;
        else
            v1 <= issue;
        g1_1 <= g1;
        blk1 <= b[7:2];
        h1 <= b[1:0];
        p1 <= p;
        j1 <= j[1:0];
        ms0_1 <= msrc0;
        ms1_1 <= msrc1;
        last1 <= last_j;
    end

    // Both rows of a pair share row bit 1 (= p[0]); parity selects the half.
    assign ae_slot = {p1[0], j1};
    assign ao_slot = {p1[0], j1};
    assign a_blk = blk1;
    assign s_slot = j1;
    assign s_blk = b[7:2];
    assign t_slot = j1;
    assign t_blk = b[7:2];
    assign v_slot = j1;
    assign v_blk = b[7:2];

    wire [47:0] g_blk;
    mlkem_gamma_rom u_gamma (.blk(blk1), .g(g_blk));

    function [23:0] qtr24;
        input [95:0] f_blk;
        input [1:0] f_h;
        qtr24 = f_blk[24*f_h +: 24];
    endfunction

    // Stage R: the operand blocks this term needs, registered after the
    // source select only (the quarters are taken in stage 2): the even-row
    // source, the odd-row source and the vector.
    reg vr, g1_r, last_r;
    reg [1:0] h_r;
    reg [1:0] h1_r;                 // h_r + 1 (the next quarter), registered
    reg [8:0] meta_r;
    reg [95:0] x0_r, x1_r, v_r;
    reg [47:0] g_r;
    always @(posedge clk) begin
        if (!rst_n || kill)
            vr <= 1'b0;
        else
            vr <= v1;
        g1_r <= g1_1;
        last_r <= last1;
        meta_r <= {p1, blk1, h1};
        h_r <= h1;
        h1_r <= h1 + 2'd1;
        x0_r <= (ms0_1 == `MLKEM_MS_A) ? ae_rdata : (ms0_1 == `MLKEM_MS_S) ? s_rdata : t_rdata;
        x1_r <= (ms1_1 == `MLKEM_MS_A) ? ao_rdata : t_rdata;
        v_r <= v_rdata;
        g_r <= {24'd0, g_blk[12*(h1 + 2'd1) +: 12], g_blk[12*h1 +: 12]};
    end

    // Stage 2: operands (the quarter of the block this term covers)
    reg v2, g1_2, last2;
    reg [23:0] m0_2, m1_2;
    reg [23:0] y2;
    reg [11:0] g2, g2b;
    reg [23:0] y2b;
    reg [9:0] meta2;                // {two rows, pair, block, quarter} of the term
    always @(posedge clk) begin
        if (!rst_n || kill)
            v2 <= 1'b0;
        else
            v2 <= vr;
        g1_2 <= g1_r;
        last2 <= last_r;
        m0_2 <= qtr24(x0_r, h_r);
        // Single-row pair: lane 1 takes the next quarter of the even row.
        m1_2 <= g1_r ? qtr24(x1_r, h_r) : qtr24(x0_r, h1_r);
        y2 <= qtr24(v_r, h_r);
        y2b <= qtr24(v_r, g1_r ? h_r : h1_r);
        g2 <= g_r[11:0];
        g2b <= g1_r ? g_r[11:0] : g_r[23:12];
        meta2 <= {g1_r, meta_r};
    end

    // Two basemul lanes (one per row of the pair, or two quarters of a
    // single row); they start every request with empty accumulators.
    wire lane_rst_n = rst_n && !kill && !go;
    wire [1:0] acc_v;
    wire [23:0] acc0, acc1;
    mlkem_basemul_lane u_lane0 (
        .clk(clk), .rst_n(lane_rst_n), .in_valid(v2), .in_last(last2),
        .a0(m0_2[11:0]), .a1(m0_2[23:12]), .b0(y2[11:0]), .b1(y2[23:12]), .g(g2),
        .out_valid(acc_v[0]), .r0(acc0[11:0]), .r1(acc0[23:12])
    );
    mlkem_basemul_lane u_lane1 (
        .clk(clk), .rst_n(lane_rst_n), .in_valid(v2), .in_last(last2),
        .a0(m1_2[11:0]), .a1(m1_2[23:12]), .b0(y2b[11:0]), .b1(y2b[23:12]), .g(g2b),
        .out_valid(acc_v[1]), .r0(acc1[11:0]), .r1(acc1[23:12])
    );

    // Result scaling. The vector operands come unscaled from the NTT engines;
    // the factor is applied once to each sum (the sum is linear):
    //   KeyGen          * 2^16  (the lanes remove 2^16; t^ = A o s^ exactly)
    //   Encaps, Decaps  * 2^9   (the lanes remove 2^16, the INTT adds 2^7)
    reg scale_kg;
    always @(posedge clk)
        scale_kg <= (kind == `MLKEM_PJ_KG);
    wire [1:0] lane_v;
    wire [23:0] res0, res1;
    genvar l;
    generate
        for (l = 0; l < 2; l = l + 1) begin : g_scale
            mlkem_scale u_s0 (.clk(clk), .kg(scale_kg), .x(acc0[12*l +: 12]), .r(res0[12*l +: 12]));
            mlkem_scale u_s1 (.clk(clk), .kg(scale_kg), .x(acc1[12*l +: 12]), .r(res1[12*l +: 12]));
        end
    endgenerate
    reg [2*SCALE_LAT-1:0] sv_sr;          // valid flags beside the scaling
    always @(posedge clk) begin
        if (!lane_rst_n)
            sv_sr <= {2*SCALE_LAT{1'b0}};
        else
            sv_sr <= {sv_sr[2*SCALE_LAT-3:0], acc_v};
    end
    assign lane_v = sv_sr[2*SCALE_LAT-1 -: 2];

    wire [9:0] meta_o;
    mlkem_delay #(.W(10), .D(LANE_LAT)) u_meta (.clk(clk), .d(meta2), .q(meta_o));
    wire g1_o = meta_o[9];

    wire [2:0] or0 = {meta_o[8:7], 1'b0};
    wire [2:0] or1 = {meta_o[8:7], 1'b1};

    // The lower half of a block is held until its upper half (the next group
    // of the same pair, k cycles later) completes; only full blocks are written.
    // Two-row pair: quarter q of each row per group. Single-row pair: lane 0
    // has quarter q (0 or 2) of the row, lane 1 quarter q + 1.
    wire hi_o = (meta_o[1:0] == (g1_o ? 2'd3 : 2'd2));
    reg [71:0] lo0, lo1;
    always @(posedge clk) begin
        if (lane_v[0] && !hi_o) begin
            if (g1_o)
                lo0 <= {res0, lo0[71:24]};
            else
                lo0[47:0] <= {res1, res0};
        end
        if (lane_v[1] && !hi_o && g1_o)
            lo1 <= {res1, lo1[71:24]};
    end
    wire out0_v = lane_v[0] && hi_o;
    wire out1_v = lane_v[1] && hi_o && g1_o;
    wire [95:0] blk0 = g1_o ? {res0, lo0} : {res1, res0, lo0[47:0]};

    // ENC row r < k feeds row lane 4 + r; the t^.y^ row (r = k) and DEC feed
    // lane 8. The two ports never address lane 8 in the same cycle.
    wire row0_v = out0_v && !to_t;
    wire row1_v = out1_v && !to_t;
    wire to8_0 = !((kind == `MLKEM_PJ_ENC) && (or0 != k));
    wire to8_1 = !((kind == `MLKEM_PJ_ENC) && (or1 != k));

    always @(posedge clk) begin
        if (!rst_n || kill) begin
            wr_t_en <= 4'd0;
            wr_lane_en <= 5'd0;
        end else begin
            wr_t_en[0] <= out0_v && to_t && (or0 == 3'd0);
            wr_t_en[1] <= out1_v && to_t && (or1 == 3'd1);
            wr_t_en[2] <= out0_v && to_t && (or0 == 3'd2);
            wr_t_en[3] <= out1_v && to_t && (or1 == 3'd3);
            wr_lane_en[4] <= row0_v && !to8_0 && (or0 == 3'd0);
            wr_lane_en[5] <= row1_v && !to8_1 && (or1 == 3'd1);
            wr_lane_en[6] <= row0_v && !to8_0 && (or0 == 3'd2);
            wr_lane_en[7] <= row1_v && !to8_1 && (or1 == 3'd3);
            wr_lane_en[8] <= (row0_v && to8_0) || (row1_v && to8_1);
        end
        wr8_p1 <= row1_v && to8_1;
        wr8_ep <= (kind == `MLKEM_PJ_ENC) && v_e;
        wr_blk <= meta_o[6:2];
        wr_first <= (meta_o[6:2] == 5'd0);
        wr0_data <= blk0;
        wr1_data <= {res1, lo1};
    end

endmodule
