`timescale 1ns / 1ps

// Self-checking testbench for mlkem_core (no UVM).
// Vectors come from vector/mlkem_gen.py (FIPS 203 model).
// Plusargs: +PERF        always-ready streams (cycle counts)
//           +STALL=<pct> stall probability on both streams (default 30)
//           +SEED=<n>    stall pattern seed
module tb_mlkem_core;

    localparam MAX_CASES = 128;
    localparam MAX_WORDS = 1 << 16;
    localparam TIMEOUT = 40000;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #2.5 clk = ~clk;

    reg start = 1'b0;
    reg [1:0] op = 2'd0;
    reg [1:0] pset = 2'd0;
    reg [511:0] seed = 512'd0;
    reg abort = 1'b0;
    wire ready, done, error;
    wire [2:0] err_code;

    reg [63:0] s_tdata = 64'd0;
    reg [7:0] s_tkeep = 8'hFF;
    reg s_tlast = 1'b0;
    reg s_tvalid = 1'b0;
    wire s_tready;
    wire [63:0] m_tdata;
    wire [7:0] m_tkeep;
    wire m_tlast;
    wire m_tvalid;
    reg m_tready = 1'b0;

    mlkem_core dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .op(op), .pset(pset), .seed(seed), .abort(abort),
        .ready(ready), .done(done), .error(error), .err_code(err_code),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tlast(s_tlast),
        .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tlast(m_tlast),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready)
    );

    reg [63:0] hdr [0:MAX_CASES-1];
    reg [63:0] seeds [0:8*MAX_CASES-1];
    reg [63:0] in_mem [0:MAX_WORDS-1];
    reg [63:0] out_mem [0:MAX_WORDS-1];

    integer n_cases;
    integer stall_pct;
    integer rnd_seed;
    bit perf;
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer cyc;
    always @(posedge clk) cyc <= cyc + 1;

    string op_name [0:3] = '{"KeyGen", "Encaps", "Decaps", "Bad"};
    string set_name [0:3] = '{"ML-KEM-512 ", "ML-KEM-768 ", "ML-KEM-1024", "Bad        "};

    // Per-request state shared by the stream tasks (no ref ports, so the bench
    // also runs on simulators without reference-port support).
    bit stop;
    integer errors;
    integer got;

    function automatic bit stall();
        return !perf && (($urandom % 100) < stall_pct);
    endfunction

    // Drives the input packet; trunc_at >= 0 asserts TLAST early on that word.
    task automatic drive_input(input integer base, input integer nwords, input integer trunc_at);
        integer w;
        w = 0;
        while (w < nwords && !stop) begin
            if (stall()) begin
                s_tvalid <= 1'b0;
                @(posedge clk);
            end else begin
                s_tvalid <= 1'b1;
                s_tdata <= in_mem[base + w];
                s_tkeep <= 8'hFF;
                s_tlast <= (w == nwords - 1) || (w == trunc_at);
                @(posedge clk);
                while (!s_tready && !stop) @(posedge clk);
                if (w == trunc_at) begin
                    s_tvalid <= 1'b0;
                    s_tlast <= 1'b0;
                    return;
                end
                w = w + 1;
            end
        end
        s_tvalid <= 1'b0;
        s_tlast <= 1'b0;
    endtask

    task automatic check_output(input integer base, input integer nwords);
        got = 0;
        while (!stop) begin
            m_tready <= !stall();
            @(posedge clk);
            if (m_tvalid && m_tready) begin
                if (got >= nwords) begin
                    errors = errors + 1;
                    if (errors < 4) $display("    extra output word %0d: %016h", got, m_tdata);
                end else begin
                    if (m_tdata !== out_mem[base + got] || m_tkeep !== 8'hFF ||
                        m_tlast !== (got == nwords - 1)) begin
                        errors = errors + 1;
                        if (errors < 4)
                            $display("    word %0d: got %016h last=%0b exp %016h", got, m_tdata, m_tlast,
                                     out_mem[base + got]);
                    end
                end
                got = got + 1;
            end
        end
        m_tready <= 1'b0;
    endtask

    task automatic run_case(input string name, input integer c_op, input integer c_set,
                            input integer exp_err, input integer sbase, input integer ibase,
                            input integer nin, input integer obase, input integer nout,
                            input integer trunc_at, input integer abort_after);
        integer t0, t1, i;
        bit got_done, got_err;
        integer code;
        stop = 0;
        errors = 0;
        got = 0;
        while (!ready) @(posedge clk);
        op <= c_op[1:0];
        pset <= c_set[1:0];
        for (i = 0; i < 8; i = i + 1)
            seed[64*i +: 64] <= seeds[sbase + i];
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        t0 = cyc;
        got_done = 0;
        got_err = 0;
        code = 0;
        fork
            begin
                if (nin > 0) drive_input(ibase, nin, trunc_at);
            end
            begin
                check_output(obase, nout);
            end
            begin
                if (abort_after > 0) begin
                    repeat (abort_after) @(posedge clk);
                    abort <= 1'b1;
                    @(posedge clk);
                    abort <= 1'b0;
                end
            end
            begin
                while (!done && !error && (cyc - t0) < TIMEOUT) @(posedge clk);
                got_done = done;
                got_err = error;
                code = err_code;
                t1 = cyc;
                @(posedge clk);
                stop = 1;
            end
        join
        if (!got_done && !got_err) errors = errors + 1;
        if (exp_err == 0) begin
            if (!got_done || got != nout) errors = errors + 1;
        end else begin
            if (!got_err || code != exp_err) errors = errors + 1;
        end
        if (errors == 0) begin
            pass_cnt = pass_cnt + 1;
            $display("PASS %-40s cycles=%0d", name, t1 - t0);
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("FAIL %-40s done=%0b err=%0b code=%0d words=%0d/%0d errors=%0d cycles=%0d",
                     name, got_done, got_err, code, got, nout, errors, t1 - t0);
        end
        repeat (3) @(posedge clk);
    endtask

    integer c, ib, ob, nin, nout, c_op, c_set, c_err;
    integer first_enc_ib, first_enc_nin, first_enc_set, first_enc_sb;
    initial begin
        string tag;
        string vec;
        if (!$value$plusargs("VEC=%s", vec)) vec = "vector";
        if (!$value$plusargs("STALL=%d", stall_pct)) stall_pct = 30;
        if (!$value$plusargs("SEED=%d", rnd_seed)) rnd_seed = 1;
        perf = $test$plusargs("PERF");
        void'($urandom(rnd_seed));
        cyc = 0;
        for (c = 0; c < MAX_CASES; c = c + 1) hdr[c] = 64'hFFFF_FFFF_FFFF_FFFF;
        $readmemh({vec, "/tv_hdr.mem"}, hdr);
        $readmemh({vec, "/tv_seed.mem"}, seeds);
        $readmemh({vec, "/tv_in.mem"}, in_mem);
        $readmemh({vec, "/tv_out.mem"}, out_mem);
        n_cases = 0;
        while (n_cases < MAX_CASES && hdr[n_cases] !== 64'hFFFF_FFFF_FFFF_FFFF && hdr[n_cases] !== 64'bx)
            n_cases = n_cases + 1;
        if (n_cases == 0) begin
            $display("FAIL: no vector cases found in %0s (run from the repository root or pass +VEC=<dir>)", vec);
            $finish;
        end
        if (perf)
            $display("Loaded %0d vector cases, always-ready streams", n_cases);
        else
            $display("Loaded %0d vector cases, stall %0d%%", n_cases, stall_pct);

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        repeat (5) @(posedge clk);

        ib = 0;
        ob = 0;
        first_enc_nin = -1;
        for (c = 0; c < n_cases; c = c + 1) begin
            c_op = hdr[c][63:56];
            c_set = hdr[c][55:48];
            c_err = hdr[c][47:40];
            nin = hdr[c][39:20];
            nout = hdr[c][19:0];
            if (c_err != 0)
                tag = $sformatf("%0d %s %s (expect error %0d)", c, set_name[c_set], op_name[c_op], c_err);
            else
                tag = $sformatf("%0d %s %s", c, set_name[c_set], op_name[c_op]);
            run_case(tag, c_op, c_set, c_err, 8 * c, ib, nin, ob, nout, -1, 0);
            if (c_op == 1 && c_err == 0 && first_enc_nin < 0) begin
                first_enc_ib = ib;
                first_enc_nin = nin;
                first_enc_set = c_set;
                first_enc_sb = 8 * c;
            end
            ib = ib + nin;
            ob = ob + nout;
        end

        if (first_enc_nin > 0) begin
            run_case("framing: early TLAST", 1, first_enc_set, 2, first_enc_sb, first_enc_ib,
                     first_enc_nin, 0, 0, first_enc_nin / 2, 0);
            run_case("abort during Encaps", 1, first_enc_set, 6, first_enc_sb, first_enc_ib,
                     first_enc_nin, 0, 0, -1, 1500);
        end
        run_case("invalid configuration", 3, 0, 1, 0, 0, 0, 0, 0, -1, 0);

        // Recovery: the first vectors must still pass after the error cases.
        ib = 0;
        ob = 0;
        for (c = 0; c < n_cases && c < 3; c = c + 1) begin
            nin = hdr[c][39:20];
            nout = hdr[c][19:0];
            run_case($sformatf("recovery %0d %s %s", c, set_name[hdr[c][55:48]], op_name[hdr[c][63:56]]),
                     hdr[c][63:56], hdr[c][55:48], hdr[c][47:40], 8 * c, ib, nin, ob, nout, -1, 0);
            ib = ib + nin;
            ob = ob + nout;
        end

        $display("RESULT: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** TESTS FAILED ***");
        $finish;
    end

endmodule
