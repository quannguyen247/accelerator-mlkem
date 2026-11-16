`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// Shared NTT engine: an ntt4_core (four butterflies) and the load/unload
// pipelines around the core's four-coefficient-per-cycle port (one group =
// coefficients 4n .. 4n + 3 per cycle, so a load or an unload takes 64
// cycles). Unloading writes zeros behind the read, so the core RAM is clean
// after every job. Every read takes one cycle more than the issue: the
// buffer and C store register the block address beside the memory (the
// engine sends n), and the core read follows the issue by one cycle (na).
//
// The engine runs one job at a time for a logical lane (jlane) whose noise
// memory and buffer live in mlkem_lane_ctx; the core routes the context and
// store ports by the latched lane (lid). Job kinds by logical lane:
//   0..3  vector: forward NTT of s / y (CBD noise) or Decaps u' (C store),
//                 result to the buffer (KeyGen s^: read from there for dk)
//   4..7  row:    INTT of a u row plus e1, compressed to C / compared
//                 (KeyGen: forward NTT of e to the buffer)
//   8     scalar: INTT of v plus e2 and the message, compressed to C /
//                 compared; Decaps first job: w, compressed to m' bits
// The core has no INTT scale pass, so an INTT returns 128 times the inverse
// transform; the PMAC folds the missing factor into its result scaling.
module mlkem_lane (
    input wire clk,
    input wire rst_n,

    // Request control
    input wire kill,
    input wire go,
    input wire scrub,
    input wire zero_core,
    input wire [1:0] op,
    input wire [2:0] k,
    output wire busy,

    // Job dispatch (taken in the idle state): logical lane and job number
    input wire jstart,
    input wire [3:0] jlane,
    input wire jnum,
    output reg [3:0] lid,               // logical lane of the current job
    output wire [2:0] cslot,            // C store slot of the current job

    // Context of the current job (b_rdata: block b_rblk, one cycle after
    // the address)
    output wire [4:0] nz_raddr,
    input wire [63:0] nz_rdata,
    input wire [4:0] nz_cnt,
    output wire [4:0] b_rblk,
    input wire [95:0] b_rdata,
    input wire [5:0] b_fill,
    input wire b_ep,
    output wire b_we,
    output wire [5:0] b_widx,
    output wire [47:0] b_wdata,
    output wire b_first,
    output wire b_last,
    output wire b_wep,

    // C store slot cslot (Decaps ciphertext): block read (c_rdata[87:0],
    // eight 11-bit values at c_rblk, one cycle after the address).
    // c_rdata[91:88] are the message bits of group mu_idx, valid one cycle
    // after the index. Encaps writes its compressed u / v groups to the
    // lane's own buffer instead (epoch 1, 11-bit values in 12-bit fields).
    output wire c_rreq,
    output wire [4:0] c_rblk,
    input wire [91:0] c_rdata,
    input wire [5:0] c_fill,

    // Message group index, decoded message strobe (mp_bits: the four bits
    // of the unload group), re-encryption mismatch (sticky per request)
    output wire [5:0] mu_idx,
    output reg mp_we,
    output reg [3:0] mp_bits,
    output reg diff
);

    `include "mlkem_funcs.vh"

    // Engine FSM states
    localparam [8:0] ST_IDLE   = 9'b000000001;
    localparam [8:0] ST_LDW    = 9'b000000010;   // wait for the load source
    localparam [8:0] ST_LOAD   = 9'b000000100;
    localparam [8:0] ST_START  = 9'b000001000;
    localparam [8:0] ST_RUN    = 9'b000010000;
    localparam [8:0] ST_ULW    = 9'b000100000;   // wait for the unload inputs
    localparam [8:0] ST_UNLOAD = 9'b001000000;
    localparam [8:0] ST_DRAIN  = 9'b010000000;
    localparam [8:0] ST_SCRUB  = 9'b100000000;

    reg [8:0] curr_state, next_state;

    wire st_idle = curr_state[0];
    wire st_ldw = curr_state[1];
    wire st_load = curr_state[2];
    wire st_start = curr_state[3];
    wire st_run = curr_state[4];
    wire st_ulw = curr_state[5];
    wire st_unload = curr_state[6];
    wire st_drain = curr_state[7];
    wire st_scrub = curr_state[8];

    reg [6:0] n;                         // group counter, n[6]: all issued
    reg [6:0] sc;
    reg [3:0] drain;
    wire nz_rdy = (nz_cnt != 5'd0);

    wire is_keygen = (op == `MLKEM_OP_KEYGEN);
    wire is_decaps = (op == `MLKEM_OP_DECAPS);
    wire is_encaps = (op == `MLKEM_OP_ENCAPS);

    // Job descriptor, latched with the job:
    //   jd_ld / jd_ld_ep   load source and the buffer epoch it waits for
    //   jd_mode            0: NTT, 1: INTT
    //   jd_ul / jd_ul_ep   unload destination and the epoch it writes
    //   jd_cmp             compare with the received ciphertext (Decaps)
    //   ul_noise           add CBD noise while unloading
    //   ul_cread           read the C store while unloading
    //   r_scl              scalar job (message bits)
    reg [1:0] jd_ld;
    reg jd_ld_ep;
    reg jd_mode;
    reg [1:0] jd_ul;
    reg jd_ul_ep;
    reg jd_cmp;
    reg ul_noise;
    reg ul_cread;
    reg r_scl;
    reg [2:0] r_cslot;
    assign cslot = r_cslot;

    wire j_vec = (jlane < 4'd4);
    wire j_row = (jlane >= 4'd4) && (jlane < 4'd8);
    wire j_scl = (jlane == 4'd8);
    wire j_posw = j_scl && is_decaps && !jnum;
    always @(posedge clk) begin
        if (st_idle && jstart) begin
            lid <= jlane;
            r_scl <= j_scl;
            r_cslot <= j_scl ? 3'd4 : {1'b0, jlane[1:0]};
            jd_ld <= j_vec ? ((is_decaps && !jnum) ? `MLKEM_LD_DEC : `MLKEM_LD_CBD) :
                     (j_row && is_keygen) ? `MLKEM_LD_CBD : `MLKEM_LD_BUF;
            jd_ld_ep <= j_scl && jnum;
            jd_mode <= !j_vec && !(j_row && is_keygen);
            jd_ul <= j_vec ? `MLKEM_UL_BUF :
                     j_row ? (is_keygen ? `MLKEM_UL_BUF : `MLKEM_UL_POSU) :
                     (j_posw ? `MLKEM_UL_POSW : `MLKEM_UL_POSV);
            jd_ul_ep <= (j_vec && is_decaps && jnum) || (!j_vec && is_encaps);
            jd_cmp <= !j_vec && is_decaps;
            ul_noise <= (j_row && !is_keygen) || (j_scl && !j_posw);
            ul_cread <= !j_vec && is_decaps;
        end
    end

    // ML-KEM-1024 (du = 11, dv = 5), registered: k is stable for the whole request.
    reg k4_reg;
    always @(posedge clk)
        k4_reg <= (k == 3'd4);
    // eta = 3 noise (ML-KEM-512 secrets) while loading, eta = 2 otherwise
    reg cbd_eta3_reg;

    wire cbd_init;
    wire cbd_pop;
    wire cbd_v;
    wire [47:0] cbd_val;
    mlkem_cbd4_stream u_cbd (
        .clk(clk),
        .rst_n(rst_n),
        .init(cbd_init),
        .eta3(cbd_eta3_reg),
        .avail(nz_cnt),
        .rd_addr(nz_raddr),
        .rd_data(nz_rdata),
        .pop(cbd_pop),
        .val_v(cbd_v),
        .val(cbd_val)
    );

    // NTT core. Its write port is driven by engine registers; the read data
    // of ext_raddr arrives in the next cycle.
    reg core_rst_n_reg;
    reg core_start;
    reg [5:0] na;                        // group issued one cycle ago
    reg ext_we;
    reg [5:0] ext_waddr;
    wire [47:0] ext_dout;
    wire core_busy_unused;
    wire core_done;

    always @(posedge clk)
        core_rst_n_reg <= rst_n && !kill;

    ntt4_core u_core (
        .clk(clk),
        .rst_n(core_rst_n_reg),
        .start(core_start),
        .mode(jd_mode),
        .ext_we(ext_we),
        .ext_waddr(ext_waddr),
        .ext_din(l2_val),
        .ext_raddr(na),
        .ext_dout(ext_dout),
        .busy(core_busy_unused),
        .done(core_done)
    );

    // Group issued two, three and four cycles ago (na: one cycle)
    reg [5:0] n0, n1, n2;
    always @(posedge clk) begin
        na <= n[5:0];
        n0 <= na;
        n1 <= n0;
        n2 <= n1;
    end
    assign mu_idx = n0;

    // Stage 0 of both pipelines: the C store block, the buffer block and the
    // CBD values of the issued group, registered (the CBD values wait one
    // cycle in cbd_a for the store reads).
    reg [87:0] c_blk_reg;
    reg [95:0] b_blk_reg;
    reg [47:0] cbd_a, cbd_reg;
    always @(posedge clk) begin
        c_blk_reg <= c_rdata[87:0];
        b_blk_reg <= b_rdata;
        cbd_a <= cbd_val;
        cbd_reg <= cbd_a;
    end
    wire [43:0] c_sel = n0[0] ? c_blk_reg[87:44] : c_blk_reg[43:0];
    wire [47:0] b_sel = n0[0] ? b_blk_reg[95:48] : b_blk_reg[47:0];

    // Load path: stage 0 (sources), stage 1 (raw value), stage 2 (value)
    wire ld_ready = (jd_ld == `MLKEM_LD_CBD) ? cbd_v :
                    (jd_ld == `MLKEM_LD_DEC) ? (c_fill > {1'b0, n[5:1]}) :
                    ((b_ep == jd_ld_ep) && (b_fill > {1'b0, n[5:1]}));
    wire ld_issue = st_load && !n[6] && ld_ready;

    reg la_v, l0_v, l1_v, l2_v;
    reg [47:0] l1_raw;
    // l2_val is also the core's write data: zero outside LOAD (the unload
    // writes zeros behind the read, the scrub zeroes the core).
    reg [47:0] l2_val;

    // CBD noise, PMAC result from the buffer, or Decaps u' decompressed from
    // the C store (du = 10 or 11). The source selects of the stage 1 and 2
    // registers are the decode of jd_ld one cycle later (ld_dec_d, ld_buf_d):
    // the first group reaches stage 1 three cycles after the job is latched
    // (LDW, issue, stage A), so the select registers drive only these values.
    integer i;
    reg ld_dec_d, ld_buf_d;
    always @(posedge clk) begin
        ld_dec_d <= (jd_ld == `MLKEM_LD_DEC);
        ld_buf_d <= (jd_ld == `MLKEM_LD_BUF);
    end
    reg [12:0] l1_y3 [0:3];
    reg [11:0] l1_yr [0:3];
    reg [22:0] l1_sum;
    always @(posedge clk) begin
        l1_raw <= ld_dec_d ?
                  {1'b0, c_sel[43:33], 1'b0, c_sel[32:22], 1'b0, c_sel[21:11], 1'b0, c_sel[10:0]} :
                  ld_buf_d ? b_sel : cbd_reg;
        for (i = 0; i < 4; i = i + 1) begin
            l1_y3[i] <= {2'd0, c_sel[11*i +: 11]} + {1'b0, c_sel[11*i +: 11], 1'b0};
            l1_yr[i] <= {1'b0, c_sel[11*i +: 11]} + (k4_reg ? 12'd1024 : 12'd512);
        end
        for (i = 0; i < 4; i = i + 1) begin
            l1_sum = mlkem_decompress_sum(l1_y3[i], l1_raw[12*i +: 11], l1_yr[i]);
            if (!st_load)
                l2_val[12*i +: 12] <= 12'd0;
            else
                l2_val[12*i +: 12] <= !ld_dec_d ? l1_raw[12*i +: 12] :
                                      k4_reg ? l1_sum[22:11] : l1_sum[21:10];
        end
    end

    // Unload path
    wire ul_go = st_unload && !n[6] && (!ul_noise || cbd_v);
    reg [7:0] v_ul;
    reg v0;
    reg [47:0] x1;
    reg [5:0] n7;
    reg n7_first, n7_last;               // n7 == 0, n7 ends a block of eight
    wire [5:0] n6;
    wire v6 = v_ul[6];

    assign cbd_pop = cbd_v && !n[6] && ((st_load && (jd_ld == `MLKEM_LD_CBD)) || (st_unload && ul_noise));
    assign cbd_init = (st_ldw && jd_ld == `MLKEM_LD_CBD && nz_rdy) ||
                      (st_ulw && ul_noise && nz_rdy && drain == 4'd0);

    reg c_rreq_q;
    assign c_rreq = c_rreq_q;
    assign c_rblk = n[5:1];
    assign b_rblk = n[5:1];
    assign busy = !st_idle;

    // Core write port: load stage 2 (l2_val, so the strobe and the address
    // are taken with it, from stage 1), zeros behind the unload read, or the
    // scrub counter.
    always @(posedge clk) begin
        if (!rst_n || kill)
            ext_we <= 1'b0;
        else if (st_scrub)
            ext_we <= zero_core;
        else if (st_load)
            ext_we <= l1_v;
        else if (st_unload)
            ext_we <= ul_go;
        else
            ext_we <= 1'b0;
        ext_waddr <= st_scrub ? sc[5:0] : st_unload ? n[5:0] : n1;
        c_rreq_q <= (st_ldw && (jd_ld == `MLKEM_LD_DEC)) || (st_load && (jd_ld == `MLKEM_LD_DEC) && !n[6]) ||
                    (st_ulw && ul_cread) || (st_unload && ul_cread && !n[6]);
    end

    // FSM transition conditions
    wire ld_done = n[6] && !la_v && !l0_v && !l1_v && !l2_v && !ext_we;
    // C store slot complete, registered (fills only grow during a job)
    reg c_full_q;
    always @(posedge clk)
        c_full_q <= (c_fill == 6'd32);
    wire ul_wait = ul_cread && !c_full_q;
    // Noise jobs: initialise the CBD stream once, then wait for its first value.
    wire ul_arm = !ul_wait && ul_noise && (drain == 4'd0) && nz_rdy;
    wire ul_start = !ul_wait && (!ul_noise || ((drain != 4'd0) && cbd_v));
    wire scrub_last = zero_core ? (sc == 7'd63) : (sc == 7'd31);

    always @(*) begin
        next_state = curr_state;

        case (1'b1)
            st_idle: if (scrub)
                next_state = ST_SCRUB;
            else if (jstart)
                next_state = ST_LDW;
            st_ldw: if (jd_ld != `MLKEM_LD_CBD || nz_rdy)
                next_state = ST_LOAD;
            st_load: if (ld_done)
                next_state = ST_START;
            st_start: next_state = ST_RUN;
            st_run: if (core_done)
                next_state = ST_ULW;
            st_ulw: if (ul_start)
                next_state = ST_UNLOAD;
            st_unload: if (n[6])
                next_state = ST_DRAIN;
            st_drain: if (drain == 4'd1)
                next_state = ST_IDLE;
            st_scrub: if (scrub_last)
                next_state = ST_IDLE;
            default: next_state = ST_IDLE;
        endcase
    end

    // Engine FSMD update
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            curr_state <= ST_IDLE;
            n <= 7'd0;
            sc <= 7'd0;
            drain <= 4'd0;
            core_start <= 1'b0;
            cbd_eta3_reg <= 1'b0;
        end else begin
            curr_state <= next_state;
            core_start <= st_start;
            cbd_eta3_reg <= (next_state[1] || next_state[2]) && (k == 3'd2);
            case (1'b1)
                st_idle: begin
                    if (scrub)
                        sc <= 7'd0;
                end
                st_ldw: begin
                    n <= 7'd0;
                end
                st_load: begin
                    if (ld_issue)
                        n <= n + 7'd1;
                end
                st_run: begin
                    if (core_done) begin
                        n <= 7'd0;
                        drain <= 4'd0;
                    end
                end
                st_ulw: begin
                    if (ul_arm)
                        drain <= 4'd1;
                end
                st_unload: begin
                    if (ul_go)
                        n <= n + 7'd1;
                    if (n[6])
                        drain <= 4'd12;
                end
                st_drain: begin
                    drain <= drain - 4'd1;
                end
                st_scrub: begin
                    sc <= sc + 7'd1;
                end
                default: ;
            endcase
        end
    end

    // Pipeline valid flags
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            la_v <= 1'b0;
            l0_v <= 1'b0;
            l1_v <= 1'b0;
            l2_v <= 1'b0;
            v0 <= 1'b0;
            v_ul <= 8'd0;
        end else begin
            la_v <= ld_issue;
            l0_v <= la_v;
            l1_v <= l0_v;
            l2_v <= l1_v;
            v0 <= ul_go;
            v_ul <= {v_ul[6:0], v0};
        end
    end

    // Unload stage 1: the core returns group na (read one cycle after the issue).
    always @(posedge clk) begin
        x1 <= ext_dout;
        n7 <= n6;
        n7_first <= (n6 == 6'd0);
        n7_last <= n6[0];
    end
    mlkem_delay #(.W(6), .D(4)) u_dn6 (.clk(clk), .d(n2), .q(n6));

    // Buffer unload, aligned with the post-processing pipeline below: the
    // transformed values (the PMAC scales its sums), or the Encaps
    // ciphertext group (u / v compressed, ul_cw).
    wire [47:0] x6;
    genvar gi;
    mlkem_delay #(.W(48), .D(5)) u_dx6 (.clk(clk), .d(x1), .q(x6));
    wire ul_cw = ul_noise && !jd_cmp;

    // Noise, compression and compare, per coefficient of the group:
    //   row     u = x + e1, compressed to du bits
    //   scalar  v = x + e2 + Decompress_1(mu), compressed to dv bits
    //           Decaps first job: w = Decompress_dv(c2) - x, compressed to 1 bit
    // Encaps writes the result to the buffer; Decaps compares it with the
    // received ciphertext (cr), the first scalar job returns the message bits.
    reg [43:0] cr1;
    reg [47:0] e1, s2, s3;
    wire [43:0] cr6;
    wire [43:0] cq6;
    reg [3:0] cmp_d;
    reg [47:0] x2, vd2;
    reg [3:0] mu2;
    // c2 decompressed (dv = 4 or 5, so y has five bits): 3 * y and
    // y + 2^(dv-1) are registered with cr1
    reg [6:0] cr1_y3 [0:3];
    reg [5:0] cr1_yr [0:3];
    reg [22:0] cr1_sum;
    wire posw = (jd_ul == `MLKEM_UL_POSW);

    always @(posedge clk) begin
        cr1 <= c_sel;
        e1 <= cbd_reg;
        for (i = 0; i < 4; i = i + 1)
            s2[12*i +: 12] <= mlkem_mod_add(x1[12*i +: 12], e1[12*i +: 12]);
        for (i = 0; i < 4; i = i + 1) begin
            cr1_y3[i] <= {2'd0, c_sel[11*i +: 5]} + {1'b0, c_sel[11*i +: 5], 1'b0};
            cr1_yr[i] <= {1'b0, c_sel[11*i +: 5]} + (k4_reg ? 6'd16 : 6'd8);
            cr1_sum = mlkem_decompress_sum({6'd0, cr1_y3[i]}, {6'd0, cr1[11*i +: 5]},
                                           {6'd0, cr1_yr[i]});
            vd2[12*i +: 12] <= k4_reg ? cr1_sum[16:5] : cr1_sum[15:4];
            s3[12*i +: 12] <= posw ? mlkem_mod_sub(vd2[12*i +: 12], x2[12*i +: 12]) :
                              !r_scl ? s2[12*i +: 12] :
                              mlkem_mod_add(s2[12*i +: 12], mu2[i] ? 12'd1665 : 12'd0);
        end
        x2 <= x1;
        mu2 <= c_rdata[91:88];
        cmp_d <= !r_scl ? (k4_reg ? 4'd11 : 4'd10) : posw ? 4'd1 : (k4_reg ? 4'd5 : 4'd4);
    end
    mlkem_delay #(.W(44), .D(5)) u_dc6 (.clk(clk), .d(cr1), .q(cr6));

    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_comp
            mlkem_compress #(.HI(2)) u_comp (.clk(clk), .x(s3[12*gi +: 12]), .d(cmp_d),
                                            .y(cq6[11*gi +: 11]));
        end
    endgenerate

    // Buffer write: v7 && (jd_ul == UL_BUF || ul_cw), registered (the job
    // fields are constant during a job). x7 is zero outside unload groups,
    // so a vector buffer takes it without a select and its scrub (engines
    // idle) writes zeros.
    reg ulb_q;
    reg [47:0] x7;
    always @(posedge clk) begin
        if (!rst_n || kill)
            ulb_q <= 1'b0;
        else
            ulb_q <= v6 && ((jd_ul == `MLKEM_UL_BUF) || ul_cw);
        if (!v6)
            x7 <= 48'd0;
        else
            x7 <= ul_cw ? {1'b0, cq6[43:33], 1'b0, cq6[32:22], 1'b0, cq6[21:11], 1'b0, cq6[10:0]} : x6;
    end
    assign b_we = ulb_q;
    assign b_widx = n7;
    assign b_wdata = x7;
    assign b_first = n7_first;
    assign b_last = n7_last;
    assign b_wep = jd_ul_ep;

    // Compare in two steps: the four 11-bit fields, then the verdict.
    reg cmp_v;
    reg [3:0] ne_q;
    always @(posedge clk) begin
        for (i = 0; i < 4; i = i + 1)
            ne_q[i] <= (cq6[11*i +: 11] != cr6[11*i +: 11]);
        if (!rst_n || kill) begin
            mp_we <= 1'b0;
            cmp_v <= 1'b0;
            diff <= 1'b0;
        end else begin
            mp_we <= v6 && posw;
            cmp_v <= v6 && ul_noise && jd_cmp;
            if (go)
                diff <= 1'b0;
            else if (cmp_v && (ne_q != 4'd0))
                diff <= 1'b1;
        end
        mp_bits <= {cq6[33], cq6[22], cq6[11], cq6[0]};
    end

endmodule
