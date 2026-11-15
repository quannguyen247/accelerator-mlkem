`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// Hash engine: runs the per-operation job list on one keccak_sponge.
//   KeyGen: G(d||k), PRF(sigma,0..2k-1), XOF x k^2, H(ek), WIPE
//   Encaps: H(ek), G(m||h), PRF(r,0..k-1), XOF x k^2, PRF(r,k..2k), WIPE
//   Decaps: H(ek), XOF x k^2, G(m'||h), PRF(r',0..2k), J(z||c), WIPE
// Long messages (ek, c) arrive through the tap FIFO; PRF blocks go to the
// lanes' noise memories; XOF blocks go to the sampler. Start and squeeze
// handshakes are combinational so back-to-back jobs add no idle cycles, and
// the block that completes a matrix polynomial is identified before its
// handshake, so no permutation is wasted. WIPE overwrites the Keccak input
// registers at the end of the request.
// The engine pads the block while it assembles it (FIPS 202 suffix byte and
// final bit), so the sponge absorbs the block register directly.
module mlkem_hash (
    input wire clk,
    input wire rst_n,

    // Request control
    input wire kill,
    input wire go,
    input wire scrub,
    input wire [1:0] op,
    input wire [2:0] k,
    output wire busy,

    // Seeds and values produced by other engines
    input wire [255:0] seed_d,
    input wire [255:0] seed_m,
    input wire [255:0] rho_in,
    input wire rho_in_v,
    input wire [255:0] h_in,
    input wire h_in_v,
    input wire [255:0] z_in,
    input wire z_in_v,
    input wire [255:0] mprime,
    input wire mprime_v,

    // Long messages (ek, c) from the tap FIFO
    input wire [63:0] fifo_data,
    input wire fifo_empty,
    output wire fifo_pop,

    // Hash results
    output wire [255:0] rho,
    output wire rho_v,
    output wire [255:0] h,
    // rho / h are held in the input engine's registers: write strobes
    output wire wr_rho,
    output wire wr_h,
    output wire [255:0] wr_val,
    output reg h_v,
    output reg [255:0] kk,
    output reg kk_v,
    output reg [255:0] kbar,
    output reg kbar_v,
    output reg hfail,

    // PRF words to the lane noise memories
    output reg nz_we,
    output reg [3:0] nz_lane,
    output reg [4:0] nz_addr,
    output reg [63:0] nz_wdata,

    // XOF blocks to the sampler
    output reg smp_load,
    output reg smp_new,
    output reg [3:0] smp_slot,
    output reg [1343:0] cap,
    input wire smp_busy,
    input wire [8:0] smp_count
);

    `include "mlkem_funcs.vh"

    // rho: G(d) output in KeyGen, else the input engine's register (no copy)
    reg rho_g_v;
    wire op_kg = (op == `MLKEM_OP_KEYGEN);
    assign rho = rho_in;
    assign rho_v = op_kg ? rho_g_v : rho_in_v;
    assign h = h_in;

    localparam [2:0] J_G = 3'd0, J_H = 3'd1, J_J = 3'd2, J_PRF = 3'd3, J_XOF = 3'd4,
                     J_WIPE = 3'd5, J_END = 3'd6;

    // Hash FSM states
    localparam [7:0] ST_IDLE  = 8'b00000001;
    localparam [7:0] ST_NEXT  = 8'b00000010;   // pick the next job, wait for its inputs
    localparam [7:0] ST_START = 8'b00000100;
    localparam [7:0] ST_ABS   = 8'b00001000;
    localparam [7:0] ST_SQZ   = 8'b00010000;
    localparam [7:0] ST_WAIT  = 8'b00100000;   // Keccak done
    localparam [7:0] ST_WIPE  = 8'b01000000;
    localparam [7:0] ST_FIN   = 8'b10000000;

    reg [7:0] curr_state, next_state;

    // Job counters
    reg [2:0] ph;
    reg [4:0] cnt;
    reg [3:0] n_prf;
    reg [1:0] xr, xj;
    reg [255:0] pseed;

    // Job program decode
    // The decode of the job list is registered from the next value of ph, so
    // it is valid in the same cycle as ph and stays off the datapath enables.
    function [7:0] job_of;              // {jtype, jcount}
        input [1:0] f_op;
        input [2:0] f_ph;
        input [2:0] f_k;
        reg [2:0] t;
        reg [4:0] c;
        begin
            t = J_END;
            c = 5'd1;
            case (f_op)
                `MLKEM_OP_KEYGEN: case (f_ph)
                    3'd0: t = J_G;
                    3'd1: begin t = J_PRF; c = {1'b0, f_k, 1'b0}; end
                    3'd2: begin t = J_XOF; c = f_k * f_k; end
                    3'd3: t = J_H;
                    3'd4: t = J_WIPE;
                    default: t = J_END;
                endcase
                `MLKEM_OP_ENCAPS: case (f_ph)
                    3'd0: t = J_H;
                    3'd1: t = J_G;
                    3'd2: begin t = J_PRF; c = {2'd0, f_k}; end
                    3'd3: begin t = J_XOF; c = f_k * f_k; end
                    3'd4: begin t = J_PRF; c = {2'd0, f_k} + 5'd1; end
                    3'd5: t = J_WIPE;
                    default: t = J_END;
                endcase
                default: case (f_ph)
                    3'd0: t = J_H;
                    3'd1: begin t = J_XOF; c = f_k * f_k; end
                    3'd2: t = J_G;
                    3'd3: begin t = J_PRF; c = {1'b0, f_k, 1'b0} + 5'd1; end
                    3'd4: t = J_J;
                    3'd5: t = J_WIPE;
                    default: t = J_END;
                endcase
            endcase
            job_of = {t, c};
        end
    endfunction

    // The job of the next phase is decoded one cycle ahead (job_inc): ph
    // never steps in two consecutive cycles (WAIT and FIN are followed by
    // NEXT), so a phase step only loads a register.
    reg [2:0] jtype;
    reg [4:0] jcount;
    reg [7:0] job_inc;
    wire k_done;
    wire job_first_go = (curr_state == ST_IDLE) && go;
    wire ph_inc = ((curr_state == ST_WAIT) && k_done && (cnt + 5'd1 == jcount)) || (curr_state == ST_FIN);
    wire [2:0] ph_nx = job_first_go ? 3'd0 : ph_inc ? ph + 3'd1 : ph;
    wire [7:0] job_first = job_of(op, 3'd0, k);

    // Job flags, loaded with jtype (op is constant during a request): the
    // datapath selects (short block, absorb, result loads, word source) come
    // from registers, not from a decode of jtype.
    //   f_gk / f_ge / f_gd  G of KeyGen / Encaps / Decaps
    //   f_xk / f_xe         XOF in KeyGen / Encaps-Decaps index order
    reg f_g, f_h, f_j, f_prf, f_xof, f_long;
    reg f_gk, f_ge, f_gd, f_xk, f_xe;
    function [10:0] flags_of;           // {long, xe, xk, gd, ge, gk, xof, prf, j, h, g}
        input [2:0] t;
        input [1:0] f_op;
        flags_of = {(t == J_H) || (t == J_J),
                    (t == J_XOF) && (f_op != `MLKEM_OP_KEYGEN), (t == J_XOF) && (f_op == `MLKEM_OP_KEYGEN),
                    (t == J_G) && (f_op == `MLKEM_OP_DECAPS), (t == J_G) && (f_op == `MLKEM_OP_ENCAPS),
                    (t == J_G) && (f_op == `MLKEM_OP_KEYGEN),
                    t == J_XOF, t == J_PRF, t == J_J, t == J_H, t == J_G};
    endfunction
    always @(posedge clk) begin
        job_inc <= job_of(op, ph + 3'd1, k);
        if (job_first_go) begin
            {jtype, jcount} <= job_first;
            {f_long, f_xe, f_xk, f_gd, f_ge, f_gk, f_xof, f_prf, f_j, f_h, f_g} <= flags_of(job_first[7:5], op);
        end else if (ph_inc) begin
            {jtype, jcount} <= job_inc;
            {f_long, f_xe, f_xk, f_gd, f_ge, f_gk, f_xof, f_prf, f_j, f_h, f_g} <= flags_of(job_inc[7:5], op);
        end
    end

    // eta and the destination lane of PRF number n_prf, registered: n_prf
    // changes only between jobs.
    reg eta3;
    reg [3:0] prf_lane;
    always @(posedge clk) begin
        eta3 <= ((op == `MLKEM_OP_KEYGEN) || (n_prf < {1'b0, k})) && (mlkem_eta1(k) == 2'd3);
        prf_lane <= (n_prf < {1'b0, k}) ? n_prf :
                    (n_prf < {k, 1'b0}) ? n_prf - {1'b0, k} + 4'd4 : 4'd8;
    end
    wire [3:0] du = mlkem_du(k);
    wire [3:0] dv = mlkem_dv(k);
    // Message words: H(ek) = 48k + 4, J(z||c) = 4 + 4(du*k + dv)
    reg [8:0] h_words;
    reg [8:0] j_words;
    always @(posedge clk) begin
        h_words <= {2'd0, k, 4'd0} * 9'd3 + 9'd4;
        j_words <= 9'd4 + {3'd0, du, 2'd0} * k + {3'd0, dv, 2'd0};
    end
    wire [8:0] msg_words = f_j ? j_words : h_words;

    reg [1:0] kmode;
    always @(*) begin
        if (f_g)
            kmode = `MLKEM_KMODE_SHA3_512;
        else if (f_h)
            kmode = `MLKEM_KMODE_SHA3_256;
        else if (f_j || f_prf)
            kmode = `MLKEM_KMODE_SHAKE256;
        else
            kmode = `MLKEM_KMODE_SHAKE128;
    end

    // Short single-block inputs of rate lanes 0..8, padded: the suffix byte
    // follows the message and the final bit closes the rate (72, 136 or 168
    // bytes; the last two are set apart, see abuf and the sponge input). The
    // long jobs and WIPE start from a zero block.
    // KeyGen A[r][j] = SampleNTT(rho||j||r); encryption uses the transpose.
    wire [575:0] sb_gk = {1'b1, 303'd0, `MLKEM_PAD_SHA3, 5'd0, k, seed_d};
    wire [575:0] sb_ge = {1'b1, 55'd0, `MLKEM_PAD_SHA3, h, seed_m};
    wire [575:0] sb_gd = {1'b1, 55'd0, `MLKEM_PAD_SHA3, h_in, mprime};
    wire [575:0] sb_prf = {304'd0, `MLKEM_PAD_SHAKE, 4'd0, n_prf, pseed};
    wire [575:0] sb_xk = {296'd0, `MLKEM_PAD_SHAKE, 6'd0, xr, 6'd0, xj, rho};
    wire [575:0] sb_xe = {296'd0, `MLKEM_PAD_SHAKE, 6'd0, xj, 6'd0, xr, rho};
    wire [575:0] sblk = ({576{f_gk}} & sb_gk) | ({576{f_ge}} & sb_ge) | ({576{f_gd}} & sb_gd) |
                        ({576{f_prf}} & sb_prf) | ({576{f_xk}} & sb_xk) | ({576{f_xe}} & sb_xe);

    wire deps_ok = f_gd ? (mprime_v && h_in_v) :
                   f_xof ? rho_v :
                   f_j ? z_in_v : 1'b1;

    // Keccak core
    reg k_rst;
    reg absorb_valid;
    reg absorb_last;
    // Absorb block (rate lanes 0..16), XORed into the state directly: the
    // short block, loaded in START (sblk_ld), or the words of a long job
    // (blk_word_reg) and their pad (pad_lh / pad_lj: the suffix after the last
    // word and the final bit of the 136-byte rate, written with the last
    // word's strobe). Cleared after every absorb (abuf_clr), so a job starts
    // from a zero block. Lanes 17..20 carry only the SHAKE128 final bit.
    reg [1087:0] abuf;
    reg abuf_clr;
    reg sblk_ld;
    // Pad strobes, one cycle after the last word: the suffix lane (one-hot)
    // of a SHA3 (pad_lh) or SHAKE (pad_lj) suffix, and the final bit (pad_st).
    // The suffix lane is still zero, so the suffix bits are only set.
    reg [16:0] pad_lh, pad_lj;
    reg pad_st;
    // Word write strobe per rate lane of abuf and the word (registered taken word)
    reg [20:0] blk_word_reg;
    reg blk_word_v;                 // some blk_word_reg bit is set
    reg [63:0] word_reg;
    // Result loads, registered with the squeeze handshake (the block is
    // taken the next cycle): each wide register is enabled by one flip-flop.
    reg ld_kk, ld_kbar, ld_pseed, ld_cap;
    // cap takes lanes 0..10 with ld_cap and lanes 11..20 one cycle later
    // (ld_cap2): the state holds the block until the end of that cycle (the
    // first round or the idle clear), the noise writer reads word 0 first
    // and the sampler starts two cycles later.
    reg ld_cap2;
    reg wr_rho_q, wr_h_q;
    reg scr_q;                      // scrub of the wide registers, one cycle later
    wire absorb_ready;
    wire squeeze_valid;
    wire [1343:0] squeeze_out;
    wire [7:0] squeeze_bytes_unused;

    reg nw_busy;
    reg k_start;                    // registered: it fans out across the Keccak input registers
    wire job_go = (curr_state == ST_NEXT) && (jtype != J_END) && (jtype != J_WIPE) && deps_ok;
    wire wipe_go = (curr_state == ST_NEXT) && (jtype == J_WIPE) && !smp_busy && !nw_busy;

    // Squeeze handshake, decided in the cycle the block appears.
    wire [6:0] pc;
    reg [2:0] sv_age;               // cycles the block has waited (saturates at 5)
    reg [1:0] sq_blk;
    reg xof_first;
    reg xof_new_q;
    reg sq_cap;
    // Coefficients still needed by the polynomial (256 - count) and whether
    // a block certainly cannot complete it (fewer than 112 + count), both
    // registered: the count is final while the sampler is idle, which every
    // XOF squeeze waits for.
    wire [8:0] cnt_eff = xof_first ? 9'd0 : smp_count;
    reg [8:0] xof_rem;
    reg xof_sure_more;
    always @(posedge clk) begin
        xof_rem <= 9'd256 - cnt_eff;
        xof_sure_more <= (cnt_eff < 9'd144);
    end
    // The precount is valid from the fourth waiting cycle; its compare with
    // rem is registered, so an uncertain block is decided in the fifth.
    reg xof_last;
    always @(posedge clk)
        xof_last <= ({2'd0, pc} >= xof_rem);
    reg sq_ok;
    always @(*) begin
        if (f_h)
            sq_ok = (op != `MLKEM_OP_DECAPS) || h_in_v;
        else if (f_prf)
            sq_ok = !nw_busy && !smp_busy;
        else if (f_xof)
            sq_ok = !smp_busy && !nw_busy && (xof_sure_more || sv_age == 3'd5);
        else
            sq_ok = 1'b1;
    end
    // READY does not look at VALID (no combinational loop through the sponge);
    // the handshake is VALID && READY.
    wire squeeze_ready = (curr_state == ST_SQZ) && sq_ok;
    wire sq_fire = squeeze_valid && squeeze_ready;
    // The sponge ends a SHAKE job on squeeze_last: the block that completes
    // the polynomial (XOF), the second block of an eta = 3 PRF, else the first.
    wire xof_end = !xof_sure_more && xof_last;
    wire sq_end = f_xof ? xof_end : !(f_prf && eta3 && sq_blk == 2'd0);
    wire squeeze_last = sq_end;

    // Keccak reset, registered: kill and the WIPE reset reach the 1600-bit
    // state one cycle later (no permutation is started in that cycle).
    reg k_rst_n;
    always @(posedge clk)
        k_rst_n <= rst_n && !kill && !k_rst;

    keccak_sponge #(.MASK(0)) u_keccak (
        .clk(clk),
        .rst_n(k_rst_n),
        .mode(kmode),
        .absorb_valid(absorb_valid),
        .absorb_last(absorb_last),
        .absorb_in({f_xof, 255'd0, abuf}),
        .absorb_ready(absorb_ready),
        .squeeze_ready(squeeze_ready),
        .squeeze_last(squeeze_last),
        .squeeze_valid(squeeze_valid),
        .squeeze_out(squeeze_out),
        .squeeze_bytes(squeeze_bytes_unused),
        .start(k_start),
        .done(k_done)
    );

    mlkem_rej_count u_pc (.clk(clk), .blk(squeeze_out), .cnt(pc));

    // Long assembler
    reg [2:0] tc;                   // words taken, saturating at 4 (z words of J)
    reg [8:0] rem;                  // message words not yet taken
    reg [4:0] wc;
    reg blk_full;
    reg wleft;                      // words left (rem != 0), registered with rem
    wire use_z = f_j && !tc[2];
    // Words are collected in abuf, so they are taken also while the sponge
    // permutes the previous block (abuf is cleared one cycle after the
    // handshake, before the first word of the next block lands).
    wire want_word = (curr_state == ST_ABS) && f_long && !blk_full && wleft;
    assign fifo_pop = want_word && !use_z && !fifo_empty;
    wire got_word = want_word && (use_z || !fifo_empty);
    wire [63:0] word_in = use_z ? z_in[{tc[1:0], 6'd0} +: 64] : fifo_data;
    // A taken word waits one cycle in a register before it lands in the
    // block, so the FIFO read drives 64 flip-flops instead of the whole block.
    // The block is complete in the cycle absorb_valid rises (no extra latency).

    // Long jobs: each taken word is written into its rate lane of abuf
    // (blk_word_reg strobe, one cycle after the take), the pad with the last
    // word (suffix byte after it, final bit of the 136-byte rate); the block
    // handshake absorbs abuf and starts the permutation, while the next block
    // is collected. The word counts of H(ek) and J(z||c) are never a multiple
    // of 17, so the last block always has room for the suffix. Short jobs
    // load sblk into abuf in START (its inputs are stable from the job start).
    localparam [7:0] PAD_H = `MLKEM_PAD_SHA3;     // H(ek): SHA3-256
    localparam [7:0] PAD_J = `MLKEM_PAD_SHAKE;    // J(z||c): SHAKE256
    integer pb;

    // H(ek) check in two stages: four 64-bit compares, then the verdict
    reg h_chk_reg;
    reg [3:0] h_ne_reg;

    // Noise writer
    reg [4:0] nw_cnt;
    reg [4:0] nw_left;
    reg [4:0] nw_base;
    reg [3:0] nw_lane;

    // Hash FSM next state
    wire absorb_fire = absorb_valid && absorb_ready;

    integer w;
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            blk_word_reg <= 21'd0;
            blk_word_v <= 1'b0;
            pad_lh <= 17'd0;
            pad_lj <= 17'd0;
            pad_st <= 1'b0;
            sblk_ld <= 1'b0;
            ld_kk <= 1'b0;
            ld_kbar <= 1'b0;
            ld_pseed <= 1'b0;
            ld_cap <= 1'b0;
            ld_cap2 <= 1'b0;
            wr_rho_q <= 1'b0;
            wr_h_q <= 1'b0;
        end else begin
            for (w = 0; w < 21; w = w + 1)
                blk_word_reg[w] <= got_word && (wc == w);
            blk_word_v <= got_word;
            for (w = 0; w < 17; w = w + 1) begin
                pad_lh[w] <= got_word && (rem == 9'd1) && (wc + 5'd1 == w) && !f_j;
                pad_lj[w] <= got_word && (rem == 9'd1) && (wc + 5'd1 == w) && f_j;
            end
            pad_st <= got_word && (rem == 9'd1);
            sblk_ld <= (curr_state == ST_NEXT) && job_go && !f_long;
            ld_kk <= sq_fire && f_g && !op_kg;
            ld_kbar <= sq_fire && f_j;
            ld_pseed <= sq_fire && f_g;
            ld_cap <= sq_fire && (f_prf || f_xof);
            ld_cap2 <= ld_cap;
            wr_rho_q <= sq_fire && f_g && op_kg;
            wr_h_q <= sq_fire && f_h && (op != `MLKEM_OP_DECAPS);
        end
    end

    // Absorb block and the wide result registers. Their clears are
    // registered (abuf_clr: an absorb, kill or reset; scr_c / scr_r: scrub),
    // so each is enabled or cleared by one flip-flop.
    always @(posedge clk) begin
        abuf_clr <= !rst_n || kill || scrub || absorb_fire;
        scr_q <= scrub;
    end

    integer aw;
    always @(posedge clk) begin
        if (abuf_clr) begin
            abuf <= 1088'd0;
        end else begin
            if (sblk_ld) begin
                abuf[575:0] <= sblk;
                abuf[1087] <= f_prf;
            end
            for (aw = 0; aw < 17; aw = aw + 1) begin
                if (blk_word_reg[aw])
                    abuf[64*aw +: 64] <= word_reg;
                for (pb = 0; pb < 8; pb = pb + 1) begin
                    if (pad_lh[aw] && PAD_H[pb])
                        abuf[64*aw + pb] <= 1'b1;
                    if (pad_lj[aw] && PAD_J[pb])
                        abuf[64*aw + pb] <= 1'b1;
                end
            end
            if (pad_st)
                abuf[1087] <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (scr_q) begin
            cap <= 1344'd0;
        end else begin
            if (ld_cap)
                cap[703:0] <= squeeze_out[703:0];
            if (ld_cap2)
                cap[1343:704] <= squeeze_out[1343:704];
        end
    end

    always @(posedge clk) begin
        if (scr_q) begin
            pseed <= 256'd0;
            kk <= 256'd0;
            kbar <= 256'd0;
            word_reg <= 64'd0;
        end else begin
            if (ld_pseed)
                pseed <= squeeze_out[511:256];
            if (ld_kk)
                kk <= squeeze_out[255:0];
            if (ld_kbar)
                kbar <= squeeze_out[255:0];
            word_reg <= word_in;
        end
    end

    always @(*) begin
        next_state = curr_state;

        case (curr_state)
            ST_IDLE: if (go)
                next_state = ST_NEXT;
            ST_NEXT: if (jtype == J_END) begin
                if (!smp_busy && !nw_busy)
                    next_state = ST_IDLE;
            end else if (wipe_go)
                next_state = ST_WIPE;
            else if (job_go)
                next_state = ST_START;
            ST_START: next_state = ST_ABS;
            ST_ABS: if (absorb_fire && (!f_long || absorb_last))
                next_state = ST_SQZ;
            ST_SQZ: if (sq_fire && sq_end)
                next_state = ST_WAIT;
            ST_WAIT: if (k_done)
                next_state = ST_NEXT;
            ST_WIPE: if (cnt == 5'd6)
                next_state = ST_FIN;
            ST_FIN: next_state = ST_NEXT;
            default: next_state = ST_IDLE;
        endcase
    end

    // Hash FSMD update
    integer cw;
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            curr_state <= ST_IDLE;
            ph <= 3'd0;
            cnt <= 5'd0;
            n_prf <= 4'd0;
            xr <= 2'd0;
            xj <= 2'd0;
            k_rst <= 1'b0;
            k_start <= 1'b0;
            sq_cap <= 1'b0;
            absorb_valid <= 1'b0;
            smp_load <= 1'b0;
            nw_busy <= 1'b0;
            nz_we <= 1'b0;
            rho_g_v <= 1'b0;
            h_v <= 1'b0;
            kk_v <= 1'b0;
            kbar_v <= 1'b0;
            hfail <= 1'b0;
            h_chk_reg <= 1'b0;
            blk_full <= 1'b0;
            sv_age <= 3'd0;
        end else begin
            curr_state <= next_state;
            k_rst <= 1'b0;
            k_start <= 1'b0;
            smp_load <= 1'b0;
            nz_we <= 1'b0;
            h_chk_reg <= 1'b0;
            if (h_chk_reg)
                hfail <= (h_ne_reg != 4'd0);
            ph <= ph_nx;
            sq_cap <= sq_fire;

            // Results are taken the cycle after the handshake (Keccak is in
            // START or DONE, its state still holds the block).
            if (sq_cap) begin
                case (jtype)
                    J_G: begin
                        if (op == `MLKEM_OP_KEYGEN) begin
                            rho_g_v <= 1'b1;
                        end else begin
                            kk_v <= 1'b1;
                        end
                    end
                    J_H: begin
                        if (op != `MLKEM_OP_DECAPS) begin
                            h_v <= 1'b1;
                        end else begin
                            h_chk_reg <= 1'b1;
                            h_ne_reg[0] <= (squeeze_out[63:0] != h_in[63:0]);
                            h_ne_reg[1] <= (squeeze_out[127:64] != h_in[127:64]);
                            h_ne_reg[2] <= (squeeze_out[191:128] != h_in[191:128]);
                            h_ne_reg[3] <= (squeeze_out[255:192] != h_in[255:192]);
                        end
                    end
                    J_J: begin
                        kbar_v <= 1'b1;
                    end
                    J_PRF: begin
                        nw_busy <= 1'b1;
                        nw_cnt <= 5'd0;
                        nw_lane <= prf_lane;
                        nw_base <= (sq_blk == 2'd1) ? 5'd0 : 5'd17;
                        nw_left <= !eta3 ? 5'd16 : (sq_blk == 2'd1) ? 5'd17 : 5'd7;
                    end
                    default: begin
                        smp_load <= 1'b1;
                        smp_new <= xof_new_q;
                        smp_slot <= {xr, xj};
                    end
                endcase
            end


            // Noise writer: one 64-bit PRF word per cycle into the lane memory.
            if (nw_busy) begin
                nz_we <= 1'b1;
                nz_lane <= nw_lane;
                nz_addr <= nw_base + nw_cnt;
                nz_wdata <= cap[{nw_cnt, 6'd0} +: 64];
                nw_cnt <= nw_cnt + 5'd1;
                if (nw_cnt + 5'd1 == nw_left)
                    nw_busy <= 1'b0;
            end

            if (!squeeze_valid || sq_fire || curr_state != ST_SQZ)
                sv_age <= 3'd0;
            else if (sv_age != 3'd5)
                sv_age <= sv_age + 3'd1;

            case (curr_state)
                ST_IDLE: begin
                    if (go) begin
                        cnt <= 5'd0;
                        n_prf <= 4'd0;
                        xr <= 2'd0;
                        xj <= 2'd0;
                        rho_g_v <= 1'b0;
                        h_v <= 1'b0;
                        kk_v <= 1'b0;
                        kbar_v <= 1'b0;
                        hfail <= 1'b0;
                    end
                end
                ST_NEXT: begin
                    tc <= 3'd0;
                    rem <= msg_words;
                    wleft <= (msg_words != 9'd0);
                    wc <= 5'd0;
                    blk_full <= 1'b0;
                    sq_blk <= 2'd0;
                    xof_first <= 1'b1;
                    if (wipe_go) begin
                        k_start <= 1'b1;
                        cnt <= 5'd0;
                    end else if (job_go) begin
                        k_start <= 1'b1;
                    end
                end
                ST_START: begin
                    if (!f_long) begin
                        absorb_valid <= 1'b1;
                        absorb_last <= 1'b1;
                    end
                end
                ST_ABS: begin
                    if (!f_long) begin
                        if (absorb_valid && absorb_ready)
                            absorb_valid <= 1'b0;
                    end else begin
                        if (got_word) begin
                            wc <= wc + 5'd1;
                            if (!tc[2])
                                tc <= tc + 3'd1;
                            rem <= rem - 9'd1;
                            wleft <= (rem != 9'd1);
                            if (wc == 5'd16 || rem == 9'd1)
                                blk_full <= 1'b1;
                        end
                        if (blk_full && !absorb_valid) begin
                            absorb_valid <= 1'b1;
                            absorb_last <= !wleft;
                        end
                        if (absorb_valid && absorb_ready) begin
                            absorb_valid <= 1'b0;
                            blk_full <= 1'b0;
                            wc <= 5'd0;
                        end
                    end
                end
                ST_SQZ: begin
                    if (sq_fire) begin
                        xof_new_q <= xof_first;
                        if (f_prf)
                            sq_blk <= sq_blk + 2'd1;
                        if (f_xof)
                            xof_first <= 1'b0;
                    end
                end
                ST_WAIT: begin
                    if (k_done) begin
                        if (f_prf)
                            n_prf <= n_prf + 4'd1;
                        if (f_xof) begin
                            if (xj == k[1:0] - 2'd1) begin
                                xj <= 2'd0;
                                xr <= xr + 2'd1;
                            end else begin
                                xj <= xj + 2'd1;
                            end
                        end
                        if (cnt + 5'd1 == jcount)
                            cnt <= 5'd0;
                        else
                            cnt <= cnt + 5'd1;
                    end
                end
                ST_WIPE: begin
                    // Absorb a zero block to overwrite the input registers,
                    // then reset the permutation before it runs out.
                    cnt <= cnt + 5'd1;
                    if (cnt == 5'd0) begin
                        absorb_valid <= 1'b1;
                        absorb_last <= 1'b1;
                    end
                    if (absorb_valid && absorb_ready)
                        absorb_valid <= 1'b0;
                    if (cnt == 5'd6)
                        k_rst <= 1'b1;
                end
                ST_FIN: begin
                    cnt <= 5'd0;
                end
                default: ;
            endcase

            if (scrub) begin
                nz_wdata <= 64'd0;
                kk_v <= 1'b0;
                kbar_v <= 1'b0;
            end
        end
    end

    assign busy = (curr_state != ST_IDLE);

    // Written in the cycle the result is taken (sq_cap), with its flag
    assign wr_val = squeeze_out[255:0];
    assign wr_rho = wr_rho_q;
    assign wr_h = wr_h_q;


endmodule
