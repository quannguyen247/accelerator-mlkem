`ifndef MLKEM_DEFS_VH
`define MLKEM_DEFS_VH

`define MLKEM_Q 12'd3329

`define MLKEM_OP_KEYGEN 2'd0
`define MLKEM_OP_ENCAPS 2'd1
`define MLKEM_OP_DECAPS 2'd2

`define MLKEM_ERR_NONE   3'd0
`define MLKEM_ERR_CONFIG 3'd1
`define MLKEM_ERR_FRAME  3'd2
`define MLKEM_ERR_KEY    3'd3
`define MLKEM_ERR_ABORT  3'd6

// Keccak IP mode encodings (keccak_defs.vh)
`define MLKEM_KMODE_SHAKE128 2'd0
`define MLKEM_KMODE_SHAKE256 2'd1
`define MLKEM_KMODE_SHA3_256 2'd2
`define MLKEM_KMODE_SHA3_512 2'd3

// NTT lane load sources
`define MLKEM_LD_CBD 2'd0
`define MLKEM_LD_DEC 2'd1
`define MLKEM_LD_BUF 2'd2

// NTT lane unload destinations
`define MLKEM_UL_BUF  2'd0
`define MLKEM_UL_POSU 2'd1
`define MLKEM_UL_POSV 2'd2
`define MLKEM_UL_POSW 2'd3

// PMAC job kinds
`define MLKEM_PJ_KG  2'd0
`define MLKEM_PJ_ENC 2'd1
`define MLKEM_PJ_DEC 2'd2

// Polynomial matrix sources of the PMAC
`define MLKEM_MS_A 2'd0
`define MLKEM_MS_S 2'd1
`define MLKEM_MS_T 2'd2

`endif
