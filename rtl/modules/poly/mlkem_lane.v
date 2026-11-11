`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// One NTT lane: an ntt_core_top, its local polynomial buffer, its PRF noise
// memory, and the load/unload pipelines around the core's
// one-coefficient-per-cycle port. Unloading writes zeros behind the read, so
// the core RAM is clean after every job.
// The core runs without its INTT scale pass (256 cycles saved per INTT), so
// an INTT returns 128 times the inverse transform. The vector lanes fold the
// missing factor into the PMAC operand they unload:
//   KeyGen          s^ * 2^16  (PMAC removes 2^16, t^ is not transformed back)
//   Encaps, Decaps  y^ * 2^9, u'^ * 2^9  (PMAC removes 2^16, INTT adds 2^7)
//   LANE 0..3  vector lanes: forward NTT of s / y / u', result to the buffer
//   LANE 4..7  row lanes:    INTT of u-rows (KeyGen: forward NTT of e)
//   LANE 8     scalar lane:  INTT of v (Decaps also w)
// Each lane type instantiates only the registers its jobs use.
module mlkem_lane #(
    parameter LANE = 0,
    // Width of c_rdata (derived, not to be overridden): the scalar lane's
    // bus carries the message bit next to the C store block.
    parameter C_RW = (LANE == 8) ? 89 : 88
)(
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

    // PRF noise words from the hash engine
    input wire nz_we,
    input wire [4:0] nz_addr,
    input wire [63:0] nz_wdata,

    // Lane buffer: PMAC operand read, PMAC result write, fill state
    input wire [4:0] pm_rd_blk,
    output wire [95:0] pm_rd_data,
    input wire pm_we,
    input wire [4:0] pm_wr_blk,
    input wire pm_wr_first,              // pm_wr_blk == 0
    input wire [95:0] pm_wr_data,
    input wire pm_wr_ep,
    output wire [5:0] b_fill,
    output wire b_ep,

    // S store write (KeyGen s^); s_first / s_last: the coefficient is the
    // first of the polynomial / the last of its 8-coefficient block
    output reg s_we,
    output reg [7:0] s_idx,
    output reg [11:0] s_data,
    output reg s_first,
    output reg s_last,

    // C store: compressed u / v block read (Decaps) and coefficient write
    // (Encaps). c_rdata[87:0] is the block of eight 11-bit values at c_rblk.
    // Scalar lane: c_rdata[88] is the message bit of coefficient mu_idx,
    // valid one cycle after the index.
    output wire c_rreq,
    output wire [4:0] c_rblk,
    input wire [C_RW-1:0] c_rdata,
    input wire [5:0] c_fill,
    output reg c_we,
    output wire [7:0] c_widx,
    output reg [10:0] c_wdata,
    output wire c_first,
    output wire c_last,

    // Scalar lane: index of the message bit it needs next, decoded message
    // strobe (bit c_wdata[0] of coefficient c_widx); row and scalar lanes:
    // re-encryption mismatch
    output wire [7:0] mu_idx,
    output reg mp_we,
    output reg diff
);

    `include "mlkem_funcs.vh"

    localparam IS_VEC = (LANE < 4);
    localparam IS_ROW = (LANE >= 4) && (LANE < 8);
    localparam IS_SCL = (LANE == 8);
    localparam [2:0] LIDX = (LANE < 4) ? LANE : ((LANE < 8) ? LANE - 4 : 0);

    // Lane FSM states
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

    // The state register is one-hot by construction; its bits are used
    // directly, so no state test depends on the tool recognising the FSM.
    wire st_idle = curr_state[0];
    wire st_ldw = curr_state[1];
    wire st_load = curr_state[2];
    wire st_start = curr_state[3];
    wire st_run = curr_state[4];
    wire st_ulw = curr_state[5];
    wire st_unload = curr_state[6];
    wire st_drain = curr_state[7];
    wire st_scrub = curr_state[8];

    // Job state
    wire job;                            // second job of a Decaps request
    wire job_nx;
    reg [8:0] n;
    reg [8:0] sc;
    reg [3:0] drain;
    reg [4:0] nz_cnt;                    // PRF words written so far
    wire nz_rdy = (nz_cnt != 5'd0);

    wire is_keygen = (op == `MLKEM_OP_KEYGEN);
    wire is_decaps = (op == `MLKEM_OP_DECAPS);
    wire active = IS_SCL ? !is_keygen : (LIDX < k);
    // The core sets op and k one cycle before go, so a registered copy is
    // valid with go.
    reg active_q;
    always @(posedge clk)
        active_q <= active;
    wire last_job = !(is_decaps && (IS_VEC || IS_SCL)) || job;

    // Job descriptor. Its variable part is registered from the operation
    // and the next job index, so it is valid from the first cycle of a job
    // and the request parameters stay off the pipeline enables.
    //   jd_ld / jd_ld_ep   load source and the buffer epoch it waits for
    //   jd_mode            0: NTT, 1: INTT
    //   jd_ul / jd_ul_ep   unload destination and the epoch it writes
    //   jd_swr             copy the result to the S store (KeyGen s^)
    //   jd_cmp             compare with the received ciphertext (Decaps)
    //   ul_noise           add CBD noise while unloading
    //   ul_cread           read the C store while unloading
    reg [1:0] jd_ld;
    reg jd_ld_ep;
    reg jd_mode;
    reg [1:0] jd_ul;
    reg jd_ul_ep;
    reg jd_swr;
    reg jd_cmp;
    reg ul_noise;
    reg ul_cread;

    generate
        if (IS_VEC) begin : g_jd_vec
            // NTT of CBD noise; the first Decaps job transforms u' instead.
            reg ld_dec_reg;
            always @(posedge clk) begin
                ld_dec_reg <= is_decaps && !job_nx;
                jd_ul_ep <= is_decaps && job_nx;
                jd_swr <= is_keygen;
            end
            always @(*) begin
                jd_ld = ld_dec_reg ? `MLKEM_LD_DEC : `MLKEM_LD_CBD;
                jd_ld_ep = 1'b0;
                jd_mode = 1'b0;
                jd_ul = `MLKEM_UL_BUF;
                jd_cmp = 1'b0;
                ul_noise = 1'b0;
                ul_cread = 1'b0;
            end
        end else if (IS_ROW) begin : g_jd_row
            // KeyGen: NTT of e. Encaps, Decaps: INTT of a u row, plus e1.
            reg u_row_reg;
            reg dec_reg;
            always @(posedge clk) begin
                u_row_reg <= !is_keygen;
                dec_reg <= is_decaps;
            end
            always @(*) begin
                jd_ld = u_row_reg ? `MLKEM_LD_BUF : `MLKEM_LD_CBD;
                jd_ld_ep = 1'b0;
                jd_mode = u_row_reg;
                jd_ul = u_row_reg ? `MLKEM_UL_POSU : `MLKEM_UL_BUF;
                jd_ul_ep = 1'b0;
                jd_swr = 1'b0;
                jd_cmp = dec_reg;
                ul_noise = u_row_reg;
                ul_cread = dec_reg;
            end
        end else begin : g_jd_scl
            // INTT of v plus e2 and the message; the first Decaps job returns w.
            reg posw_reg;
            reg dec_reg;
            always @(posedge clk) begin
                posw_reg <= is_decaps && !job_nx;
                dec_reg <= is_decaps;
            end
            always @(*) begin
                jd_ld = `MLKEM_LD_BUF;
                jd_ld_ep = job;
                jd_mode = 1'b1;
                jd_ul = posw_reg ? `MLKEM_UL_POSW : `MLKEM_UL_POSV;
                jd_ul_ep = 1'b0;
                jd_swr = 1'b0;
                jd_cmp = dec_reg;
                ul_noise = !posw_reg;
                ul_cread = dec_reg;
            end
        end
    endgenerate

    // ML-KEM-1024 (du = 11, dv = 5), registered: k is stable for the whole request.
    reg k4_reg;
    always @(posedge clk)
        k4_reg <= (k == 3'd4);
    // eta = 3 noise (ML-KEM-512 secrets) while loading, eta = 2 otherwise
    reg cbd_eta3_reg;

    // Lane buffer and noise memory
    wire [95:0] b_rdata;
    reg [7:0] b_we;
    reg [4:0] b_waddr;
    reg [95:0] b_wdata;
    wire [4:0] b_raddr;

    mlkem_poly_ram #(.W(12), .AW(5)) u_buf (
        .clk(clk),
        .we(b_we),
        .waddr({8{b_waddr}}),
        .wdata(b_wdata),
        .raddr(b_raddr),
        .rdata(b_rdata)
    );

    // Buffer read ports. Vector lanes: the PMAC reads its operand. Row
    // lanes: the load path reads at its own counter and the output engine
    // reads the KeyGen e^ block through a second port. Scalar lane: the
    // load path only.
    generate
        if (IS_VEC) begin : g_buf_vec
            assign b_raddr = pm_rd_blk;
            assign pm_rd_data = b_rdata;
        end else if (IS_ROW) begin : g_buf_row
            assign b_raddr = n[7:3];
            mlkem_poly_ram #(.W(12), .AW(5)) u_buf_o (
                .clk(clk),
                .we(b_we),
                .waddr({8{b_waddr}}),
                .wdata(b_wdata),
                .raddr(pm_rd_blk),
                .rdata(pm_rd_data)
            );
        end else begin : g_buf_scl
            // Registered port select: it changes only on state transitions.
            reg b_ld_sel;
            always @(posedge clk)
                b_ld_sel <= st_ldw || st_load;
            assign b_raddr = b_ld_sel ? n[7:3] : pm_rd_blk;
            assign pm_rd_data = b_rdata;
        end
    endgenerate

    // The PRF word write port is registered in the lane: the hash engine
    // feeds nine lanes, the memory sees a local register.
    reg nz_we_reg;
    reg [4:0] nz_addr_reg;
    reg [63:0] nz_wdata_reg;
    always @(posedge clk) begin
        if (!rst_n || kill)
            nz_we_reg <= 1'b0;
        else
            nz_we_reg <= nz_we;
        nz_addr_reg <= nz_addr;
        nz_wdata_reg <= nz_wdata;
    end

    (* ram_style = "distributed" *) reg [63:0] nmem [0:31];
    wire [4:0] nz_raddr;
    always @(posedge clk) begin
        if (st_scrub)
            nmem[sc[4:0]] <= 64'd0;
        else if (nz_we_reg)
            nmem[nz_addr_reg] <= nz_wdata_reg;
    end

    wire cbd_init;
    wire cbd_pop;
    wire cbd_v;
    wire [11:0] cbd_val;
    mlkem_cbd_stream u_cbd (
        .clk(clk),
        .rst_n(rst_n),
        .init(cbd_init),
        .eta3(cbd_eta3_reg),
        .avail(nz_cnt),
        .rd_addr(nz_raddr),
        .rd_data(nmem[nz_raddr]),
        .pop(cbd_pop),
        .val_v(cbd_v),
        .val(cbd_val)
    );

    // NTT core, with registered RAM ports: the address goes out one cycle
    // ahead of ext_we / ext_din / ext_dout and is registered in the core.
    // The core's reset is registered in the lane: kill reaches the core one
    // cycle later, still before the scrub that follows an abort.
    reg core_rst_n_reg;
    reg core_start;
    reg ext_we;
    wire [7:0] ext_addr;
    reg [11:0] ext_din;
    wire [11:0] ext_dout;
    wire core_busy_unused;
    wire core_done;

    always @(posedge clk)
        core_rst_n_reg <= rst_n && !kill;

    ntt_core_top #(
        .INTT_SCALE(0),
        .PORT_REG(1)
    ) u_core (
        .clk(clk),
        .rst_n(core_rst_n_reg),
        .start(core_start),
        .mode(jd_mode),
        .ext_we(ext_we),
        .ext_addr(ext_addr),
        .ext_din(ext_din),
        .ext_dout(ext_dout),
        .busy(core_busy_unused),
        .done(core_done)
    );

    // Index of the coefficient issued one, two and three cycles ago
    reg [7:0] n0, n1, n2;
    always @(posedge clk) begin
        n0 <= n[7:0];
        n1 <= n0;
        n2 <= n1;
    end
    assign mu_idx = n0;

    // Stage 0 of both pipelines: the C store block and the CBD value of the
    // issued coefficient, registered; the coefficient is selected from the
    // block in the next stage.
    reg [87:0] c_blk_reg;
    reg [11:0] cbd_reg;
    always @(posedge clk) begin
        c_blk_reg <= c_rdata[87:0];
        cbd_reg <= cbd_val;
    end
    wire [10:0] c_sel = c_blk_reg[n0[2:0]*11 +: 11];

    // Load path: stage 0 (sources), stage 1 (raw value), stage 2 (value)
    wire ld_ready = (jd_ld == `MLKEM_LD_CBD) ? cbd_v :
                    (jd_ld == `MLKEM_LD_DEC) ? (c_fill > {1'b0, n[7:3]}) :
                    ((b_ep == jd_ld_ep) && (b_fill > {1'b0, n[7:3]}));
    wire ld_issue = st_load && !n[8] && ld_ready;

    reg l0_v, l1_v, l2_v;
    reg [11:0] l1_raw, l2_val;

    generate
        if (IS_VEC) begin : g_ld_vec
            // CBD noise, or Decaps u' decompressed from the C store (du = 10 or 11)
            reg [12:0] l1_y3;
            reg [11:0] l1_yr;
            wire [22:0] l1_sum = mlkem_decompress_sum(l1_y3, l1_raw[10:0], l1_yr);
            always @(posedge clk) begin
                l1_raw <= (jd_ld == `MLKEM_LD_DEC) ? {1'b0, c_sel} : cbd_reg;
                l1_y3 <= {2'd0, c_sel} + {1'b0, c_sel, 1'b0};
                l1_yr <= {1'b0, c_sel} + (k4_reg ? 12'd1024 : 12'd512);
                l2_val <= (jd_ld != `MLKEM_LD_DEC) ? l1_raw : k4_reg ? l1_sum[22:11] : l1_sum[21:10];
            end
        end else begin : g_ld_buf
            // PMAC result from the lane buffer (row lanes, KeyGen: CBD noise)
            reg [95:0] b_blk_reg;
            wire [11:0] b_sel = b_blk_reg[n0[2:0]*12 +: 12];
            always @(posedge clk) begin
                b_blk_reg <= b_rdata;
                l2_val <= l1_raw;
            end
            if (IS_ROW) begin : g_row
                always @(posedge clk)
                    l1_raw <= (jd_ld == `MLKEM_LD_BUF) ? b_sel : cbd_reg;
            end else begin : g_scl
                always @(posedge clk)
                    l1_raw <= b_sel;
            end
        end
    endgenerate

    // Unload path
    wire ul_go = st_unload && !n[8] && (!ul_noise || cbd_v);
    reg [7:0] v_ul;
    reg v0;
    reg [11:0] x1;
    reg [7:0] n7;
    reg n7_first, n7_last;               // n7 == 0, n7 ends a block of eight
    wire [7:0] n6;
    wire v6 = v_ul[5];
    wire v7 = v_ul[6];

    // CBD values are taken by the load (noise jobs) or by the unload (u, v
    // noise). Written out on its own (= ld_issue for CBD loads, ul_go for
    // noise unloads), so the pop does not depend on the other load sources.
    assign cbd_pop = cbd_v && !n[8] && ((st_load && (jd_ld == `MLKEM_LD_CBD)) || (st_unload && ul_noise));
    assign cbd_init = (st_ldw && jd_ld == `MLKEM_LD_CBD && nz_rdy) ||
                      (st_ulw && ul_noise && nz_rdy && drain == 4'd0);

    // The C store request is registered: it changes only on state transitions.
    reg c_rreq_q;
    assign c_rreq = c_rreq_q;
    assign c_rblk = n[7:3];
    assign busy = !st_idle;

    // Core port: load stage 2, unload address (read, then zero written
    // behind it), or the scrub counter.
    assign ext_addr = st_scrub ? sc[7:0] : st_unload ? n[7:0] : n2;

    always @(posedge clk) begin
        if (!rst_n || kill)
            ext_we <= 1'b0;
        else if (st_scrub)
            ext_we <= zero_core;
        else if (st_load)
            ext_we <= l2_v;
        else if (st_unload)
            ext_we <= ul_go;
        else
            ext_we <= 1'b0;
        ext_din <= st_load ? l2_val : 12'd0;
        c_rreq_q <= (st_ldw && (jd_ld == `MLKEM_LD_DEC)) || (st_load && (jd_ld == `MLKEM_LD_DEC) && !n[8]) ||
                    (st_ulw && ul_cread) || (st_unload && ul_cread && !n[8]);
    end

    // FSM transition conditions
    wire ld_done = n[8] && !l0_v && !l1_v && !l2_v && !ext_we;
    // C store slot complete, registered (fills only grow during a job). The
    // vector lanes never read the C store while unloading.
    wire c_full;
    generate
        if (IS_VEC) begin : g_cfull_none
            assign c_full = 1'b1;
        end else begin : g_cfull
            reg c_full_q;
            always @(posedge clk)
                c_full_q <= (c_fill == 6'd32);
            assign c_full = c_full_q;
        end
    endgenerate
    wire ul_wait = ul_cread && !c_full;
    // Noise jobs: initialise the CBD stream once, then wait for its first value.
    wire ul_arm = !ul_wait && ul_noise && (drain == 4'd0) && nz_rdy;
    wire ul_start = !ul_wait && (!ul_noise || ((drain != 4'd0) && cbd_v));
    wire scrub_last = zero_core ? (sc == 9'd255) : (sc == 9'd31);

    always @(*) begin
        next_state = curr_state;

        case (1'b1)
            st_idle: if (scrub)
                next_state = ST_SCRUB;
            else if (go && active_q)
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
            st_unload: if (n[8])
                next_state = ST_DRAIN;
            st_drain: if (drain == 4'd1)
                next_state = last_job ? ST_IDLE : ST_LDW;
            st_scrub: if (scrub_last)
                next_state = ST_IDLE;
            default: next_state = ST_IDLE;
        endcase
    end

    // Lane FSMD update
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            curr_state <= ST_IDLE;
            n <= 9'd0;
            sc <= 9'd0;
            drain <= 4'd0;
            core_start <= 1'b0;
            nz_cnt <= 5'd0;
            cbd_eta3_reg <= 1'b0;
        end else begin
            curr_state <= next_state;
            core_start <= st_start;
            cbd_eta3_reg <= (next_state[1] || next_state[2]) && (k == 3'd2);
            if (nz_we_reg)
                nz_cnt <= nz_addr_reg + 5'd1;
            case (1'b1)
                st_idle: begin
                    if (scrub) begin
                        sc <= 9'd0;
                        nz_cnt <= 5'd0;
                    end else if (go) begin
                        nz_cnt <= 5'd0;
                    end
                end
                st_ldw: begin
                    n <= 9'd0;
                end
                st_load: begin
                    if (ld_issue)
                        n <= n + 9'd1;
                end
                st_run: begin
                    if (core_done) begin
                        n <= 9'd0;
                        drain <= 4'd0;
                    end
                end
                st_ulw: begin
                    if (ul_arm)
                        drain <= 4'd1;
                end
                st_unload: begin
                    if (ul_go)
                        n <= n + 9'd1;
                    if (n[8])
                        drain <= 4'd11;
                end
                st_drain: begin
                    drain <= drain - 4'd1;
                end
                st_scrub: begin
                    sc <= sc + 9'd1;
                end
                default: ;
            endcase
        end
    end

    // Job index: the vector and scalar lanes run two jobs in a Decaps request.
    generate
        if (IS_ROW) begin : g_job_one
            assign job = 1'b0;
            assign job_nx = 1'b0;
        end else begin : g_job_two
            reg job_reg;
            assign job_nx = (st_idle && !scrub && go) ? 1'b0 :
                            (st_drain && (drain == 4'd1) && !last_job) ? 1'b1 : job_reg;
            always @(posedge clk) begin
                if (!rst_n || kill)
                    job_reg <= 1'b0;
                else
                    job_reg <= job_nx;
            end
            assign job = job_reg;
        end
    endgenerate

    // Pipeline valid flags
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            l0_v <= 1'b0;
            l1_v <= 1'b0;
            l2_v <= 1'b0;
            v0 <= 1'b0;
            v_ul <= 8'd0;
        end else begin
            l0_v <= ld_issue;
            l1_v <= l0_v;
            l2_v <= l1_v;
            v0 <= ul_go;
            v_ul <= {v_ul[6:0], v0};
        end
    end

    // Unload stage 1: the core reads ext_addr (= n0) one cycle after the issue.
    always @(posedge clk) begin
        x1 <= ext_dout;
        n7 <= n6;
        n7_first <= (n6 == 8'd0);
        n7_last <= (n6[2:0] == 3'd7);
    end
    mlkem_delay #(.W(8), .D(4)) u_dn6 (.clk(clk), .d(n2), .q(n6));
    assign c_widx = n7;
    assign c_first = n7_first;
    assign c_last = n7_last;

    // Buffer and S store unload (vector and row lanes): the transformed
    // value, scaled for the PMAC in the vector lanes.
    wire ul_buf_we;
    wire [11:0] ul_bval;
    generate
        if (IS_VEC) begin : g_ul_vec
            // PMAC operand scaling: x * 2^e mod q = MontRed(x * (2^(e+16) mod q))
            //   KeyGen          e = 16: 2^32 mod q = 1353
            //   Encaps, Decaps  e = 9:  2^25 mod q = 1441
            reg [10:0] xr_const_reg;
            wire [22:0] xr_p3;
            wire [11:0] xr7;
            wire [11:0] x7;
            always @(posedge clk)
                xr_const_reg <= is_keygen ? 11'd1353 : 11'd1441;
            mlkem_mul #(.WA(12), .WB(11)) u_xr_mul (.clk(clk), .a(x1), .b(xr_const_reg), .p(xr_p3));
            mlkem_montred u_xr_red (.clk(clk), .t({5'd0, xr_p3}), .r(xr7));
            mlkem_delay #(.W(12), .D(6)) u_dx7 (.clk(clk), .d(x1), .q(x7));
            assign ul_buf_we = v7;
            assign ul_bval = xr7;

            always @(posedge clk) begin
                if (!rst_n || kill)
                    s_we <= 1'b0;
                else
                    s_we <= ul_buf_we && jd_swr;
                s_idx <= n7;
                s_data <= x7;
                s_first <= n7_first;
                s_last <= n7_last;
            end
        end else begin : g_ul_no_s
            always @(*) begin
                s_we = 1'b0;
                s_idx = 8'd0;
                s_data = 12'd0;
                s_first = 1'b0;
                s_last = 1'b0;
            end
            if (IS_ROW) begin : g_row
                mlkem_delay #(.W(12), .D(6)) u_dx7 (.clk(clk), .d(x1), .q(ul_bval));
                // v7 && (jd_ul == UL_BUF), registered (jd_ul is constant in a request)
                reg ulb_q;
                always @(posedge clk) begin
                    if (!rst_n || kill)
                        ulb_q <= 1'b0;
                    else
                        ulb_q <= v6 && (jd_ul == `MLKEM_UL_BUF);
                end
                assign ul_buf_we = ulb_q;
            end else begin : g_scl
                assign ul_buf_we = 1'b0;
                assign ul_bval = 12'd0;
            end
        end
    endgenerate

    always @(*) begin
        b_we = 8'd0;
        b_waddr = pm_wr_blk;
        b_wdata = pm_wr_data;
        if (st_scrub) begin
            b_we = 8'hFF;
            b_waddr = sc[4:0];
            b_wdata = 96'd0;
        end else if (pm_we) begin
            b_we = 8'hFF;
        end else if (ul_buf_we) begin
            b_we = 8'd1 << n7[2:0];
            b_waddr = n7[7:3];
            b_wdata = {8{ul_bval}};
        end
    end

    mlkem_slot_state u_bstate (
        .clk(clk),
        .rst_n(rst_n),
        .clr(go || st_scrub),
        .first(pm_we ? pm_wr_first : (ul_buf_we && n7_first)),
        .first_ep(pm_we ? pm_wr_ep : jd_ul_ep),
        .inc(pm_we || (ul_buf_we && n7_last)),
        .fill(b_fill),
        .ep(b_ep)
    );

    // Noise, compression and compare (row and scalar lanes):
    //   row     u = x + e1, compressed to du bits
    //   scalar  v = x + e2 + Decompress_1(mu), compressed to dv bits
    //           Decaps first job: w = Decompress_dv(c2) - x, compressed to 1 bit
    // Encaps writes the result to the C store; Decaps compares it with the
    // received ciphertext (cr), the first scalar job returns the message bits.
    generate
        if (IS_VEC) begin : g_post_none
            always @(*) begin
                c_we = 1'b0;
                c_wdata = 11'd0;
                mp_we = 1'b0;
                diff = 1'b0;
            end
        end else begin : g_post
            reg [10:0] cr1;
            reg [11:0] e1, s2, s3;
            wire [10:0] cr6;
            wire [10:0] cq6;
            wire [3:0] cmp_d;

            always @(posedge clk) begin
                cr1 <= c_sel;
                e1 <= cbd_reg;
                s2 <= mlkem_mod_add(x1, e1);
            end
            mlkem_delay #(.W(11), .D(5)) u_dc6 (.clk(clk), .d(cr1), .q(cr6));

            if (IS_ROW) begin : g_row
                always @(posedge clk)
                    s3 <= s2;
                assign cmp_d = k4_reg ? 4'd11 : 4'd10;
                mlkem_compress #(.HI(1)) u_comp (.clk(clk), .x(s3), .d(cmp_d), .y(cq6));
                always @(*)
                    mp_we = 1'b0;
            end else begin : g_scl
                reg [11:0] x2, vd2;
                reg mu2;
                // c2 decompressed (dv = 4 or 5, so y has five bits): 3 * y
                // and y + 2^(dv-1) are registered with cr1
                reg [6:0] cr1_y3;
                reg [5:0] cr1_yr;
                wire [22:0] cr1_sum = mlkem_decompress_sum({6'd0, cr1_y3}, {6'd0, cr1[4:0]}, {6'd0, cr1_yr});
                always @(posedge clk) begin
                    cr1_y3 <= {2'd0, c_sel[4:0]} + {1'b0, c_sel[4:0], 1'b0};
                    cr1_yr <= {1'b0, c_sel[4:0]} + (k4_reg ? 6'd16 : 6'd8);
                    x2 <= x1;
                    vd2 <= k4_reg ? cr1_sum[16:5] : cr1_sum[15:4];
                    mu2 <= c_rdata[88];
                    s3 <= (jd_ul == `MLKEM_UL_POSW) ? mlkem_mod_sub(vd2, x2)
                                                    : mlkem_mod_add(s2, mu2 ? 12'd1665 : 12'd0);
                end
                assign cmp_d = (jd_ul == `MLKEM_UL_POSW) ? 4'd1 : (k4_reg ? 4'd5 : 4'd4);
                mlkem_compress #(.HI(0)) u_comp (.clk(clk), .x(s3), .d(cmp_d), .y(cq6));
                always @(posedge clk) begin
                    if (!rst_n || kill)
                        mp_we <= 1'b0;
                    else
                        mp_we <= v6 && (jd_ul == `MLKEM_UL_POSW);
                end
            end

            always @(posedge clk) begin
                if (!rst_n || kill) begin
                    c_we <= 1'b0;
                    diff <= 1'b0;
                end else begin
                    if (go && st_idle)
                        diff <= 1'b0;
                    c_we <= v6 && ul_noise && !jd_cmp;
                    if (v6 && ul_noise && jd_cmp && (cq6 != cr6))
                        diff <= 1'b1;
                end
                c_wdata <= cq6;
            end
        end
    endgenerate

endmodule
