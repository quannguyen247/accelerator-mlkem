`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// ML-KEM (FIPS 203) KeyGen / Encaps / Decaps core, ML-KEM-512/768/1024.
//
// Dataflow organisation: every engine runs its own fixed program for the
// latched operation and waits only on block-level progress of the objects it
// reads, so the Keccak, the nine NTT lanes, the multiply-accumulate unit and
// both stream engines overlap. One request is active at a time.
//
//   request words -> mlkem_in --> S / T / C stores, rho/h/z, hash FIFO
//   mlkem_hash (keccak_top) --> sampler (A store), lane noise, rho/K/h
//   lanes 0..3 (NTT), 4..7 (INTT, KeyGen NTT), 8 (INTT) <-> mlkem_pmac
//   mlkem_out <-- S / T / C stores and registers --> result words
//
// The request and result words (64-bit, FIPS 203 byte order, lowest byte in
// bits [7:0]) move on valid/ready ports; the core takes exactly the words of
// its request and emits exactly the words of its result.
// Seed words (32-bit) are written while ready: words 0..7 are d (KeyGen) or
// m (Encaps), words 8..15 are z (KeyGen). The seed is cleared at the end of
// every request and by seed_clr.
module mlkem_core (
    input wire clk,
    input wire rst_n,

    input wire start,
    input wire [1:0] op,
    input wire [1:0] pset,
    input wire [15:0] seed_we,
    input wire [31:0] seed_wdata,
    input wire seed_clr,
    input wire abort,
    output wire ready,
    output reg done,
    output reg error,
    output reg [2:0] err_code,

    // Request words
    input wire [63:0] in_data,
    input wire in_valid,
    output wire in_ready,

    // Result words
    output wire [63:0] out_data,
    output wire out_valid,
    input wire out_ready
);

    `include "mlkem_funcs.vh"

    localparam [1:0] IDLE = 2'd0;
    localparam [1:0] RUN  = 2'd1;
    localparam [1:0] WAIT = 2'd2;
    localparam [1:0] DONE = 2'd3;

    reg [1:0] tstate;
    reg [1:0] op_r;
    reg [2:0] k_r;
    reg [255:0] seed_a;
    reg go;
    reg launch;                     // op_r / k_r latched, go follows next cycle
    reg kill;
    reg scrub;
    reg scrub_r;
    reg boot;
    reg computed;
    reg [1:0] run_age;
    reg zero_core;
    reg started;
    reg [5:0] sc;
    reg fail;
    reg [2:0] fail_code;

    assign ready = (tstate == IDLE) && !launch;

    // Engines
    wire in_busy, out_busy, hsh_busy, pmac_busy;
    wire out_secrets_read;
    wire in_err;
    wire hfail;

    wire fifo_push_in, fifo_push_out, fifo_pop, fifo_full, fifo_empty;
    wire [63:0] fifo_din_in, fifo_din_out, fifo_dout;

    wire [3:0] st_we_s;
    wire [3:0] st_we_t;
    wire [4:0] st_we_c;
    wire [4:0] st_blk;
    wire st_first;
    wire [95:0] st_data;
    wire [255:0] in_rho, in_h, in_z;
    wire in_rho_v, in_h_v, in_z_v;

    wire [255:0] rho, h;
    wire rho_v, h_v, kk_v, kbar_v;

    wire hs_wr_rho, hs_wr_h;
    wire [255:0] hs_wr_val;
    wire nz_we;
    wire [3:0] nz_lane;
    wire [4:0] nz_addr;
    wire [63:0] nz_wdata;

    wire smp_load, smp_new, smp_busy;
    wire [3:0] smp_slot;
    wire [1343:0] cap;
    wire [8:0] smp_count;
    wire smp_nz_start, smp_nz_run;
    wire [95:0] smp_chunk;
    wire [16*6-1:0] a_fill;
    wire [95:0] ae_rdata, ao_rdata;

    wire [2:0] pm_ae_slot, pm_ao_slot;
    wire [4:0] pm_a_blk, pm_s_blk, pm_t_blk, pm_v_blk;
    wire [1:0] pm_s_slot, pm_t_slot, pm_v_slot;
    wire [3:0] pm_wr_t_en;
    wire [8:4] pm_wr_lane_en;
    wire pm_wr8_p1, pm_wr8_ep;
    wire [4:0] pm_wr_blk;
    wire pm_wr_first;
    wire [95:0] pm_wr0_data, pm_wr1_data;

    wire [1:0] out_rd_dest;
    wire [2:0] out_rd_slot, out_rd_dslot;
    wire [2:0] out_rd_dslot_t, out_rd_dslot_b;
    wire out_rd_en;
    wire [4:0] out_rd_blk;

    // m' (Decaps) is kept in seed_a, which Decaps does not use.
    reg [8:0] mp_cnt;
    wire mprime_v = mp_cnt[8];

    // Lane context arrays
    localparam integer NENG = 2;    // shared NTT engines
    // Fixed engine of each logical lane (lane 8: either), see the dispatcher
    localparam [8:0] LMASK0 = 9'b1_1010_0101;
    localparam [8:0] LMASK1 = 9'b1_0101_1010;
    wire [95:0] l_pm_rdata [0:8];
    wire [5:0] l_b_fill [0:8];
    wire [8:0] l_b_ep;
    // C store read address of each slot: the engine whose job reads it
    reg [4:0] ec_rblk [0:4];

    // Stores
    // Store port selects, registered (constant during a request).
    reg is_kg;
    reg is_enc;
    reg is_dec;
    always @(posedge clk) begin
        is_kg <= (op_r == `MLKEM_OP_KEYGEN);
        is_enc <= (op_r == `MLKEM_OP_ENCAPS);
        is_dec <= (op_r == `MLKEM_OP_DECAPS);
    end
    // The output engine reads the vector lane buffers (KeyGen s^ segment;
    // its segment fields are registers, the S store of the segment table)
    wire out_s_sel = is_kg && (out_rd_dest == 2'd0);
    // sc counts 0..32 in WAIT only (it is 32 in every other state), so its
    // top bit alone tells whether the stores are being cleared.
    wire scrub_mem = !sc[5];

    // Every store has one read port, shared by the compute engines (PMAC,
    // lanes) and the output engine (*_o) by request type. Reads take one
    // cycle: the block address is registered in the store (the output
    // engine's address only while out_rd_en, see mlkem_out).
    wire [95:0] s_rd [0:3];
    wire [95:0] t_rd [0:3];
    wire [87:0] c_rd [0:4];
    wire [95:0] t_rd_o [0:3];
    wire [5:0] s_fill [0:3];
    wire [5:0] t_fill [0:3];
    wire [5:0] c_fill [0:4];

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_st
            // S: Decaps s^ from the input (KeyGen s^ stays in the vector
            // lane buffers, where the output engine reads it). The input's
            // block register is zero outside its store writes, so the scrub
            // writes it as is.
            wire s_in = st_we_s[g];
            wire s_we = scrub_mem || s_in;
            wire [4:0] s_wa = scrub_mem ? sc[4:0] : st_blk;
            // Read by the PMAC only (Decaps)
            mlkem_poly_ram #(.W(12), .AW(5), .RREG(1)) u_s (
                .clk(clk), .we({8{s_we}}), .waddr({8{s_wa}}), .wdata(st_data),
                .ra_en(1'b1), .raddr(pm_s_blk),
                .rdata(s_rd[g]));
            wire s_ep_unused;
            mlkem_slot_state u_s_st (
                .clk(clk), .rst_n(rst_n), .clr(go),
                .first(st_first),
                .first_ep(1'b0),
                .inc(s_in),
                .fill(s_fill[g]), .ep(s_ep_unused));

            // T: t^ from the input, or KeyGen t^ from the PMAC (even rows on
            // write port 0, odd rows on port 1).
            wire t_in = st_we_t[g];
            wire t_pm = pm_wr_t_en[g];
            wire [95:0] t_pm_data = (g % 2 == 0) ? pm_wr0_data : pm_wr1_data;
            wire t_ep_unused;
            // One read port: the output engine reads T only in KeyGen (the
            // PMAC writes it then), the PMAC only in Encaps / Decaps.
            mlkem_poly_ram #(.W(12), .AW(5), .RREG(1)) u_t (
                .clk(clk), .we({8{t_in || t_pm}}), .waddr({8{t_pm ? pm_wr_blk : st_blk}}),
                .wdata(t_pm ? t_pm_data : st_data),
                .ra_en(is_kg ? out_rd_en : 1'b1), .raddr(is_kg ? out_rd_blk : pm_t_blk),
                .rdata(t_rd[g]));
            assign t_rd_o[g] = t_rd[g];
            mlkem_slot_state u_t_st (
                .clk(clk), .rst_n(rst_n), .clr(go),
                .first((t_in && st_first) || (t_pm && pm_wr_first)),
                .first_ep(1'b0), .inc(t_in || t_pm),
                .fill(t_fill[g]), .ep(t_ep_unused));
        end

        for (g = 0; g < 5; g = g + 1) begin : g_c
            // C: the Decaps ciphertext, compressed u (slots 0..3) and v
            // (slot 4), from the input; read by the engines. (Encaps writes
            // its ciphertext to the row / scalar lane buffers.)
            wire c_in = st_we_c[g];
            wire [87:0] c_wd;
            genvar bi;
            for (bi = 0; bi < 8; bi = bi + 1) begin : g_cw
                assign c_wd[11*bi +: 11] = st_data[12*bi +: 11];
            end
            mlkem_poly_ram #(.W(11), .AW(5), .RREG(1)) u_c (
                .clk(clk), .we({8{c_in}}), .waddr({8{st_blk}}), .wdata(c_wd),
                .ra_en(1'b1), .raddr(ec_rblk[g]),
                .rdata(c_rd[g]));
            wire c_ep_unused;
            mlkem_slot_state u_c_st (
                .clk(clk), .rst_n(rst_n), .clr(go),
                .first(c_in && st_first),
                .first_ep(1'b0),
                .inc(c_in),
                .fill(c_fill[g]), .ep(c_ep_unused));
        end
    endgenerate

    // Lanes: nine logical lanes (contexts: noise memory and buffer) served
    // by NENG shared NTT engines. A job of a logical lane is dispatched to a
    // free engine once its load source has its first block; the engine then
    // runs it to completion (load, transform, unload).
    wire [4:0] x_nz_cnt [0:8];
    wire [63:0] x_nz_rdata [0:8];
    wire [95:0] x_e_rdata [0:8];
    wire [8:0] x_busy;

    wire [NENG-1:0] e_busy;
    wire [3:0] e_lid [0:NENG-1];
    wire [2:0] e_cslot [0:NENG-1];
    wire [4:0] e_nz_raddr [0:NENG-1];
    wire [4:0] e_b_rblk [0:NENG-1];
    wire [NENG-1:0] e_b_we;
    wire [5:0] e_b_widx [0:NENG-1];
    wire [47:0] e_b_wdata [0:NENG-1];
    wire [NENG-1:0] e_b_first, e_b_last, e_b_wep;
    wire [NENG-1:0] e_c_rreq;
    wire [4:0] e_c_rblk [0:NENG-1];
    wire [3:0] e_mp_bits [0:NENG-1];
    wire [5:0] e_mu_idx [0:NENG-1];
    wire [NENG-1:0] e_mp_we;
    wire [NENG-1:0] e_diff;

    // Lane and C slot of each engine's job, one-hot, registered with the job
    // start (as the engine's lid): the selects below need no compare.
    reg [8:0] lsel [0:NENG-1];
    reg [4:0] csel [0:NENG-1];

    // Engine port of each context: the engine whose current job is this lane.
    // Read addresses pass straight through; the unload writes are registered
    // (the fill moves with them, so readers see the same order).
    reg [4:0] x_nz_raddr [0:8];
    reg [4:0] x_e_rblk [0:8];
    reg [8:0] x_e_we, x_e_first, x_e_last, x_e_ep;
    reg [5:0] x_e_widx [0:8];
    reg [47:0] x_e_wdata [0:8];
    integer xe, xl;
    always @(*) begin
        for (xl = 0; xl < 9; xl = xl + 1) begin
            x_nz_raddr[xl] = 5'd0;
            x_e_rblk[xl] = 5'd0;
            for (xe = 0; xe < NENG; xe = xe + 1)
                if (((xe == 0) ? LMASK0[xl] : LMASK1[xl]) && (xl != 8 || lsel[xe][8])) begin
                    x_nz_raddr[xl] = e_nz_raddr[xe];
                    x_e_rblk[xl] = e_b_rblk[xe];
                end
        end
    end
    always @(*) begin
        for (xl = 0; xl < 9; xl = xl + 1) begin
            x_e_we[xl] = 1'b0;
            x_e_first[xl] = 1'b0;
            x_e_last[xl] = 1'b0;
            x_e_ep[xl] = 1'b0;
            x_e_widx[xl] = 6'd0;
            x_e_wdata[xl] = 48'd0;
            for (xe = 0; xe < NENG; xe = xe + 1)
                if (((xe == 0) ? LMASK0[xl] : LMASK1[xl]) && (xl != 8 || lsel[xe][8])) begin
                    x_e_we[xl] = e_b_we[xe] && lsel[xe][xl];
                    x_e_first[xl] = e_b_first[xe];
                    x_e_last[xl] = e_b_last[xe];
                    x_e_ep[xl] = e_b_wep[xe];
                    x_e_widx[xl] = e_b_widx[xe];
                    x_e_wdata[xl] = e_b_wdata[xe];
                end
        end
    end

    generate
        for (g = 0; g < 9; g = g + 1) begin : g_ctx
            // PMAC result write: row lanes take one port each (even rows
            // port 0, odd rows port 1), the scalar lane takes either; the
            // vector lanes are never written.
            wire pm_w;
            wire [95:0] pm_wdata;
            wire pm_wep;
            // Vector buffers: the PMAC, or the output engine while it reads
            // the KeyGen s^ segment (the PMAC has written every t^ row by then)
            wire [4:0] pm_rblk = (g >= 4) ? out_rd_blk : out_s_sel ? out_rd_blk : pm_v_blk;
            if (g < 4) begin : g_pm_none
                assign pm_w = 1'b0;
                assign pm_wdata = 96'd0;
                assign pm_wep = 1'b0;
            end else if (g < 8) begin : g_pm_row
                assign pm_w = pm_wr_lane_en[g];
                assign pm_wdata = (g % 2 == 0) ? pm_wr0_data : pm_wr1_data;
                assign pm_wep = 1'b0;
            end else begin : g_pm_scl
                assign pm_w = pm_wr_lane_en[8];
                assign pm_wdata = pm_wr8_p1 ? pm_wr1_data : pm_wr0_data;
                assign pm_wep = pm_wr8_ep;
            end
            mlkem_lane_ctx #(.LANE(g)) u_ctx (
                .clk(clk), .rst_n(rst_n), .kill(kill), .go(go), .scrub(scrub),
                .out_rd((g < 4) ? out_s_sel : (g < 8) ? (is_kg || (is_enc && l_b_ep[g])) :
                        (is_enc && l_b_ep[g])),
                .keep_buf((g >= 4) && is_enc && !zero_core), .busy(x_busy[g]),
                .nz_we(nz_we && nz_lane == g), .nz_addr(nz_addr), .nz_wdata(nz_wdata),
                .nz_cnt(x_nz_cnt[g]), .nz_raddr(x_nz_raddr[g]), .nz_rdata(x_nz_rdata[g]),
                .pm_ra_en(out_rd_en), .pm_rd_blk(pm_rblk), .pm_rd_data(l_pm_rdata[g]),
                .pm_we(pm_w), .pm_wr_blk(pm_wr_blk), .pm_wr_first(pm_wr_first),
                .pm_wr_data(pm_wdata), .pm_wr_ep(pm_wep),
                .e_rblk(x_e_rblk[g]), .e_rdata(x_e_rdata[g]),
                .e_we(x_e_we[g]), .e_widx(x_e_widx[g]), .e_wdata(x_e_wdata[g]),
                .e_first(x_e_first[g]), .e_last(x_e_last[g]), .e_ep(x_e_ep[g]),
                .b_fill(l_b_fill[g]), .b_ep(l_b_ep[g])
            );
        end
    endgenerate

    // Job dispatch. pend: lane has a job waiting; jn: its job number (the
    // vector and scalar lanes run a second job in Decaps, queued when the
    // first one completes).
    reg [8:0] pend;
    reg [8:0] jn;
    reg [8:0] rdy_q;
    reg [NENG-1:0] e_job;              // engine runs a dispatched job
    reg [NENG-1:0] e_busy_q;
    reg [NENG-1:0] jst;
    reg [3:0] jst_lane [0:NENG-1];
    reg [NENG-1:0] jst_num;

    // The load source of each lane's next job has its first block,
    // registered. A lane whose job number changes (second job queued) or
    // whose stores are cleared (go) reads not ready for that cycle, so a
    // stale answer never dispatches a job early.
    reg [8:0] rq_clr;
    integer rl, rc;
    always @(*) begin
        rq_clr = 9'd0;
        for (rc = 0; rc < NENG; rc = rc + 1)
            if (e_job[rc] && e_busy_q[rc] && !e_busy[rc])
                rq_clr[e_lid[rc]] = 1'b1;
    end
    always @(posedge clk) begin
        for (rl = 0; rl < 9; rl = rl + 1) begin
            if (go || launch || rq_clr[rl])
                rdy_q[rl] <= 1'b0;
            else if (rl < 4)
                rdy_q[rl] <= (is_dec && !jn[rl]) ? (c_fill[rl] != 6'd0) : (x_nz_cnt[rl] != 5'd0);
            else if (rl < 8)
                rdy_q[rl] <= is_kg ? (x_nz_cnt[rl] != 5'd0) : (!l_b_ep[rl] && l_b_fill[rl] != 6'd0);
            else
                rdy_q[rl] <= (l_b_ep[rl] == jn[rl]) && (l_b_fill[rl] != 6'd0);
        end
    end

    // Engine of each logical lane: fixed, so every context has one engine
    // port and every engine reads five contexts (no 9:1 selects). The vector
    // lanes and the rows alternate between the engines, the rows the other
    // way round, so each phase (vector NTTs, row INTTs) is split evenly for
    // k = 2, 3, 4 and for k = 3 the extra vector and the extra row run on
    // different engines; the scalar lane runs on whichever engine is free.
    //   engine 0: lanes 0, 2, 5, 7 (+ 8)    engine 1: lanes 1, 3, 4, 6 (+ 8)
    // Pick order within an engine: vector lanes, the rows, the scalar lane
    // (so the shared scalar job goes to the engine without a row to run),
    // i.e. the lowest candidate lane; picks are one-hot, like lsel.
    function [8:0] pick;
        input [8:0] c;
        pick = c & (~c + 9'd1);
    endfunction
    // C slot of a lane (one-hot): s for lanes s and s + 4, slot 4 for lane 8
    function [4:0] cslot_of;
        input [8:0] oh;
        cslot_of = {oh[8], oh[7:4] | oh[3:0]};
    endfunction
    function [3:0] lane_of;
        input [8:0] oh;
        integer li;
        begin
            lane_of = 4'd0;
            for (li = 0; li < 9; li = li + 1)
                if (oh[li])
                    lane_of = li[3:0];
        end
    endfunction
    wire [8:0] cand = pend & rdy_q;
    wire e0_free = !e_busy[0] && !jst[0];
    wire e1_free = !e_busy[1] && !jst[1];
    // Candidates of each engine; engine 1 sees lane 8 only if engine 0 does
    // not take it. The picks load lsel; their valid (any candidate) is
    // formed apart, so the register enables do not wait for the pick.
    wire [8:0] cd0 = cand & LMASK0;
    wire e0_l8 = e0_free && cd0[8] && (cd0[7:0] == 8'd0);
    wire [8:0] cd1 = cand & LMASK1 & ~{e0_l8, 8'd0};
    wire pk0_v = e0_free && (cd0 != 9'd0);
    wire pk1_v = e1_free && (cd1 != 9'd0);
    wire [8:0] pk0 = pick(cd0);
    wire [8:0] pk1 = pick(cd1);

    integer de, dl;
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            pend <= 9'd0;
            jn <= 9'd0;
            jst <= {NENG{1'b0}};
            e_job <= {NENG{1'b0}};
            e_busy_q <= {NENG{1'b0}};
            for (de = 0; de < NENG; de = de + 1) begin
                lsel[de] <= 9'd0;
                csel[de] <= 5'd0;
            end
        end else begin
            jst <= {NENG{1'b0}};
            e_busy_q <= e_busy;
            if (go) begin
                jn <= 9'd0;
                for (de = 0; de < 4; de = de + 1) begin
                    pend[de] <= (de < k_r);
                    pend[4 + de] <= (de < k_r);
                end
                pend[8] <= !is_kg;
                e_job <= {NENG{1'b0}};
            end else begin
                // Completed jobs: the Decaps vector and scalar lanes queue
                // their second job.
                for (de = 0; de < NENG; de = de + 1) begin
                    if (e_job[de] && e_busy_q[de] && !e_busy[de]) begin
                        e_job[de] <= 1'b0;
                        if (is_dec && (e_lid[de] < 4'd4 || e_lid[de] == 4'd8) &&
                            !jn[e_lid[de]]) begin
                            pend[e_lid[de]] <= 1'b1;
                            jn[e_lid[de]] <= 1'b1;
                        end
                    end
                end
                if (pk0_v) begin
                    lsel[0] <= pk0;
                    csel[0] <= cslot_of(pk0);
                    jst[0] <= 1'b1;
                    jst_lane[0] <= lane_of(pk0);
                    jst_num[0] <= |(jn & pk0);
                    for (dl = 0; dl < 9; dl = dl + 1)
                        if (pk0[dl])
                            pend[dl] <= 1'b0;
                    e_job[0] <= 1'b1;
                end
                if (pk1_v) begin
                    lsel[1] <= pk1;
                    csel[1] <= cslot_of(pk1);
                    jst[1] <= 1'b1;
                    jst_lane[1] <= lane_of(pk1);
                    jst_num[1] <= |(jn & pk1);
                    for (dl = 0; dl < 9; dl = dl + 1)
                        if (pk1[dl])
                            pend[dl] <= 1'b0;
                    e_job[1] <= 1'b1;
                end
            end
        end
    end

    // Context ports seen by each engine: its own lanes only. The read
    // selects use lsel_r, a copy of lsel one cycle later without an enable:
    // an engine reads its lane's context from the cycle after its job start
    // (LDW), so the wide read muxes see a plain register.
    reg [8:0] lsel_r [0:NENG-1];
    integer lr;
    always @(posedge clk)
        for (lr = 0; lr < NENG; lr = lr + 1)
            lsel_r[lr] <= lsel[lr];
    reg [63:0] nz_rdata_e [0:NENG-1];
    reg [4:0] nz_cnt_e [0:NENG-1];
    reg [95:0] e_rdata_e [0:NENG-1];
    reg [5:0] l_b_fill_e [0:NENG-1];
    reg [NENG-1:0] l_b_ep_e;
    integer me, ml;
    always @(*) begin
        for (me = 0; me < NENG; me = me + 1) begin
            nz_rdata_e[me] = 64'd0;
            e_rdata_e[me] = 96'd0;
            for (ml = 0; ml < 9; ml = ml + 1)
                if (((me == 0) ? LMASK0[ml] : LMASK1[ml]) && lsel_r[me][ml]) begin
                    nz_rdata_e[me] = x_nz_rdata[ml];
                    e_rdata_e[me] = x_e_rdata[ml];
                end
        end
    end

    // C store block and fill seen by each engine (its job's slot). The block
    // select uses csel_r, csel one cycle later without an enable (the
    // engine's first C read is issued in LDW), taken with the job start
    // (csel is loaded with jst).
    reg [4:0] csel_r [0:NENG-1];
    always @(posedge clk)
        for (lr = 0; lr < NENG; lr = lr + 1)
            if (!rst_n || kill)
                csel_r[lr] <= 5'd0;
            else if (jst[lr])
                csel_r[lr] <= csel[lr];
    reg [87:0] c_rd_e [0:NENG-1];
    integer ce, cs;
    always @(*) begin
        for (ce = 0; ce < NENG; ce = ce + 1) begin
            c_rd_e[ce] = 88'd0;
            for (cs = 0; cs < 5; cs = cs + 1)
                if (csel_r[ce][cs]) begin
                    c_rd_e[ce] = c_rd_e[ce] | c_rd[cs];
                end
        end
    end

    // Noise count, buffer / C store fill and buffer epoch of each engine's
    // job, registered: counts and fills only grow, so a one-cycle-old value
    // is a safe (conservative) answer to the engine's readiness.
    reg [5:0] c_fill_e [0:NENG-1];
    integer fe, fl;
    always @(posedge clk) begin
        for (fe = 0; fe < NENG; fe = fe + 1) begin
            nz_cnt_e[fe] <= 5'd0;
            l_b_fill_e[fe] <= 6'd0;
            l_b_ep_e[fe] <= 1'b0;
            c_fill_e[fe] <= 6'd0;
            for (fl = 0; fl < 9; fl = fl + 1)
                if (((fe == 0) ? LMASK0[fl] : LMASK1[fl]) && lsel[fe][fl] && !jst[fe]) begin
                    nz_cnt_e[fe] <= x_nz_cnt[fl];
                    l_b_fill_e[fe] <= l_b_fill[fl];
                    l_b_ep_e[fe] <= l_b_ep[fl];
                end
            for (fl = 0; fl < 5; fl = fl + 1)
                if (csel[fe][fl] && !jst[fe])
                    c_fill_e[fe] <= c_fill[fl];
        end
    end

    // Message bits of the group an engine unloads, registered (the engine
    // sends the group one cycle ahead).
    wire [255:0] mu_bits = seed_a;
    // One index mux: only the engine running the scalar lane reads them.
    reg [3:0] mu_bit_reg;
    wire [5:0] mu_idx_sel = (e_lid[0] == 4'd8) ? e_mu_idx[0] : e_mu_idx[1];
    always @(posedge clk)
        mu_bit_reg <= mu_bits[4*mu_idx_sel +: 4];

    generate
        for (g = 0; g < NENG; g = g + 1) begin : g_lane
            mlkem_lane u_lane (
                .clk(clk),
                .rst_n(rst_n),
                .kill(kill),
                .go(go),
                .scrub(scrub),
                .zero_core(zero_core),
                .op(op_r),
                .k(k_r),
                .busy(e_busy[g]),
                .jstart(jst[g]),
                .jlane(jst_lane[g]),
                .jnum(jst_num[g]),
                .lid(e_lid[g]),
                .cslot(e_cslot[g]),
                .nz_raddr(e_nz_raddr[g]),
                .nz_rdata(nz_rdata_e[g]),
                .nz_cnt(nz_cnt_e[g]),
                .b_rblk(e_b_rblk[g]),
                .b_rdata(e_rdata_e[g]),
                .b_fill(l_b_fill_e[g]),
                .b_ep(l_b_ep_e[g]),
                .b_we(e_b_we[g]),
                .b_widx(e_b_widx[g]),
                .b_wdata(e_b_wdata[g]),
                .b_first(e_b_first[g]),
                .b_last(e_b_last[g]),
                .b_wep(e_b_wep[g]),
                .c_rreq(e_c_rreq[g]),
                .c_rblk(e_c_rblk[g]),
                .c_rdata({mu_bit_reg, c_rd_e[g]}),
                .c_fill(c_fill_e[g]),
                .mu_idx(e_mu_idx[g]),
                .mp_we(e_mp_we[g]),
                .mp_bits(e_mp_bits[g]),
                .diff(e_diff[g])
            );
        end
    endgenerate

    // C read addresses: the engine whose job reads that slot (one-hot
    // selects, no compare).
    always @(*) begin
        for (xl = 0; xl < 5; xl = xl + 1)
            ec_rblk[xl] = (csel[1][xl] && e_c_rreq[1]) ? e_c_rblk[1] : e_c_rblk[0];
    end

    wire [3:0] l_v_ep = l_b_ep[3:0];

    // Input
    mlkem_in u_in (
        .clk(clk), .rst_n(rst_n), .kill(kill), .go(go), .scrub(scrub_r),
        .ext_rho_we(hs_wr_rho), .ext_h_we(hs_wr_h), .ext_val(hs_wr_val),
        .ext_z_we(seed_we[15:8]), .ext_z_wdata(seed_wdata), .z_clr(seed_clr || tstate == DONE),
        .op(op_r), .k(k_r), .busy(in_busy),
        .s_tdata(in_data), .s_tvalid(in_valid), .s_tready(in_ready),
        .fifo_push(fifo_push_in), .fifo_din(fifo_din_in), .fifo_full(fifo_full),
        .st_we_s(st_we_s), .st_we_t(st_we_t), .st_we_c(st_we_c),
        .st_blk(st_blk), .st_first(st_first), .st_data(st_data),
        .rho(in_rho), .rho_v(in_rho_v), .h(in_h), .h_v(in_h_v), .z(in_z), .z_v(in_z_v),
        .err(in_err)
    );

    // 256 words: also holds a whole KeyGen ek copy (196 words at most), which
    // the output engine pushes without looking at full.
    mlkem_fifo #(.W(64), .AW(8)) u_fifo (
        .clk(clk), .rst_n(rst_n), .clr(go || kill),
        .push(fifo_push_in || fifo_push_out),
        .din(is_kg ? fifo_din_out : fifo_din_in),
        .full(fifo_full),
        .pop(fifo_pop), .dout(fifo_dout), .empty(fifo_empty)
    );

    // Hash
    mlkem_hash u_hash (
        .clk(clk), .rst_n(rst_n), .kill(kill), .go(go), .scrub(scrub_r),
        .op(op_r), .k(k_r), .busy(hsh_busy),
        .seed_d(seed_a), .seed_m(seed_a),
        .rho_in(in_rho), .rho_in_v(in_rho_v),
        .h_in(in_h), .h_in_v(in_h_v),
        .z_in(in_z), .z_in_v(in_z_v),
        .mprime(seed_a), .mprime_v(mprime_v),
        .fifo_data(fifo_dout), .fifo_empty(fifo_empty), .fifo_pop(fifo_pop),
        .rho(rho), .rho_v(rho_v), .h(h), .h_v(h_v),
        .wr_rho(hs_wr_rho), .wr_h(hs_wr_h), .wr_val(hs_wr_val),
        .kk_v(kk_v), .kbar_v(kbar_v), .hfail(hfail),
        .nz_we(nz_we), .nz_lane(nz_lane), .nz_addr(nz_addr), .nz_wdata(nz_wdata),
        .smp_load(smp_load), .smp_new(smp_new), .smp_slot(smp_slot), .cap(cap),
        .smp_busy(smp_busy), .smp_count(smp_count),
        .smp_nz_start(smp_nz_start), .smp_nz_run(smp_nz_run), .smp_chunk(smp_chunk)
    );

    mlkem_sampler u_sampler (
        .clk(clk), .rst_n(rst_n), .kill(kill), .clr(go),
        .blk_load(smp_load), .blk_new(smp_new), .blk_slot(smp_slot), .cap(cap),
        .busy(smp_busy), .count(smp_count),
        .nz_start(smp_nz_start), .nz_run(smp_nz_run), .chunk_data(smp_chunk),
        .rde_slot(pm_ae_slot), .rdo_slot(pm_ao_slot), .rd_blk(pm_a_blk),
        .rde_data(ae_rdata), .rdo_data(ao_rdata), .fill(a_fill)
    );

    // PMAC
    mlkem_pmac u_pmac (
        .clk(clk), .rst_n(rst_n), .kill(kill), .go(go),
        .op(op_r), .k(k_r), .busy(pmac_busy),
        .ae_slot(pm_ae_slot), .ao_slot(pm_ao_slot), .a_blk(pm_a_blk),
        .ae_rdata(ae_rdata), .ao_rdata(ao_rdata), .a_fill(a_fill),
        .s_slot(pm_s_slot), .s_blk(pm_s_blk), .s_rdata(s_rd[pm_s_slot]),
        .s_fill({s_fill[3], s_fill[2], s_fill[1], s_fill[0]}),
        .t_slot(pm_t_slot), .t_blk(pm_t_blk), .t_rdata(t_rd[pm_t_slot]),
        .t_fill({t_fill[3], t_fill[2], t_fill[1], t_fill[0]}),
        .v_slot(pm_v_slot), .v_blk(pm_v_blk), .v_rdata(l_pm_rdata[pm_v_slot]),
        .v_fill({l_b_fill[3], l_b_fill[2], l_b_fill[1], l_b_fill[0]}), .v_ep(l_v_ep),
        .wr_t_en(pm_wr_t_en), .wr_lane_en(pm_wr_lane_en), .wr8_p1(pm_wr8_p1), .wr8_ep(pm_wr8_ep),
        .wr_blk(pm_wr_blk), .wr_first(pm_wr_first), .wr0_data(pm_wr0_data), .wr1_data(pm_wr1_data)
    );

    // Output
    wire diff_any = |e_diff;
    reg lanes_idle;
    always @(posedge clk)
        lanes_idle <= (e_busy == {NENG{1'b0}}) && (x_busy == 9'd0) && (pend == 9'd0) &&
                      (jst == {NENG{1'b0}}) && (e_job == {NENG{1'b0}});
    // Decaps key valid, registered (cleared with go, like its inputs)
    reg fin_v;
    always @(posedge clk)
        fin_v <= !go && !kill && (op_r == `MLKEM_OP_DECAPS) && computed && kbar_v && kk_v;
    // The shared secret lives in the input engine's h (K, K') or, after a
    // failed re-encryption check, rho (K-bar); the flag is final before fin_v.
    reg key_rho;
    always @(posedge clk)
        key_rho <= (op_r == `MLKEM_OP_DECAPS) && diff_any;
    reg [5:0] out_rd_fill;
    always @(*) begin
        case (out_rd_dest)
            2'd0: out_rd_fill = l_b_fill[out_rd_slot[1:0]];
            2'd1: out_rd_fill = t_fill[out_rd_slot[1:0]];
            // Encaps ciphertext: lane buffer 4 + slot, written with epoch 1
            default: out_rd_fill = l_b_ep[4 + out_rd_slot] ? l_b_fill[4 + out_rd_slot] : 6'd0;
        endcase
    end

    mlkem_out u_out (
        .clk(clk), .rst_n(rst_n), .kill(kill), .go(go),
        .op(op_r), .k(k_r), .busy(out_busy), .secrets_read(out_secrets_read),
        .rd_dest(out_rd_dest), .rd_slot(out_rd_slot), .rd_en(out_rd_en), .rd_blk(out_rd_blk),
        .rd_dslot(out_rd_dslot), .rd_dslot_t(out_rd_dslot_t),
        .rd_dslot_b(out_rd_dslot_b),
        .rd_s_data(l_pm_rdata[out_rd_dslot[1:0]]), .rd_t_data(t_rd_o[out_rd_dslot_t[1:0]]),
        .rd_fill(out_rd_fill),
        .bias_data(l_pm_rdata[4 + out_rd_dslot_b]),
        .bias_fill(l_b_fill[4 + out_rd_slot[1:0]]),
        .bias_ep(l_b_ep[4 + out_rd_slot[1:0]]),
        .rho(rho), .rho_v(rho_v), .h(h), .h_v(h_v), .z(in_z),
        .key_rho(key_rho), .key_v(is_enc ? kk_v : fin_v),
        .fifo_push(fifo_push_out), .fifo_din(fifo_din_out),
        .m_tdata(out_data), .m_tvalid(out_valid), .m_tready(out_ready)
    );

    // Seed words: written while ready, cleared with DONE and by seed_clr
    // (z is held in the input engine's z register, shared with Decaps.)
    // seed_a also receives m' in Decaps, four bits per scalar group: the
    // groups arrive in order (0..63), so they are shifted in from the top.
    integer sw, mpe;
    always @(posedge clk) begin
        if (seed_clr || tstate == DONE) begin
            seed_a <= 256'd0;
        end else begin
            for (sw = 0; sw < 8; sw = sw + 1)
                if (seed_we[sw])
                    seed_a[32*sw +: 32] <= seed_wdata;
            for (mpe = 0; mpe < NENG; mpe = mpe + 1)
                if (e_mp_we[mpe])
                    seed_a <= {e_mp_bits[mpe], seed_a[255:4]};
        end
    end

    // M' register
    integer mpc;
    always @(posedge clk) begin
        if (!rst_n || go || scrub_r) begin
            mp_cnt <= 9'd0;
        end else begin
            for (mpc = 0; mpc < NENG; mpc = mpc + 1)
                if (e_mp_we[mpc])
                    mp_cnt <= mp_cnt + 9'd4;
        end
    end

    // Control
    // Normal completion: once every compute engine is idle and the output no
    // longer reads secret buffers, the lane buffers, noise memories and the S
    // store are cleared while the output tail drains; registers are cleared
    // with DONE. Errors and ABORT reset the engines and zero the NTT cores.
    wire compute_idle = started && !in_busy && !hsh_busy && !pmac_busy && lanes_idle;
    wire run_err = in_err || hfail;

    always @(posedge clk) begin
        if (!rst_n) begin
            // Leaving reset clears the secret memories before READY rises.
            tstate <= WAIT;
            boot <= 1'b1;
            go <= 1'b0;
            launch <= 1'b0;
            kill <= 1'b1;
            scrub <= 1'b0;
            scrub_r <= 1'b0;
            zero_core <= 1'b0;
            started <= 1'b0;
            computed <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            err_code <= `MLKEM_ERR_NONE;
            fail <= 1'b0;
            fail_code <= `MLKEM_ERR_NONE;
            sc <= 6'd32;
            op_r <= `MLKEM_OP_KEYGEN;
            k_r <= 3'd2;
        end else begin
            go <= 1'b0;
            kill <= 1'b0;
            scrub <= 1'b0;
            scrub_r <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            case (tstate)
                IDLE: begin
                    started <= 1'b0;
                    computed <= 1'b0;
                    run_age <= 2'd0;
                    // The request parameters are latched one cycle before go,
                    // so the engines can decode them into registers.
                    if (launch) begin
                        launch <= 1'b0;
                        go <= 1'b1;
                        tstate <= RUN;
                    end else if (start) begin
                        fail <= 1'b0;
                        fail_code <= `MLKEM_ERR_NONE;
                        if (op == 2'd3 || pset == 2'd3) begin
                            fail <= 1'b1;
                            fail_code <= `MLKEM_ERR_CONFIG;
                            tstate <= DONE;
                        end else begin
                            op_r <= op;
                            k_r <= mlkem_k(pset);
                            launch <= 1'b1;
                        end
                    end
                end
                RUN: begin
                    // Engine busy flags are trusted from the third cycle after go.
                    if (run_age != 2'd3)
                        run_age <= run_age + 2'd1;
                    started <= (run_age == 2'd3);
                    if (compute_idle)
                        computed <= 1'b1;
                    if (abort || run_err) begin
                        fail <= 1'b1;
                        fail_code <= abort ? `MLKEM_ERR_ABORT : `MLKEM_ERR_KEY;
                        kill <= 1'b1;
                        tstate <= WAIT;
                    end else if (compute_idle && out_secrets_read) begin
                        scrub <= 1'b1;
                        zero_core <= 1'b0;
                        sc <= 6'd0;
                        tstate <= WAIT;
                    end
                end
                WAIT: begin
                    if (kill) begin
                        // Engines are reset; zero the NTT cores and clear the stores.
                        scrub <= 1'b1;
                        zero_core <= 1'b1;
                        sc <= 6'd0;
                    end else begin
                        if (sc != 6'd32)
                            sc <= sc + 6'd1;
                        if (sc == 6'd32 && lanes_idle && !scrub && !out_busy)
                            tstate <= DONE;
                    end
                end
                DONE: begin
                    scrub_r <= 1'b1;
                    boot <= 1'b0;
                    done <= !fail && !boot;
                    error <= fail && !boot;
                    if (!boot)
                        err_code <= fail_code;
                    tstate <= IDLE;
                end
                default: tstate <= IDLE;
            endcase
        end
    end

endmodule
