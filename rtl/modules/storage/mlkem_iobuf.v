`timescale 1ns / 1ps

// Request/result buffer of the ML-KEM IP and its AXI4 slave port.
//
// One single-port distributed RAM of DEPTH 64-bit words holds the request
// objects written by the host (Encaps ek, Decaps dk || c) and then the result
// objects (KeyGen ek || dk, Encaps c || K, Decaps K), both from word 0, bytes
// in FIPS 203 order with the lowest-addressed byte in bits [7:0].
// While a request runs (serve) the core owns the RAM: the reader hands the
// request words from word 0 to the core (which takes exactly the words of
// its request), and the writer stores the result words from word 0, with
// priority over the reader. A result word never overwrites an unread request
// word: every result depends on the end of the request (rho closes ek; K
// needs all of dk || c), so the core has taken the whole request before it
// emits its first result word.
//
// AXI4 slave, 64-bit data: INCR, FIXED and WRAP bursts, narrow transfers and
// byte strobes; one burst at a time, a waiting read and write alternate.
// A burst accepted while the buffer is closed (a request runs, or a wipe is
// pending or running) is answered with SLVERR and leaves the RAM untouched
// (read data zero), as is every beat beyond DEPTH words or with AxSIZE > 3.
// A burst accepted while open completes on the RAM before a request or a
// wipe takes it.
//
// RAM port: address, write strobes and write data come from registers; the
// asynchronous read lands in a two-entry queue through clock enables.
module mlkem_iobuf #(
    parameter ID_W = 4,
    parameter ADDR_W = 13,
    parameter DEPTH = 592
)(
    input wire clk,
    input wire rst_n,

    // Ownership
    input wire serve,               // a request owns the RAM (level)
    input wire wipe,                // zero the whole RAM (pulse)
    output reg wiping,              // wipe pending or running (also after reset)

    // Request words to the core, from word 0
    output wire in_valid,
    output wire [63:0] in_data,
    input wire in_ready,
    // Result words from the core, stored from word 0
    input wire out_valid,
    input wire [63:0] out_data,
    output wire out_ready,

    // AXI4 slave
    input wire [ID_W-1:0] s_axi_awid,
    input wire [ADDR_W-1:0] s_axi_awaddr,
    input wire [7:0] s_axi_awlen,
    input wire [2:0] s_axi_awsize,
    input wire [1:0] s_axi_awburst,
    input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [63:0] s_axi_wdata,
    input wire [7:0] s_axi_wstrb,
    input wire s_axi_wlast,
    input wire s_axi_wvalid,
    output wire s_axi_wready,
    output wire [ID_W-1:0] s_axi_bid,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [ID_W-1:0] s_axi_arid,
    input wire [ADDR_W-1:0] s_axi_araddr,
    input wire [7:0] s_axi_arlen,
    input wire [2:0] s_axi_arsize,
    input wire [1:0] s_axi_arburst,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output wire [ID_W-1:0] s_axi_rid,
    output wire [63:0] s_axi_rdata,
    output wire [1:0] s_axi_rresp,
    output wire s_axi_rlast,
    output wire s_axi_rvalid,
    input wire s_axi_rready
);

    localparam WA = ADDR_W - 3;     // word address bits
    localparam [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;
    localparam [1:0] BURST_FIXED = 2'b00, BURST_WRAP = 2'b10;

    // Byte address of the beat after a, per AXI4 burst rules
    function [ADDR_W-1:0] next_addr;
        input [ADDR_W-1:0] a;
        input [2:0] size;
        input [1:0] burst;
        input [6:0] wmask;
        reg [ADDR_W-1:0] step, inc, wm;
        begin
            step = {{(ADDR_W-1){1'b0}}, 1'b1} << size;
            inc = (a & ~(step - 1'b1)) + step;
            wm = {{(ADDR_W-7){1'b0}}, wmask};
            case (burst)
                BURST_FIXED: next_addr = a;
                BURST_WRAP: next_addr = (a & ~wm) | (inc & wm);
                default: next_addr = inc;
            endcase
        end
    endfunction

    // RAM and its registered port
    reg [WA-1:0] a_q;
    reg [7:0] we_q;
    reg [63:0] wd_q;
    wire [63:0] rd;

    mlkem_buf_ram #(.DEPTH(DEPTH), .AW(WA)) u_ram (
        .clk(clk),
        .we(we_q),
        .addr(a_q),
        .wdata(wd_q),
        .rdata(rd)
    );

    // Burst state: one burst (read or write) at a time
    reg wb_act;                     // write burst: data beats outstanding
    reg rb_act;                     // read burst: until its last beat has left
    reg r_iss;                      // read burst: beats left to issue
    reg [ID_W-1:0] x_id;
    reg [ADDR_W-1:0] x_addr;        // byte address of the current beat
    reg [2:0] x_size;
    reg [1:0] x_burst;
    reg [6:0] x_wmask;              // WRAP: offset bits inside the wrap window
    reg [7:0] x_left;               // read: beats to issue after the current one
    reg x_legal;                    // accepted while open, AxSIZE <= 3
    reg x_inr;                      // current beat lies inside the RAM
    reg b_err;                      // a refused beat in the write burst
    reg prio_w;                     // a write wins over a waiting read

    wire open = !serve && !wiping && !wipe;
    wire idle = !wb_act && !s_axi_bvalid && !rb_act;
    wire ax_legal = (wb_act || rb_act) && x_legal;     // the burst owns the RAM

    assign s_axi_awready = idle && (prio_w || !s_axi_arvalid);
    assign s_axi_arready = idle && (!prio_w || !s_axi_awvalid);
    wire aw_take = s_axi_awvalid && s_axi_awready;
    wire ar_take = s_axi_arvalid && s_axi_arready;

    wire [ADDR_W-1:0] t_addr = aw_take ? s_axi_awaddr : s_axi_araddr;
    wire [7:0] t_len = aw_take ? s_axi_awlen : s_axi_arlen;
    wire [2:0] t_size = aw_take ? s_axi_awsize : s_axi_arsize;
    wire [7:0] t_span = ({4'd0, t_len[3:0]} + 8'd1) << t_size;

    wire w_fire = s_axi_wvalid && wb_act;
    wire beat_ok = x_legal && x_inr;
    wire rq_can, rq_idle;
    wire r_go = r_iss && rq_can;            // one read beat issued
    wire [ADDR_W-1:0] x_nxt = next_addr(x_addr, x_size, x_burst, x_wmask);

    always @(posedge clk) begin
        if (aw_take || ar_take) begin
            x_id <= aw_take ? s_axi_awid : s_axi_arid;
            x_addr <= t_addr;
            x_size <= t_size;
            x_burst <= aw_take ? s_axi_awburst : s_axi_arburst;
            x_wmask <= t_span[6:0] - 7'd1;
            x_left <= t_len;
            x_legal <= open && (t_size <= 3'd3);
            x_inr <= (t_addr[ADDR_W-1:3] < DEPTH);
        end else if (w_fire || r_go) begin
            x_addr <= x_nxt;
            x_inr <= (x_nxt[ADDR_W-1:3] < DEPTH);
            x_left <= x_left - 8'd1;
        end
    end

    // Write burst and response
    assign s_axi_wready = wb_act;
    assign s_axi_bid = x_id;

    always @(posedge clk) begin
        if (!rst_n) begin
            wb_act <= 1'b0;
            s_axi_bvalid <= 1'b0;
            s_axi_bresp <= RESP_OKAY;
            b_err <= 1'b0;
            prio_w <= 1'b0;
        end else begin
            if (aw_take) begin
                wb_act <= 1'b1;
                b_err <= 1'b0;
                prio_w <= 1'b0;
            end
            if (ar_take)
                prio_w <= 1'b1;
            if (w_fire) begin
                if (!beat_ok)
                    b_err <= 1'b1;
                if (s_axi_wlast) begin
                    wb_act <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                    s_axi_bresp <= (b_err || !beat_ok) ? RESP_SLVERR : RESP_OKAY;
                end
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // Read burst: beats are issued into the R queue as long as it has room
    reg ri_last, ri_err;
    always @(posedge clk) begin
        if (!rst_n) begin
            rb_act <= 1'b0;
            r_iss <= 1'b0;
        end else if (ar_take) begin
            rb_act <= 1'b1;
            r_iss <= 1'b1;
        end else begin
            if (r_go && x_left == 8'd0)
                r_iss <= 1'b0;
            if (rb_act && !r_iss && rq_idle)
                rb_act <= 1'b0;
        end
        ri_last <= (x_left == 8'd0);
        ri_err <= !beat_ok;
    end

    wire [65:0] rq_dout;
    mlkem_rdq #(.W(66), .ZW(64)) u_rq (
        .clk(clk),
        .clr(!rst_n),
        .issue(r_go),
        .din({ri_err, ri_last, rd}),
        .zero(ri_err),
        .can_issue(rq_can),
        .idle(rq_idle),
        .valid(s_axi_rvalid),
        .dout(rq_dout),
        .pop(s_axi_rready)
    );
    assign s_axi_rid = x_id;
    assign s_axi_rdata = rq_dout[63:0];
    assign s_axi_rlast = rq_dout[64];
    assign s_axi_rresp = rq_dout[65] ? RESP_SLVERR : RESP_OKAY;

    // Core side: reader, writer and wipe share one pointer set
    reg [WA-1:0] rptr;              // next request word to read
    reg rend;                       // the reader has passed the last word
    reg [WA-1:0] wptr;              // next result word / next word to wipe
    wire iq_can;
    wire iq_idle;                   // not needed: serve ends with the request

    wire eng = !ax_legal;           // no legal AXI burst holds the RAM
    wire wipe_go = wiping && eng;
    wire o_go = serve && eng && out_valid;
    wire i_go = serve && eng && !out_valid && !rend && iq_can;
    assign out_ready = serve && eng;

    always @(posedge clk) begin
        if (!rst_n) begin
            wiping <= 1'b1;
            wptr <= {WA{1'b0}};
            rptr <= {WA{1'b0}};
            rend <= 1'b0;
        end else begin
            if (wipe) begin
                wiping <= 1'b1;
                wptr <= {WA{1'b0}};
            end else if (wipe_go) begin
                wptr <= wptr + 1'b1;
                if (wptr == DEPTH - 1)
                    wiping <= 1'b0;
            end else if (o_go) begin
                wptr <= wptr + 1'b1;
            end else if (!serve && !wiping) begin
                wptr <= {WA{1'b0}};
            end
            if (!serve) begin
                rptr <= {WA{1'b0}};
                rend <= 1'b0;
            end else if (i_go) begin
                rptr <= rptr + 1'b1;
                if (rptr == DEPTH - 1)
                    rend <= 1'b1;
            end
        end
    end

    mlkem_rdq #(.W(64), .ZW(64)) u_iq (
        .clk(clk),
        .clr(!rst_n || !serve),
        .issue(i_go),
        .din(rd),
        .zero(1'b0),
        .can_issue(iq_can),
        .idle(iq_idle),
        .valid(in_valid),
        .dout(in_data),
        .pop(in_ready)
    );

    // RAM port: AXI beats, then the wipe, then the writer, then the reader
    always @(posedge clk) begin
        if (w_fire && beat_ok) begin
            a_q <= x_addr[ADDR_W-1:3];
            we_q <= s_axi_wstrb;
            wd_q <= s_axi_wdata;
        end else if (r_go && beat_ok) begin
            a_q <= x_addr[ADDR_W-1:3];
            we_q <= 8'h00;
        end else if (wipe_go) begin
            a_q <= wptr;
            we_q <= 8'hFF;
            wd_q <= 64'd0;
        end else if (o_go) begin
            a_q <= wptr;
            we_q <= 8'hFF;
            wd_q <= out_data;
        end else if (i_go) begin
            a_q <= rptr;
            we_q <= 8'h00;
        end else begin
            we_q <= 8'h00;
        end
    end

endmodule
