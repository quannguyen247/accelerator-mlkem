`timescale 1ns / 1ps

// Montgomery reduction, R = 2^16: r = t * R^-1 mod q for t < q * R.
// Four registered stages; the result is canonical.
module mlkem_montred (
    input wire clk,
    input wire [27:0] t,
    output reg [11:0] r
);

    wire [15:0] lo = t[15:0];
    // m = t * 3327 mod 2^16, 3327 = 2^12 - 2^9 - 2^8 - 1
    wire [15:0] m_c = (lo << 12) - (lo << 9) - (lo << 8) - lo;

    reg [27:0] t1;
    reg [15:0] m1;
    reg [28:0] s2a;
    reg [28:0] s2b;
    reg [12:0] u3;

    always @(posedge clk) begin
        t1 <= t;
        m1 <= m_c;
        // m * 3329 = (m << 11) + (m << 10) + (m << 8) + m
        s2a <= ({13'd0, m1} << 11) + ({13'd0, m1} << 10);
        s2b <= ({13'd0, m1} << 8) + {13'd0, m1} + {1'b0, t1};
        u3 <= (s2a + s2b) >> 16;
        r <= (u3 >= 13'd3329) ? u3 - 13'd3329 : u3[11:0];
    end

endmodule
