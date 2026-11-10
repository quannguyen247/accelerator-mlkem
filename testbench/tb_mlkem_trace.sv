`timescale 1ns / 1ps

// Simulation-only timeline of the engines inside mlkem_core (+TRACE).
// Prints, per request, when each engine phase starts and ends so the
// critical path and idle resources can be read off directly.
module tb_mlkem_trace;

    bit en;
    initial en = $test$plusargs("TRACE");

    wire clk = tb_mlkem_core.clk;
    integer t;
    integer t0;
    string names [0:6] = '{"G", "H", "J", "PRF", "XOF", "WIPE", "END"};

    // Keccak engine
    reg [2:0] hs_q;
    integer kbusy;
    integer job_t0;
    integer xof_t0, xof_n;
    always @(posedge clk) begin
        t = tb_mlkem_core.cyc;
        if (tb_mlkem_core.dut.go) begin
            t0 = t;
            kbusy = 0;
            xof_n = 0;
        end
        if (tb_mlkem_core.dut.u_hash.u_keccak.u_sponge.curr_state != 6'b000001)
            kbusy = kbusy + 1;
        if (en) begin
            if (tb_mlkem_core.dut.u_hash.state == 3'd2 && hs_q != 3'd2)
                job_t0 = t;
            if (tb_mlkem_core.dut.u_hash.state == 3'd4 && tb_mlkem_core.dut.u_hash.k_done) begin
                if (tb_mlkem_core.dut.u_hash.jtype == 3'd4) begin
                    if (xof_n == 0) xof_t0 = job_t0;
                    xof_n = xof_n + 1;
                    if (xof_n == tb_mlkem_core.dut.k_r * tb_mlkem_core.dut.k_r)
                        $display("      [%5d..%5d] keccak XOF x%0d", xof_t0 - t0, t - t0, xof_n);
                end else begin
                    $display("      [%5d..%5d] keccak %s", job_t0 - t0, t - t0,
                             names[tb_mlkem_core.dut.u_hash.jtype]);
                end
            end
        end
        hs_q <= tb_mlkem_core.dut.u_hash.state;
    end

    // NTT lanes
    genvar g;
    generate
        for (g = 0; g < 9; g = g + 1) begin : g_l
            reg [3:0] q;
            integer tl, tr, tu;
            always @(posedge clk) begin
                if (en) begin
                    if (tb_mlkem_core.dut.g_lane[g].u_lane.state == 4'd2 && q != 4'd2) tl = t;
                    if (tb_mlkem_core.dut.g_lane[g].u_lane.state == 4'd4 && q != 4'd4) tr = t;
                    if (tb_mlkem_core.dut.g_lane[g].u_lane.state == 4'd6 && q != 4'd6) tu = t;
                    if (tb_mlkem_core.dut.g_lane[g].u_lane.state == 4'd7 && q != 4'd7)
                        $display("      lane %0d %s load %5d-%5d  transform %5d-%5d  unload %5d-%5d", g,
                                 tb_mlkem_core.dut.g_lane[g].u_lane.jd_mode ? "INTT" : "NTT ",
                                 tl - t0, tr - t0, tr - t0, tu - t0, tu - t0, t - t0);
                end
                q <= tb_mlkem_core.dut.g_lane[g].u_lane.state;
            end
        end
    endgenerate

    // Multiply-accumulate unit
    reg pbusy_q;
    integer p_first, p_last, p_issue, p_wait;
    always @(posedge clk) begin
        if (tb_mlkem_core.dut.go) begin
            p_first = -1;
            p_issue = 0;
            p_wait = 0;
        end
        if (tb_mlkem_core.dut.u_pmac.issue) begin
            if (p_first < 0) p_first = t;
            p_last = t;
            p_issue = p_issue + 1;
        end else if (p_first >= 0 && tb_mlkem_core.dut.u_pmac.running) begin
            p_wait = p_wait + 1;
        end
        if (en && pbusy_q && !tb_mlkem_core.dut.u_pmac.busy && p_first >= 0) begin
            $display("      [%5d..%5d] pmac steps=%0d  operand waits after first step=%0d", p_first - t0,
                     p_last - t0, p_issue, p_wait);
            p_first = -1;
            p_issue = 0;
            p_wait = 0;
        end
        pbusy_q <= tb_mlkem_core.dut.u_pmac.busy;
    end

    // Streams
    integer i_first, i_last, o_first, o_last;
    always @(posedge clk) begin
        if (tb_mlkem_core.dut.go) begin
            i_first = -1;
            o_first = -1;
        end
        if (tb_mlkem_core.s_tvalid && tb_mlkem_core.s_tready) begin
            if (i_first < 0) i_first = t;
            i_last = t;
        end
        if (tb_mlkem_core.m_tvalid && tb_mlkem_core.m_tready) begin
            if (o_first < 0) o_first = t;
            o_last = t;
        end
        if (en && (tb_mlkem_core.done || tb_mlkem_core.error)) begin
            if (i_first >= 0) $display("      [%5d..%5d] input stream", i_first - t0, i_last - t0);
            if (o_first >= 0) $display("      [%5d..%5d] output stream", o_first - t0, o_last - t0);
            $display("      keccak busy %0d of %0d cycles", kbusy, t - t0);
        end
    end

endmodule
