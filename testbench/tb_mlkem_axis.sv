`timescale 1ns / 1ps
// Stream variant testbench: AXI4-Lite registers, request on s_axis, result
// on m_axis (random VALID/READY stalls), every golden vector case.
module tb_mlkem_axis;
    localparam MAX_CASES = 128;
    localparam MAX_WORDS = 1 << 16;
    reg clk = 1'b0;
    reg rstn = 1'b0;
    always #2.5 clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    reg [11:0] awaddr = 0, araddr = 0;
    reg awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg [31:0] wdata = 0;
    reg [3:0] wstrb = 4'hF;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    reg [63:0] s_tdata = 0;
    reg s_tvalid = 0, m_tready = 0;
    wire s_tready, m_tvalid, m_tlast;
    wire [63:0] m_tdata;
    wire irq;

    mlkem_axis_top dut (
        .aclk(clk), .aresetn(rstn),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid),
        .s_axil_wready(wready), .s_axil_bresp(bresp), .s_axil_bvalid(bvalid),
        .s_axil_bready(bready), .s_axil_araddr(araddr), .s_axil_arvalid(arvalid),
        .s_axil_arready(arready), .s_axil_rdata(rdata), .s_axil_rresp(rresp),
        .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast), .irq(irq)
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


    integer t_last_out;
    task automatic push(input integer src, input integer n);
        integer i;
        i = 0;
        while (i < n) begin
            if (stall()) begin
                s_tvalid <= 1'b0;
                @(posedge clk);
            end else begin
                s_tvalid <= 1'b1;
                s_tdata <= in_mem[src + i];
                @(posedge clk);
                while (!s_tready) @(posedge clk);
                i = i + 1;
            end
        end
        s_tvalid <= 1'b0;
    endtask

    task automatic pop(input integer base, input integer n, output integer errs);
        integer i;
        errs = 0;
        i = 0;
        while (i < n) begin
            m_tready <= !stall();
            @(posedge clk);
            if (m_tvalid && m_tready) begin
                if (m_tdata !== out_mem[base + i]) errs = errs + 1;
                if (m_tlast !== (i == n - 1)) errs = errs + 1;
                i = i + 1;
                t_last_out = cyc;
            end
        end
        m_tready <= 1'b0;
    endtask

    task automatic run_vec(input integer c);
        integer op, set, err, nin, nout, i, errs, t_a;
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
        t_a = cyc;
        wr_ok(12'h000, 32'h1);
        errs = 0;
        if (err == 0) begin
            fork
                if (nin > 0) push(in_off[c], nin);
                pop(out_off[c], nout, errs);
            join
            wait_outcome(st);
            check(st[2] && !st[3] && irq, $sformatf("case %0d DONE with irq", c));
            check(errs == 0, $sformatf("case %0d result matches (%0d mismatches)", c, errs));
            $display("E2E case %0d op=%0d set=%0d: %0d cycles (request in .. result out)", c, op, set, t_last_out - t_a);
        end else begin
            fork
                begin
                    if (nin > 0) push(in_off[c], nin);
                end
                wait_outcome(st);
            join_any
            disable fork;
            s_tvalid <= 1'b0;
            axi_read(12'h008, code, r);
            check(st[3] && code == err && irq, $sformatf("case %0d ERROR %0d", c, err));
            $display("  case %0d op=%0d set=%0d: ERROR %0d as expected", c, op, set, code);
        end
        wr_ok(12'h000, 32'h4);
        wait_ready();
    endtask

    integer c, ib, ob;
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
        n_cases = 0; ib = 0; ob = 0;
        while (n_cases < MAX_CASES && hdr[n_cases] !== 64'hFFFF_FFFF_FFFF_FFFF) begin
            in_off[n_cases] = ib;
            out_off[n_cases] = ob;
            ib = ib + hdr[n_cases][39:20];
            ob = ob + hdr[n_cases][19:0];
            n_cases = n_cases + 1;
        end
        repeat (5) @(posedge clk);
        rstn <= 1'b1;
        wait_ready();
        wr_ok(12'h010, 32'h1);
        for (c = 0; c < n_cases; c = c + 1)
            run_vec(c);
        $display("RESULT: %0d checks, %0d failed", checks, fails);
        if (fails == 0) $display("*** ALL TESTS PASSED ***");
        else $display("*** TESTS FAILED ***");
        $finish;
    end
endmodule
