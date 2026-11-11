`timescale 1ns / 1ps

// Two-entry register slice (skid buffer): full throughput, and both READY
// towards the source and VALID/DATA towards the sink come from registers.
// s_allow gates acceptance (the source side may only fill the slice while a
// transfer is expected).
module mlkem_axis_slice #(
    parameter W = 73
)(
    input wire clk,
    input wire rst_n,
    input wire clr,
    input wire s_allow,
    input wire s_valid,
    input wire [W-1:0] s_data,
    output wire s_ready,
    output wire m_valid,
    output wire [W-1:0] m_data,
    input wire m_ready
);

    reg [W-1:0] d0, d1;
    reg v0, v1;

    assign s_ready = !v1 && s_allow;
    assign m_valid = v0;
    assign m_data = d0;

    wire s_fire = s_valid && s_ready;
    wire m_fire = v0 && m_ready;

    // Valid flags
    always @(posedge clk) begin
        if (!rst_n || clr) begin
            v0 <= 1'b0;
            v1 <= 1'b0;
        end else begin
            case ({s_fire, m_fire})
                2'b10: begin
                    if (!v0)
                        v0 <= 1'b1;
                    else
                        v1 <= 1'b1;
                end
                2'b01: begin
                    if (v1)
                        v1 <= 1'b0;
                    else
                        v0 <= 1'b0;
                end
                default: ;
            endcase
        end
    end

    // Data registers: no reset, so clr stays off their enables. The head
    // takes the skid entry when it leaves, else an accepted word when it is
    // empty or leaves; the skid entry takes every accepted word.
    always @(posedge clk) begin
        if (m_fire && v1)
            d0 <= d1;
        else if (s_fire && (!v0 || m_fire))
            d0 <= s_data;
        if (s_fire)
            d1 <= s_data;
    end

endmodule
