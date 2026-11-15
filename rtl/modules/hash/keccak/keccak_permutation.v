`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_permutation (
    input wire clk,
    input wire rst_n,
    input wire clear,
    input wire in_valid,
    input wire xor_only,                 // XOR the enabled lanes without starting
    // Lanes of xor_in XORed into the state with in_valid. The enable acts on
    // the register enables, so a state bit's input is the round output or
    // the bit XOR its block bit, nothing else.
    input wire [`KECCAK_NUM_LANES-1:0] xor_lane_en,
    input wire [`KECCAK_STATE_WIDTH-1:0] xor_in,
    output wire last_round,
    output reg [`KECCAK_STATE_WIDTH-1:0] state_out
);

    `include "keccak_funcs.vh"

    localparam ST_IDLE = 2'b01;
    localparam ST_ROUND = 2'b10;

    // Round counter, round datapath and FSM
    reg [4:0] round_ctr;
    wire [`KECCAK_STATE_WIDTH-1:0] trp_out;
    wire [`KECCAK_STATE_WIDTH-1:0] round_out;
    reg [1:0] curr_state, next_state;

    // Determine if the current round is the last round
    assign last_round = (curr_state == ST_ROUND) && (round_ctr == (`KECCAK_NUM_ROUNDS - 1));

    keccak_theta_rho_pi u_trp (
        .state_in(state_out),
        .state_out(trp_out)
    );

    keccak_chi_iota u_ci (
        .state_in(trp_out),
        .round_const(round_constant(round_ctr)),
        .state_out(round_out)
    );

    always @(*) begin
        next_state = curr_state;
        case (curr_state)
            ST_IDLE: if (in_valid) next_state = ST_ROUND;
            ST_ROUND: next_state = last_round ? ST_IDLE : ST_ROUND;
            default: next_state = ST_IDLE;
        endcase
    end

    wire idle = (curr_state == ST_IDLE);

    always @(posedge clk) begin
        if (!rst_n) begin
            curr_state <= ST_IDLE;
        end else begin
            curr_state <= next_state;
            if (idle ? in_valid : !last_round)
                round_ctr <= idle ? 5'd0 : round_ctr + 5'd1;
        end
    end

    // State. A bit's input is the round output (rounds) or the bit XOR its
    // block bit (idle: a block, in_valid, which starts the rounds, or a single
    // word, xor_only, into the enabled lanes), so the round logic and the
    // input share one LUT. The reset and clear (the sponge is idle, never with
    // a block or a word) act on the register reset, the lane enables on the
    // register enables.
    wire take = in_valid || xor_only;
    // Kept as one net per bit: the sponge's input select stays in its own
    // LUT and the state bit's LUT sees a single input bit (with the three
    // chi operands, the state bit and idle: six inputs).
    (* keep = "true" *) wire [`KECCAK_STATE_WIDTH-1:0] xin = xor_in;
    integer l;
    always @(posedge clk) begin
        for (l = 0; l < `KECCAK_NUM_LANES; l = l + 1) begin
            if (!rst_n || (idle && clear))
                state_out[64*l +: 64] <= 64'd0;
            else if (!idle || (take && xor_lane_en[l]))
                state_out[64*l +: 64] <= idle ? (state_out[64*l +: 64] ^ xin[64*l +: 64]) :
                                                round_out[64*l +: 64];
        end
    end

endmodule


module keccak_theta_rho_pi (
    input wire [`KECCAK_STATE_WIDTH-1:0] state_in,
    output reg [`KECCAK_STATE_WIDTH-1:0] state_out
);

    `include "keccak_funcs.vh"

    // Variables for the Theta, Rho and Pi steps
    reg [63:0] A [0:`KECCAK_NUM_LANES-1];
    reg [63:0] B [0:`KECCAK_NUM_LANES-1];
    reg [63:0] C [0:4];
    reg [63:0] D [0:4];
    integer x, y, i;

    always @(*) begin
        // A[x,y] = state[64*(x+5y) +: 64] (Load lanes)
        for (i = 0; i < `KECCAK_NUM_LANES; i = i + 1) begin
            A[i] = state_in[(i * 64) +: 64];
        end

        // C[x] = A[x,0] ^ A[x,1] ^ A[x,2] ^ A[x,3] ^ A[x,4] (Theta)
        for (x = 0; x < 5; x = x + 1) begin
            C[x] = A[x] ^ A[x + 5] ^ A[x + 10] ^ A[x + 15] ^ A[x + 20];
        end

        // D[x] = C[x-1] ^ ROT(C[x+1], 1)
        for (x = 0; x < 5; x = x + 1) begin
            D[x] = C[(x + 4) % 5] ^ rotl64(C[(x + 1) % 5], 6'd1);
        end

        // A'[x,y] = A[x,y] ^ D[x]
        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                A[x + (5 * y)] = A[x + (5 * y)] ^ D[x];
            end
        end

        // A''[x,y] = ROT(A'[x,y], r[x,y]) (Rho)
        for (i = 0; i < `KECCAK_NUM_LANES; i = i + 1) begin
            A[i] = rotl64(A[i], rho_offset(i[4:0]));
        end

        // B[y,2x+3y] = A''[x,y] (Pi)
        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                i = ((x + 3 * y) % 5) + 5 * x;
                B[x + (5 * y)] = A[i];
            end
        end

        for (i = 0; i < `KECCAK_NUM_LANES; i = i + 1) begin
            state_out[(i * 64) +: 64] = B[i];
        end
    end

endmodule


module keccak_chi_iota (
    input wire [`KECCAK_STATE_WIDTH-1:0] state_in,
    input wire [63:0] round_const,
    output reg [`KECCAK_STATE_WIDTH-1:0] state_out
);

    // Variables for the Chi and Iota steps
    reg [63:0] A [0:`KECCAK_NUM_LANES-1];
    reg [63:0] B [0:`KECCAK_NUM_LANES-1];
    integer x, y, i;

    always @(*) begin
        for (i = 0; i < `KECCAK_NUM_LANES; i = i + 1) begin
            B[i] = state_in[(i * 64) +: 64];
        end

        // A'''[x,y] = B[x,y] ^ ((~B[x+1,y]) & B[x+2,y]) (Chi), with
        // A''''[0,0] = A'''[0,0] ^ RC[r] (Iota) applied to the own operand of
        // lane 0 (XOR is linear), so the constant joins the theta LUT.
        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                A[x + (5 * y)] = ((x + 5 * y == 0) ? (B[0] ^ round_const) : B[x + (5 * y)]) ^
                                 ((~B[((x + 1) % 5) + (5 * y)]) & B[((x + 2) % 5) + (5 * y)]);
            end
        end
        for (i = 0; i < `KECCAK_NUM_LANES; i = i + 1) begin
            state_out[(i * 64) +: 64] = A[i];
        end
    end

endmodule
