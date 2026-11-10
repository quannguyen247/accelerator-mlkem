`timescale 1ns / 1ps

// Basemul twiddles of one 8-coefficient block: {g(4b+3), g(4b+2), g(4b+1), g(4b)},
// g(i) = gamma_i * 2^16 mod q. Kept in LUTs (the IP uses no block RAM).
module mlkem_gamma_rom (
    input wire [4:0] blk,
    output wire [47:0] g
);

    `include "mlkem_funcs.vh"

    (* rom_style = "distributed" *) reg [47:0] rom [0:31];
    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1)
            rom[i] = {mlkem_gamma_r(4 * i + 3), mlkem_gamma_r(4 * i + 2),
                      mlkem_gamma_r(4 * i + 1), mlkem_gamma_r(4 * i)};
    end

    assign g = rom[blk];

endmodule
