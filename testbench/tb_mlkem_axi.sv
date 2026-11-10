`timescale 1ns / 1ps

// Directed testbench for the AXI4-Lite / AXI4-Stream IP top (mlkem_axi), no UVM.
// Runs the driver sequence of SPEC section 4 for KeyGen, Encaps and Decaps of
// every parameter set with the golden vectors, then the register and
// lifecycle error cases.
module tb_mlkem_axi;

    localparam MAX_CASES = 128;
    localparam MAX_WORDS = 1 << 16;

    reg clk = 1'b0;
    reg rstn = 1'b0;
    always #2.5 clk = ~clk;

    reg [11:0] awaddr = 0, araddr = 0;
    reg awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg [31:0] wdata = 0;
    reg [3:0] wstrb = 4'hF;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;

    reg [63:0] s_tdata = 0;
    reg s_tvalid = 0, s_tlast = 0;
    wire s_tready;
    wire [63:0] m_tdata;
    wire [7:0] m_tkeep;
    wire m_tlast, m_tvalid;
    reg m_tready = 0;
    wire irq;

    mlkem_axi dut (
        .aclk(clk), .aresetn(rstn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
        .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(8'hFF), .s_axis_tlast(s_tlast), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tlast(m_tlast),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .irq(irq)
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

    task automatic check(input bit cond, input string what);
        checks = checks + 1;
        if (!cond) begin
            fails = fails + 1;
            $display("  FAIL: %s", what);
        end
    endtask

    // Single 32-bit write; returns BRESP.
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

    task automatic wait_status(output [31:0] st);
        reg [1:0] r;
        st = 0;
        while (!st[2] && !st[3]) begin
            axi_read(12'h004, st, r);
        end
    endtask

    // One request through the CSRs and the streams (DMA model).
    task automatic run_vec(input integer c);
        integer op, set, nin, nout, w, got, errs, i, t0;
        reg [31:0] st, code;
        reg [1:0] r;
        integer klen [0:2];
        op = hdr[c][63:56];
        set = hdr[c][55:48];
        nin = hdr[c][39:20];
        nout = hdr[c][19:0];
        wr_ok(12'h00C, {28'd0, set[1:0], op[1:0]});
        case (op)
            0: begin
                wr_ok(12'h010, 0); wr_ok(12'h014, 0);
                wr_ok(12'h018, 384 * (set + 2) + 32); wr_ok(12'h01C, 768 * (set + 2) + 96);
                for (i = 0; i < 16; i = i + 1)
                    wr_ok(12'h040 + 4 * i, seeds[8 * c + i / 2][32 * (i % 2) +: 32]);
            end
            1: begin
                wr_ok(12'h010, nin * 8); wr_ok(12'h014, 0);
                wr_ok(12'h018, (nout - 4) * 8); wr_ok(12'h01C, 32);
                for (i = 0; i < 8; i = i + 1)
                    wr_ok(12'h040 + 4 * i, seeds[8 * c + i / 2][32 * (i % 2) +: 32]);
            end
            default: begin
                wr_ok(12'h010, 768 * (set + 2) + 96); wr_ok(12'h014, nin * 8 - 768 * (set + 2) - 96);
                wr_ok(12'h018, 32); wr_ok(12'h01C, 0);
            end
        endcase
        wr_ok(12'h000, 32'h1);
        t0 = $time;
        got = 0;
        errs = 0;
        fork
            begin
                for (w = 0; w < nin; w = w + 1) begin
                    s_tdata <= in_mem[in_off[c] + w];
                    s_tlast <= (w == nin - 1);
                    s_tvalid <= 1'b1;
                    @(posedge clk);
                    while (!s_tready) @(posedge clk);
                end
                s_tvalid <= 1'b0;
                s_tlast <= 1'b0;
            end
            begin
                m_tready <= 1'b1;
                while (got < nout) begin
                    @(posedge clk);
                    if (m_tvalid) begin
                        if (m_tdata !== out_mem[out_off[c] + got] || m_tlast !== (got == nout - 1))
                            errs = errs + 1;
                        got = got + 1;
                    end
                end
                m_tready <= 1'b0;
            end
        join
        wait_status(st);
        check(st[2] && !st[3] && irq, $sformatf("case %0d DONE", c));
        check(errs == 0, $sformatf("case %0d output matches (%0d mismatches)", c, errs));
        $display("  case %0d op=%0d set=%0d: %0d output words checked, %0d ns", c, op, set, got, ($time - t0));
        wr_ok(12'h000, 32'h4);
        axi_read(12'h004, st, r);
        check(st == 32'h1 && !irq, "ACK returns to READY");
    endtask

    integer c, ib, ob;
    reg [31:0] st, v;
    reg [1:0] r;
    initial begin
        string vec;
        if (!$value$plusargs("VEC=%s", vec)) vec = "vector";
        for (c = 0; c < MAX_CASES; c = c + 1) hdr[c] = 64'hFFFF_FFFF_FFFF_FFFF;
        $readmemh({vec, "/tv_hdr.mem"}, hdr);
        $readmemh({vec, "/tv_seed.mem"}, seeds);
        $readmemh({vec, "/tv_in.mem"}, in_mem);
        $readmemh({vec, "/tv_out.mem"}, out_mem);
        n_cases = 0;
        ib = 0;
        ob = 0;
        while (n_cases < MAX_CASES && hdr[n_cases] !== 64'hFFFF_FFFF_FFFF_FFFF) begin
            in_off[n_cases] = ib;
            out_off[n_cases] = ob;
            ib = ib + hdr[n_cases][39:20];
            ob = ob + hdr[n_cases][19:0];
            n_cases = n_cases + 1;
        end

        repeat (5) @(posedge clk);
        rstn <= 1'b1;
        axi_read(12'h004, st, r);
        check(st[0] == 1'b0, "READY low while the post-reset clear runs");
        st = 0;
        while (!st[0]) axi_read(12'h004, st, r);
        $display("READY after reset clear");

        $display("Requests through CSR + DMA streams:");
        for (c = 0; c < n_cases; c = c + 1)
            if (hdr[c][47:40] == 0)
                run_vec(c);

        $display("Register and lifecycle checks:");
        axi_read(12'h000, v, r);
        check(r == 2'b10, "CONTROL is write-only");
        axi_write(12'h004, 32'h0, r);
        check(r == 2'b10, "STATUS is read-only");
        axi_read(12'h020, v, r);
        check(r == 2'b10, "unmapped offset");
        axi_read(12'h040, v, r);
        check(r == 2'b10, "SEED is write-only");
        axi_write(12'h000, 32'h3, r);
        check(r == 2'b10, "CONTROL with two command bits");
        axi_write(12'h00C, 32'h10, r);
        check(r == 2'b10, "CONFIG reserved bits");
        axi_write(12'h00D, 32'h0, r);
        check(r == 2'b10, "misaligned write");
        axi_read(12'h005, v, r);
        check(r == 2'b10, "misaligned read");
        wstrb = 4'h3;
        axi_write(12'h010, 32'h0, r);
        check(r == 2'b10, "partial strobes");
        wstrb = 4'hF;
        axi_write(12'h000, 32'h4, r);
        check(r == 2'b10, "ACK without an outcome");

        // Wrong ek length -> ERROR code 2, no transfer.
        wr_ok(12'h00C, 32'h1);
        wr_ok(12'h010, 32'd100);
        wr_ok(12'h014, 0);
        wr_ok(12'h018, 768);
        wr_ok(12'h01C, 32);
        for (c = 0; c < 8; c = c + 1) wr_ok(12'h040 + 4 * c, c);
        wr_ok(12'h000, 32'h1);
        axi_read(12'h004, st, r);
        axi_read(12'h008, v, r);
        check(st[3] && v == 2 && irq, "length mismatch -> ERROR 2");
        wr_ok(12'h000, 32'h4);

        // Missing seed words -> ERROR code 4.
        wr_ok(12'h010, 32'd800);
        for (c = 0; c < 7; c = c + 1) wr_ok(12'h040 + 4 * c, c);
        wr_ok(12'h000, 32'h1);
        axi_read(12'h008, v, r);
        check(v == 4, "incomplete seed -> ERROR 4");
        wr_ok(12'h000, 32'h4);

        // Invalid parameter set -> ERROR code 1.
        wr_ok(12'h00C, 32'hC);
        wr_ok(12'h000, 32'h1);
        axi_read(12'h008, v, r);
        check(v == 1, "invalid configuration -> ERROR 1");
        wr_ok(12'h000, 32'h4);

        // KeyGen started; START again and register writes while busy fail; ABORT -> ERROR 6.
        wr_ok(12'h00C, 32'h0);
        wr_ok(12'h010, 0);
        wr_ok(12'h018, 800);
        wr_ok(12'h01C, 1632);
        for (c = 0; c < 16; c = c + 1) wr_ok(12'h040 + 4 * c, c);
        wr_ok(12'h000, 32'h1);
        axi_write(12'h000, 32'h1, r);
        check(r == 2'b10, "START while busy");
        axi_write(12'h00C, 32'h1, r);
        check(r == 2'b10, "CONFIG write while busy");
        axi_write(12'h040, 32'h1, r);
        check(r == 2'b10, "SEED write while busy");
        repeat (300) @(posedge clk);
        wr_ok(12'h000, 32'h2);
        m_tready <= 1'b1;
        wait_status(st);
        m_tready <= 1'b0;
        axi_read(12'h008, v, r);
        check(st[3] && v == 6, "ABORT -> ERROR 6");
        wr_ok(12'h000, 32'h4);
        st = 0;
        while (!st[0]) axi_read(12'h004, st, r);

        // The IP still works after the error cases.
        for (c = 0; c < n_cases && c < 3; c = c + 1)
            run_vec(c);

        $display("RESULT: %0d checks, %0d failed", checks, fails);
        if (fails == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** TESTS FAILED ***");
        $finish;
    end

endmodule
