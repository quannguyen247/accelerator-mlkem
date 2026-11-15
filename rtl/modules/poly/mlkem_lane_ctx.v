`timescale 1ns / 1ps
`include "mlkem_defs.vh"

// Storage of one logical lane: its PRF noise memory and its polynomial buffer
// with fill state. The NTT engines (mlkem_lane) are shared; whichever engine
// runs a job of this lane reads the noise and the buffer through the engine
// port and writes its unload results here.
//   LANE 0..3  vector: buffer read by the PMAC (V operand), written by the engine
//   LANE 4..7  row:    buffer written by the PMAC (Encaps) or the engine (KeyGen
//                      e^), read by the engine and by the output engine (bias)
//   LANE 8     scalar: buffer written by the PMAC, read by the engine
// scrub clears the noise memory and the buffer (32 cycles, busy meanwhile).
// Buffer reads take one cycle: the read address is registered in the buffer
// (the output engine's address only while pm_ra_en, see mlkem_out).
module mlkem_lane_ctx #(
    parameter LANE = 0
)(
    input wire clk,
    input wire rst_n,
    input wire kill,
    input wire go,
    input wire scrub,
    input wire out_rd,                   // KeyGen: the output engine reads the row buffer
    output wire busy,

    // PRF noise words from the hash engine
    input wire nz_we,
    input wire [4:0] nz_addr,
    input wire [63:0] nz_wdata,
    output reg [4:0] nz_cnt,             // words written so far
    input wire [4:0] nz_raddr,
    output wire [63:0] nz_rdata,

    // PMAC / output port
    input wire pm_ra_en,
    input wire [4:0] pm_rd_blk,
    output wire [95:0] pm_rd_data,
    input wire pm_we,
    input wire [4:0] pm_wr_blk,
    input wire pm_wr_first,
    input wire [95:0] pm_wr_data,
    input wire pm_wr_ep,

    // Engine port: load read, unload group write (four coefficients of group
    // e_widx), first / last group of an 8-coefficient block, epoch
    input wire [4:0] e_rblk,
    output wire [95:0] e_rdata,
    input wire e_we,
    input wire [5:0] e_widx,
    input wire [47:0] e_wdata,
    input wire e_first,
    input wire e_last,
    input wire e_ep,

    output wire [5:0] b_fill,
    output wire b_ep
);

    localparam IS_VEC = (LANE < 4);
    localparam IS_ROW = (LANE >= 4) && (LANE < 8);

    reg scrubbing;
    reg [4:0] sc;
    assign busy = scrubbing;

    always @(posedge clk) begin
        if (!rst_n || kill) begin
            scrubbing <= 1'b0;
            sc <= 5'd0;
        end else if (scrub) begin
            scrubbing <= 1'b1;
            sc <= 5'd0;
        end else if (scrubbing) begin
            sc <= sc + 5'd1;
            if (sc == 5'd31)
                scrubbing <= 1'b0;
        end
    end

    // Noise memory; the write port is registered (the hash feeds nine
    // contexts, the memory sees a local register).
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
    always @(posedge clk) begin
        if (scrubbing)
            nmem[sc] <= 64'd0;
        else if (nz_we_reg)
            nmem[nz_addr_reg] <= nz_wdata_reg;
    end
    assign nz_rdata = nmem[nz_raddr];

    always @(posedge clk) begin
        if (!rst_n || kill || go || scrub)
            nz_cnt <= 5'd0;
        else if (nz_we_reg)
            nz_cnt <= nz_addr_reg + 5'd1;
    end

    // Buffer
    reg [7:0] b_we;
    reg [4:0] b_waddr;
    reg [95:0] b_wdata;
    always @(*) begin
        b_we = 8'd0;
        b_waddr = pm_wr_blk;
        b_wdata = pm_wr_data;
        if (scrubbing) begin
            b_we = 8'hFF;
            b_waddr = sc;
            b_wdata = 96'd0;
        end else if (pm_we) begin
            b_we = 8'hFF;
        end else if (e_we) begin
            b_we = e_widx[0] ? 8'hF0 : 8'h0F;
            b_waddr = e_widx[5:1];
            b_wdata = {2{e_wdata}};
        end
    end

    generate
        if (IS_ROW) begin : g_two
            // One read port: the output engine reads the KeyGen e^ bias, the
            // engine loads the PMAC row in Encaps / Decaps.
            mlkem_poly_ram #(.W(12), .AW(5), .RREG(1)) u_buf (
                .clk(clk), .we(b_we), .waddr({8{b_waddr}}), .wdata(b_wdata),
                .ra_en(out_rd ? pm_ra_en : 1'b1), .raddr(out_rd ? pm_rd_blk : e_rblk),
                .rdata(e_rdata));
            assign pm_rd_data = e_rdata;
        end else if (IS_VEC) begin : g_vec
            // Read only by the PMAC
            mlkem_poly_ram #(.W(12), .AW(5), .RREG(1)) u_buf (
                .clk(clk), .we(b_we), .waddr({8{b_waddr}}), .wdata(b_wdata),
                .ra_en(1'b1), .raddr(pm_rd_blk), .rdata(pm_rd_data));
            assign e_rdata = 96'd0;
        end else begin : g_scl
            // Read only by the engine
            mlkem_poly_ram #(.W(12), .AW(5), .RREG(1)) u_buf (
                .clk(clk), .we(b_we), .waddr({8{b_waddr}}), .wdata(b_wdata),
                .ra_en(1'b1), .raddr(e_rblk), .rdata(e_rdata));
            assign pm_rd_data = 96'd0;
        end
    endgenerate

    mlkem_slot_state u_bstate (
        .clk(clk),
        .rst_n(rst_n),
        .clr(go || scrubbing || kill),
        .first(pm_we ? pm_wr_first : (e_we && e_first)),
        .first_ep(pm_we ? pm_wr_ep : e_ep),
        .inc(pm_we || (e_we && e_last)),
        .fill(b_fill),
        .ep(b_ep)
    );

endmodule
