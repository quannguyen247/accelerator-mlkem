`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// Input stream engine. Decodes the request packet segment by segment into the
// S, T and C stores and the rho/h/z registers, taps the hashed bytes into the
// FIFO, and checks the Encaps modulus condition.
//   Encaps: ek = t^ (12-bit, checked) || rho
//   Decaps: dk = s^ || t^ || rho || h || z, then c = c1 (du) || c2 (dv)
// A register slice isolates the port; it accepts exactly the request's words
// (the I/O buffer supplies them in order, so there is no framing to check).
module mlkem_in (
    input wire clk,
    input wire rst_n,

    // Request control
    input wire kill,
    input wire go,
    input wire scrub,
    input wire [1:0] op,
    input wire [2:0] k,
    output wire busy,

    // Request words
    input wire [63:0] s_tdata,
    input wire s_tvalid,
    output wire s_tready,

    // Hashed bytes to the tap FIFO
    output wire fifo_push,
    output wire [63:0] fifo_din,
    input wire fifo_full,

    // Decoded blocks to the stores: one write strobe per slot of the S, T
    // and C stores, the block index and whether it is block 0
    output reg [3:0] st_we_s,
    output reg [3:0] st_we_t,
    output reg [4:0] st_we_c,
    output reg [4:0] st_blk,
    output reg st_first,
    output reg [95:0] st_data,

    // Decoded byte strings
    output reg [255:0] rho,
    output reg rho_v,
    output reg [255:0] h,
    output reg h_v,
    output reg [255:0] z,
    output reg z_v,

    // Encaps modulus check failed
    output reg err
);

    `include "mlkem_funcs.vh"

    localparam [1:0] SK_VAL = 2'd0, SK_REG = 2'd1, SK_END = 2'd2;

    wire [3:0] du = mlkem_du(k);
    wire [3:0] dv = mlkem_dv(k);

    // Port and framing
    reg on;
    reg [9:0] acc_left;
    wire [9:0] tot_words = (op == `MLKEM_OP_ENCAPS) ? {k, 4'd0} * 2'd3 + 10'd4 :
                           {k, 5'd0} * 2'd3 + 10'd12 + {4'd0, du, 2'd0} * k + {4'd0, dv, 2'd0};
    wire q_valid;
    wire [63:0] q_data;
    wire q_pop;

    mlkem_axis_slice #(.W(64)) u_slice (
        .clk(clk),
        .rst_n(rst_n),
        .clr(go || kill),
        .s_allow(on && (acc_left != 10'd0)),
        .s_valid(s_tvalid),
        .s_data(s_tdata),
        .s_ready(s_tready),
        .m_valid(q_valid),
        .m_data(q_data),
        .m_ready(q_pop)
    );
    wire s_acc = s_tvalid && s_tready;

    // Segments
    // {sk, sd, sdest, snsl, sslot0, sreg, stap, schk}
    function [17:0] seg_of;
        input [1:0] f_op;
        input [2:0] f_seg;
        input [2:0] f_k;
        reg [1:0] t_sk, t_dest, t_reg;
        reg [3:0] t_d;
        reg [2:0] t_nsl, t_s0;
        reg t_tap, t_chk;
        begin
            t_sk = SK_END; t_d = 4'd8; t_dest = 2'd0; t_nsl = f_k; t_s0 = 3'd0;
            t_reg = 2'd0; t_tap = 1'b0; t_chk = 1'b0;
            if (f_op == `MLKEM_OP_ENCAPS) begin
                case (f_seg)
                    3'd0: begin t_sk = SK_VAL; t_d = 4'd12; t_dest = 2'd1; t_tap = 1'b1; t_chk = 1'b1; end
                    3'd1: begin t_sk = SK_REG; t_reg = 2'd0; t_tap = 1'b1; end
                    default: t_sk = SK_END;
                endcase
            end else if (f_op == `MLKEM_OP_DECAPS) begin
                case (f_seg)
                    3'd0: begin t_sk = SK_VAL; t_d = 4'd12; t_dest = 2'd0; end
                    3'd1: begin t_sk = SK_VAL; t_d = 4'd12; t_dest = 2'd1; t_tap = 1'b1; end
                    3'd2: begin t_sk = SK_REG; t_reg = 2'd0; t_tap = 1'b1; end
                    3'd3: begin t_sk = SK_REG; t_reg = 2'd1; end
                    3'd4: begin t_sk = SK_REG; t_reg = 2'd2; end
                    3'd5: begin t_sk = SK_VAL; t_d = mlkem_du(f_k); t_dest = 2'd2; t_tap = 1'b1; end
                    3'd6: begin t_sk = SK_VAL; t_d = mlkem_dv(f_k); t_dest = 2'd2; t_nsl = 3'd1; t_s0 = 3'd4; t_tap = 1'b1; end
                    default: t_sk = SK_END;
                endcase
            end
            seg_of = {t_sk, t_d, t_dest, t_nsl, t_s0, t_reg, t_tap, t_chk};
        end
    endfunction

    reg active;
    reg [2:0] seg;
    reg [7:0] bcnt;
    reg [8:0] seg_left;     // words of the segment not yet consumed
    reg [7:0] blk_left;     // blocks of the segment not yet emitted
    reg seg_more_reg;       // seg_left != 0, kept as a flag for the handshakes
    reg blk_more_reg;       // blk_left != 0
    reg [1:0] sk;
    reg [3:0] sd;
    reg [1:0] sdest;
    reg [2:0] sslot0;
    reg [1:0] sreg;         // 0: rho, 1: h, 2: z
    reg stap;
    reg schk;

    wire seg_done = active && (sk != SK_END) && !seg_more_reg && !blk_more_reg;
    wire [2:0] seg_nx = go ? 3'd0 : seg_done ? seg + 3'd1 : seg;
    wire [17:0] seg_d = seg_of(op, seg_nx, k);
    // Words: VAL = 4*d per slot, REG = 4. Blocks: VAL = 32 per slot, REG = 4.
    wire [8:0] nx_words = (seg_d[17:16] == SK_REG) ? 9'd4 :
                          (seg_d[17:16] == SK_END) ? 9'd0 : {3'd0, seg_d[15:12], 2'd0} * seg_d[9:7];
    wire [7:0] nx_blocks = (seg_d[17:16] == SK_REG) ? 8'd4 :
                           (seg_d[17:16] == SK_END) ? 8'd0 : {seg_d[9:7], 5'd0};

    wire up_ready;
    wire up_valid;
    wire [95:0] up_raw;
    wire [95:0] up_vals;
    wire want = active && seg_more_reg && (!stap || !fifo_full);
    assign q_pop = want && up_ready;
    wire pop = q_valid && q_pop;

    mlkem_unpack u_unpack (
        .clk(clk),
        .rst_n(rst_n),
        .clr(go || kill),
        .db(sd),
        .in_valid(q_valid && want),
        .in_data(q_data),
        .in_ready(up_ready),
        .out_en(active && blk_more_reg),
        .out_valid(up_valid),
        .out_raw(up_raw),
        .out_vals(up_vals)
    );

    assign fifo_push = pop && stap;
    assign fifo_din = q_data;

    // Stage B: decoded block registered, then reduced/checked and written.
    reg bv;
    reg key_bad;                    // Encaps ek check failed (registered, reported next cycle)
    reg b_reg_seg;
    reg b_d12;
    reg b_chk;
    reg [1:0] b_dest;
    reg [2:0] b_slot;
    reg [4:0] b_blk;
    reg [1:0] b_sreg;
    reg [95:0] b_vals;
    assign busy = active || bv;

    integer i;
    reg [95:0] red;
    reg bad;
    always @(*) begin
        red = b_vals;
        bad = 1'b0;
        if (b_d12) begin
            for (i = 0; i < 8; i = i + 1) begin
                if (b_vals[12*i +: 12] >= 12'd3329) begin
                    red[12*i +: 12] = b_vals[12*i +: 12] - 12'd3329;
                    bad = 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        {sk, sd, sdest, sslot0, sreg, stap, schk} <=
            {seg_d[17:16], seg_d[15:12], seg_d[11:10], seg_d[6:4], seg_d[3:2], seg_d[1], seg_d[0]};
    end

    always @(posedge clk) begin
        if (!rst_n || kill) begin
            on <= 1'b0;
            acc_left <= 10'd0;
            active <= 1'b0;
            seg <= 3'd0;
            bcnt <= 8'd0;
            seg_left <= 9'd0;
            blk_left <= 8'd0;
            seg_more_reg <= 1'b0;
            blk_more_reg <= 1'b0;
            st_we_s <= 4'd0;
            st_we_t <= 4'd0;
            st_we_c <= 5'd0;
            key_bad <= 1'b0;
            rho_v <= 1'b0;
            h_v <= 1'b0;
            z_v <= 1'b0;
            err <= 1'b0;
            bv <= 1'b0;
        end else begin
            st_we_s <= 4'd0;
            st_we_t <= 4'd0;
            st_we_c <= 5'd0;
            err <= 1'b0;
            bv <= 1'b0;
            key_bad <= 1'b0;
            if (key_bad) begin
                err <= 1'b1;
                on <= 1'b0;
            end

            // Port side: words still to accept
            if (s_acc)
                acc_left <= acc_left - 10'd1;

            if (active && up_valid) begin
                bv <= 1'b1;
                b_reg_seg <= (sk == SK_REG);
                b_d12 <= (sd == 4'd12);
                b_chk <= schk;
                b_dest <= sdest;
                b_slot <= sslot0 + {1'b0, bcnt[6:5]};
                b_blk <= bcnt[4:0];
                b_sreg <= sreg;
                b_vals <= up_vals;          // byte strings (d = 8) pass raw
            end
            if (bv) begin
                if (!b_reg_seg) begin
                    for (i = 0; i < 5; i = i + 1) begin
                        if (b_slot == i) begin
                            if (i < 4) begin
                                st_we_s[i] <= (b_dest == 2'd0);
                                st_we_t[i] <= (b_dest == 2'd1);
                            end
                            st_we_c[i] <= (b_dest == 2'd2);
                        end
                    end
                    st_blk <= b_blk;
                    st_first <= (b_blk == 5'd0);
                    st_data <= red;
                    key_bad <= b_chk && bad;
                end else begin
                    case (b_sreg)
                        2'd0: rho[b_blk[1:0]*64 +: 64] <= b_vals[63:0];
                        2'd1: h[b_blk[1:0]*64 +: 64] <= b_vals[63:0];
                        default: z[b_blk[1:0]*64 +: 64] <= b_vals[63:0];
                    endcase
                    if (b_blk[1:0] == 2'd3) begin
                        case (b_sreg)
                            2'd0: rho_v <= 1'b1;
                            2'd1: h_v <= 1'b1;
                            default: z_v <= 1'b1;
                        endcase
                    end
                end
            end

            if (scrub) begin
                z <= 256'd0;
                z_v <= 1'b0;
            end

            if (go) begin
                on <= (op != `MLKEM_OP_KEYGEN);
                acc_left <= (op != `MLKEM_OP_KEYGEN) ? tot_words : 10'd0;
                active <= (op != `MLKEM_OP_KEYGEN);
                seg <= 3'd0;
                bcnt <= 8'd0;
                seg_left <= nx_words;
                blk_left <= nx_blocks;
                seg_more_reg <= (nx_words != 9'd0);
                blk_more_reg <= (nx_blocks != 8'd0);
                rho_v <= 1'b0;
                h_v <= 1'b0;
                z_v <= 1'b0;
            end else if (active) begin
                if (sk == SK_END) begin
                    active <= 1'b0;
                    on <= 1'b0;
                end else begin
                    if (pop) begin
                        seg_left <= seg_left - 9'd1;
                        seg_more_reg <= (seg_left != 9'd1);
                    end
                    if (up_valid) begin
                        bcnt <= bcnt + 8'd1;
                        blk_left <= blk_left - 8'd1;
                        blk_more_reg <= (blk_left != 8'd1);
                    end
                    if (seg_done) begin
                        seg <= seg_nx;
                        bcnt <= 8'd0;
                        seg_left <= nx_words;
                        blk_left <= nx_blocks;
                        seg_more_reg <= (nx_words != 9'd0);
                        blk_more_reg <= (nx_blocks != 8'd0);
                    end
                end
            end
        end
    end

endmodule
