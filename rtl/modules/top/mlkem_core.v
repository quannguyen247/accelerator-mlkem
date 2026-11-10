`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// ML-KEM (FIPS 203) KeyGen / Encaps / Decaps core, ML-KEM-512/768/1024.
//
// Dataflow organisation: every engine runs its own fixed program for the
// latched operation and waits only on block-level progress of the objects it
// reads, so the Keccak, the nine NTT lanes, the multiply-accumulate unit and
// both stream engines overlap. One request is active at a time.
//
//   input stream -> mlkem_in --> S / T / C stores, rho/h/z, hash FIFO
//   mlkem_hash (keccak_top) --> sampler (A store), lane noise, rho/K/h
//   lanes 0..3 (NTT), 4..7 (INTT, KeyGen NTT), 8 (INTT) <-> mlkem_pmac
//   mlkem_out <-- S / T / C stores and registers --> output stream
//
// seed[255:0] is d (KeyGen) or m (Encaps); seed[511:256] is z (KeyGen).
module mlkem_core (
    input wire clk,
    input wire rst_n,

    input wire start,
    input wire [1:0] op,
    input wire [1:0] pset,
    input wire [511:0] seed,
    input wire abort,
    output wire ready,
    output reg done,
    output reg error,
    output reg [2:0] err_code,

    input wire [63:0] s_axis_tdata,
    input wire [7:0] s_axis_tkeep,
    input wire s_axis_tlast,
    input wire s_axis_tvalid,
    output wire s_axis_tready,

    output wire [63:0] m_axis_tdata,
    output wire [7:0] m_axis_tkeep,
    output wire m_axis_tlast,
    output wire m_axis_tvalid,
    input wire m_axis_tready
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
    reg [255:0] seed_z;
    reg go;
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

    assign ready = (tstate == IDLE);

    // Engines
    wire in_busy, out_busy, hsh_busy, pmac_busy;
    wire out_secrets_read;
    wire [8:0] lane_busy;
    wire in_err;
    wire [2:0] in_err_code;
    wire hfail;

    wire fifo_push_in, fifo_push_out, fifo_pop, fifo_full, fifo_empty;
    wire [63:0] fifo_din_in, fifo_din_out, fifo_dout;

    wire st_we;
    wire [1:0] st_dest;
    wire [2:0] st_slot;
    wire [4:0] st_blk;
    wire [95:0] st_data;
    wire [255:0] in_rho, in_h, in_z;
    wire in_rho_v, in_h_v, in_z_v;

    wire [255:0] rho, h, kk, kbar;
    wire rho_v, h_v, kk_v, kbar_v;

    wire nz_we;
    wire [3:0] nz_lane;
    wire [4:0] nz_addr;
    wire [63:0] nz_wdata;

    wire smp_load, smp_new, smp_busy;
    wire [3:0] smp_slot;
    wire [1343:0] cap;
    wire [8:0] smp_count;
    wire [16*6-1:0] a_fill;
    wire [95:0] ae_rdata, ao_rdata;

    wire [2:0] pm_ae_slot, pm_ao_slot;
    wire [4:0] pm_a_blk, pm_s_blk, pm_t_blk, pm_v_blk;
    wire [1:0] pm_s_slot, pm_t_slot, pm_v_slot;
    wire pm_wr0_en, pm_wr1_en, pm_wr_t, pm_wr0_ep, pm_wr1_ep;
    wire [2:0] pm_wr0_row, pm_wr1_row;
    wire [3:0] pm_wr0_lane, pm_wr1_lane;
    wire [4:0] pm_wr_blk;
    wire [95:0] pm_wr0_data, pm_wr1_data;

    wire [1:0] out_rd_dest;
    wire [2:0] out_rd_slot;
    wire [4:0] out_rd_blk, out_rd_blk_c, out_rd_blk_b;

    reg [255:0] mprime;
    reg [8:0] mp_cnt;
    wire mprime_v = (mp_cnt == 9'd256);

    // Lane arrays
    wire [95:0] l_pm_rdata [0:8];
    wire [5:0] l_b_fill [0:8];
    wire [8:0] l_b_ep;
    wire [8:0] l_s_we;
    wire [7:0] l_s_idx [0:8];
    wire [11:0] l_s_data [0:8];
    wire [8:0] l_c_rreq;
    wire [7:0] l_c_ridx [0:8];
    wire [10:0] l_c_rdata [0:8];
    wire [5:0] l_c_fill [0:8];
    wire [8:0] l_c_we;
    wire [7:0] l_c_widx [0:8];
    wire [10:0] l_c_wdata [0:8];
    wire [8:0] l_mp_we;
    wire [7:0] l_mp_idx [0:8];
    wire [8:0] l_mp_bit;
    wire [8:0] l_diff;

    // Stores
    // Store port selects, registered (constant during a request).
    reg is_kg, is_enc;
    always @(posedge clk) begin
        is_kg <= (op_r == `MLKEM_OP_KEYGEN);
        is_enc <= (op_r == `MLKEM_OP_ENCAPS);
    end
    wire scrub_mem = (tstate == WAIT) && (sc != 6'd32);

    wire [95:0] s_rd [0:3];
    wire [95:0] t_rd [0:3];
    wire [87:0] c_rd [0:4];
    wire [5:0] s_fill [0:3];
    wire [5:0] t_fill [0:3];
    wire [5:0] c_fill [0:4];

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_st
            // S: Decaps s^ from the input, KeyGen s^ from vector lane g.
            wire s_in = st_we && (st_dest == 2'd0) && (st_slot == g);
            wire s_ln = l_s_we[g];
            reg [7:0] s_we;
            reg [4:0] s_wa;
            reg [95:0] s_wd;
            always @(*) begin
                s_we = 8'd0;
                s_wa = st_blk;
                s_wd = st_data;
                if (scrub_mem) begin
                    s_we = 8'hFF;
                    s_wa = sc[4:0];
                    s_wd = 96'd0;
                end else if (s_in) begin
                    s_we = 8'hFF;
                end else if (s_ln) begin
                    s_we = 8'd1 << l_s_idx[g][2:0];
                    s_wa = l_s_idx[g][7:3];
                    s_wd = {8{l_s_data[g]}};
                end
            end
            mlkem_poly_ram #(.W(12), .AW(5)) u_s (
                .clk(clk), .we(s_we), .waddr({8{s_wa}}), .wdata(s_wd),
                .raddr(is_kg ? out_rd_blk : pm_s_blk), .rdata(s_rd[g]));
            wire s_ep_unused;
            mlkem_slot_state u_s_st (
                .clk(clk), .rst_n(rst_n), .clr(go),
                .first(s_in ? (st_blk == 5'd0) : (s_ln && l_s_idx[g] == 8'd0)),
                .first_ep(1'b0),
                .inc(s_in || (s_ln && l_s_idx[g][2:0] == 3'd7)),
                .fill(s_fill[g]), .ep(s_ep_unused));

            // T: t^ from the input, or KeyGen t^ from the PMAC (even rows on
            // write port 0, odd rows on port 1).
            wire t_in = st_we && (st_dest == 2'd1) && (st_slot == g);
            wire t_pm = (g % 2 == 0) ? (pm_wr0_en && pm_wr_t && (pm_wr0_row == g))
                                     : (pm_wr1_en && pm_wr_t && (pm_wr1_row == g));
            wire [95:0] t_pm_data = (g % 2 == 0) ? pm_wr0_data : pm_wr1_data;
            wire t_ep_unused;
            mlkem_poly_ram #(.W(12), .AW(5)) u_t (
                .clk(clk), .we({8{t_in || t_pm}}), .waddr({8{t_pm ? pm_wr_blk : st_blk}}),
                .wdata(t_pm ? t_pm_data : st_data),
                .raddr(is_kg ? out_rd_blk : pm_t_blk), .rdata(t_rd[g]));
            mlkem_slot_state u_t_st (
                .clk(clk), .rst_n(rst_n), .clr(go),
                .first((t_in && st_blk == 5'd0) || (t_pm && pm_wr_blk == 5'd0)),
                .first_ep(1'b0), .inc(t_in || t_pm),
                .fill(t_fill[g]), .ep(t_ep_unused));
        end

        for (g = 0; g < 5; g = g + 1) begin : g_c
            // C: compressed u (slots 0..3) and v (slot 4).
            localparam integer WL = (g < 4) ? 4 + g : 8;
            wire c_in = st_we && (st_dest == 2'd2) && (st_slot == g);
            wire c_ln = l_c_we[WL];
            wire [7:0] c_ridx = (g < 4) ? (l_c_rreq[WL] ? l_c_ridx[WL] : l_c_ridx[g]) : l_c_ridx[8];
            reg [7:0] c_we;
            reg [4:0] c_wa;
            reg [87:0] c_wd;
            integer bi;
            always @(*) begin
                c_we = 8'd0;
                c_wa = st_blk;
                for (bi = 0; bi < 8; bi = bi + 1)
                    c_wd[11*bi +: 11] = st_data[12*bi +: 11];
                if (c_in) begin
                    c_we = 8'hFF;
                end else if (c_ln) begin
                    c_we = 8'd1 << l_c_widx[WL][2:0];
                    c_wa = l_c_widx[WL][7:3];
                    c_wd = {8{l_c_wdata[WL]}};
                end
            end
            mlkem_poly_ram #(.W(11), .AW(5)) u_c (
                .clk(clk), .we(c_we), .waddr({8{c_wa}}), .wdata(c_wd),
                .raddr(is_enc ? out_rd_blk_c : c_ridx[7:3]), .rdata(c_rd[g]));
            wire c_ep_unused;
            mlkem_slot_state u_c_st (
                .clk(clk), .rst_n(rst_n), .clr(go),
                .first(c_in ? (st_blk == 5'd0) : (c_ln && l_c_widx[WL] == 8'd0)),
                .first_ep(1'b0),
                .inc(c_in || (c_ln && l_c_widx[WL][2:0] == 3'd7)),
                .fill(c_fill[g]), .ep(c_ep_unused));
        end
    endgenerate

    // Lanes
    wire [255:0] mu_bits = is_enc ? seed_a : mprime;
    wire [3:0] l_v_ep;

    generate
        for (g = 0; g < 9; g = g + 1) begin : g_lane
            localparam integer CS = (g < 4) ? g : ((g < 8) ? g - 4 : 4);
            wire [4:0] pm_rblk = (g < 4) ? pm_v_blk : out_rd_blk_b;
            wire pm_w0 = pm_wr0_en && !pm_wr_t && (pm_wr0_lane == g);
            wire pm_w1 = pm_wr1_en && !pm_wr_t && (pm_wr1_lane == g);
            mlkem_lane #(.LANE(g)) u_lane (
                .clk(clk),
                .rst_n(rst_n),
                .kill(kill),
                .go(go),
                .scrub(scrub),
                .zero_core(zero_core),
                .op(op_r),
                .k(k_r),
                .busy(lane_busy[g]),
                .nz_we(nz_we && nz_lane == g),
                .nz_addr(nz_addr),
                .nz_wdata(nz_wdata),
                .pm_rd_blk(pm_rblk),
                .pm_rd_data(l_pm_rdata[g]),
                .pm_we(pm_w0 || pm_w1),
                .pm_wr_blk(pm_wr_blk),
                .pm_wr_data(pm_w1 ? pm_wr1_data : pm_wr0_data),
                .pm_wr_ep(pm_w1 ? pm_wr1_ep : pm_wr0_ep),
                .b_fill(l_b_fill[g]),
                .b_ep(l_b_ep[g]),
                .s_we(l_s_we[g]),
                .s_idx(l_s_idx[g]),
                .s_data(l_s_data[g]),
                .c_rreq(l_c_rreq[g]),
                .c_ridx(l_c_ridx[g]),
                .c_rdata(l_c_rdata[g]),
                .c_fill(c_fill[CS]),
                .c_we(l_c_we[g]),
                .c_widx(l_c_widx[g]),
                .c_wdata(l_c_wdata[g]),
                .mu_bits(mu_bits),
                .mp_we(l_mp_we[g]),
                .mp_idx(l_mp_idx[g]),
                .mp_bit(l_mp_bit[g]),
                .diff(l_diff[g])
            );
            assign l_c_rdata[g] = c_rd[CS][11*l_c_ridx[g][2:0] +: 11];
        end
    endgenerate

    assign l_v_ep = l_b_ep[3:0];

    // Input
    mlkem_in u_in (
        .clk(clk), .rst_n(rst_n), .kill(kill), .go(go), .scrub(scrub_r),
        .op(op_r), .k(k_r), .busy(in_busy),
        .s_tdata(s_axis_tdata), .s_tkeep(s_axis_tkeep), .s_tlast(s_axis_tlast),
        .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
        .fifo_push(fifo_push_in), .fifo_din(fifo_din_in), .fifo_full(fifo_full),
        .st_we(st_we), .st_dest(st_dest), .st_slot(st_slot), .st_blk(st_blk), .st_data(st_data),
        .rho(in_rho), .rho_v(in_rho_v), .h(in_h), .h_v(in_h_v), .z(in_z), .z_v(in_z_v),
        .err(in_err), .err_code(in_err_code)
    );

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
        .mprime(mprime), .mprime_v(mprime_v),
        .fifo_data(fifo_dout), .fifo_empty(fifo_empty), .fifo_pop(fifo_pop),
        .rho(rho), .rho_v(rho_v), .h(h), .h_v(h_v),
        .kk(kk), .kk_v(kk_v), .kbar(kbar), .kbar_v(kbar_v), .hfail(hfail),
        .nz_we(nz_we), .nz_lane(nz_lane), .nz_addr(nz_addr), .nz_wdata(nz_wdata),
        .smp_load(smp_load), .smp_new(smp_new), .smp_slot(smp_slot), .cap(cap),
        .smp_busy(smp_busy), .smp_count(smp_count)
    );

    mlkem_sampler u_sampler (
        .clk(clk), .rst_n(rst_n), .kill(kill), .clr(go),
        .blk_load(smp_load), .blk_new(smp_new), .blk_slot(smp_slot), .cap(cap),
        .busy(smp_busy), .count(smp_count),
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
        .wr0_en(pm_wr0_en), .wr1_en(pm_wr1_en), .wr_t(pm_wr_t),
        .wr0_row(pm_wr0_row), .wr1_row(pm_wr1_row),
        .wr0_lane(pm_wr0_lane), .wr1_lane(pm_wr1_lane), .wr_blk(pm_wr_blk),
        .wr0_data(pm_wr0_data), .wr1_data(pm_wr1_data), .wr0_ep(pm_wr0_ep), .wr1_ep(pm_wr1_ep)
    );

    // Output
    wire diff_any = |l_diff[8:4];
    reg lanes_idle;
    always @(posedge clk)
        lanes_idle <= (lane_busy == 9'd0);
    wire fin_v = (op_r == `MLKEM_OP_DECAPS) && computed && kbar_v && kk_v;
    wire [255:0] k_final = diff_any ? kbar : kk;
    reg [95:0] out_rd_data;
    reg [5:0] out_rd_fill;
    integer obi;
    always @(*) begin
        case (out_rd_dest)
            2'd0: begin out_rd_data = s_rd[out_rd_slot[1:0]]; out_rd_fill = s_fill[out_rd_slot[1:0]]; end
            2'd1: begin out_rd_data = t_rd[out_rd_slot[1:0]]; out_rd_fill = t_fill[out_rd_slot[1:0]]; end
            default: begin
                out_rd_data = 96'd0;
                for (obi = 0; obi < 8; obi = obi + 1)
                    out_rd_data[12*obi +: 11] = c_rd[out_rd_slot][11*obi +: 11];
                out_rd_fill = c_fill[out_rd_slot];
            end
        endcase
    end

    mlkem_out u_out (
        .clk(clk), .rst_n(rst_n), .kill(kill), .go(go),
        .op(op_r), .k(k_r), .busy(out_busy), .secrets_read(out_secrets_read),
        .rd_dest(out_rd_dest), .rd_slot(out_rd_slot), .rd_blk(out_rd_blk),
        .rd_blk_c(out_rd_blk_c), .rd_blk_b(out_rd_blk_b),
        .rd_data(out_rd_data), .rd_fill(out_rd_fill),
        .bias_data(l_pm_rdata[4 + out_rd_slot[1:0]]),
        .bias_fill(l_b_fill[4 + out_rd_slot[1:0]]),
        .bias_ep(l_b_ep[4 + out_rd_slot[1:0]]),
        .rho(rho), .rho_v(rho_v), .h(h), .h_v(h_v), .z(seed_z),
        .key(is_enc ? kk : k_final), .key_v(is_enc ? kk_v : fin_v),
        .fifo_push(fifo_push_out), .fifo_din(fifo_din_out), .fifo_full(fifo_full),
        .m_tdata(m_axis_tdata), .m_tkeep(m_axis_tkeep), .m_tlast(m_axis_tlast),
        .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready)
    );

    // M' register
    always @(posedge clk) begin
        if (!rst_n || go || scrub_r) begin
            mprime <= 256'd0;
            mp_cnt <= 9'd0;
        end else if (l_mp_we[8]) begin
            mprime[l_mp_idx[8]] <= l_mp_bit[8];
            mp_cnt <= mp_cnt + 9'd1;
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
                    if (start) begin
                        fail <= 1'b0;
                        fail_code <= `MLKEM_ERR_NONE;
                        if (op == 2'd3 || pset == 2'd3) begin
                            fail <= 1'b1;
                            fail_code <= `MLKEM_ERR_CONFIG;
                            tstate <= DONE;
                        end else begin
                            op_r <= op;
                            k_r <= mlkem_k(pset);
                            seed_a <= seed[255:0];
                            seed_z <= seed[511:256];
                            go <= 1'b1;
                            tstate <= RUN;
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
                        fail_code <= abort ? `MLKEM_ERR_ABORT : (in_err ? in_err_code : `MLKEM_ERR_KEY);
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
                    seed_a <= 256'd0;
                    seed_z <= 256'd0;
                    tstate <= IDLE;
                end
                default: tstate <= IDLE;
            endcase
        end
    end

endmodule
