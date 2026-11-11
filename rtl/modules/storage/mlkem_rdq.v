`timescale 1ns / 1ps

// Two-entry queue behind a RAM read with one cycle of latency: a read issued
// in one cycle (issue) delivers its word (din) in the next. can_issue leaves
// room for that word. The entries load through their clock enables, so
// nothing sits between the RAM output and the registers; zero (given with
// din) clears the low ZW bits of the entry through its synchronous reset.
// The head is selected at the output.
module mlkem_rdq #(
    parameter W = 64,
    parameter ZW = 64
)(
    input wire clk,
    input wire clr,
    input wire issue,
    input wire [W-1:0] din,
    input wire zero,
    output wire can_issue,
    output wire idle,               // empty and no word on the way
    output wire valid,
    output wire [W-1:0] dout,
    input wire pop
);

    reg [W-1:0] e0, e1;
    reg [1:0] cnt;
    reg wp, rp;
    reg infl;                       // the word of the previous issue arrives

    wire do_pop = pop && (cnt != 2'd0);

    assign valid = (cnt != 2'd0);
    assign idle = (cnt == 2'd0) && !infl;
    assign dout = rp ? e1 : e0;
    // After this cycle cnt + infl - do_pop words are held; one more may follow.
    assign can_issue = ({1'b0, cnt} + {2'd0, infl}) <= (do_pop ? 3'd2 : 3'd1);

    always @(posedge clk) begin
        if (clr) begin
            cnt <= 2'd0;
            wp <= 1'b0;
            rp <= 1'b0;
            infl <= 1'b0;
        end else begin
            infl <= issue;
            if (infl)
                wp <= !wp;
            if (do_pop)
                rp <= !rp;
            cnt <= cnt + {1'b0, infl} - {1'b0, do_pop};
        end
    end

    always @(posedge clk) begin
        if (infl && !wp)
            e0[ZW-1:0] <= zero ? {ZW{1'b0}} : din[ZW-1:0];
        if (infl && wp)
            e1[ZW-1:0] <= zero ? {ZW{1'b0}} : din[ZW-1:0];
    end

    generate
        if (W > ZW) begin : g_meta
            always @(posedge clk) begin
                if (infl && !wp)
                    e0[W-1:ZW] <= din[W-1:ZW];
                if (infl && wp)
                    e1[W-1:ZW] <= din[W-1:ZW];
            end
        end
    endgenerate

endmodule
