`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// ML-KEM IP top for SoC integration (SPEC section 4): AXI4-Lite register slave,
// AXI4-Stream request/result packets for the DMA, and a level interrupt.
//
//   0x000 CONTROL   WO  exactly one of bit0 START, bit1 ABORT, bit2 ACK
//   0x004 STATUS    RO  bit0 READY, bit1 BUSY, bit2 DONE, bit3 ERROR
//   0x008 ERRCODE   RO
//   0x00C CONFIG    RW  [1:0] operation, [3:2] parameter set (while READY)
//   0x010 IN0_LEN   RW  0x014 IN1_LEN, 0x018 OUT0_CAP, 0x01C OUT1_CAP (while READY)
//   0x020-0x03C     reserved, SLVERR
//   0x040-0x07C SEED WO  d||z (KeyGen) or m (Encaps), while READY
//
// Only aligned 32-bit accesses with all strobes are supported;
// anything else, a register in the wrong direction, an unmapped offset or a
// command illegal in the current state returns SLVERR without side effects.
module mlkem_axi #(
    parameter ADDR_W = 12
)(
    input wire aclk,
    input wire aresetn,

    input wire [ADDR_W-1:0] s_axi_awaddr,
    input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output wire s_axi_wready,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [ADDR_W-1:0] s_axi_araddr,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid,
    input wire s_axi_rready,

    input wire [63:0] s_axis_tdata,
    input wire [7:0] s_axis_tkeep,
    input wire s_axis_tlast,
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    output wire [63:0] m_axis_tdata,
    output wire [7:0] m_axis_tkeep,
    output wire m_axis_tlast,
    output wire m_axis_tvalid,
    input wire m_axis_tready,

    output wire irq
);

    `include "mlkem_funcs.vh"

    localparam [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;

    // State
    reg [3:0] config_r;
    reg [31:0] in0_len, in1_len, out0_cap, out1_cap;
    reg [511:0] seed;
    reg [15:0] seed_cov;
    reg busy_r, done_r, error_r;
    reg aborted;
    reg [2:0] code_r;

    reg core_start;
    reg core_abort;
    wire core_ready, core_done, core_error;
    wire [2:0] core_code;

    wire ready = core_ready && !busy_r && !done_r && !error_r;
    assign irq = done_r || error_r;

    // Expected request/result sizes for the programmed configuration
    wire [2:0] k = mlkem_k(config_r[3:2]);
    wire [31:0] ek_len = 32'd384 * k + 32'd32;
    wire [31:0] dk_len = 32'd768 * k + 32'd96;
    wire [31:0] c_len = 32'd32 * ({28'd0, mlkem_du(k)} * k + {28'd0, mlkem_dv(k)});
    reg len_ok;
    reg seed_ok;
    always @(*) begin
        case (config_r[1:0])
            `MLKEM_OP_KEYGEN: begin
                len_ok = (in0_len == 0) && (in1_len == 0) && (out0_cap >= ek_len) && (out1_cap >= dk_len);
                seed_ok = &seed_cov;
            end
            `MLKEM_OP_ENCAPS: begin
                len_ok = (in0_len == ek_len) && (in1_len == 0) && (out0_cap >= c_len) && (out1_cap >= 32);
                seed_ok = &seed_cov[7:0];
            end
            default: begin
                len_ok = (in0_len == dk_len) && (in1_len == c_len) && (out0_cap >= 32) && (out1_cap == 0);
                seed_ok = 1'b1;
            end
        endcase
    end
    wire cfg_ok = (config_r[1:0] != 2'd3) && (config_r[3:2] != 2'd3);

    // Write path
    reg w_addr_ok;
    reg w_data;
    reg [ADDR_W-1:0] w_addr;

    assign s_axi_awready = !w_addr_ok && !s_axi_bvalid;
    assign s_axi_wready = w_addr_ok && !s_axi_bvalid;
    wire w_fire = s_axi_wvalid && s_axi_wready;

    wire w_legal = (w_addr[1:0] == 2'b00) && (s_axi_wstrb == 4'hF);
    wire is_seed_w = (w_addr[ADDR_W-1:6] == (12'h040 >> 6));
    wire [3:0] seed_w = w_addr[5:2];

    // Register write legality and effect (evaluated on the data transfer).
    reg w_ok;
    always @(*) begin
        w_ok = 1'b0;
        if (w_legal) begin
            if (is_seed_w) begin
                w_ok = ready;
            end else begin
                case (w_addr)
                    12'h000: w_ok = ((s_axi_wdata == 32'h1) && ready) ||
                                    ((s_axi_wdata == 32'h2) && busy_r) ||
                                    ((s_axi_wdata == 32'h4) && (done_r || error_r));
                    12'h00C: w_ok = ready && (s_axi_wdata[31:4] == 28'd0);
                    12'h010, 12'h014, 12'h018, 12'h01C: w_ok = ready;
                    default: w_ok = 1'b0;
                endcase
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            w_addr_ok <= 1'b0;
            s_axi_bvalid <= 1'b0;
            s_axi_bresp <= RESP_OKAY;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                w_addr_ok <= 1'b1;
                w_addr <= s_axi_awaddr;
            end
            if (w_fire) begin
                w_addr_ok <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp <= w_ok ? RESP_OKAY : RESP_SLVERR;
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // Read path
    reg r_busy;
    reg [ADDR_W-1:0] r_addr;
    assign s_axi_arready = !r_busy;

    reg [31:0] r_val;
    reg r_ok;
    always @(*) begin
        r_val = 32'd0;
        r_ok = (r_addr[1:0] == 2'b00);
        case (r_addr)
            12'h004: r_val = {28'd0, error_r, done_r, busy_r, ready};
            12'h00C: r_val = {28'd0, config_r};
            12'h010: r_val = in0_len;
            12'h014: r_val = in1_len;
            12'h018: r_val = out0_cap;
            12'h01C: r_val = out1_cap;
            12'h008: r_val = {29'd0, code_r};
            default: r_ok = 1'b0;
        endcase
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            r_busy <= 1'b0;
            s_axi_rvalid <= 1'b0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                r_busy <= 1'b1;
                r_addr <= s_axi_araddr;
            end else if (r_busy && !s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rdata <= r_ok ? r_val : 32'd0;
                s_axi_rresp <= r_ok ? RESP_OKAY : RESP_SLVERR;
            end else if (s_axi_rvalid && s_axi_rready) begin
                r_busy <= 1'b0;
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // Registers and core
    wire wr_now = w_fire && w_ok;
    always @(posedge aclk) begin
        if (!aresetn) begin
            config_r <= 4'd0;
            in0_len <= 32'd0;
            in1_len <= 32'd0;
            out0_cap <= 32'd0;
            out1_cap <= 32'd0;
            seed <= 512'd0;
            seed_cov <= 16'd0;
            busy_r <= 1'b0;
            aborted <= 1'b0;
            done_r <= 1'b0;
            error_r <= 1'b0;
            code_r <= `MLKEM_ERR_NONE;
            core_start <= 1'b0;
            core_abort <= 1'b0;
        end else begin
            core_start <= 1'b0;
            core_abort <= 1'b0;
            // The core latches the seed with START; drop the copy afterwards.
            if (core_start) begin
                seed <= 512'd0;
                seed_cov <= 16'd0;
            end
            if (core_done || core_error) begin
                busy_r <= 1'b0;
                aborted <= 1'b0;
                done_r <= core_done && !aborted;
                error_r <= core_error || aborted;
                code_r <= aborted ? `MLKEM_ERR_ABORT : core_error ? core_code : `MLKEM_ERR_NONE;
            end
            if (wr_now) begin
                if (is_seed_w) begin
                    seed[seed_w*32 +: 32] <= s_axi_wdata;
                    seed_cov[seed_w] <= 1'b1;
                end else begin
                    case (w_addr)
                        12'h000: begin
                            if (s_axi_wdata[0]) begin
                                if (!cfg_ok) begin
                                    error_r <= 1'b1;
                                    code_r <= `MLKEM_ERR_CONFIG;
                                end else if (!len_ok) begin
                                    error_r <= 1'b1;
                                    code_r <= `MLKEM_ERR_FRAME;
                                end else if (!seed_ok) begin
                                    error_r <= 1'b1;
                                    code_r <= 3'd4;
                                end else begin
                                    busy_r <= 1'b1;
                                    core_start <= 1'b1;
                                end
                                if (!cfg_ok || !len_ok || !seed_ok) begin
                                    seed <= 512'd0;
                                    seed_cov <= 16'd0;
                                end
                            end
                            if (s_axi_wdata[1]) begin
                                core_abort <= 1'b1;
                                aborted <= 1'b1;
                            end
                            if (s_axi_wdata[2]) begin
                                done_r <= 1'b0;
                                error_r <= 1'b0;
                                code_r <= `MLKEM_ERR_NONE;
                            end
                        end
                        12'h00C: config_r <= s_axi_wdata[3:0];
                        12'h010: in0_len <= s_axi_wdata;
                        12'h014: in1_len <= s_axi_wdata;
                        12'h018: out0_cap <= s_axi_wdata;
                        12'h01C: out1_cap <= s_axi_wdata;
                        default: ;
                    endcase
                end
            end
        end
    end

    mlkem_core u_core (
        .clk(aclk),
        .rst_n(aresetn),
        .start(core_start),
        .op(config_r[1:0]),
        .pset(config_r[3:2]),
        .seed(seed),
        .abort(core_abort),
        .ready(core_ready),
        .done(core_done),
        .error(core_error),
        .err_code(core_code),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready)
    );

endmodule
