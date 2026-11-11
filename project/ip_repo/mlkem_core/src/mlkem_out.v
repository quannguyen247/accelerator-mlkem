`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// Output stream engine. Encodes the result packet segment by segment from the
// stores and registers as soon as each block exists, so the stream overlaps
// the computation.
//   KeyGen: ek = t^ || rho, dk = s^ || ek || h || z   (first ek copy is hashed)
//   Encaps: c = c1 (du) || c2 (dv), then K
//   Decaps: K
module mlkem_out (
    input wire clk,
    input wire rst_n,

    // Request control
    input wire kill,
    input wire go,
    input wire [1:0] op,
    input wire [2:0] k,
    output wire busy,
    output wire secrets_read,      // no further reads of the S store or lane buffers

    // Store read
    output wire [1:0] rd_dest,     // 0: S, 1: T, 2: C
    output reg [2:0] rd_slot,
    output wire [4:0] rd_blk,      // S and T stores
    output wire [4:0] rd_blk_c,    // C store
    output wire [4:0] rd_blk_b,    // lane buffers (KeyGen e^)
    input wire [95:0] rd_s_data,   // block of slot rd_slot of each store
    input wire [95:0] rd_t_data,
    input wire [87:0] rd_c_data,
    input wire [5:0] rd_fill,      // fill of the store selected by rd_dest
    input wire [95:0] bias_data,   // KeyGen e^[slot] block, added to the T store value
    input wire [5:0] bias_fill,
    input wire bias_ep,

    // Byte strings
    input wire [255:0] rho,
    input wire rho_v,
    input wire [255:0] h,
    input wire h_v,
    input wire [255:0] z,
    input wire [255:0] key,
    input wire key_v,

    // Hashed ek copy to the tap FIFO (KeyGen)
    output wire fifo_push,
    output wire [63:0] fifo_din,
    input wire fifo_full,

    // Result words
    output wire [63:0] m_tdata,
    output wire m_tvalid,
    input wire m_tready
);

    `include "mlkem_funcs.vh"

    localparam [1:0] SK_VAL = 2'd0, SK_REG = 2'd1, SK_END = 2'd2;

    reg active;
    reg [2:0] seg;
    reg [7:0] bcnt;
    reg [9:0] ocnt;

    wire [3:0] du = mlkem_du(k);
    wire [3:0] dv = mlkem_dv(k);

    // Segment table, registered from the next segment index.
    // {sk, sd, sdest, snsl, sslot0, sreg}
    function [15:0] seg_of;
        input [1:0] f_op;
        input [2:0] f_seg;
        input [2:0] f_k;
        reg [1:0] t_sk, t_dest, t_reg;
        reg [3:0] t_d;
        reg [2:0] t_nsl, t_s0;
        begin
            t_sk = SK_END; t_d = 4'd8; t_dest = 2'd1; t_nsl = f_k; t_s0 = 3'd0; t_reg = 2'd0;
            case (f_op)
                `MLKEM_OP_KEYGEN: case (f_seg)
                    3'd0: begin t_sk = SK_VAL; t_d = 4'd12; t_dest = 2'd1; end
                    3'd1: begin t_sk = SK_REG; t_reg = 2'd0; end
                    3'd2: begin t_sk = SK_VAL; t_d = 4'd12; t_dest = 2'd0; end
                    3'd3: begin t_sk = SK_VAL; t_d = 4'd12; t_dest = 2'd1; end
                    3'd4: begin t_sk = SK_REG; t_reg = 2'd0; end
                    3'd5: begin t_sk = SK_REG; t_reg = 2'd1; end
                    3'd6: begin t_sk = SK_REG; t_reg = 2'd2; end
                    default: t_sk = SK_END;
                endcase
                `MLKEM_OP_ENCAPS: case (f_seg)
                    3'd0: begin t_sk = SK_VAL; t_d = mlkem_du(f_k); t_dest = 2'd2; end
                    3'd1: begin t_sk = SK_VAL; t_d = mlkem_dv(f_k); t_dest = 2'd2; t_nsl = 3'd1; t_s0 = 3'd4; end
                    3'd2: begin t_sk = SK_REG; t_reg = 2'd3; end
                    default: t_sk = SK_END;
                endcase
                default: case (f_seg)
                    3'd0: begin t_sk = SK_REG; t_reg = 2'd3; end
                    default: t_sk = SK_END;
                endcase
            endcase
            seg_of = {t_sk, t_d, t_dest, t_nsl, t_s0, t_reg};
        end
    endfunction

    reg [1:0] sk;
    reg [3:0] sd;
    reg [1:0] sdest;
    reg [1:0] sreg;      // 0: rho, 1: h, 2: z, 3: key
    reg use_bias;        // KeyGen t^ segment: e^ is added to the T store value
    reg [7:0] seg_blocks;
    reg [9:0] tot_words;
    reg [9:0] tap_words;

    wire seg_done = active && (sk != SK_END) && (bcnt == seg_blocks);
    wire [2:0] seg_nx = go ? 3'd0 : seg_done ? seg + 3'd1 : seg;
    wire [15:0] seg_d = seg_of(op, seg_nx, k);
    // snsl (slot count) and sslot0 (first slot) are used from seg_d directly.
    always @(posedge clk) begin
        sk <= seg_d[15:14];
        sd <= seg_d[13:10];
        sdest <= seg_d[9:8];
        sreg <= seg_d[1:0];
        use_bias <= (op == `MLKEM_OP_KEYGEN) && (seg_d[15:14] == SK_VAL) && (seg_d[9:8] == 2'd1);
        seg_blocks <= (seg_d[15:14] == SK_REG) ? 8'd4 : {seg_d[7:5], 5'd0};
        tot_words <= (op == `MLKEM_OP_KEYGEN) ? {k, 4'd0} * 4'd9 + 10'd16 :
                     (op == `MLKEM_OP_ENCAPS) ? {4'd0, du, 2'd0} * k + {4'd0, dv, 2'd0} + 10'd4 :
                     10'd4;
        tap_words <= (op == `MLKEM_OP_KEYGEN) ? {k, 4'd0} * 2'd3 + 10'd4 : 10'd0;
    end

    assign rd_dest = sdest;
    // Read addresses are registered copies of the next block index, one per
    // store group, so the block counter does not fan out to every memory.
    wire issue;
    wire [7:0] bcnt_nx = go ? 8'd0 : !active ? bcnt : seg_done ? 8'd0 : issue ? bcnt + 8'd1 : bcnt;
    (* keep = "true" *) reg [4:0] blk_st;
    (* keep = "true" *) reg [4:0] blk_c;
    (* keep = "true" *) reg [4:0] blk_b;
    always @(posedge clk) begin
        blk_st <= bcnt_nx[4:0];
        blk_c <= bcnt_nx[4:0];
        blk_b <= bcnt_nx[4:0];
        rd_slot <= seg_d[4:2] + {1'b0, bcnt_nx[6:5]};
    end
    assign rd_blk = blk_st;
    assign rd_blk_c = blk_c;
    assign rd_blk_b = blk_b;

    reg reg_ok;
    reg [255:0] reg_val;
    always @(*) begin
        case (sreg)
            2'd0: begin reg_ok = rho_v; reg_val = rho; end
            2'd1: begin reg_ok = h_v; reg_val = h; end
            2'd2: begin reg_ok = 1'b1; reg_val = z; end
            default: begin reg_ok = key_v; reg_val = key; end
        endcase
    end

    // Block readiness from the previous cycle: blocks available ahead of bcnt
    // (fills only grow). One idle cycle follows a slot or segment change.
    reg [5:0] avail_q;
    reg [5:0] bavail_q;
    reg issue_q;
    reg fresh;
    always @(posedge clk) begin
        avail_q <= rd_fill - {1'b0, bcnt[4:0]};
        bavail_q <= bias_ep ? 6'd0 : bias_fill - {1'b0, bcnt[4:0]};
    end
    wire [5:0] need = issue_q ? 6'd2 : 6'd1;
    wire blk_ok = fresh && (avail_q >= need) && (!use_bias || (bavail_q >= need));
    wire src_ok = (sk == SK_REG) ? reg_ok : blk_ok;

    // Read pipeline between the stores and the packer:
    //   R0  blocks as read, one register per store, KeyGen e^ block, register word
    //   R1  block of the segment's store (or the register word)
    //   R2  KeyGen t^: t^ - e^ from the T store plus e^
    //   D   block in decoding order, in a two-entry register slice
    // R0..R2 advance together whenever the slice can take a block (its
    // registered ready), so every stage is enabled by one flip-flop; the valid
    // flags carry the issue. The slice has room for the block in flight when
    // its ready falls.
    reg r0_v;
    reg r0_reg;
    reg r0_bias;
    reg [3:0] r0_sd;
    reg [1:0] r0_dest;
    reg [95:0] r0_s;
    reg [95:0] r0_t;
    reg [87:0] r0_c;
    reg [95:0] r0_add;
    reg [63:0] r0_word;

    reg r1_v;
    reg r1_reg;
    reg r1_bias;
    reg [3:0] r1_sd;
    reg [95:0] r1_data;
    reg [95:0] r1_add;

    reg r2_v;
    reg r2_reg;
    reg [3:0] r2_sd;
    reg [95:0] r2_data;

    wire adv;                       // R0..R2 advance (the slice has room)
    wire dv_r;                      // slice -> packer
    wire [95:0] d_raw;
    wire [3:0] d_db;

    integer i;
    reg [95:0] r0_data;
    always @(*) begin
        case (r0_dest)
            2'd0: r0_data = r0_s;
            2'd1: r0_data = r0_t;
            default: begin
                r0_data = 96'd0;
                for (i = 0; i < 8; i = i + 1)
                    r0_data[12*i +: 11] = r0_c[11*i +: 11];
            end
        endcase
    end

    integer a;
    reg [95:0] r1_sum;
    always @(*) begin
        for (a = 0; a < 8; a = a + 1)
            r1_sum[12*a +: 12] = r1_bias ? mlkem_mod_add(r1_data[12*a +: 12], r1_add[12*a +: 12])
                                         : r1_data[12*a +: 12];
    end

    // Block in decoding order: d bytes, zero filled.
    integer e;
    reg [95:0] enc;
    always @(*) begin
        enc = 96'd0;
        if (r2_reg) begin
            enc[63:0] = r2_data[63:0];
        end else begin
            for (e = 0; e < 8; e = e + 1) begin
                case (r2_sd)
                    4'd12: enc[12*e +: 12] = r2_data[12*e +: 12];
                    4'd11: enc[11*e +: 11] = r2_data[12*e +: 11];
                    4'd10: enc[10*e +: 10] = r2_data[12*e +: 10];
                    4'd5:  enc[5*e +: 5] = r2_data[12*e +: 5];
                    default: enc[4*e +: 4] = r2_data[12*e +: 4];
                endcase
            end
        end
    end

    wire pk_ready;
    assign issue = active && (sk != SK_END) && (bcnt != seg_blocks) && src_ok && adv;

    always @(posedge clk) begin
        if (adv) begin
            r0_reg <= (sk == SK_REG);
            r0_bias <= use_bias;
            r0_sd <= sd;
            r0_dest <= sdest;
            r0_s <= rd_s_data;
            r0_t <= rd_t_data;
            r0_c <= rd_c_data;
            r0_add <= bias_data;
            r0_word <= reg_val[{bcnt[1:0], 6'd0} +: 64];
            r1_reg <= r0_reg;
            r1_bias <= r0_bias;
            r1_sd <= r0_sd;
            r1_data <= r0_reg ? {32'd0, r0_word} : r0_data;
            r1_add <= r0_add;
            r2_reg <= r1_reg;
            r2_sd <= r1_sd;
            r2_data <= r1_sum;
        end
    end

    mlkem_axis_slice #(.W(100)) u_dslice (
        .clk(clk),
        .rst_n(rst_n),
        .clr(go || kill),
        .s_allow(1'b1),
        .s_valid(r2_v),
        .s_data({r2_sd, enc}),
        .s_ready(adv),
        .m_valid(dv_r),
        .m_data({d_db, d_raw}),
        .m_ready(pk_ready)
    );

    wire pk_valid;
    wire [63:0] pk_data;
    reg tap;                          // word belongs to the hashed ek copy (KeyGen)
    wire sl_ready;
    wire out_ok = sl_ready && (!tap || !fifo_full);

    mlkem_pack u_pack (
        .clk(clk),
        .rst_n(rst_n),
        .clr(go || kill),
        .db(d_db),
        .in_valid(dv_r),
        .in_raw(d_raw),
        .in_ready(pk_ready),
        .out_valid(pk_valid),
        .out_data(pk_data),
        .out_ready(out_ok)
    );

    // Output register slice: valid, data and the packer's ready are registered.
    wire fire = pk_valid && out_ok;
    wire sl_valid;
    mlkem_axis_slice #(.W(64)) u_slice (
        .clk(clk),
        .rst_n(rst_n),
        .clr(go || kill),
        .s_allow(1'b1),
        .s_valid(pk_valid && (!tap || !fifo_full)),
        .s_data(pk_data),
        .s_ready(sl_ready),
        .m_valid(sl_valid),
        .m_data(m_tdata),
        .m_ready(m_tready)
    );
    assign m_tvalid = sl_valid;
    assign fifo_push = fire && tap;
    assign fifo_din = pk_data;
    assign busy = active;
    assign secrets_read = !active || (op != `MLKEM_OP_KEYGEN) || (seg >= 3'd4);

    always @(posedge clk)
        tap <= ((fire ? ocnt + 10'd1 : ocnt) < tap_words);

    always @(posedge clk) begin
        if (!rst_n || kill) begin
            active <= 1'b0;
            seg <= 3'd0;
            bcnt <= 8'd0;
            ocnt <= 10'd0;
            r0_v <= 1'b0;
            r1_v <= 1'b0;
            r2_v <= 1'b0;
            issue_q <= 1'b0;
            fresh <= 1'b0;
        end else begin
            issue_q <= issue;
            fresh <= !go && !seg_done && !(issue && bcnt[4:0] == 5'd31);
            if (go) begin
                active <= 1'b1;
                seg <= 3'd0;
                bcnt <= 8'd0;
                ocnt <= 10'd0;
                r0_v <= 1'b0;
                r1_v <= 1'b0;
                r2_v <= 1'b0;
            end else if (active) begin
                if (issue)
                    bcnt <= bcnt + 8'd1;
                if (adv) begin
                    r0_v <= issue;
                    r1_v <= r0_v;
                    r2_v <= r1_v;
                end
                if (seg_done) begin
                    seg <= seg_nx;
                    bcnt <= 8'd0;
                end
                if (fire)
                    ocnt <= ocnt + 10'd1;
                // Done once every word has been emitted and has left the slice.
                if (ocnt == tot_words && !sl_valid && !fire)
                    active <= 1'b0;
            end
        end
    end

endmodule
