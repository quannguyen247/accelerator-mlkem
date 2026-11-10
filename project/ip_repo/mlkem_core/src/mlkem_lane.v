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
module mlkem_lane #(
    parameter LANE = 0
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
    input wire [95:0] pm_wr_data,
    input wire pm_wr_ep,
    output wire [5:0] b_fill,
    output wire b_ep,

    // S store write (KeyGen s^)
    output reg s_we,
    output reg [7:0] s_idx,
    output reg [11:0] s_data,

    // C store: compressed u / v read (Decaps) and write (Encaps)
    output wire c_rreq,
    output wire [7:0] c_ridx,
    input wire [10:0] c_rdata,
    input wire [5:0] c_fill,
    output reg c_we,
    output reg [7:0] c_widx,
    output reg [10:0] c_wdata,

    // Message bits in, decoded message and re-encryption mismatch out
    input wire [255:0] mu_bits,
    output reg mp_we,
    output reg [7:0] mp_idx,
    output reg mp_bit,
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

    // Job state
    reg job;
    reg [8:0] n;
    reg [8:0] sc;
    reg [3:0] drain;
    reg [4:0] nz_cnt;                    // PRF words written so far
    wire nz_rdy = (nz_cnt != 5'd0);

    wire is_keygen = (op == `MLKEM_OP_KEYGEN);
    wire is_decaps = (op == `MLKEM_OP_DECAPS);
    wire active = IS_SCL ? !is_keygen : (LIDX < k);
    wire last_job = !(is_decaps && (IS_VEC || IS_SCL)) || job;

    // Job descriptor
    reg [1:0] jd_ld;
    reg jd_ld_ep;
    reg jd_mode;
    reg [1:0] jd_ul;
    reg jd_ul_ep;
    reg jd_swr;
    reg jd_cmp;
    always @(*) begin
        jd_ld = `MLKEM_LD_CBD;
        jd_ld_ep = 1'b0;
        jd_mode = 1'b0;
        jd_ul = `MLKEM_UL_BUF;
        jd_ul_ep = 1'b0;
        jd_swr = 1'b0;
        jd_cmp = is_decaps;
        if (IS_VEC) begin
            jd_swr = is_keygen;
            if (is_decaps) begin
                jd_ld = job ? `MLKEM_LD_CBD : `MLKEM_LD_DEC;
                jd_ul_ep = job;
            end
        end else if (IS_ROW) begin
            if (!is_keygen) begin
                jd_ld = `MLKEM_LD_BUF;
                jd_mode = 1'b1;
                jd_ul = `MLKEM_UL_POSU;
            end
        end else begin
            jd_ld = `MLKEM_LD_BUF;
            jd_ld_ep = job;
            jd_mode = 1'b1;
            jd_ul = (is_decaps && !job) ? `MLKEM_UL_POSW : `MLKEM_UL_POSV;
        end
    end

    // Parameter-set constants, registered (k is stable for the whole request).
    reg [3:0] du, dv;
    reg k4_reg;                          // ML-KEM-1024: du = 11, dv = 5
    always @(posedge clk) begin
        du <= mlkem_du(k);
        dv <= mlkem_dv(k);
        k4_reg <= (k == 3'd4);
    end
    wire ul_noise = (jd_ul == `MLKEM_UL_POSU) || (jd_ul == `MLKEM_UL_POSV);
    wire ul_cread = (jd_ul == `MLKEM_UL_POSW) || (ul_noise && jd_cmp);
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
    assign pm_rd_data = b_rdata;

    (* ram_style = "distributed" *) reg [63:0] nmem [0:31];
    wire [4:0] nz_raddr;
    always @(posedge clk) begin
        if (curr_state == ST_SCRUB)
            nmem[sc[4:0]] <= 64'd0;
        else if (nz_we)
            nmem[nz_addr] <= nz_wdata;
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

    // NTT core
    reg core_start;
    reg ext_we;
    reg [7:0] ext_addr;
    reg [11:0] ext_din;
    wire [11:0] ext_dout;
    wire core_busy;
    wire core_done;

    ntt_core_top #(
        .INTT_SCALE(0)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n && !kill),
        .start(core_start),
        .mode(jd_mode),
        .ext_we(ext_we),
        .ext_addr(ext_addr),
        .ext_din(ext_din),
        .ext_dout(ext_dout),
        .busy(core_busy),
        .done(core_done)
    );

    // Load path
    wire ld_ready = (jd_ld == `MLKEM_LD_CBD) ? cbd_v :
                    (jd_ld == `MLKEM_LD_DEC) ? (c_fill > {1'b0, n[7:3]}) :
                    ((b_ep == jd_ld_ep) && (b_fill > {1'b0, n[7:3]}));
    wire ld_issue = (curr_state == ST_LOAD) && !n[8] && ld_ready;

    reg l1_v, l2_v;
    reg [7:0] l1_n, l2_n;
    reg [11:0] l1_raw, l2_val;
    wire [11:0] b_sel = b_rdata[n[2:0]*12 +: 12];

    // Unload path
    wire ul_go = (curr_state == ST_UNLOAD) && !n[8] && (!ul_noise || cbd_v);
    reg [7:0] v_ul;
    reg v0;
    reg [7:0] n0, n1, n2, n3;
    reg [10:0] cr0;
    reg [11:0] e0;
    reg [11:0] x1, x2, e1, s2, vd2, s3;
    reg [10:0] cr1, cr2, cr3;
    reg mu2;
    wire [7:0] n6, n7;
    wire [10:0] cr6;
    wire [11:0] x7;
    wire [10:0] cq6;
    wire [22:0] xr_p3;
    wire [11:0] xr7;

    assign cbd_pop = ld_issue && (jd_ld == `MLKEM_LD_CBD) || ul_go && ul_noise;
    assign cbd_init = (curr_state == ST_LDW && jd_ld == `MLKEM_LD_CBD && nz_rdy) ||
                      (curr_state == ST_ULW && ul_noise && nz_rdy && drain == 4'd0);

    // Port selects are registered: they change only on state transitions.
    reg c_rreq_q;
    reg b_ld_sel;
    assign c_rreq = c_rreq_q;
    assign c_ridx = n[7:0];
    assign b_raddr = b_ld_sel ? n[7:3] : pm_rd_blk;
    assign busy = (curr_state != ST_IDLE);

    // The core port is driven from registers: load stage 2, unload address
    // (read now, zero written behind it), or the scrub counter.
    always @(posedge clk) begin
        if (!rst_n || kill)
            ext_we <= 1'b0;
        else if (curr_state == ST_SCRUB)
            ext_we <= zero_core;
        else if (curr_state == ST_LOAD)
            ext_we <= l2_v;
        else if (curr_state == ST_UNLOAD)
            ext_we <= ul_go;
        else
            ext_we <= 1'b0;
        ext_addr <= (curr_state == ST_SCRUB) ? sc[7:0] : (curr_state == ST_UNLOAD) ? n[7:0] : l2_n;
        ext_din <= (curr_state == ST_LOAD) ? l2_val : 12'd0;
        c_rreq_q <= ((curr_state == ST_LDW) && (jd_ld == `MLKEM_LD_DEC)) || ((curr_state == ST_LOAD) && (jd_ld == `MLKEM_LD_DEC) && !n[8]) ||
                    ((curr_state == ST_ULW) && ul_cread) || ((curr_state == ST_UNLOAD) && ul_cread && !n[8]);
        b_ld_sel <= ((curr_state == ST_LDW) || (curr_state == ST_LOAD)) && (jd_ld == `MLKEM_LD_BUF);
    end

    // FSM transition conditions
    wire ld_done = n[8] && !l1_v && !l2_v && !ext_we;
    wire ul_wait = ul_cread && (c_fill != 6'd32);
    // Noise jobs: initialise the CBD stream once, then wait for its first value.
    wire ul_arm = !ul_wait && ul_noise && (drain == 4'd0) && nz_rdy;
    wire ul_start = !ul_wait && (!ul_noise || ((drain != 4'd0) && cbd_v));
    wire scrub_last = zero_core ? (sc == 9'd255) : (sc == 9'd31);

    always @(*) begin
        next_state = curr_state;

        case (curr_state)
            ST_IDLE: if (scrub)
                next_state = ST_SCRUB;
            else if (go && active)
                next_state = ST_LDW;
            ST_LDW: if (jd_ld != `MLKEM_LD_CBD || nz_rdy)
                next_state = ST_LOAD;
            ST_LOAD: if (ld_done)
                next_state = ST_START;
            ST_START: next_state = ST_RUN;
            ST_RUN: if (core_done)
                next_state = ST_ULW;
            ST_ULW: if (ul_start)
                next_state = ST_UNLOAD;
            ST_UNLOAD: if (n[8])
                next_state = ST_DRAIN;
            ST_DRAIN: if (drain == 4'd1)
                next_state = last_job ? ST_IDLE : ST_LDW;
            ST_SCRUB: if (scrub_last)
                next_state = ST_IDLE;
            default: next_state = ST_IDLE;
        endcase
    end

    // Lane FSMD update
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            curr_state <= ST_IDLE;
            job <= 1'b0;
            n <= 9'd0;
            sc <= 9'd0;
            drain <= 4'd0;
            core_start <= 1'b0;
            nz_cnt <= 5'd0;
            cbd_eta3_reg <= 1'b0;
        end else begin
            curr_state <= next_state;
            core_start <= (curr_state == ST_START);
            cbd_eta3_reg <= ((next_state == ST_LDW) || (next_state == ST_LOAD)) && (k == 3'd2);
            if (nz_we)
                nz_cnt <= nz_addr + 5'd1;
            case (curr_state)
                ST_IDLE: begin
                    if (scrub) begin
                        sc <= 9'd0;
                        nz_cnt <= 5'd0;
                    end else if (go) begin
                        job <= 1'b0;
                        nz_cnt <= 5'd0;
                    end
                end
                ST_LDW: begin
                    n <= 9'd0;
                end
                ST_LOAD: begin
                    if (ld_issue)
                        n <= n + 9'd1;
                end
                ST_RUN: begin
                    if (core_done) begin
                        n <= 9'd0;
                        drain <= 4'd0;
                    end
                end
                ST_ULW: begin
                    if (ul_arm)
                        drain <= 4'd1;
                end
                ST_UNLOAD: begin
                    if (ul_go)
                        n <= n + 9'd1;
                    if (n[8])
                        drain <= 4'd11;
                end
                ST_DRAIN: begin
                    drain <= drain - 4'd1;
                    if (drain == 4'd1 && !last_job)
                        job <= 1'b1;
                end
                ST_SCRUB: begin
                    sc <= sc + 9'd1;
                end
                default: ;
            endcase
        end
    end

    // Load pipeline
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            l1_v <= 1'b0;
            l2_v <= 1'b0;
        end else begin
            l1_v <= ld_issue;
            l2_v <= l1_v;
        end
        l1_n <= n[7:0];
        l2_n <= l1_n;
        l2_val <= (jd_ld == `MLKEM_LD_DEC) ? mlkem_decompress_u(l1_raw[10:0], k4_reg) : l1_raw;
        case (jd_ld)
            `MLKEM_LD_CBD: l1_raw <= cbd_val;
            `MLKEM_LD_DEC: l1_raw <= {1'b0, c_rdata};
            default: l1_raw <= b_sel;
        endcase
    end

    // Unload pipeline
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            v0 <= 1'b0;
            v_ul <= 8'd0;
        end else begin
            v0 <= ul_go;
            v_ul <= {v_ul[6:0], v0};
        end
        // Stage 0: the core reads ext_addr (= n0) during the next cycle.
        n0 <= n[7:0];
        cr0 <= c_rdata;
        e0 <= cbd_val;
        n1 <= n0;
        x1 <= ext_dout;
        cr1 <= cr0;
        e1 <= e0;
        n2 <= n1;
        x2 <= x1;
        cr2 <= cr1;
        s2 <= mlkem_mod_add(x1, e1);
        vd2 <= mlkem_decompress_v(cr1, k4_reg);
        mu2 <= mu_bits[n1];
        n3 <= n2;
        cr3 <= cr2;
        case (jd_ul)
            `MLKEM_UL_POSV: s3 <= mlkem_mod_add(s2, mu2 ? 12'd1665 : 12'd0);
            `MLKEM_UL_POSW: s3 <= mlkem_mod_sub(vd2, x2);
            default: s3 <= s2;
        endcase
    end

    wire [3:0] cmp_d = (jd_ul == `MLKEM_UL_POSU) ? du :
                       (jd_ul == `MLKEM_UL_POSV) ? dv : 4'd1;

    generate
        if (IS_ROW) begin : g_cmp_hi
            mlkem_compress #(.HI(1)) u_comp (.clk(clk), .x(s3), .d(cmp_d), .y(cq6));
        end else if (IS_SCL) begin : g_cmp_lo
            mlkem_compress #(.HI(0)) u_comp (.clk(clk), .x(s3), .d(cmp_d), .y(cq6));
        end else begin : g_cmp_none
            assign cq6 = 11'd0;
        end
    endgenerate

    mlkem_delay #(.W(8), .D(3)) u_dn6 (.clk(clk), .d(n3), .q(n6));
    mlkem_delay #(.W(11), .D(3)) u_dc6 (.clk(clk), .d(cr3), .q(cr6));
    mlkem_delay #(.W(8), .D(6)) u_dn7 (.clk(clk), .d(n1), .q(n7));
    mlkem_delay #(.W(12), .D(6)) u_dx7 (.clk(clk), .d(x1), .q(x7));

    generate
        if (IS_VEC) begin : g_xr
            // PMAC operand scaling: x * 2^e mod q = MontRed(x * (2^(e+16) mod q))
            //   KeyGen          e = 16: 2^32 mod q = 1353
            //   Encaps, Decaps  e = 9:  2^25 mod q = 1441
            reg [10:0] xr_const_reg;
            always @(posedge clk)
                xr_const_reg <= is_keygen ? 11'd1353 : 11'd1441;
            mlkem_mul #(.WA(12), .WB(11)) u_xr_mul (.clk(clk), .a(x1), .b(xr_const_reg), .p(xr_p3));
            mlkem_montred u_xr_red (.clk(clk), .t({5'd0, xr_p3}), .r(xr7));
        end else begin : g_no_xr
            assign xr_p3 = 23'd0;
            assign xr7 = 12'd0;
        end
    endgenerate

    wire v6 = v_ul[5];
    wire v7 = v_ul[6];
    wire ul_buf_we = v7 && (jd_ul == `MLKEM_UL_BUF);
    wire [11:0] ul_bval = IS_VEC ? xr7 : x7;

    always @(*) begin
        b_we = 8'd0;
        b_waddr = n7[7:3];
        b_wdata = {8{ul_bval}};
        if (curr_state == ST_SCRUB) begin
            b_we = 8'hFF;
            b_waddr = sc[4:0];
            b_wdata = 96'd0;
        end else if (pm_we) begin
            b_we = 8'hFF;
            b_waddr = pm_wr_blk;
            b_wdata = pm_wr_data;
        end else if (ul_buf_we) begin
            b_we = 8'd1 << n7[2:0];
        end
    end

    mlkem_slot_state u_bstate (
        .clk(clk),
        .rst_n(rst_n),
        .clr(go || (curr_state == ST_SCRUB)),
        .first(pm_we ? (pm_wr_blk == 5'd0) : (ul_buf_we && n7 == 8'd0)),
        .first_ep(pm_we ? pm_wr_ep : jd_ul_ep),
        .inc(pm_we || (ul_buf_we && n7[2:0] == 3'd7)),
        .fill(b_fill),
        .ep(b_ep)
    );

    // Outputs to stores
    always @(posedge clk) begin
        if (!rst_n || kill) begin
            s_we <= 1'b0;
            c_we <= 1'b0;
            mp_we <= 1'b0;
            diff <= 1'b0;
        end else begin
            if (go && curr_state == ST_IDLE)
                diff <= 1'b0;
            s_we <= ul_buf_we && jd_swr;
            c_we <= v6 && (jd_ul == `MLKEM_UL_POSU || jd_ul == `MLKEM_UL_POSV) && !jd_cmp;
            mp_we <= v6 && (jd_ul == `MLKEM_UL_POSW);
            if (v6 && ul_noise && jd_cmp && (cq6 != cr6))
                diff <= 1'b1;
        end
        s_idx <= n7;
        s_data <= x7;
        c_widx <= n6;
        c_wdata <= cq6;
        mp_idx <= n6;
        mp_bit <= cq6[0];
    end

endmodule
