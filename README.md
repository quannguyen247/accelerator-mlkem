# ML-KEM accelerator core (FIPS 203) for FPGA

This repository contains synthesizable Verilog RTL for a complete FIPS 203
ML-KEM accelerator: KeyGen, Encaps and Decaps for ML-KEM-512, -768 and -1024
with the public byte-string interface (`ek`, `dk`, `c`, `K`). An AXI4-Lite
register slave and two 64-bit AXI4-Stream ports connect the core to a host CPU
and an AXI DMA. The design uses LUTs, flip-flops and distributed RAM only:
0 BRAM, 0 URAM, 0 DSP.

The accelerator contains the two finished cores of this project. Their sources
are copied unchanged from the `ntt-mlkem` and `keccak-mlkem` repositories:

| Core | Folder | Use |
| --- | --- | --- |
| `ntt_core_top` | [`rtl/modules/poly/ntt/`](rtl/modules/poly/ntt/) | nine instances (NTT/INTT lanes), `INTT_SCALE = 0` |
| `keccak_top` | [`rtl/modules/hash/keccak/`](rtl/modules/hash/keccak/) | one instance (G, H, J, PRF, XOF) |

## Key results

The standalone run of `mlkem_axi` (the IP top, including the AXI wrapper) uses
AMD Vivado 2025.2.1 on K26 `xck26-sfvc784-2LV-c` (KV260), out of context, at
250 MHz (4 ns clock period), with default synthesis and implementation
strategies:

- Resources: 40,323 LUTs (4,762 as distributed RAM, 825 as shift registers),
  25,091 flip-flops, 0 BRAM, 0 URAM, 0 DSP.
- Timing: WNS = +0.276 ns, WHS = +0.036 ns, no failing endpoints. The
  estimated Fmax from WNS is 1000 / (4.000 - 0.276), about 268 MHz.
- Latency (cycles from `start` to `done`, KeyGen / Encaps / Decaps):
  1,900 / 3,023 / 5,707 for ML-KEM-512, 2,014 / 3,142 / 5,849 for ML-KEM-768
  and 2,198 / 3,365 / 6,157 for ML-KEM-1024; at 250 MHz that is 7.6 / 12.1 /
  22.8 µs and 8.8 / 13.5 / 24.6 µs for the smallest and largest set.
- Power: 1.51 W vectorless estimate (not a measurement).

Details are in the [implementation results](docs/RESULT.md).

## Architecture

```text
 AXI4-Lite ◄─► Slave CSR ◄── start / done ──► ML-KEM Controller (IDLE → RUN → WAIT → DONE)
               CONTROL STATUS ERRCODE                        │
               CONFIG LEN CAP SEED                           ▼
 ┌─ ML-KEM Datapath ──────────────────────────────────────────────────────────────────┐
 │                       ┌──────────── noise (PRF) ───────────┐                        │
 │                       │                                    ▼                        │
 │  Stream In ──► Keccak (hash) ──► Sampler ──► Polynomial Arithmetic Unit ──► Stream Out
 │  AXIS slave    G H J PRF XOF     SampleNTT   Poly MAC ◄─► NTT lanes ×9      AXIS master
 │  ByteDecode                      Â store     BaseMul ×8   load / NTT /      ByteEncode
 │      │              ▲                │                    unload            add ê
 │      ▼              │                ▼                       ▲                 ▲
 │  Local Storage: tap FIFO (64-bit × 256) · key registers · polynomial stores ŝ t̂ c₁ c₂
 └────────────────────────────────────────────────────────────────────────────────────┘
```

Each block of the diagram is one folder of [`rtl/modules/`](rtl/modules/):

| Block | Folder | Modules |
| --- | --- | --- |
| Slave CSR, ML-KEM Controller | [`top/`](rtl/modules/top/) | `mlkem_axi.v` (AXI4-Lite CSR, streams, interrupt: the IP top), `mlkem_core.v` (controller, stores and datapath wiring: the native core) |
| Stream In, Stream Out | [`stream/`](rtl/modules/stream/) | `mlkem_in.v`, `mlkem_unpack.v` (ByteDecode), `mlkem_out.v`, `mlkem_pack.v` (ByteEncode), `mlkem_axis_slice.v` (register slice) |
| Keccak | [`hash/`](rtl/modules/hash/) | `mlkem_hash.v` (job list on one `keccak_top`), `mlkem_rej_count.v` (accepted-candidate precount of an XOF block). Keccak core: `keccak/` (`keccak_top.v`, `keccak_sponge.v`, `keccak_permutation.v`, `keccak_pad_block.v`) |
| Sampler | [`sampler/`](rtl/modules/sampler/) | `mlkem_sampler.v` (SampleNTT, 8 candidates per cycle, matrix store) |
| Polynomial Arithmetic Unit | [`poly/`](rtl/modules/poly/) | Poly MAC: `mlkem_pmac.v`, `mlkem_basemul_lane.v`, `mlkem_gamma_rom.v`. NTT lanes: `mlkem_lane.v` (load, `ntt_core_top`, unload), `mlkem_cbd_stream.v`, `mlkem_compress.v`. Shared arithmetic: `mlkem_mul.v`, `mlkem_montred.v`, `mlkem_delay.v`. NTT core: `ntt/` (`ntt_core_top.v` and its controller, AGU, butterfly, multiplier, RAM, twiddle ROM) |
| Local Storage | [`storage/`](rtl/modules/storage/) | `mlkem_fifo.v` (tap FIFO), `mlkem_poly_ram.v` (polynomial memories), `mlkem_slot_state.v` (fill counter and epoch of a slot) |

Shared headers are in [`rtl/utils/`](rtl/utils/): `mlkem_defs.vh`,
`mlkem_funcs.vh`, `ntt_defs.vh`, `ntt_funcs.vh`, `keccak_defs.vh` and
`keccak_funcs.vh`.

## Source layout

| Path | Purpose |
| --- | --- |
| [`rtl/`](rtl/) | Accelerator RTL (`modules/<block>/`) and shared headers (`utils/`) |
| [`testbench/`](testbench/) | Self-checking testbenches: `tb_mlkem_core.sv` (native core), `tb_mlkem_axi.sv` (IP top), `tb_mlkem_trace.sv` (timeline monitor) |
| [`vector/`](vector/) | `mlkem_gen.py`, the FIPS 203 golden model, and the default vector set `tv_*.mem` |
| [`constraint/`](constraint/) | 4 ns clock constraint for the standalone build |
| [`project/mlkem_top/`](project/mlkem_top/) | Vivado project (K26, out of context) for standalone `mlkem_axi` |
| [`project/ip_repo/mlkem_core/`](project/ip_repo/mlkem_core/) | Packaged IP `quannguyen247.org:user:mlkem_core:1.0`: the accelerator (`mlkem_axi`), copy of all RTL |
| [`project/ip_repo/ntt_core/`](project/ip_repo/ntt_core/) | Packaged IP `quannguyen247.org:user:ntt_core:1.0`: the NTT/INTT core (`ntt_core_top`, parameter `INTT_SCALE`) |
| [`project/ip_repo/keccak_core/`](project/ip_repo/keccak_core/) | Packaged IP `quannguyen247.org:user:keccak_core:1.0`: the AXI4-Stream Keccak core of `keccak-mlkem`, unchanged |
| [`scripts/`](scripts/) | Vivado Tcl used by the `Makefile`: `sources.tcl` (file lists), `create_project.tcl`, `package_ip.tcl`, `run_project.tcl` |
| [`docs/SPEC.md`](docs/SPEC.md) | SoC / IP specification and CSR map |
| [`docs/RESULT.md`](docs/RESULT.md) | Synthesis and implementation results |
| [`docs/VERIFICATION_PLAN.md`](docs/VERIFICATION_PLAN.md), [`docs/IMPLEMENTATION_SIGNOFF.md`](docs/IMPLEMENTATION_SIGNOFF.md) | Verification plan and signoff gates |
| [`docs/Ref.txt`](docs/Ref.txt) | The 30 ML-KEM architecture papers used as design evidence |

All sources are in this repository; the packaged IPs hold copies of them.
Generated run directories and simulator outputs are not
tracked. Rebuild them after changing RTL or constraints.

## Test and build

The repository includes the default vector set (one key set per parameter
set), so the testbenches run after a fresh clone. To regenerate it, or to
choose another number of key sets, from the repository root:

```sh
python3 vector/mlkem_gen.py 1
```

The core regression runs in Icarus Verilog 12+ from the repository root:

```sh
make sim-iverilog
```

| Target | Content |
| --- | --- |
| `make sim-iverilog` | core regression on Icarus Verilog with random stalls on both streams (`STALL=30`, `SEED=1`, `N=1`) |
| `make test` | the same regression on QuestaSim (`vlog`/`vsim`) |
| `make perf` | always-ready streams, prints cycles per request |
| `make trace` | per-request engine timeline (Keccak jobs, NTT lanes, PMAC, streams) |
| `make test-axi` | AXI4-Lite register slave and DMA-style streams (SPEC section 4), error and lifecycle cases |
| `make lint` | Verilator lint of the RTL |
| `make project` | recreates `project/mlkem_top/mlkem_top.xpr` |
| `make package` | repackages `project/ip_repo/mlkem_core` and `project/ip_repo/ntt_core` |
| `make impl` | synthesis and implementation of `project/mlkem_top`; routed reports in `build/impl` |

A run passes only when every case prints `PASS` and the bench ends with
`*** ALL TESTS PASSED ***`. The Vivado targets take `VIVADO_HOME=<install dir>`
when `vivado` is not on `PATH`.

For the standalone implementation, open `project/mlkem_top/mlkem_top.xpr` in
Vivado 2025.2.1 and run synthesis and implementation, or use `make impl`. The
synthesis run is out of context (no I/O buffers) and limits block RAM, UltraRAM
and DSP to zero. To use the IPs in a block design, add
`project/ip_repo` to the IP repository paths.

## Native interface (`mlkem_core`)

| Signal | Dir | Meaning |
| --- | --- | --- |
| `start`, `op[1:0]`, `pset[1:0]`, `seed[511:0]` | in | one-cycle start while `ready`; op 0 KeyGen, 1 Encaps, 2 Decaps; set 0/1/2 = 512/768/1024; `seed[255:0]` = d (KeyGen) or m (Encaps), `seed[511:256]` = z |
| `abort` | in | stop the request, clear secrets, report error 6 |
| `ready`, `done`, `error`, `err_code[2:0]` | out | `done`/`error` pulse at the end; codes: 1 config, 2 framing, 3 invalid key (Encaps ek modulus check or Decaps H(ek) check), 6 abort |
| `s_axis_*` (64-bit) | in | request packet: Encaps `ek`, Decaps `dk || c` |
| `m_axis_*` (64-bit) | out | result packet: KeyGen `ek || dk`, Encaps `c || K`, Decaps `K` |

Byte 0 of a packet is `TDATA[7:0]`. All packets are whole 64-bit words, so
`TKEEP` is always `0xFF`; `TLAST` marks the last word. The input port accepts
exactly the words of the active request. A failed Decaps re-encryption check is
not an error: the core returns the implicit-rejection key `J(z || c)` with the
same timing as a successful decapsulation.

`mlkem_axi` wraps the core with the SPEC section 4 register map (CONTROL,
STATUS, CONFIG, IN0/IN1_LEN, OUT0/OUT1_CAP, ERRCODE, SEED window) and `irq`.

## Microarchitecture

```text
 s_axis ─► mlkem_in ──► S / T / C stores, rho h z ──────────────┐
             │ tap (ek, c)                                       │
             ▼                                                   ▼
          FIFO ─► mlkem_hash (keccak_top) ─► sampler ─► A store (k² polys)
                     │ PRF words                                 │
                     ▼                                           ▼
   lanes 0..3  NTT  (s, y, u')   ── buffers B0..3 ──► mlkem_pmac (8 basemul lanes)
   lanes 4..7  INTT (u rows) / NTT (KeyGen e)  ◄── B4..7 ◄──┘   │
   lane  8     INTT (v, w)                      ◄── B8   ◄──────┘
        │ compress / compare / m'                    │ t^ (KeyGen)
        ▼                                            ▼
       C store ─────────────────────────► mlkem_out ─► m_axis
```

* **Dataflow control.** Each engine (input, hash, nine lanes, PMAC, output)
  runs a fixed program for the latched operation. Every polynomial slot carries
  a fill counter (complete 8-coefficient blocks) and an epoch bit; consumers
  wait at block granularity, so engines overlap without a global schedule.
* **NTT lanes.** The NTT IP has one butterfly and a one-coefficient port, so
  parallelism comes from nine instances: a whole vector is transformed at once,
  and loads/unloads stream through CBD, decompression, `+e1/e2/µ`, compression
  and compare units at one coefficient per cycle. Unloading writes zeros
  behind the read, so core memories are clean after every job.
* **PMAC.** Two groups of four basemul lanes process two matrix rows that share
  one vector block (16 coefficients per cycle). Lazy Montgomery accumulation
  (one reduction per output). The matrix store is split by row parity, so the
  two row reads never collide. Groups start only when all their operand blocks
  exist; ready row pairs are taken lowest first (KeyGen, Encaps: output order)
  or round robin (Decaps re-encryption: balanced INTT loads).
* **Hash engine.** One job list per operation; long messages come from a tap
  FIFO filled by the stream engines, so the streams never wait for Keccak.
  PRF output goes straight into the lane noise memories; consumers start on the
  first written word. The block that completes a matrix polynomial is found by
  a precount before its handshake, so no permutation is wasted. A final WIPE job
  overwrites the Keccak input registers.
* **Scaling conventions.** NTT IP output is the exact FIPS NTT. The lanes run
  the IP with `INTT_SCALE = 0`: the 256-cycle scale pass is skipped and an INTT
  returns `128·INTT`. The PMAC returns `(M ∘ V)·R⁻¹` (`R = 2^16`), so the
  vector lanes unload `ŷ·2^9` and `û′·2^9` (`2^9·R⁻¹·2^7 = 1`): INTT gives
  exact `u`, `v`, `w`. KeyGen feeds `ŝ·R` to the PMAC and adds `ê` in the
  output encoder, which gives exact `t̂` without waiting for `ê`. Both factors
  use the multiplier that the vector lanes already had (`x·2^e =
  MontRed(x·(2^(e+16) mod q))`, constants 1353 and 1441).

## Performance

Cycles from `start` to `done`, always-ready streams, 64-bit streams, including
the secret clearing at the end (`make perf`):

| Parameter set | KeyGen | Encaps | Decaps |
| --- | ---: | ---: | ---: |
| ML-KEM-512 | 1,900 | 3,023 | 5,707 |
| ML-KEM-768 | 2,014 | 3,142 | 5,849 |
| ML-KEM-1024 | 2,198 | 3,365 | 6,157 |

### Bottleneck analysis

The first correct version took 2,489 / 4,134 / 6,937 cycles (ML-KEM-1024
KeyGen / Encaps / Decaps). `make trace` showed where each request waited; each
step below was measured on its own (ML-KEM-1024):

| Limit found | Change | KeyGen | Encaps | Decaps |
| --- | --- | ---: | ---: | ---: |
| Keccak idle cycles at squeeze handshakes and XOF ends | handshake in the first valid cycle; precount ends the XOF on its last block | −11 | −88 | −9 |
| PMAC was the longest non-NTT phase (640 steps) | row pairs share the vector read: 16 coefficients/cycle | −178 | −240 | −256 |
| KeyGen rows waited for `ê` | `ê` added in the output encoder | −60 | | |
| Fixed sweep order waited for the last matrix polynomial; lanes waited for a whole PRF block; clearing ran after the output | dynamic pair scheduler; noise usable from the first written word; clearing overlaps the output tail | −40 | −165 | −15 |
| `u[0]` reached the output late | Encaps takes the lowest ready row pair first | | −23 | |
| Timing closure (registered starts, stream slices, extra pipeline stages) | | +31 | 0 | +22 |
| Current `keccak_top` handshake | hash engine adapted to the released Keccak IP | −33 | +3 | −10 |
| INTT scale pass (256 cycles per INTT) | `INTT_SCALE = 0`; the factor is folded into the PMAC operand of the vector lanes | 0 | −256 | −512 |

What remains on the critical path is fixed by the reused IPs and by FIPS 203
data dependencies:

* **NTT IP latency.** Each transform (NTT or INTT) takes 905 cycles plus
  256-cycle load and unload through its single port. Encaps has two such steps
  in series (NTT(y) → INTT(u, v)), Decaps four (NTT(u′) → INTT(w) → NTT(y) →
  INTT(u, v)); they are about 70 % (Encaps) and 80 % (Decaps) of the latency.
  All transforms of a vector already run in parallel lanes. Loading and
  unloading two coefficients per cycle is possible (the IP memory has two
  banks), but it doubles the CBD, compress and decompress datapaths of the nine
  lanes; that area-for-latency trade is not taken.
* **Keccak.** H(ek) of a 1,568-byte key is 12 dependent absorptions (≈ 325
  cycles) before G and the PRFs can start; the IP absorbs one block per 25
  cycles. Matrix generation is otherwise hidden behind the NTTs.
* **Output.** ML-KEM-1024 KeyGen emits 4,736 bytes (592 words at 8 bytes/cycle);
  the Encaps ciphertext cannot leave before `u[0]` is unloaded (256 cycles).

## Verification

* `mlkem_gen.py` implements FIPS 203 directly (hashlib only) and was
  cross-checked against the independent `kyber-py` implementation for all three
  parameter sets (KeyGen, Encaps, Decaps including implicit rejection). It also
  confirms the NTT IP scaling from its twiddle table and checks the Compress and
  Montgomery constants exhaustively.
* `tb_mlkem_core`: every operation × parameter set, a tampered ciphertext
  (implicit rejection), an `ek` with a coefficient ≥ q, a `dk` with a wrong
  `H(ek)`, early `TLAST`, ABORT during Encaps, an invalid configuration, and
  recovery after the error cases; random backpressure on both streams.
* `tb_mlkem_axi`: the same requests through the register map and streams, plus
  SLVERR cases (read of WO, write of RO, unmapped offset, two command bits,
  reserved CONFIG bits, misaligned access, partial strobes, ACK without outcome, START,
  CONFIG or SEED while busy), length/seed/config errors and ABORT.
* The testbench detects corrupted expected words (checked by mutation).

## Documentation

- [SoC / IP specification](docs/SPEC.md): interfaces, register map, error
  codes, microarchitecture, verification and completion evidence.
- [Implementation results](docs/RESULT.md): resources, timing and the critical
  paths of the standalone build.
- [Verification plan](docs/VERIFICATION_PLAN.md) and
  [implementation signoff](docs/IMPLEMENTATION_SIGNOFF.md).

## Limits

No masking, hiding or fault countermeasures; no FIPS validation. The SoC
items of SPEC sections 4–6 (DMA, firmware, board test, RBG provider) are not
part of this repository yet.

## References

1. National Institute of Standards and Technology, *Module-Lattice-Based
   Key-Encapsulation Mechanism Standard*, FIPS 203, Aug. 2024. DOI:
   [10.6028/NIST.FIPS.203](https://doi.org/10.6028/NIST.FIPS.203).
2. National Institute of Standards and Technology, *SHA-3 Standard:
   Permutation-Based Hash and Extendable-Output Functions*, FIPS 202, Aug.
   2015. DOI: [10.6028/NIST.FIPS.202](https://doi.org/10.6028/NIST.FIPS.202).

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE)
for details.
