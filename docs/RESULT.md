# ML-KEM accelerator IP implementation results

This document lists the synthesis and implementation results of the IP
specified in [SPEC.md](SPEC.md).

Standalone IP: the Vivado project is `project/mlkem_top`, and its synthesis
top is `mlkem_axi`, which instantiates the native `mlkem_core`, nine
`ntt_core_top` and one `keccak_top`. The results include the AXI wrapper. The
build uses K26 `xck26-sfvc784-2LV-c` (KV260), out of context, a 4 ns clock
([`mlkem.xdc`](../constraint/mlkem.xdc)), and Vivado 2025.2.1 default synthesis
and implementation strategies. Synthesis limits block RAM, UltraRAM and DSP to
zero; the RTL also infers none without the limit.

| LUT | LUTRAM | SRL | FF | BRAM | URAM | DSP | WNS | WHS | Failing endpoints |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 40,323 | 4,762 | 825 | 25,091 | 0 | 0 | 0 | +0.276 ns | +0.036 ns | 0 of 96,831 |

Resource counts are taken from the routed design: 34,736 LUTs are logic, 5,587
are memory (4,762 distributed RAM, 825 shift registers); the design uses
1,384 CARRY8, 534 F7 and 60 F8 muxes. From the routed WNS the estimated Fmax is
`1000 / (4.000 - 0.276)`, about 268 MHz. Vivado's vectorless power estimate is
1.51 W (1.22 W dynamic, 0.29 W static, default activity); it is an estimate,
not a measurement. The run reports no critical warning.

Cycles from `start` to `done` (always-ready streams, including secret
clearing) and latency at the 250 MHz constraint:

| Parameter set | KeyGen | Encaps | Decaps |
| --- | ---: | ---: | ---: |
| ML-KEM-512 | 1,900 (7.6 µs) | 3,023 (12.1 µs) | 5,707 (22.8 µs) |
| ML-KEM-768 | 2,014 (8.1 µs) | 3,142 (12.6 µs) | 5,849 (23.4 µs) |
| ML-KEM-1024 | 2,198 (8.8 µs) | 3,365 (13.5 µs) | 6,157 (24.6 µs) |

## Critical paths

The three slowest path groups of the routed design are dominated by routing,
not by logic depth:

| Slack | Path | Logic levels | Route share |
| ---: | --- | ---: | ---: |
| +0.276 ns | parameter-set register `k_r` → PMAC readiness (`rdyn_q`) | 2 | 87 % |
| +0.316 ns | lane load counter → buffer read → coefficient select (`l1_raw`) | 5 | 76 % |
| +0.317 ns | `kill` → global buffer → synchronous reset of the NTT controllers | 2 | 92 % |

The first and third are high-fanout control nets (a constant during a request
and the abort/reset); local copies per engine would shorten them. They were
not changed after this run, so the numbers above belong to the RTL in this
repository.

## Changes from the previous revision

The previous measured revision was `mlkem_core` alone (without the AXI
wrapper) on the same device and constraint: WNS +0.031 ns, 42,079 LUT (4,754
LUTRAM), 27,013 FF, 0 BRAM / URAM / DSP, and 3,621 / 6,669 cycles for
ML-KEM-1024 Encaps / Decaps. On Artix-7 `xc7a100tcsg324-1` it reached about
150 MHz (WNS −1.689 ns at 5 ns); the Artix-7 build has not been repeated.

Each change below came from a critical-path report of that revision or from
the post-synthesis estimate of the new RTL. None adds a pipeline stage; cycle
counts changed only through the removed INTT scale pass (−256 cycles per
INTT) and by one cycle in the Decaps wrong-`H(ek)` error case.

| Path (device) | Cause | Change |
| --- | --- | --- |
| PMAC accumulator (K26 worst, +0.031 ns) | first-term select in front of the 28-bit adder, its control flip-flop shared by all lanes | the accumulator is cleared by the last term; enable/clear strobes are registered per lane (`mlkem_basemul_lane`) |
| NTT multiplier product (K26 second, Artix-7 worst after synthesis) | 12 × 12 product as a five-level carry-save tree in one stage | radix-4 product: `3·b` is formed in the operand stage, six partial products, two adder levels (`ntt_mod_mul_12b`) |
| NTT RAM ports (Artix-7 worst, −1.689 ns) | port select from a 10-input OR of the busy flags | one registered busy flag (`ntt_core_top`) |
| NTT address generator (Artix-7) | `block_idx · 2·len` as a multiplier | shift selected by the one-hot `len` (`ntt_agu`) |
| FIFO → Keccak message block (Artix-7) | FIFO read drove the enables and data of 1,344 flip-flops | the taken word waits one cycle in a 64-bit register (`mlkem_hash`) |
| Input unpacker handshake (Artix-7) | block-fit compare → offset add → word count → ready → window muxes | ready from registers, insert-then-shift window, registered segment flags (`mlkem_unpack`, `mlkem_in`) |
| H(ek) check (Artix-7) | 256-bit compare from the Keccak state in one cycle | four 64-bit compares, then the verdict (one cycle later, error case only) |
| u / v decompression, CBD select (Artix-7) | variable shift by `d`; FSM decode in front of the CBD stream | two-way select per parameter set; one-hot lane FSM with a registered `eta` select (`mlkem_lane`) |
| NTT RAM write select (post-synthesis worst of the new RTL) | address FIFO read → 8-bit parity → bank select, seven logic levels | the bank bit is stored in the address FIFO with the address (`ntt_core_top`, `ntt_ram_dual`) |
| Tap FIFO full → output engine | pointer compare in front of the stream handshakes | registered "one word left" flag (`mlkem_fifo`) |
| NTT twiddle ROM | the registered address let synthesis pull the table into a RAMB18 per lane | explicit LUT ROM, `rom_style = "distributed"` (`ntt_twiddle_rom`) |

The NTT IP changes keep the IP's default behaviour: the edited core was
checked cycle by cycle against the released version, the multiplier (all 2^24
operand pairs) and the address generator exhaustively, and the IP's own
testbench passes (23 / 23 NTT, 23 / 23 INTT, 23 / 23 round trips).
