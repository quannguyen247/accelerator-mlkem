`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// Polynomial multiply-accumulate unit: out[r] = sum_j M[r][j] o V[j] * 2^-16.
// Rows are processed in pairs (r0 = 2p, r1 = 2p + 1) that share the V[j]
// block read: two groups of four basemul lanes handle one 8-coefficient block
// of each row per cycle (16 coefficients/cycle). The matrix store is split by
// row parity, so the two matrix reads never collide. Each step issues only
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

    // Results: T store (KeyGen) or lane buffers 4..8
    output reg wr0_en,
    output reg wr1_en,
    output reg wr_t,
    output reg [2:0] wr0_row,
    output reg [2:0] wr1_row,
    output reg [3:0] wr0_lane,
    output reg [3:0] wr1_lane,
    output reg [4:0] wr_blk,
    output reg [95:0] wr0_data,
    output reg [95:0] wr1_data,
    output reg wr0_ep,
    output reg wr1_ep
);

    `include "mlkem_funcs.vh"

    localparam LANE_LAT = 15;
    localparam DRAIN = 20;

    reg running;
    reg job;
    reg [1:0] kind;
    reg [5:0] bp [0:2];       // next block of each row pair (32 = finished)
    reg [1:0] cur;            // pair of the group in progress
    reg [1:0] last;           // last pair started (round robin)
    reg in_grp;
    reg [2:0] j;
    reg [6:0] groups;         // completed (pair, block) groups of the job
    reg [4:0] drain;

    wire [2:0] rows = (kind == `MLKEM_PJ_KG) ? k : (kind == `MLKEM_PJ_ENC) ? k + 3'd1 : 3'd1;
    reg [1:0] last_p;               // ceil(rows / 2) - 1, constant during a job
    always @(posedge clk)
        last_p <= rows[2:1] - {1'b0, ~rows[0]};
    wire [6:0] total = {last_p + 2'd1, 5'd0};
    wire v_e = (kind == `MLKEM_PJ_ENC) && (op == `MLKEM_OP_DECAPS);
    wire to_t = (kind == `MLKEM_PJ_KG);

    // A group (one block of both rows of a pair, all k terms) is started only
    // when every operand block it needs exists; fills only grow, so the group
    // then runs k cycles without a stall. KeyGen and Encaps take the lowest
    // ready pair first, so rows finish in output order (t^ / c1 stream out
    // early); the Decaps re-encryption only compares, so ready pairs are taken
    // round robin and all INTT loads finish together.
    // Readiness is registered for the current and the next block of every
    // pair (fills only grow, so a one-cycle-old answer is conservative); after
    // a pair finishes a group its "next block" answer applies.
    reg [2:0] rdy_cur, rdy_nxt;     // combinational
    reg [2:0] rdy_q, rdyn_q;        // registered
    reg [2:0] inc_q;                // bp[q] advanced in the previous cycle

    // Per-job pair constants and epoch-filtered vector fills, registered.
    reg [1:0] ms0_q [0:2];
    reg [1:0] ms1_q [0:2];
    reg [2:0] g1_q;
    reg [2:0] qv_q;
    reg [5:0] fv_q [0:3];
    integer q, jj;
    reg [2:0] rq0, rq1;
    always @(posedge clk) begin
        for (q = 0; q < 3; q = q + 1) begin
            rq0 = 2 * q;
            rq1 = 2 * q + 1;
            ms0_q[q] <= (kind == `MLKEM_PJ_KG) ? `MLKEM_MS_A : (kind == `MLKEM_PJ_DEC) ? `MLKEM_MS_S :
                        (rq0 == k) ? `MLKEM_MS_T : `MLKEM_MS_A;
            ms1_q[q] <= ((kind == `MLKEM_PJ_ENC) && (rq1 == k)) ? `MLKEM_MS_T : `MLKEM_MS_A;
            g1_q[q] <= (rq1 < rows);
            qv_q[q] <= (q <= last_p);
        end
        for (jj = 0; jj < 4; jj = jj + 1)
            fv_q[jj] <= (v_ep[jj] == v_e) ? v_fill[jj * 6 +: 6] : 6'd0;
    end

    reg ok0, ok1;
    reg [5:0] bq, f0, f1, fv;
    always @(*) begin
        rdy_cur = 3'd0;
        rdy_nxt = 3'd0;
        f0 = 6'd0;
        f1 = 6'd0;
        fv = 6'd0;
        for (q = 0; q < 3; q = q + 1) begin
            bq = bp[q];
            ok0 = qv_q[q];
            ok1 = qv_q[q];
            for (jj = 0; jj < 4; jj = jj + 1) begin
                if (jj < k) begin
                    f0 = (ms0_q[q] == `MLKEM_MS_A) ? a_fill[((8 * q + jj) % 16) * 6 +: 6] :
                         (ms0_q[q] == `MLKEM_MS_S) ? s_fill[jj * 6 +: 6] : t_fill[jj * 6 +: 6];
                    f1 = (ms1_q[q] == `MLKEM_MS_A) ? a_fill[((8 * q + 4 + jj) % 16) * 6 +: 6] : t_fill[jj * 6 +: 6];
                    fv = fv_q[jj];
                    if (!(f0 > bq) || (g1_q[q] && !(f1 > bq)) || !(fv > bq))
                        ok0 = 1'b0;
                    if (!(f0 > bq + 6'd1) || (g1_q[q] && !(f1 > bq + 6'd1)) || !(fv > bq + 6'd1))
                        ok1 = 1'b0;
                end
            end
            rdy_cur[q] = ok0;
            rdy_nxt[q] = ok1;
        end
    end

    always @(posedge clk) begin
        rdy_q <= rdy_cur;
        rdyn_q <= rdy_nxt;
    end

    wire [2:0] rdy = (inc_q & rdyn_q) | (~inc_q & rdy_q);

    wire [1:0] c0 = !v_e ? 2'd0 : ((last >= last_p) ? 2'd0 : last + 2'd1);
    wire [1:0] c1 = (c0 >= last_p) ? 2'd0 : c0 + 2'd1;
    wire [1:0] c2 = (c1 >= last_p) ? 2'd0 : c1 + 2'd1;
    wire any_rdy = rdy[c0] || rdy[c1] || rdy[c2];
    wire [1:0] p_sel = rdy[c0] ? c0 : rdy[c1] ? c1 : c2;

    reg [1:0] hold;                 // registered readiness settles after a (re)start (3 cycles)
    wire issue = running && (drain == 5'd0) && (hold == 2'd0) && (in_grp || any_rdy);
    reg [5:0] b_grp;                // block of the group in progress
    wire [1:0] p = in_grp ? cur : p_sel;
    wire [5:0] b = in_grp ? b_grp : bp[p_sel];
    wire last_j = (j == k - 3'd1);

    wire [2:0] r0 = {p, 1'b0};
    wire [2:0] r1 = {p, 1'b1};
    wire g1 = (r1 < rows);
    wire [1:0] msrc0 = (kind == `MLKEM_PJ_KG) ? `MLKEM_MS_A :
                       (kind == `MLKEM_PJ_DEC) ? `MLKEM_MS_S :
                       (r0 == k) ? `MLKEM_MS_T : `MLKEM_MS_A;
    wire [1:0] msrc1 = ((kind == `MLKEM_PJ_ENC) && (r1 == k)) ? `MLKEM_MS_T : `MLKEM_MS_A;

    assign busy = running || (drain != 5'd0);

    integer z;
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            running <= 1'b0;
            job <= 1'b0;
            kind <= `MLKEM_PJ_KG;
            in_grp <= 1'b0;
            j <= 3'd0;
            groups <= 7'd0;
            last <= 2'd3;
            drain <= 5'd0;
            hold <= 2'd0;
            inc_q <= 3'd0;
            for (z = 0; z < 3; z = z + 1)
                bp[z] <= 6'd0;
        end else begin
            inc_q <= 3'd0;
            if (hold != 2'd0)
                hold <= hold - 2'd1;
            if (drain != 5'd0) begin
                drain <= drain - 5'd1;
                if (drain == 5'd1 && op == `MLKEM_OP_DECAPS && !job) begin
                    job <= 1'b1;
                    kind <= `MLKEM_PJ_ENC;
                    running <= 1'b1;
                    groups <= 7'd0;
                    last <= 2'd3;
                    hold <= 2'd3;
                    for (z = 0; z < 3; z = z + 1)
                        bp[z] <= 6'd0;
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
                groups <= 7'd0;
                last <= 2'd3;
                for (z = 0; z < 3; z = z + 1)
                    bp[z] <= 6'd0;
            end else if (issue) begin
                if (!in_grp) begin
                    cur <= p_sel;
                    last <= p_sel;
                    b_grp <= bp[p_sel];
                end
                if (last_j) begin
                    in_grp <= 1'b0;
                    j <= 3'd0;
                    bp[cur] <= b_grp + 6'd1;
                    inc_q[cur] <= 1'b1;
                    groups <= groups + 7'd1;
                    if (groups + 7'd1 == total) begin
                        running <= 1'b0;
                        drain <= DRAIN;
                    end
                end else begin
                    in_grp <= 1'b1;
                    j <= j + 3'd1;
                end
            end
        end
    end

    // Stage 1: registered read addresses
    reg v1, g1_1, last1;
    reg [4:0] blk1;
    reg [1:0] p1;
    reg [1:0] j1;
    reg [1:0] ms0_1, ms1_1;
    always @(posedge clk) begin
        if (!rst_n || kill)
            v1 <= 1'b0;
        else
            v1 <= issue;
        g1_1 <= g1;
        blk1 <= b;
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
    assign s_blk = blk1;
    assign t_slot = j1;
    assign t_blk = blk1;
    assign v_slot = j1;
    assign v_blk = blk1;

    wire [47:0] g_blk;
    mlkem_gamma_rom u_gamma (.blk(blk1), .g(g_blk));

    // Stage 2: operands
    reg v2, g1_2, last2;
    reg [95:0] m0_2, m1_2;
    reg [95:0] y2;
    reg [47:0] g2;
    reg [7:0] meta2;
    always @(posedge clk) begin
        if (!rst_n || kill)
            v2 <= 1'b0;
        else
            v2 <= v1;
        g1_2 <= g1_1;
        last2 <= last1;
        m0_2 <= (ms0_1 == `MLKEM_MS_A) ? ae_rdata : (ms0_1 == `MLKEM_MS_S) ? s_rdata : t_rdata;
        m1_2 <= (ms1_1 == `MLKEM_MS_A) ? ao_rdata : t_rdata;
        y2 <= v_rdata;
        g2 <= g_blk;
        meta2 <= {g1_1, p1, blk1};
    end

    // The lanes start every request with empty accumulators.
    wire lane_rst_n = rst_n && !kill && !go;
    wire [7:0] lane_v;
    wire [95:0] res0, res1;
    genvar l;
    generate
        for (l = 0; l < 4; l = l + 1) begin : g_lane
            mlkem_basemul_lane u_lane0 (
                .clk(clk),
                .rst_n(lane_rst_n),
                .in_valid(v2),
                .in_last(last2),
                .a0(m0_2[24*l +: 12]),
                .a1(m0_2[24*l+12 +: 12]),
                .b0(y2[24*l +: 12]),
                .b1(y2[24*l+12 +: 12]),
                .g(g2[12*l +: 12]),
                .out_valid(lane_v[l]),
                .r0(res0[24*l +: 12]),
                .r1(res0[24*l+12 +: 12])
            );
            mlkem_basemul_lane u_lane1 (
                .clk(clk),
                .rst_n(lane_rst_n),
                .in_valid(v2 && g1_2),
                .in_last(last2),
                .a0(m1_2[24*l +: 12]),
                .a1(m1_2[24*l+12 +: 12]),
                .b0(y2[24*l +: 12]),
                .b1(y2[24*l+12 +: 12]),
                .g(g2[12*l +: 12]),
                .out_valid(lane_v[4+l]),
                .r0(res1[24*l +: 12]),
                .r1(res1[24*l+12 +: 12])
            );
        end
    endgenerate

    wire [7:0] meta_o;
    mlkem_delay #(.W(8), .D(LANE_LAT)) u_meta (.clk(clk), .d(meta2), .q(meta_o));

    wire [2:0] or0 = {meta_o[6:5], 1'b0};
    wire [2:0] or1 = {meta_o[6:5], 1'b1};

    // ENC row r < k feeds row lane 4 + r; the t^.y^ row and DEC feed lane 8.
    wire [3:0] dest0 = ((kind == `MLKEM_PJ_ENC) && (or0 != k)) ? {1'b0, or0} + 4'd4 : 4'd8;
    wire [3:0] dest1 = ((kind == `MLKEM_PJ_ENC) && (or1 != k)) ? {1'b0, or1} + 4'd4 : 4'd8;

    always @(posedge clk) begin
        if (!rst_n || kill) begin
            wr0_en <= 1'b0;
            wr1_en <= 1'b0;
        end else begin
            wr0_en <= lane_v[0];
            wr1_en <= lane_v[4];
        end
        wr_t <= to_t;
        wr0_row <= or0;
        wr1_row <= or1;
        wr0_lane <= dest0;
        wr1_lane <= dest1;
        wr_blk <= meta_o[4:0];
        wr0_ep <= (kind == `MLKEM_PJ_ENC) && (or0 == k) && v_e;
        wr1_ep <= (kind == `MLKEM_PJ_ENC) && (or1 == k) && v_e;
        wr0_data <= res0;
        wr1_data <= res1;
    end

endmodule
