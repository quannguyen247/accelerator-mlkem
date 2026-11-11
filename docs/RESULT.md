# ML-KEM accelerator IP implementation results

This document lists the synthesis and implementation results of the IP
specified in [SPEC.md](SPEC.md) and compares them with the published ML-KEM
hardware that reports a complete set of FPGA figures on the same device.

## Build

Standalone IP: the Vivado project is `project/mlkem_top` (`make project`,
`make impl`), and its synthesis top is `mlkem_axi`, which instantiates the
native `mlkem_core` (nine `ntt_core_top`, one Keccak sponge) and the
request/result buffer `mlkem_iobuf`. The results include both AXI slaves
(AXI4-Lite registers, AXI4 buffer).

| Item | Setting |
| --- | --- |
| Device | Artix-7 XC7A200T-3 (`xc7a200tfbg676-3`) |
| Tool | AMD Vivado 2025.2.1, default synthesis and implementation strategies |
| Context | out of context ([`mlkem_ooc.xdc`](../constraint/mlkem_ooc.xdc)): clock source `BUFGCTRL_X0Y16`, so clock delay and skew are timed; partition pins of the other ports in `SLICE_X60Y110:SLICE_X100Y140`, so every port net is routed |
| Clock | 4.4 ns, 227.3 MHz ([`mlkem.xdc`](../constraint/mlkem.xdc)) |
| Hard macros | synthesis limits block RAM, UltraRAM and DSP to zero; the RTL infers none without the limit |

The device follows the comparison paper below: Ni et al. [15] report their
ML-KEM accelerator on Artix-7 XC7A200T-3.

## Results (routed design)

| LUT | LUT as logic | LUTRAM | SRL | FF | Slices | BRAM | DSP | WNS | WHS | Failing endpoints |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 40,304 | 32,921 | 6,574 | 809 | 29,330 | 12,010 | 0 | 0 | +0.135 ns | +0.054 ns | 0 of 123,718 |

The design also uses 2,813 CARRY4, 875 F7 and 220 F8 muxes. From the routed
WNS the estimated Fmax is `1000 / (4.400 - 0.135)`, about 234 MHz. Vivado's
vectorless power estimate (resets released, default activity otherwise) is
2.07 W: 1.94 W dynamic and 0.13 W static. It is an estimate, not a
measurement.

Against the AXI4-Stream revision (39,462 LUT, 5,934 LUTRAM, 29,549 FF,
11,933 slices, WNS +0.058 ns) the memory-mapped interface costs 842 LUTs
(640 of them the buffer's LUTRAM) and 77 slices and saves 219 flip-flops.

Resources by block (routed):

| Block | LUT | LUTRAM | FF |
| --- | ---: | ---: | ---: |
| `u_pmac` (8 + 8 basemul lanes, operand pipeline) | 10,316 | 0 | 9,054 |
| `u_hash` (Keccak sponge, job list, block assembly) | 7,012 | 0 | 6,090 |
| `g_lane[0..3]` (vector lanes, each) | 1,305 – 1,331 | 294 | about 900 |
| `g_lane[4..7]` (row lanes, each) | 1,638 – 1,680 | 358 | about 1,090 |
| `g_lane[8]` (scalar lane) | 1,810 | 294 | 1,139 |
| `u_in`, `u_out` (input and output engines) | 1,800, 1,594 | 0 | 1,387, 1,322 |
| `u_sampler` (SampleNTT, matrix store) ¹ | 1,758 | 1,024 | 782 |
| `u_buf` (request/result buffer and its AXI4 slave) | 1,159 | 640 | 448 |
| `u_fifo` (tap FIFO) | 457 | 344 | 100 |

¹ Synthesis moves the 1,024 LUTRAM of the matrix store to the top level of
the netlist hierarchy; they are counted here.

## Cycles and latency

Cycles from the START register write to DONE (IP top, `make test-axi`) and
latency at 227.3 MHz. They include reading the request from the IP buffer
and writing the result into it at one 64-bit word per cycle, and the secret
clearing; the native core alone (`make perf`, `start` to `done`) takes two
cycles less.

| Parameter set | KeyGen | Encaps | Decaps |
| --- | ---: | ---: | ---: |
| ML-KEM-512 | 1,907 (8.4 µs) | 3,039 (13.4 µs) | 5,731 (25.2 µs) |
| ML-KEM-768 | 2,021 (8.9 µs) | 3,158 (13.9 µs) | 5,873 (25.8 µs) |
| ML-KEM-1024 | 2,215 (9.7 µs) | 3,376 (14.9 µs) | 6,181 (27.2 µs) |

Outside this window the host copies the request into the buffer before START
and the result out of it after DONE (up to 592 beats each way: the
ML-KEM-1024 Decaps request and KeyGen result), and ACK wipes the buffer in
592 cycles before READY returns. One request runs at a time, so the latency
bounds the throughput (about 103,000 ML-KEM-1024 KeyGen per second); with
the result copy at one beat per cycle and the wipe, a back-to-back KeyGen
takes about 3,400 cycles (about 67,000 per second).

## Comparison

Reference: Z. Ni, A. Khalid, W. Liu and M. O'Neill, "A Highly Hardware
Efficient ML-KEM Accelerator with Optimised Architectural Layers", ACM TECS
24(2), 2025, [doi:10.1145/3708469](https://doi.org/10.1145/3708469)
(`ref/15_hardware_efficient_mlkem.pdf`, Table 9, post-PAR, Vivado 2020.1,
Artix-7 XC7A200T-3). Among the collected papers it is the FIPS 203 ML-KEM
accelerator with the most complete figures on this device: LUT, FF, DSP,
BRAM, slices, frequency, cycles and time of all three operations for all
three parameter sets, area-time product and a power estimate. Its LUT and FF
are the server-side build (all three operations).

ENS (equivalent number of slices) = slices + 100 DSP + 200 BRAM, and
AT = ENS × (KeyGen + Encaps + Decaps time in ms), as defined in [15].

| Set | Design | LUT | FF | DSP | BRAM | ENS | MHz | KeyGen / Encaps / Decaps (µs) | Total (µs) | AT |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| 512 | [15] | 10,076 | 8,227 | 4 | 0 | 3,447 | 270 | 6.7 / 9.9 / 13.7 | 30.2 | 104.1 |
| 512 | this work | 40,304 | 29,330 | 0 | 0 | 12,010 | 227 | 8.4 / 13.4 / 25.2 | 47.0 | 564 |
| 768 | [15] | 10,781 | 8,299 | 4 | 0 | 3,560 | 270 | 12.3 / 15.5 / 20.0 | 47.8 | 170.2 |
| 768 | this work | 40,304 | 29,330 | 0 | 0 | 12,010 | 227 | 8.9 / 13.9 / 25.8 | 48.6 | 584 |
| 1024 | [15] | 11,639 | 8,893 | 4 | 0 | 3,818 | 263 | 19.3 / 22.6 / 28.7 | 70.8 | 270.3 |
| 1024 | this work | 40,304 | 29,330 | 0 | 0 | 12,010 | 227 | 9.7 / 14.9 / 27.2 | 51.8 | 622 |

What the comparison shows:

* **Latency.** For ML-KEM-1024 every operation is faster than [15] (KeyGen
  2.0×, Encaps 1.5×, Decaps 1.06×; 1.37× for the three together). For
  ML-KEM-768 KeyGen and Encaps are faster and Decaps is 1.3× slower (total
  about equal). For ML-KEM-512 all three are slower (1.56× in total): the
  nine NTT lanes and the 16-coefficient PMAC are sized for the largest set,
  while the Decaps chain of four dependent transforms (NTT(u′), INTT(w),
  NTT(y), INTT(u, v)) does not shrink with k.
* **Area.** This design uses 3.5 – 4.0× the LUTs and 3.3 – 3.6× the
  flip-flops of [15], with no DSP (the multipliers are LUT logic) and no
  BRAM (all memories, the 4,736-byte I/O buffer included, are LUTRAM). The
  area-time product is 2.3× (ML-KEM-1024) to 5.4× (ML-KEM-512) higher.
* **Frequency.** 227 MHz against 263 – 270 MHz.
* **Scope.** One build here serves all three parameter sets and all three
  operations, selected per request; [15] builds one architecture per
  security level. The cycles here include moving the request and result
  between the IP buffer and the core and the secret clearing, not the host
  copies into and out of the buffer; [15] does not state that its cycle
  counts include I/O. The power figures are not comparable: [15] reports
  0.469 W (Vivado estimate, ML-KEM-512 server); 2.07 W here is a vectorless
  estimate with default activity.

Other complete-KEM Artix-7 results among the collected papers, for context
(LUT / FF / DSP / BRAM, MHz, KeyGen / Encaps / Decaps in µs):

| Paper | Standard, device | Resources | MHz | Level 1 (µs) | Level 5 (µs) |
| --- | --- | --- | ---: | --- | --- |
| [05] HPKA, IEEE TC 2023 | Kyber R3, XC7A200 | 16,147 / 13,868 / 2 / 0 (level 1) | 208 | 5.3 / 7.2 / 10.1 | 13.0 / 16.3 / 19.7 |
| [02] Dang et al., IEEE TC 2023 | Kyber R3, XC7A200T-3 | 9,457 / 8,543 / 4 / 4.5 (level 1) | 220 | 10.0 / 14.7 / 20.5 | 16.2 / 21.7 / 26.4 |
| [13] Jung et al., OJCAS 2025 | ML-KEM, XC7A100T-3, all levels in one design | 12,037 / 6,895 / 4 / 9 | 220 | 8.1 / 12.1 / 18.0 | 20.7 / 27.4 / 36.0 |

[05] and [02] implement CRYSTALS-Kyber round 3, not FIPS 203, so their
figures are context, not a like-for-like reference.

## Critical paths

All endpoints meet 4.4 ns. The slowest routed paths are the KeyGen `ê`
addition of the output encoder (+0.135 ns, block register into the adder
register), the row-lane job register into the CBD unit of a neighbouring lane
(+0.150 ns) and the input engine's block counter into the `ρ` register
(+0.167 ns). No path of the I/O buffer is among the 40 slowest: its RAM
address, write strobes and write data come from registers (synthesis
replicates the address register for the fan-out of the RAM), and its reads
land in registers through clock enables.

## Warnings

* Synthesis: none.
* Implementation (out of context): `Route 35-198` (port nets without
  partition pins) is fixed: [`mlkem_ooc.xdc`](../constraint/mlkem_ooc.xdc)
  places the partition pins of every port except the clock in a 41 × 31-slice
  region at the centre of the device. An earlier range over the whole device
  pulled the placement apart (WNS −1.76 ns at 4.0 ns); the small region
  does not (WNS +0.135 ns). `DRC 23-814` (connectivity DRCs not run, 6) and
  `Constraints 18-8777` (1) remain. They belong to the out-of-context mode:
  a one-register test design on the same part and tool reports both (and
  35-198) out of context and no warning at all in context, so no change to
  this design removes them; an in-context build with real I/O does not have
  them.
* Vivado commands: `Board 49-26` (78) and `Project 1-5713` are issued by
  every `open_project` of this installation, also with no `BoardPart` entry
  in the project, with `board.repoPaths` pointing to an empty folder: the
  installed board store (`data/xhub/boards/XilinxBoardStore`) lists boards
  whose device families are not installed (42 of the 60 board folders: the
  Versal, Kintex and Virtex UltraScale boards, zc702, zc706, zcu1xx, sp701
  and others). They go away only by installing those families or moving
  those folders out of the installation; the installation is left unchanged
  by choice. The script warnings are fixed (`Vivado 12-180`: the hard-macro
  check queries with `-quiet`; `Vivado 12-7122`: synthesis runs without
  auto-incremental checkpoints).

## Changes from the previous revision

This revision replaces the AXI4-Stream ports by a memory-mapped buffer
(SPEC section 4, interface version 2.0). The regressions (`make test` and
`make sim-iverilog` with random port stalls, `make perf`, `make test-axi`
with random AXI4 stalls at 20 – 60 %, `make lint`) pass; the core's cycle
counts are unchanged.

| Item | Change |
| --- | --- |
| AXI4-Stream request and result ports (DMA MM2S / S2MM) | AXI4 slave, 64-bit, INCR / FIXED / WRAP bursts, narrow transfers, byte strobes, on a 592-word single-port LUTRAM buffer (`mlkem_iobuf`). Request and result share the buffer, both from offset 0: every result depends on the end of its request, so the core has read the whole request before its first result word. One shared buffer instead of separate input and output regions halves the LUTRAM |
| `IN0_LEN`, `IN1_LEN`, `OUT0_CAP`, `OUT1_CAP`; `TKEEP` / `TLAST` framing check (error 2) | removed: the object lengths follow `CONFIG`, and the core takes exactly the words of its request |
| 512-bit seed copy in the wrapper, loaded into the core at START | the `SEED` window writes the core's seed registers directly; coverage is still checked (error 4) |
| — | `IRQ_ENABLE` (0x010) and `VERSION` (0x014) registers; the buffer is wiped after ACK of a result, before ERROR of a failed request and after reset; buffer access while busy or wiping returns `SLVERR` with zero data |
| `Route 35-198` | partition-pin region at the centre of the device |

Earlier timing changes, all still in place: every change is structural; no
tool attribute (such as `max_fanout`) and no non-default strategy is used.
The modified LUT multiplier was checked on 2 million random and edge operand
pairs, and the Keccak IP's own 150-vector testbench passes.

| Path or warning | Change |
| --- | --- |
| Keccak round: state → theta → chi → absorb select (4 LUT levels) | the sponge passes the raw block and one enable per lane (the rate is 9, 17 or 21 lanes), so the absorb select is on the register enables and a state bit's input is one LUT after theta (`keccak_sponge`, `keccak_permutation`) |
| Keccak padding behind the message length | the hash engine pads while it assembles the block; the sponge absorbs the block register (`keccak_pad_block` is not used) |
| Keccak block assembly (word index decoded onto 1,344 flip-flops) | one registered load / pad strobe per 64-bit word |
| Keccak reset from kill and WIPE | registered in the hash engine |
| job decode after a phase step, XOF last-block decision | next job decoded one cycle ahead; `256 - count` registered and the precount compare registered (an uncertain block waits one more cycle) |
| NTT butterfly add / subtract after the multiplier | both candidates of each modular add / subtract registered, then a sign select (one more stage) |
| NTT multiplier partial products | one more stage (partial sums registered) |
| NTT RAM ports | the address generator register drives the RAM address (external access one cycle ahead), registered bank-steered write ports, 7-bit in-bank write address |
| 13-bit Karatsuba product of the basemul lanes (8 levels) | three-stage multiplier with four digits of at most 4 bits |
| PMAC group start: readiness → pair select → block mux → read address | operand fills registered, readiness registered, next group (pair, block) chosen one cycle ahead in the last term |
| PMAC operand read: store → slot select → source select | blocks registered after the slot select (stage R) |
| store write ports and fill counters (scrub counter, input decode, `blk == 0` compares) | one-hot registered write strobes from the input engine, registered first / last flags from the producers, scrub flag = `!sc[5]` |
| sampler rank and count after the candidate compare | compare and prefix count in separate stages; one write-port register per bank |
| output engine (448-way enable from a chain of stage-free signals) | R0 – R2 advance together on the registered ready of a two-entry slice in front of the packer |
| tap FIFO write enable from the input decode | registered write port; full counts accepted words, empty counts written words |
| AXI4-Lite register writes (wide enables from the write decode) | address decoded at AW; register writes one cycle after W from registered strobes; START checks registered |
| lane controls (`op`, `k`, C store fill, buffer write select) | the core latches `op` / `k` one cycle before `go`; registered `active`, C-full and buffer-write flags in the lanes |
