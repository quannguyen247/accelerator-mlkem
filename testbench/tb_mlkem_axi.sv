`timescale 1ns / 1ps

// Directed testbench for the IP top (mlkem_axi): AXI4-Lite registers and the
// AXI4 request/result buffer, no UVM. Runs the driver sequence of SPEC
// section 4 for KeyGen, Encaps and Decaps of every parameter set with the
// golden vectors (buffer traffic in bursts of odd lengths with random
// VALID/READY stalls, one request through 32-bit narrow beats), then the
// register, buffer and lifecycle error cases.
// Plusargs: +VEC=<dir>  +STALL=<pct> (default 20)  +SEED=<n>
module tb_mlkem_axi;

    localparam MAX_CASES = 128;
    localparam MAX_WORDS = 1 << 16;
    localparam BUF_WORDS = 592;

    reg clk = 1'b0;
    reg rstn = 1'b0;
    always #2.5 clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // AXI4-Lite master
    reg [11:0] awaddr = 0, araddr = 0;
    reg awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg [31:0] wdata = 0;
    reg [3:0] wstrb = 4'hF;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;

    // AXI4 master
    reg [3:0] m_awid = 0, m_arid = 0;
    reg [12:0] m_awaddr = 0, m_araddr = 0;
    reg [7:0] m_awlen = 0, m_arlen = 0;
    reg [2:0] m_awsize = 3, m_arsize = 3;
    reg [1:0] m_awburst = 1, m_arburst = 1;
    reg m_awvalid = 0, m_wvalid = 0, m_wlast = 0, m_bready = 0, m_arvalid = 0, m_rready = 0;
    reg [63:0] m_wdata = 0;
    reg [7:0] m_wstrb = 0;
    wire m_awready, m_wready, m_bvalid, m_arready, m_rvalid, m_rlast;
    wire [3:0] m_bid, m_rid;
    wire [1:0] m_bresp, m_rresp;
    wire [63:0] m_rdata;
    wire irq;

    mlkem_axi #(.ID_W(4)) dut (
        .aclk(clk), .aresetn(rstn),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid),
        .s_axil_wready(wready), .s_axil_bresp(bresp), .s_axil_bvalid(bvalid),
        .s_axil_bready(bready), .s_axil_araddr(araddr), .s_axil_arvalid(arvalid),
        .s_axil_arready(arready), .s_axil_rdata(rdata), .s_axil_rresp(rresp),
        .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .s_axi_awid(m_awid), .s_axi_awaddr(m_awaddr), .s_axi_awlen(m_awlen), .s_axi_awsize(m_awsize),
        .s_axi_awburst(m_awburst), .s_axi_awvalid(m_awvalid), .s_axi_awready(m_awready),
        .s_axi_wdata(m_wdata), .s_axi_wstrb(m_wstrb), .s_axi_wlast(m_wlast), .s_axi_wvalid(m_wvalid),
        .s_axi_wready(m_wready), .s_axi_bid(m_bid), .s_axi_bresp(m_bresp), .s_axi_bvalid(m_bvalid),
        .s_axi_bready(m_bready), .s_axi_arid(m_arid), .s_axi_araddr(m_araddr), .s_axi_arlen(m_arlen),
        .s_axi_arsize(m_arsize), .s_axi_arburst(m_arburst), .s_axi_arvalid(m_arvalid),
        .s_axi_arready(m_arready), .s_axi_rid(m_rid), .s_axi_rdata(m_rdata), .s_axi_rresp(m_rresp),
        .s_axi_rlast(m_rlast), .s_axi_rvalid(m_rvalid), .s_axi_rready(m_rready),
        .irq(irq)
    );

    reg [63:0] hdr [0:MAX_CASES-1];
    reg [63:0] seeds [0:8*MAX_CASES-1];
    reg [63:0] in_mem [0:MAX_WORDS-1];
    reg [63:0] out_mem [0:MAX_WORDS-1];
    integer in_off [0:MAX_CASES-1];
    integer out_off [0:MAX_CASES-1];
    integer n_cases;
    integer fails = 0;
    integer checks = 0;
    integer stall_pct;

    // Burst data (beats) and the words read back
    reg [63:0] bd [0:255];
    reg [7:0] bs [0:255];
    reg [63:0] rd_d [0:255];
    reg [1:0] rd_r [0:255];

    // START-to-outcome cycle monitor
    integer t_start = 0, t_end = 0;
    reg fin_q = 1'b0;
    always @(posedge clk) begin
        fin_q <= dut.done_r || dut.error_r;
        if (dut.start_wr)
            t_start <= cyc;
        if ((dut.done_r || dut.error_r) && !fin_q)
            t_end <= cyc;
    end

    task automatic check(input bit cond, input string what);
        checks = checks + 1;
        if (!cond) begin
            fails = fails + 1;
            $display("  FAIL: %s", what);
        end
    endtask

    function automatic bit stall();
        return ($urandom % 100) < stall_pct;
    endfunction

    // ---------------- AXI4-Lite ----------------
    task automatic axi_write(input [11:0] addr, input [31:0] data, output [1:0] resp);
        awaddr <= addr;
        awvalid <= 1'b1;
        @(posedge clk);
        while (!awready) @(posedge clk);
        awvalid <= 1'b0;
        wdata <= data;
        wvalid <= 1'b1;
        @(posedge clk);
        while (!wready) @(posedge clk);
        wvalid <= 1'b0;
        bready <= 1'b1;
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        resp = bresp;
        bready <= 1'b0;
        @(posedge clk);
    endtask

    task automatic axi_read(input [11:0] addr, output [31:0] data, output [1:0] resp);
        araddr <= addr;
        arvalid <= 1'b1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        arvalid <= 1'b0;
        rready <= 1'b1;
        @(posedge clk);
        while (!rvalid) @(posedge clk);
        data = rdata;
        resp = rresp;
        rready <= 1'b0;
        @(posedge clk);
    endtask

    task automatic wr_ok(input [11:0] addr, input [31:0] data);
        reg [1:0] r;
        axi_write(addr, data, r);
        check(r == 2'b00, $sformatf("write %h=%h OKAY", addr, data));
    endtask

    task automatic wait_outcome(output [31:0] st);
        reg [1:0] r;
        st = 0;
        while (!st[2] && !st[3])
            axi_read(12'h004, st, r);
    endtask

    task automatic wait_ready();
        reg [31:0] st;
        reg [1:0] r;
        st = 0;
        while (!st[0])
            axi_read(12'h004, st, r);
    endtask

    // ---------------- AXI4 ----------------
    // Write burst of n beats from bd/bs; returns BRESP.
    task automatic bwrite(input [12:0] addr, input integer n, input [2:0] size, input [1:0] burst,
                          input [3:0] id, output [1:0] resp);
        integer i;
        m_awid <= id;
        m_awaddr <= addr;
        m_awlen <= n - 1;
        m_awsize <= size;
        m_awburst <= burst;
        m_awvalid <= 1'b1;
        @(posedge clk);
        while (!m_awready) @(posedge clk);
        m_awvalid <= 1'b0;
        i = 0;
        while (i < n) begin
            if (stall()) begin
                m_wvalid <= 1'b0;
                @(posedge clk);
            end else begin
                m_wvalid <= 1'b1;
                m_wdata <= bd[i];
                m_wstrb <= bs[i];
                m_wlast <= (i == n - 1);
                @(posedge clk);
                while (!m_wready) @(posedge clk);
                i = i + 1;
            end
        end
        m_wvalid <= 1'b0;
        m_wlast <= 1'b0;
        m_bready <= 1'b0;
        while (!m_bvalid || !m_bready) begin
            m_bready <= !stall();
            @(posedge clk);
        end
        resp = m_bresp;
        check(m_bid == id, "BID matches AWID");
        m_bready <= 1'b0;
    endtask

    // Read burst of n beats into rd_d/rd_r; checks RID and RLAST.
    task automatic bread(input [12:0] addr, input integer n, input [2:0] size, input [1:0] burst,
                         input [3:0] id);
        integer i;
        bit bad_last, bad_id;
        m_arid <= id;
        m_araddr <= addr;
        m_arlen <= n - 1;
        m_arsize <= size;
        m_arburst <= burst;
        m_arvalid <= 1'b1;
        @(posedge clk);
        while (!m_arready) @(posedge clk);
        m_arvalid <= 1'b0;
        i = 0;
        bad_last = 0;
        bad_id = 0;
        while (i < n) begin
            m_rready <= !stall();
            @(posedge clk);
            if (m_rvalid && m_rready) begin
                rd_d[i] = m_rdata;
                rd_r[i] = m_rresp;
                if (m_rlast !== (i == n - 1)) bad_last = 1;
                if (m_rid !== id) bad_id = 1;
                i = i + 1;
            end
        end
        m_rready <= 1'b0;
        check(!bad_last, "RLAST on the last beat only");
        check(!bad_id, "RID matches ARID");
    endtask

    // Object transfer in INCR bursts of at most maxb beats, split at 4 KB.
    task automatic put_words(input integer src, input integer nwords, input integer maxb, input bit narrow);
        integer w, n, i, room;
        reg [1:0] r;
        bit ok;
        ok = 1;
        w = 0;
        while (w < nwords) begin
            room = (4096 - ((8 * w) % 4096)) / 8;
            n = nwords - w;
            if (narrow) begin
                if (n > maxb / 2) n = maxb / 2;
                if (n > room) n = room;
                for (i = 0; i < n; i = i + 1) begin
                    bd[2 * i] = in_mem[src + w + i];
                    bs[2 * i] = 8'h0F;
                    bd[2 * i + 1] = in_mem[src + w + i];
                    bs[2 * i + 1] = 8'hF0;
                end
                bwrite(8 * w, 2 * n, 3'd2, 2'b01, w[3:0], r);
            end else begin
                if (n > maxb) n = maxb;
                if (n > room) n = room;
                for (i = 0; i < n; i = i + 1) begin
                    bd[i] = in_mem[src + w + i];
                    bs[i] = 8'hFF;
                end
                bwrite(8 * w, n, 3'd3, 2'b01, w[3:0], r);
            end
            if (r != 2'b00) ok = 0;
            w = w + n;
        end
        check(ok, "request written (BRESP OKAY)");
    endtask

    // Compares nwords buffer words from word 0 with out_mem[base..]; errs counts mismatches.
    task automatic get_words(input integer base, input integer nwords, input integer maxb, output integer errs);
        integer w, n, i, room;
        errs = 0;
        w = 0;
        while (w < nwords) begin
            room = (4096 - ((8 * w) % 4096)) / 8;
            n = nwords - w;
            if (n > maxb) n = maxb;
            if (n > room) n = room;
            bread(8 * w, n, 3'd3, 2'b01, ~w[3:0]);
            for (i = 0; i < n; i = i + 1)
                if (rd_r[i] != 2'b00 || rd_d[i] !== out_mem[base + w + i]) errs = errs + 1;
            w = w + n;
        end
    endtask

    // Counts nonzero words (or error responses) in the first nwords of the buffer.
    task automatic count_nonzero(input integer nwords, output integer nz);
        integer w, n, i, room;
        nz = 0;
        w = 0;
        while (w < nwords) begin
            room = (4096 - ((8 * w) % 4096)) / 8;
            n = nwords - w;
            if (n > 128) n = 128;
            if (n > room) n = room;
            bread(8 * w, n, 3'd3, 2'b01, 4'h5);
            for (i = 0; i < n; i = i + 1)
                if (rd_r[i] != 2'b00 || rd_d[i] !== 64'd0) nz = nz + 1;
            w = w + n;
        end
    endtask

    // One request through the CSRs and the buffer (driver sequence).
    task automatic run_vec(input integer c, input bit narrow);
        integer op, set, err, nin, nout, i, errs, nz;
        reg [31:0] st, code;
        reg [1:0] r;
        op = hdr[c][63:56];
        set = hdr[c][55:48];
        err = hdr[c][47:40];
        nin = hdr[c][39:20];
        nout = hdr[c][19:0];
        wait_ready();
        wr_ok(12'h00C, {28'd0, set[1:0], op[1:0]});
        if (op == 0)
            for (i = 0; i < 16; i = i + 1)
                wr_ok(12'h040 + 4 * i, seeds[8 * c + i / 2][32 * (i % 2) +: 32]);
        else if (op == 1)
            for (i = 0; i < 8; i = i + 1)
                wr_ok(12'h040 + 4 * i, seeds[8 * c + i / 2][32 * (i % 2) +: 32]);
        if (nin > 0)
            put_words(in_off[c], nin, narrow ? 256 : 61, narrow);
        wr_ok(12'h000, 32'h1);
        wait_outcome(st);
        axi_read(12'h008, code, r);
        if (err == 0) begin
            check(st[2] && !st[3] && irq, $sformatf("case %0d DONE with irq", c));
            get_words(out_off[c], nout, 47, errs);
            check(errs == 0, $sformatf("case %0d result matches (%0d mismatches)", c, errs));
            $display("  case %0d op=%0d set=%0d%s: %0d result words, %0d cycles START->DONE",
                     c, op, set, narrow ? " (narrow writes)" : "", nout, t_end - t_start);
        end else begin
            check(st[3] && code == err && irq, $sformatf("case %0d ERROR %0d", c, err));
            count_nonzero(nin, nz);
            check(nz == 0, $sformatf("case %0d buffer wiped before ERROR (%0d words left)", c, nz));
            $display("  case %0d op=%0d set=%0d: ERROR %0d as expected, %0d cycles START->ERROR",
                     c, op, set, code, t_end - t_start);
        end
        wr_ok(12'h000, 32'h4);
        wait_ready();
        axi_read(12'h004, st, r);
        check(st == 32'h1 && !irq, "ACK returns to READY");
        if (err == 0) begin
            count_nonzero(nout > nin ? nout : nin, nz);
            check(nz == 0, $sformatf("case %0d buffer wiped after ACK (%0d words left)", c, nz));
        end
    endtask

    integer c, ib, ob, i, nz, first_enc;
    reg [31:0] st, v;
    reg [1:0] r, r2;
    initial begin
        string vec;
        integer sd;
        if (!$value$plusargs("VEC=%s", vec)) vec = "vector";
        if (!$value$plusargs("STALL=%d", stall_pct)) stall_pct = 20;
        if (!$value$plusargs("SEED=%d", sd)) sd = 1;
        void'($urandom(sd));
        for (c = 0; c < MAX_CASES; c = c + 1) hdr[c] = 64'hFFFF_FFFF_FFFF_FFFF;
        $readmemh({vec, "/tv_hdr.mem"}, hdr);
        $readmemh({vec, "/tv_seed.mem"}, seeds);
        $readmemh({vec, "/tv_in.mem"}, in_mem);
        $readmemh({vec, "/tv_out.mem"}, out_mem);
        n_cases = 0;
        ib = 0;
        ob = 0;
        first_enc = -1;
        while (n_cases < MAX_CASES && hdr[n_cases] !== 64'hFFFF_FFFF_FFFF_FFFF) begin
            in_off[n_cases] = ib;
            out_off[n_cases] = ob;
            ib = ib + hdr[n_cases][39:20];
            ob = ob + hdr[n_cases][19:0];
            if (first_enc < 0 && hdr[n_cases][63:56] == 1 && hdr[n_cases][47:40] == 0)
                first_enc = n_cases;
            n_cases = n_cases + 1;
        end

        repeat (5) @(posedge clk);
        rstn <= 1'b1;
        axi_read(12'h004, st, r);
        check(st[0] == 1'b0, "READY low while the post-reset wipe runs");
        wait_ready();
        $display("READY after the post-reset wipe");
        axi_read(12'h014, v, r);
        check(r == 2'b00 && v == 32'h0002_0000, "VERSION");
        wr_ok(12'h010, 32'h1);
        axi_read(12'h010, v, r);
        check(v == 32'h1, "IRQ_ENABLE reads back");

        $display("Requests through the CSRs and the AXI4 buffer (stall %0d%%):", stall_pct);
        for (c = 0; c < n_cases; c = c + 1)
            run_vec(c, 1'b0);
        if (first_enc >= 0)
            run_vec(first_enc, 1'b1);

        $display("Register checks:");
        axi_read(12'h000, v, r);
        check(r == 2'b10, "CONTROL is write-only");
        axi_write(12'h004, 32'h0, r);
        check(r == 2'b10, "STATUS is read-only");
        axi_write(12'h014, 32'h0, r);
        check(r == 2'b10, "VERSION is read-only");
        axi_read(12'h018, v, r);
        check(r == 2'b10, "unmapped offset");
        axi_read(12'h040, v, r);
        check(r == 2'b10, "SEED is write-only");
        axi_write(12'h000, 32'h3, r);
        check(r == 2'b10, "CONTROL with two command bits");
        axi_write(12'h00C, 32'h10, r);
        check(r == 2'b10, "CONFIG reserved bits");
        axi_write(12'h010, 32'h2, r);
        check(r == 2'b10, "IRQ_ENABLE reserved bits");
        axi_write(12'h00D, 32'h0, r);
        check(r == 2'b10, "misaligned write");
        axi_read(12'h005, v, r);
        check(r == 2'b10, "misaligned read");
        wstrb = 4'h3;
        axi_write(12'h00C, 32'h0, r);
        check(r == 2'b10, "partial strobes");
        wstrb = 4'hF;
        axi_write(12'h000, 32'h4, r);
        check(r == 2'b10, "ACK without an outcome");

        $display("Buffer access checks:");
        // FIXED burst: the last beat wins; read back twice with FIXED.
        for (i = 0; i < 3; i = i + 1) begin
            bd[i] = 64'h1111_0000_0000_0000 * (i + 1);
            bs[i] = 8'hFF;
        end
        bwrite(13'h080, 3, 3'd3, 2'b00, 4'h1, r);
        bread(13'h080, 2, 3'd3, 2'b00, 4'h2);
        check(r == 2'b00 && rd_d[0] == 64'h3333_0000_0000_0000 && rd_d[1] == rd_d[0], "FIXED burst");
        // WRAP burst of 4 beats from word 66: words 66, 67, 64, 65.
        for (i = 0; i < 4; i = i + 1) begin
            bd[i] = 64'hA0 + i;
            bs[i] = 8'hFF;
        end
        bwrite(13'h210, 4, 3'd3, 2'b10, 4'h3, r);
        bread(13'h200, 4, 3'd3, 2'b01, 4'h4);
        check(r == 2'b00 && rd_d[0] == 64'hA2 && rd_d[1] == 64'hA3 && rd_d[2] == 64'hA0 && rd_d[3] == 64'hA1,
              "WRAP burst write order");
        // WRAP read from word 67: words 67, 64, 65, 66.
        bread(13'h218, 4, 3'd3, 2'b10, 4'h5);
        check(rd_d[0] == 64'hA1 && rd_d[1] == 64'hA2 && rd_d[2] == 64'hA3 && rd_d[3] == 64'hA0,
              "WRAP burst read order");
        // Byte strobes (lanes 2 and 5) and narrow reads.
        bd[0] = 64'h0123_4567_89AB_CDEF;
        bs[0] = 8'hFF;
        bwrite(13'h300, 1, 3'd3, 2'b01, 4'h6, r);
        bd[0] = 64'hFFFF_FFFF_FFFF_FFFF;
        bs[0] = 8'b0010_0100;
        bwrite(13'h300, 1, 3'd3, 2'b01, 4'h7, r);
        bread(13'h300, 1, 3'd3, 2'b01, 4'h8);
        check(rd_d[0] == 64'h0123_FF67_89FF_CDEF, "byte strobes");
        bread(13'h304, 2, 3'd2, 2'b01, 4'h9);
        check(rd_d[0][63:32] == 32'h0123_FF67 && rd_d[1] == 64'd0 && rd_r[1] == 2'b00, "narrow INCR read");
        // Beats beyond the buffer, and AxSIZE above the bus width.
        bread(13'd8 * (BUF_WORDS - 2), 4, 3'd3, 2'b01, 4'hA);
        check(rd_r[0] == 2'b00 && rd_r[1] == 2'b00 && rd_r[2] == 2'b10 && rd_r[3] == 2'b10 &&
              rd_d[2] == 64'd0, "read past the end: SLVERR beats");
        bd[0] = 64'h5;
        bs[0] = 8'hFF;
        bwrite(13'h1FF8, 1, 3'd3, 2'b01, 4'hB, r);
        check(r == 2'b10, "write past the end: SLVERR");
        bwrite(13'h000, 1, 3'd4, 2'b01, 4'hC, r);
        check(r == 2'b10, "AxSIZE 4 on a 64-bit bus: SLVERR");
        // A write and a read issued together both complete.
        bd[0] = 64'hDEAD_BEEF;
        bs[0] = 8'hFF;
        fork
            bwrite(13'h400, 1, 3'd3, 2'b01, 4'hD, r2);
            bread(13'h300, 1, 3'd3, 2'b01, 4'hE);
        join
        check(r2 == 2'b00 && rd_d[0] == 64'h0123_FF67_89FF_CDEF, "concurrent AW and AR");

        $display("Lifecycle checks:");
        // Missing seed words -> ERROR 4.
        wr_ok(12'h00C, 32'h1);
        for (c = 0; c < 7; c = c + 1) wr_ok(12'h040 + 4 * c, c);
        wr_ok(12'h000, 32'h1);
        axi_read(12'h004, st, r);
        axi_read(12'h008, v, r);
        check(st[3] && v == 4 && irq, "incomplete seed -> ERROR 4");
        wr_ok(12'h000, 32'h4);
        // Invalid parameter set -> ERROR 1.
        wr_ok(12'h00C, 32'hC);
        wr_ok(12'h000, 32'h1);
        axi_read(12'h008, v, r);
        check(v == 1, "invalid configuration -> ERROR 1");
        wr_ok(12'h000, 32'h4);
        // Interrupt masked.
        wr_ok(12'h010, 32'h0);
        wr_ok(12'h00C, 32'hC);
        wr_ok(12'h000, 32'h1);
        axi_read(12'h004, st, r);
        check(st[3] && !irq, "IRQ_ENABLE = 0 masks irq");
        wr_ok(12'h000, 32'h4);
        wr_ok(12'h010, 32'h1);

        // KeyGen started: START, register and buffer accesses while busy
        // fail; ABORT -> ERROR 6 with the buffer wiped.
        wr_ok(12'h00C, 32'h0);
        for (c = 0; c < 16; c = c + 1) wr_ok(12'h040 + 4 * c, c);
        wr_ok(12'h000, 32'h1);
        axi_write(12'h000, 32'h1, r);
        check(r == 2'b10, "START while busy");
        axi_write(12'h00C, 32'h1, r);
        check(r == 2'b10, "CONFIG write while busy");
        axi_write(12'h040, 32'h1, r);
        check(r == 2'b10, "SEED write while busy");
        bd[0] = 64'h77;
        bs[0] = 8'hFF;
        bwrite(13'h000, 1, 3'd3, 2'b01, 4'h1, r);
        check(r == 2'b10, "buffer write while busy: SLVERR");
        bread(13'h000, 2, 3'd3, 2'b01, 4'h2);
        check(rd_r[0] == 2'b10 && rd_r[1] == 2'b10 && rd_d[0] == 64'd0 && rd_d[1] == 64'd0,
              "buffer read while busy: SLVERR, zero data");
        repeat (1500) @(posedge clk);
        wr_ok(12'h000, 32'h2);
        wait_outcome(st);
        axi_read(12'h008, v, r);
        check(st[3] && v == 6, "ABORT -> ERROR 6");
        count_nonzero(BUF_WORDS, nz);
        check(nz == 0, $sformatf("buffer wiped after ABORT (%0d words left)", nz));
        wr_ok(12'h000, 32'h4);
        wait_ready();

        // The IP still works after the error cases.
        for (c = 0; c < n_cases && c < 3; c = c + 1)
            run_vec(c, 1'b0);

        $display("RESULT: %0d checks, %0d failed", checks, fails);
        if (fails == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** TESTS FAILED ***");
        $finish;
    end

endmodule
