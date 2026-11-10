`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// Hash engine: runs the per-operation job list on one keccak_top.
//   KeyGen: G(d||k), PRF(sigma,0..2k-1), XOF x k^2, H(ek), WIPE
//   Encaps: H(ek), G(m||h), PRF(r,0..k-1), XOF x k^2, PRF(r,k..2k), WIPE
//   Decaps: H(ek), XOF x k^2, G(m'||h), PRF(r',0..2k), J(z||c), WIPE
// Long messages (ek, c) arrive through the tap FIFO; PRF blocks go to the
// lanes' noise memories; XOF blocks go to the sampler. Start and squeeze
// handshakes are combinational so back-to-back jobs add no idle cycles, and
// the block that completes a matrix polynomial is identified before its
// handshake, so no permutation is wasted. WIPE overwrites the Keccak input
// registers at the end of the request.
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
    output reg [255:0] rho,
    output reg rho_v,
    output reg [255:0] h,
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

    reg [2:0] jtype;
    reg [4:0] jcount;
    wire k_done;
    wire ph_inc = ((curr_state == ST_WAIT) && k_done && (cnt + 5'd1 == jcount)) || (curr_state == ST_FIN);
    wire [2:0] ph_nx = (curr_state == ST_IDLE && go) ? 3'd0 : ph_inc ? ph + 3'd1 : ph;
    wire [7:0] job_nx = job_of(op, ph_nx, k);
    always @(posedge clk) begin
        jtype <= job_nx[7:5];
        jcount <= job_nx[4:0];
    end

    wire [1:0] eta = ((op == `MLKEM_OP_KEYGEN) || (n_prf < {1'b0, k})) ? mlkem_eta1(k) : 2'd2;
    wire eta3 = (eta == 2'd3);
    wire [3:0] prf_lane = (n_prf < {1'b0, k}) ? n_prf :
                          (n_prf < {k, 1'b0}) ? n_prf - {1'b0, k} + 4'd4 : 4'd8;
    wire [3:0] du = mlkem_du(k);
    wire [3:0] dv = mlkem_dv(k);
    // Message words: H(ek) = 48k + 4, J(z||c) = 4 + 4(du*k + dv)
    reg [8:0] h_words;
    reg [8:0] j_words;
    always @(posedge clk) begin
        h_words <= {2'd0, k, 4'd0} * 9'd3 + 9'd4;
        j_words <= 9'd4 + {3'd0, du, 2'd0} * k + {3'd0, dv, 2'd0};
    end
    wire [8:0] msg_words = (jtype == J_J) ? j_words : h_words;
    wire is_long = (jtype == J_H) || (jtype == J_J);

    reg [1:0] kmode;
    always @(*) begin
        case (jtype)
            J_G: kmode = `MLKEM_KMODE_SHA3_512;
            J_H: kmode = `MLKEM_KMODE_SHA3_256;
            J_J, J_PRF: kmode = `MLKEM_KMODE_SHAKE256;
            default: kmode = `MLKEM_KMODE_SHAKE128;
        endcase
    end

    // Short single-block inputs
    reg [1343:0] sblk;
    reg [7:0] slen;
    always @(*) begin
        sblk = 1344'd0;
        slen = 8'd0;
        case (jtype)
            J_G: begin
                if (op == `MLKEM_OP_KEYGEN) begin
                    sblk[263:0] = {5'd0, k, seed_d};
                    slen = 8'd33;
                end else begin
                    sblk[511:0] = (op == `MLKEM_OP_ENCAPS) ? {h, seed_m} : {h_in, mprime};
                    slen = 8'd64;
                end
            end
            J_PRF: begin
                sblk[263:0] = {4'd0, n_prf, pseed};
                slen = 8'd33;
            end
            J_XOF: begin
                // KeyGen A[r][j] = SampleNTT(rho||j||r); encryption uses the transpose.
                if (op == `MLKEM_OP_KEYGEN)
                    sblk[271:0] = {6'd0, xr, 6'd0, xj, rho};
                else
                    sblk[271:0] = {6'd0, xj, 6'd0, xr, rho};
                slen = 8'd34;
            end
            default: begin
                sblk = 1344'd0;
                slen = 8'd0;
            end
        endcase
    end

    wire deps_ok = (jtype == J_G) ? ((op == `MLKEM_OP_DECAPS) ? (mprime_v && h_in_v) : 1'b1) :
                   (jtype == J_XOF) ? rho_v :
                   (jtype == J_J) ? z_in_v : 1'b1;

    // Keccak core
    reg k_rst;
    reg absorb_valid;
    reg absorb_last;
    reg [1343:0] msg_block;
    reg [7:0] msg_len;
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
    reg [1:0] sv_age;
    reg [1:0] sq_blk;
    reg xof_first;
    reg xof_new_q;
    reg sq_cap;
    wire [9:0] cnt_eff = xof_first ? 10'd0 : {1'b0, smp_count};
    wire xof_sure_more = (cnt_eff + 10'd112 < 10'd256);
    wire xof_last = (cnt_eff + {3'd0, pc} >= 10'd256);
    reg sq_ok;
    always @(*) begin
        case (jtype)
            J_H: sq_ok = (op != `MLKEM_OP_DECAPS) || h_in_v;
            J_PRF: sq_ok = !nw_busy && !smp_busy;
            J_XOF: sq_ok = !smp_busy && !nw_busy && (xof_sure_more || sv_age == 2'd3);
            default: sq_ok = 1'b1;
        endcase
    end
    // READY does not look at VALID (no combinational loop through the sponge);
    // the handshake is VALID && READY.
    wire squeeze_ready = (curr_state == ST_SQZ) && sq_ok;
    wire sq_fire = squeeze_valid && squeeze_ready;
    // The sponge ends a SHAKE job on squeeze_last: the block that completes
    // the polynomial (XOF), the second block of an eta = 3 PRF, else the first.
    wire xof_end = !xof_sure_more && xof_last;
    wire sq_end = (jtype == J_XOF) ? xof_end : !((jtype == J_PRF) && eta3 && sq_blk == 2'd0);
    wire squeeze_last = sq_end;

    keccak_top u_keccak (
        .clk(clk),
        .rst_n(rst_n && !kill && !k_rst),
        .mode(kmode),
        .absorb_valid(absorb_valid),
        .absorb_last(absorb_last),
        .msg_block_in(msg_block),
        .msg_len_bytes(msg_len),
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
    wire words_left = (rem != 9'd0);
    wire use_z = (jtype == J_J) && !tc[2];
    wire want_word = (curr_state == ST_ABS) && is_long && !blk_full && words_left;
    assign fifo_pop = want_word && !use_z && !fifo_empty;
    wire got_word = want_word && (use_z || !fifo_empty);
    wire [63:0] word_in = use_z ? z_in[tc[1:0]*64 +: 64] : fifo_data;
    // A taken word waits one cycle in a register before it lands in the
    // block, so the FIFO read drives 64 flip-flops instead of the whole block.
    // The block is complete in the cycle absorb_valid rises (no extra latency).
    reg word_valid_reg;
    reg [4:0] word_idx_reg;
    reg [63:0] word_reg;

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
            ST_ABS: if (absorb_fire && (!is_long || absorb_last))
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
            rho_v <= 1'b0;
            h_v <= 1'b0;
            kk_v <= 1'b0;
            kbar_v <= 1'b0;
            hfail <= 1'b0;
            h_chk_reg <= 1'b0;
            blk_full <= 1'b0;
            word_valid_reg <= 1'b0;
            sv_age <= 2'd0;
        end else begin
            curr_state <= next_state;
            k_rst <= 1'b0;
            k_start <= 1'b0;
            smp_load <= 1'b0;
            nz_we <= 1'b0;
            word_valid_reg <= 1'b0;
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
                            rho <= squeeze_out[255:0];
                            rho_v <= 1'b1;
                        end else begin
                            kk <= squeeze_out[255:0];
                            kk_v <= 1'b1;
                        end
                        pseed <= squeeze_out[511:256];
                    end
                    J_H: begin
                        if (op != `MLKEM_OP_DECAPS) begin
                            h <= squeeze_out[255:0];
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
                        kbar <= squeeze_out[255:0];
                        kbar_v <= 1'b1;
                    end
                    J_PRF: begin
                        cap <= squeeze_out;
                        nw_busy <= 1'b1;
                        nw_cnt <= 5'd0;
                        nw_lane <= prf_lane;
                        nw_base <= (sq_blk == 2'd1) ? 5'd0 : 5'd17;
                        nw_left <= !eta3 ? 5'd16 : (sq_blk == 2'd1) ? 5'd17 : 5'd7;
                    end
                    default: begin
                        cap <= squeeze_out;
                        smp_load <= 1'b1;
                        smp_new <= xof_new_q;
                        smp_slot <= {xr, xj};
                    end
                endcase
            end

            if (op != `MLKEM_OP_KEYGEN && rho_in_v && !rho_v) begin
                rho <= rho_in;
                rho_v <= 1'b1;
            end

            // Noise writer: one 64-bit PRF word per cycle into the lane memory.
            if (nw_busy) begin
                nz_we <= 1'b1;
                nz_lane <= nw_lane;
                nz_addr <= nw_base + nw_cnt;
                nz_wdata <= cap[nw_cnt*64 +: 64];
                nw_cnt <= nw_cnt + 5'd1;
                if (nw_cnt + 5'd1 == nw_left)
                    nw_busy <= 1'b0;
            end

            if (!squeeze_valid || sq_fire || curr_state != ST_SQZ)
                sv_age <= 2'd0;
            else if (sv_age != 2'd3)
                sv_age <= sv_age + 2'd1;

            case (curr_state)
                ST_IDLE: begin
                    if (go) begin
                        cnt <= 5'd0;
                        n_prf <= 4'd0;
                        xr <= 2'd0;
                        xj <= 2'd0;
                        rho_v <= 1'b0;
                        h_v <= 1'b0;
                        kk_v <= 1'b0;
                        kbar_v <= 1'b0;
                        hfail <= 1'b0;
                    end
                end
                ST_NEXT: begin
                    tc <= 3'd0;
                    rem <= msg_words;
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
                    if (!is_long) begin
                        absorb_valid <= 1'b1;
                        absorb_last <= 1'b1;
                        msg_block <= sblk;
                        msg_len <= slen;
                    end
                end
                ST_ABS: begin
                    if (!is_long) begin
                        if (absorb_valid && absorb_ready)
                            absorb_valid <= 1'b0;
                    end else begin
                        if (got_word) begin
                            word_valid_reg <= 1'b1;
                            word_idx_reg <= wc;
                            word_reg <= word_in;
                            wc <= wc + 5'd1;
                            if (!tc[2])
                                tc <= tc + 3'd1;
                            rem <= rem - 9'd1;
                            if (wc == 5'd16 || rem == 9'd1)
                                blk_full <= 1'b1;
                        end
                        if (word_valid_reg)
                            msg_block[word_idx_reg*64 +: 64] <= word_reg;
                        if (blk_full && !absorb_valid) begin
                            absorb_valid <= 1'b1;
                            absorb_last <= !words_left;
                            msg_len <= {wc, 3'd0};
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
                        if (jtype == J_PRF)
                            sq_blk <= sq_blk + 2'd1;
                        if (jtype == J_XOF)
                            xof_first <= 1'b0;
                    end
                end
                ST_WAIT: begin
                    if (k_done) begin
                        if (jtype == J_PRF)
                            n_prf <= n_prf + 4'd1;
                        if (jtype == J_XOF) begin
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
                    // Absorb an empty SHAKE128 message to overwrite the input
                    // registers, then reset the permutation before it runs out.
                    cnt <= cnt + 5'd1;
                    if (cnt == 5'd0) begin
                        absorb_valid <= 1'b1;
                        absorb_last <= 1'b1;
                        msg_block <= 1344'd0;
                        msg_len <= 8'd0;
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
                pseed <= 256'd0;
                kk <= 256'd0;
                kbar <= 256'd0;
                cap <= 1344'd0;
                msg_block <= 1344'd0;
                word_reg <= 64'd0;
                kk_v <= 1'b0;
                kbar_v <= 1'b0;
            end
        end
    end

    assign busy = (curr_state != ST_IDLE);

endmodule
