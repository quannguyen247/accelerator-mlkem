`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// ML-KEM IP top, stream variant: an AXI4-Lite register slave, an AXI4-Stream
// request input, an AXI4-Stream result output and a level interrupt (for an
// AXI DMA; no request/result buffer, unlike mlkem_axi).
//
// AXI4-Lite (s_axil), 32-bit data, 4 KB aperture (as mlkem_axi):
//   0x000 CONTROL     WO  exactly one of bit0 START, bit1 ABORT, bit2 ACK
//   0x004 STATUS      RO  bit0 READY, bit1 BUSY, bit2 DONE, bit3 ERROR
//   0x008 ERRCODE     RO
//   0x00C CONFIG      RW  [1:0] operation, [3:2] parameter set (while READY)
//   0x010 IRQ_ENABLE  RW  bit0: irq follows DONE / ERROR
//   0x014 VERSION     RO
//   0x040-0x07C SEED  WO  d||z (KeyGen) or m (Encaps), while READY
// Only aligned 32-bit accesses with all strobes are supported; anything else,
// a register in the wrong direction, an unmapped offset or a command illegal
// in the current state returns SLVERR without side effects.
//
// s_axis (64-bit): the request words (Encaps ek, Decaps dk || c, nothing for
// KeyGen), accepted while BUSY. m_axis (64-bit): the result words (KeyGen
// ek || dk, Encaps c || K, Decaps K), TLAST on the last one. ACK after DONE
// returns to READY; a failed request reports ERROR.
module mlkem_axis_top (
    input wire aclk,
    input wire aresetn,

    // AXI4-Lite register slave
    input wire [11:0] s_axil_awaddr,
    input wire s_axil_awvalid,
    output wire s_axil_awready,
    input wire [31:0] s_axil_wdata,
    input wire [3:0] s_axil_wstrb,
    input wire s_axil_wvalid,
    output wire s_axil_wready,
    output reg [1:0] s_axil_bresp,
    output reg s_axil_bvalid,
    input wire s_axil_bready,
    input wire [11:0] s_axil_araddr,
    input wire s_axil_arvalid,
    output wire s_axil_arready,
    output reg [31:0] s_axil_rdata,
    output reg [1:0] s_axil_rresp,
    output reg s_axil_rvalid,
    input wire s_axil_rready,

    // AXI4-Stream request (into the core) and result (out of the core)
    input wire [63:0] s_axis_tdata,
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    output wire [63:0] m_axis_tdata,
    output wire m_axis_tvalid,
    input wire m_axis_tready,
    output wire m_axis_tlast,

    output wire irq
);

    localparam [31:0] VERSION = 32'h0002_0000;      // 2.0: memory-mapped buffer
    localparam [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;

    // State
    reg [3:0] config_r;
    reg irq_en;
    reg [15:0] seed_cov;            // seed words written since the last START
    reg busy_r, done_r, error_r;
    reg aborted;
    reg [2:0] code_r;
    reg err_pend;                   // failed: ERROR rises once the buffer is wiped
    reg [2:0] code_pend;
    reg wipe_q;
    wire wiping = 1'b0;             // no buffer to wipe

    reg core_start;
    reg core_abort;
    wire core_ready, core_done, core_error;
    wire [2:0] core_code;

    // READY and the START checks below are registered. Two register writes
    // are at least three cycles apart (AW, W, B), so a write always sees the
    // values left by the previous one.
    reg ready;
    always @(posedge aclk) begin
        if (!aresetn)
            ready <= 1'b0;
        else
            ready <= core_ready && !busy_r && !done_r && !error_r && !err_pend && !wiping && !wipe_q;
    end
    assign irq = irq_en && (done_r || error_r);

    reg seed_ok;
    reg cfg_ok;
    always @(posedge aclk) begin
        case (config_r[1:0])
            `MLKEM_OP_KEYGEN: seed_ok <= &seed_cov;
            `MLKEM_OP_ENCAPS: seed_ok <= &seed_cov[7:0];
            default: seed_ok <= 1'b1;
        endcase
        cfg_ok <= (config_r[1:0] != 2'd3) && (config_r[3:2] != 2'd3);
    end

    // Write path. The address is decoded when it is accepted, so the data
    // transfer only combines registered selects with the write data.
    reg w_addr_ok;
    reg w_aligned_reg;              // 32-bit aligned address
    reg w_ctrl_reg;                 // 0x000 CONTROL
    reg w_cfg_reg;                  // 0x00C CONFIG
    reg w_ie_reg;                   // 0x010 IRQ_ENABLE
    reg [15:0] w_seed_reg;          // 0x040 + 4 * i SEED word i

    assign s_axil_awready = !w_addr_ok && !s_axil_bvalid;
    // An address is accepted only while no response is pending, so the data
    // can be taken as soon as the address is held.
    assign s_axil_wready = w_addr_ok;
    wire w_fire = s_axil_wvalid && s_axil_wready;

    wire w_legal = w_aligned_reg && (s_axil_wstrb == 4'hF);

    // Register write legality (evaluated on the data transfer)
    reg w_ok;
    always @(*) begin
        w_ok = 1'b0;
        if (w_legal) begin
            if (w_seed_reg != 16'd0)
                w_ok = ready;
            else if (w_ctrl_reg)
                w_ok = ((s_axil_wdata == 32'h1) && ready) ||
                       ((s_axil_wdata == 32'h2) && (busy_r || err_pend)) ||
                       ((s_axil_wdata == 32'h4) && (done_r || error_r));
            else if (w_cfg_reg)
                w_ok = ready && (s_axil_wdata[31:4] == 28'd0);
            else if (w_ie_reg)
                w_ok = (s_axil_wdata[31:1] == 31'd0);
        end
    end

    integer wi;
    always @(posedge aclk) begin
        if (!aresetn) begin
            w_addr_ok <= 1'b0;
            s_axil_bvalid <= 1'b0;
            s_axil_bresp <= RESP_OKAY;
        end else begin
            if (s_axil_awvalid && s_axil_awready) begin
                w_addr_ok <= 1'b1;
                w_aligned_reg <= (s_axil_awaddr[1:0] == 2'b00);
                w_ctrl_reg <= (s_axil_awaddr == 12'h000);
                w_cfg_reg <= (s_axil_awaddr == 12'h00C);
                w_ie_reg <= (s_axil_awaddr == 12'h010);
                for (wi = 0; wi < 16; wi = wi + 1)
                    w_seed_reg[wi] <= (s_axil_awaddr[11:6] == 6'h01) && (s_axil_awaddr[5:2] == wi);
            end
            if (w_fire) begin
                w_addr_ok <= 1'b0;
                s_axil_bvalid <= 1'b1;
                s_axil_bresp <= w_ok ? RESP_OKAY : RESP_SLVERR;
            end
            if (s_axil_bvalid && s_axil_bready)
                s_axil_bvalid <= 1'b0;
        end
    end

    // Read path
    reg r_busy;
    reg [11:0] r_addr;
    assign s_axil_arready = !r_busy;

    reg [31:0] r_val;
    reg r_ok;
    always @(*) begin
        r_val = 32'd0;
        r_ok = 1'b1;
        case (r_addr)
            12'h004: r_val = {28'd0, error_r, done_r, busy_r || err_pend, ready};
            12'h008: r_val = {29'd0, code_r};
            12'h00C: r_val = {28'd0, config_r};
            12'h010: r_val = {31'd0, irq_en};
            12'h014: r_val = VERSION;
            default: r_ok = 1'b0;
        endcase
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            r_busy <= 1'b0;
            s_axil_rvalid <= 1'b0;
        end else begin
            if (s_axil_arvalid && s_axil_arready) begin
                r_busy <= 1'b1;
                r_addr <= s_axil_araddr;
            end else if (r_busy && !s_axil_rvalid) begin
                s_axil_rvalid <= 1'b1;
                s_axil_rdata <= r_ok ? r_val : 32'd0;
                s_axil_rresp <= r_ok ? RESP_OKAY : RESP_SLVERR;
            end else if (s_axil_rvalid && s_axil_rready) begin
                r_busy <= 1'b0;
                s_axil_rvalid <= 1'b0;
            end
        end
    end

    // Registers and core
    // An accepted write takes effect one cycle after its data transfer: the
    // transfer registers the data and one strobe per target, so the seed
    // words of the core see flip-flops on their enables. The next write is at
    // least three cycles later (B, AW, W), and a read issued after the B
    // response sees the new value.
    wire wr_now = w_fire && w_ok;
    reg [31:0] wr_data;
    reg wr_ctrl, wr_cfg, wr_ie;
    reg [15:0] wr_seed;
    always @(posedge aclk) begin
        if (!aresetn) begin
            wr_ctrl <= 1'b0;
            wr_cfg <= 1'b0;
            wr_ie <= 1'b0;
            wr_seed <= 16'd0;
        end else begin
            wr_ctrl <= wr_now && w_ctrl_reg;
            wr_cfg <= wr_now && w_cfg_reg;
            wr_ie <= wr_now && w_ie_reg;
            wr_seed <= wr_now ? w_seed_reg : 16'd0;
        end
        wr_data <= s_axil_wdata;
    end

    // START checks of the CONTROL write (the check registers are settled:
    // the last register write was at least three cycles earlier)
    wire start_wr = wr_ctrl && wr_data[0];
    wire start_ok = cfg_ok && seed_ok;

    // The seed words live in the core. Coverage restarts with every START;
    // a refused START also clears the seed (the core clears it at the end of
    // an accepted request).
    reg seed_drop;
    always @(posedge aclk) begin
        if (!aresetn)
            seed_drop <= 1'b0;
        else
            seed_drop <= start_wr && !start_ok;
    end

    integer si;
    always @(posedge aclk) begin
        if (!aresetn || core_start || seed_drop) begin
            seed_cov <= 16'd0;
        end else begin
            for (si = 0; si < 16; si = si + 1)
                if (wr_seed[si])
                    seed_cov[si] <= 1'b1;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            config_r <= 4'd0;
            irq_en <= 1'b0;
        end else begin
            if (wr_cfg)
                config_r <= wr_data[3:0];
            if (wr_ie)
                irq_en <= wr_data[0];
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            busy_r <= 1'b0;
            aborted <= 1'b0;
            done_r <= 1'b0;
            error_r <= 1'b0;
            code_r <= `MLKEM_ERR_NONE;
            err_pend <= 1'b0;
            code_pend <= `MLKEM_ERR_NONE;
            wipe_q <= 1'b0;
            core_start <= 1'b0;
            core_abort <= 1'b0;
        end else begin
            core_start <= 1'b0;
            core_abort <= 1'b0;
            wipe_q <= 1'b0;
            // A result stays in the buffer until ACK; a failure (or an ABORT,
            // also one that meets the completion) wipes it before ERROR.
            if (core_done || core_error) begin
                busy_r <= 1'b0;
                aborted <= 1'b0;
                if (core_done && !aborted) begin
                    done_r <= 1'b1;
                end else begin
                    err_pend <= 1'b1;
                    wipe_q <= 1'b1;
                    code_pend <= aborted ? `MLKEM_ERR_ABORT : core_code;
                end
            end
            if (err_pend && !wipe_q && !wiping) begin
                err_pend <= 1'b0;
                error_r <= 1'b1;
                code_r <= code_pend;
            end
            if (start_wr) begin
                if (!cfg_ok) begin
                    error_r <= 1'b1;
                    code_r <= `MLKEM_ERR_CONFIG;
                end else if (!seed_ok) begin
                    error_r <= 1'b1;
                    code_r <= `MLKEM_ERR_SEED;
                end else begin
                    busy_r <= 1'b1;
                    core_start <= 1'b1;
                end
            end
            // An ABORT that meets the completion of the request is dropped:
            // the request reports its own result.
            if (wr_ctrl && wr_data[1] && busy_r && !(core_done || core_error)) begin
                core_abort <= 1'b1;
                aborted <= 1'b1;
            end
            if (wr_ctrl && wr_data[2]) begin
                if (done_r)
                    wipe_q <= 1'b1;
                done_r <= 1'b0;
                error_r <= 1'b0;
                code_r <= `MLKEM_ERR_NONE;
            end
        end
    end

    wire [63:0] in_data, out_data;
    wire in_valid, in_ready, out_valid, out_ready;

    mlkem_core u_core (
        .clk(aclk),
        .rst_n(aresetn),
        .start(core_start),
        .op(config_r[1:0]),
        .pset(config_r[3:2]),
        .seed_we(wr_seed),
        .seed_wdata(wr_data),
        .seed_clr(seed_drop),
        .abort(core_abort),
        .ready(core_ready),
        .done(core_done),
        .error(core_error),
        .err_code(core_code),
        .in_data(in_data),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .out_data(out_data),
        .out_valid(out_valid),
        .out_ready(out_ready)
    );

    // Streams straight to the core while a request runs
    assign in_data = s_axis_tdata;
    assign in_valid = s_axis_tvalid && busy_r;
    assign s_axis_tready = in_ready && busy_r;
    assign m_axis_tdata = out_data;
    assign m_axis_tvalid = out_valid;
    assign out_ready = m_axis_tready;

    // TLAST on the last result word: KeyGen ek || dk (144k + 16 words),
    // Encaps c || K (4 (du k + dv) + 4), Decaps K (4)
    reg [9:0] out_tot, out_cnt;
    wire [2:0] kk = {1'b0, config_r[3:2]} + 3'd2;
    wire [3:0] du = (kk == 3'd4) ? 4'd11 : 4'd10;
    wire [3:0] dv = (kk == 3'd4) ? 4'd5 : 4'd4;
    always @(posedge aclk) begin
        out_tot <= (config_r[1:0] == `MLKEM_OP_KEYGEN) ? {kk, 4'd0} * 4'd9 + 10'd16 :
                   (config_r[1:0] == `MLKEM_OP_ENCAPS) ? {4'd0, du, 2'd0} * kk + {4'd0, dv, 2'd0} + 10'd4 :
                   10'd4;
        if (!aresetn || core_start)
            out_cnt <= 10'd0;
        else if (out_valid && out_ready)
            out_cnt <= out_cnt + 10'd1;
    end
    assign m_axis_tlast = (out_cnt == out_tot - 10'd1);

endmodule
