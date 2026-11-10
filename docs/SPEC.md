# ML-KEM SoC Technical Specification

**Status:** Draft. ML-KEM IP RTL (native core and AXI4-Lite/AXI4-Stream top) implemented and verified in simulation; SoC integration (DMA, firmware, board test) pending

**Target product:** CPU-controlled ML-KEM SoC with on-chip IMEM/DMEM SRAM; Kria K26 / KV260 as a prototype platform

**Algorithm:** NIST FIPS 203, ML-KEM-512/768/1024

## 1. Overview

This specification defines the behavior and integration boundary of the **SoC**, including the Host CPU, on-chip IMEM/DMEM SRAM, the ML-KEM hardware, the randomness service, DMA data movement, and the software that submits requests. The repositories for Keccak, sampling, polynomial arithmetic, codec, and sequencing provide constituent IP. Passing an IP test does not establish a working SoC.

The product shall execute FIPS 203 KeyGen, Encaps, and Decaps for all three parameter sets and return the standard byte strings. It shall also provide a reproducible SoC build and a CPU-driven test of those operations. The `accelerator-mlkem` checkout contains the integrated ML-KEM IP RTL (`mlkem_core`, and `mlkem_axi` with the Section 4 register block), its FIPS 203 golden model and testbenches; firmware, the DMA/SoC build and a bitstream are not yet part of it.

The words **shall** and **shall not** state requirements. **TBD** identifies a choice that must be fixed before its affected interface is implemented. Paper results in [Ref.txt](Ref.txt) are design evidence; they do not define ML-KEM semantics or predict this SoC's PPA.

### 1.1 Scope

The SoC contains one transaction controller, the compute functions listed in Section 3, temporary object storage, an AXI4-Lite host interface, a DMA engine with AXI4-Stream input/output, and a trusted source of random bytes. The first integration uses one active KEM request at a time. No particular RTL module name, port suffix convention, memory bank count, or pipeline depth is prescribed here. Section 4 fixes the first SoC's host-visible register offsets. The ML-KEM IP, including local memories and interface logic, targets LUT/FF/LUTRAM with 0 BRAM, 0 URAM, and 0 DSP; CPU, system SRAM, interconnect, RBG, and DMA resources are reported separately.

This revision does not claim masking, power/EM side-channel resistance, fault-attack resistance, FIPS validation, ASIC signoff, or measured SoC performance. Those claims require separate designs and evidence. The IP contains unchanged copies of `ntt_core_top` from `ntt-mlkem` ([`rtl/modules/poly/ntt/`](../rtl/modules/poly/ntt/), used with `INTT_SCALE = 0`) and `keccak_top` from `keccak-mlkem` ([`rtl/modules/hash/keccak/`](../rtl/modules/hash/keccak/)); sampling, CBD, base multiplication, codecs, storage and control are implemented in this repository (Section 3.3).

## 2. Functions and externally visible data

FIPS 203 fixes `n = 256` and `q = 3329`. The selected parameter set shall be latched when a request is accepted and shall apply to every constituent operation and length check.

| Set | k | η₁ | η₂ | dᵤ | dᵥ | Required RBG strength | ek bytes | dk bytes | c bytes | K bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| ML-KEM-512 | 2 | 3 | 2 | 10 | 4 | 128 bits | 800 | 1632 | 768 | 32 |
| ML-KEM-768 | 3 | 2 | 2 | 10 | 4 | 192 bits | 1184 | 2400 | 1088 | 32 |
| ML-KEM-1024 | 4 | 2 | 2 | 11 | 5 | 256 bits | 1568 | 3168 | 1568 | 32 |

The SoC application interface has the following logical operations. Section 4 defines the AXI4-Lite/DMA transport; the byte lengths and results are fixed by FIPS 203.

| Operation | Application inputs | Randomness acquired inside the SoC trust boundary | Successful outputs |
|---|---|---|---|
| KeyGen | Parameter set | Independent 32-byte `d` and `z` | `ek`, `dk` |
| Encaps | `ek`, parameter set | 32-byte `m` | `c`, `K` |
| Decaps | `dk`, `c`, parameter set | None | `K` |

The application shall not supply `d`, `z`, or `m` as ordinary operation inputs. Deterministic seed injection may exist in a testbench or isolated validation build; it shall not be exposed through the deployed application interface.

### 2.1 Input checks and result semantics

The initial SoC implementation shall perform the following checks on every request. This is a simple local policy compatible with FIPS 203, which permits prior assurance for some key checks.

| Input | Required check | On failure |
|---|---|---|
| Encaps `ek` | Length `384k + 32`; the first `384k` bytes satisfy `ByteEncode12(ByteDecode12(ek[0:384k])) = ek[0:384k]`. | Reject request; no `c` or `K` output. |
| Decaps `dk` | Length `768k + 96`; `H(dk[384k:768k+32])` equals the stored 32-byte hash at `dk[768k+32:768k+64]`. | Reject request; no `K` output. |
| Decaps `c` | Length `32(dᵤk+dᵥ)` bytes on **every** invocation. | Reject request; no `K` output. |

An unsupported operation, unsupported parameter set, insufficient buffer, RBG failure, or compute failure shall end the transaction with an error and shall not expose a partial or previous result. A correctly sized ciphertext whose re-encryption does not match is different: Decaps shall complete and return the implicit-rejection key. The equality result for `c` versus `c′` shall never be returned as status.

### 2.2 Algorithm flow

The top shall implement the public FIPS 203 algorithms, not only the K-PKE primitives:

- **KeyGen:** acquire `d,z`; run `K-PKE.KeyGen(d)`; set `ek = ekPKE` and `dk = dkPKE || ek || H(ek) || z`.
- **Encaps:** acquire `m`; compute `(K,r) = G(m || H(ek))`; run `c = K-PKE.Encrypt(ek,m,r)`.
- **Decaps:** extract `dkPKE, ek, h, z`; decrypt `m′`; compute `(K′,r′) = G(m′ || h)` and `K̄ = J(z || c)`; re-encrypt `c′ = K-PKE.Encrypt(ek,m′,r′)`; compare all bytes of `c` and `c′`; select `K′` when equal and `K̄` otherwise.

Here `H = SHA3-256`, `G = SHA3-512`, `J` and `PRF` use SHAKE256, and the matrix XOF uses SHAKE128. The final Decaps comparison and key selection shall have no secret-dependent early exit. The comparison flag is secret intermediate data and shall be discarded before completion.

## 3. SoC architecture and theory of operation

```text
CPU-controlled ML-KEM SoC (K26 / KV260 prototype)
┌──────────────────────────────────────────────────────────────┐
│ Host CPU + driver; IMEM/DMEM SRAM; RBG → fresh d,z,m         │
│             │ AXI4-Lite CSR; DMA ↔ IP via AXI4-Stream        │
│             ▼                                                │
│ AXI4-Lite + stream adapters ── controller ── object store    │
│                          │                 (scratch + bytes) │
│                          ▼                                   │
│                sequencer → dispatcher                        │
│                  │    │       │       │                      │
│               Keccak sampler polyengine codec                 │
│                          │                                   │
│                 compare / select / output                    │
└──────────────────────────────────────────────────────────────┘
```

The driver owns request submission and the host-visible buffers. The transaction controller owns acceptance, input checks, status, output commit, and recovery. The sequencer owns FIPS 203 operation order and parameter-dependent iteration; the dispatcher executes one command and reports its completion or error. The object store maps logical polynomial and byte objects to physical storage. Compute blocks only perform their declared transforms. The final SoC shall not require application software to execute hidden KEM steps between hardware commands.

The CPU and DMA memory port are AXI4 masters; IMEM, DMEM, DMA CSR, and IP CSR are slave targets of the interconnect. AXI4 is the memory interface for IMEM, DMEM, and the DMA memory port; DMA CSR and IP CSR use AXI4-Lite through the interconnect. Reuse existing DMA IP, with any necessary endpoint protocol/width adaptation in the interconnect rather than requiring a new custom DMA. IMEM stores firmware; DMEM stores CPU data/stack and KEM I/O buffers. The RBG supplies seeds to the trusted host driver. DMA moves the bulk data while the CPU can execute other work and receive completion/error interrupts. In a system diagram, a master-to-slave arrow denotes request initiation; AXI responses/read data return through the same interface.

### 3.1 Constituent IP and integration work

| Function | Checkout evidence | Integration obligation |
|---|---|---|
| Hash/XOF | [`keccak_top.v`](../rtl/modules/hash/keccak/keccak_top.v) (SHA3-256/512, SHAKE128/256) driven by [`mlkem_hash.v`](../rtl/modules/hash/mlkem_hash.v). | Done: per-operation job list, absorb assembly from the tap FIFO, squeeze distribution, input-register wipe at the end. |
| Sampling | [`mlkem_sampler.v`](../rtl/modules/sampler/mlkem_sampler.v) (SampleNTT, 8 candidates/cycle) and [`mlkem_cbd_stream.v`](../rtl/modules/poly/mlkem_cbd_stream.v) (CBD per lane). | Done. |
| Polynomial arithmetic | Nine [`ntt_core_top`](../rtl/modules/poly/ntt/ntt_core_top.v) lanes ([`mlkem_lane.v`](../rtl/modules/poly/mlkem_lane.v)) and [`mlkem_pmac.v`](../rtl/modules/poly/mlkem_pmac.v) (base multiplication with accumulation). | Done; scaling conventions in Section 3.3. |
| Serialization | [`mlkem_unpack.v`](../rtl/modules/stream/mlkem_unpack.v), [`mlkem_pack.v`](../rtl/modules/stream/mlkem_pack.v), [`mlkem_compress.v`](../rtl/modules/poly/mlkem_compress.v), decompression in [`mlkem_funcs.vh`](../rtl/utils/mlkem_funcs.vh). | Done for widths `1,4,5,10,11,12`. |
| Schedule | Fixed programs per engine in [`mlkem_in.v`](../rtl/modules/stream/mlkem_in.v), [`mlkem_hash.v`](../rtl/modules/hash/mlkem_hash.v), [`mlkem_lane.v`](../rtl/modules/poly/mlkem_lane.v), [`mlkem_pmac.v`](../rtl/modules/poly/mlkem_pmac.v), [`mlkem_out.v`](../rtl/modules/stream/mlkem_out.v); control in [`mlkem_core.v`](../rtl/modules/top/mlkem_core.v). | Done. |
| SoC top | [`mlkem_axi.v`](../rtl/modules/top/mlkem_axi.v): Section 4 registers, streams, interrupt. | Remaining: DMA integration, RBG connection, firmware and SoC build. |

One accepted request shall be outstanding at a time. An internal transfer shall happen once on its documented handshake; fields shall remain stable during backpressure. Within a request, the compute functions run concurrently (Section 3.3): a consumer shall only read a polynomial block after its producer has completed that block of the current object. These rules are independent of the final signal names.

### 3.2 Objects and representations

The logical objects are `A,S,E,T,Y,E1,E2,U,V,M,W,EK,DK,C,K,TEMP`. A conservative allocation without lifetime reuse at `k = 4` holds `A` (`k²` polynomials), six vectors `S,E,T,Y,E1,U` (`6k`), four single polynomials `E2,V,M,W`, and `TEMP` (up to `k`): `k² + 7k + 4 = 48` polynomials. At 256 coefficients × 16-bit storage each, this is `48 × 512 = 24,576` bytes. This calculation is a storage estimate, not a fixed 32 KiB allocation. The implemented schedule shall size banked LUTRAM and small FIFOs from simultaneously live objects and may generate matrix polynomials as needed. `EK,DK,C,K` are byte objects transferred between DMEM and private IP storage through the streams in Section 4; system SRAM and IP working memory are separate.

Before object-store RTL is frozen, the integration shall record each object's producer/consumer, representation, first/last use, and secrecy. Storage aliasing is allowed only after the prior object's last use. `d,z,m,r,dk,K` and secret polynomial intermediates require protected handling even where no sequencer object ID exists.

At every compute boundary the design shall document canonical versus centered values, normal versus NTT domain, Montgomery scaling, coefficient order, and byte order. An adapter shall not silently reinterpret an IP's output. Physical banking and safe lifetime-based reuse are RTL choices; published bank counts or cycle counts are not imported into this SoC.

### 3.3 Implemented microarchitecture

`mlkem_core` is organized as concurrent engines, each running a fixed program for the latched operation and parameter set. There is no central command dispatcher: every polynomial slot has a producer progress counter (complete 8-coefficient blocks) and an epoch bit, and a consumer waits only for the block it needs next. The engines are:

| Engine | Work |
|---|---|
| Input (`mlkem_in`) | Register slice limited to the request's words; framing checks; ByteDecode into the `S`, `T`, `C` stores (Encaps `ek` modulus check); `ρ`, `h`, `z` registers; `ek` and `c` words tapped into the hash FIFO. |
| Hash (`mlkem_hash`, one `keccak_top`) | KeyGen: G, PRF ×2k, XOF ×k², H(ek). Encaps: H(ek), G, PRF ×k, XOF ×k², PRF ×(k+1). Decaps: H(ek) check, XOF ×k², G, PRF ×(2k+1), J. A final empty absorb overwrites the Keccak input registers. |
| Sampler (`mlkem_sampler`) | SampleNTT at 8 candidates per cycle into the matrix store (`k²` slots, split by row parity). A precount of the block in the squeeze window tells the hash engine which block completes the polynomial. |
| NTT lanes (`mlkem_lane` ×9) | Lanes 0..3: NTT of `s`/`y`/`u′` with CBD or decompression at load; lanes 4..7: INTT of the `u` rows with `+e1`, Compress and C write or compare at unload (KeyGen: NTT of `e`); lane 8: INTT of `v` (`+e2+µ`) and Decaps `w = v′ − INTT(·)` → `m′`. Unloading writes zeros behind the read. |
| PMAC (`mlkem_pmac`) | `Σ_j M[r][j] ∘ V[j]` with two four-lane groups (two rows per step, 16 coefficients/cycle), lazy Montgomery accumulation, dynamic row-pair scheduling. |
| Output (`mlkem_out`) | ByteEncode / packet assembly from the stores and registers, `ê` added to `t̂` in KeyGen, register slice on the port; the first `ek` copy of KeyGen is tapped into the hash FIFO for H(ek). |

Scaling at the compute boundaries: the NTT IP returns the exact FIPS 203 NTT; it runs with `INTT_SCALE = 0` (no scale pass), so its INTT returns `128·INTT`. The PMAC returns `(M ∘ V)·R⁻¹` (`R = 2^16`); the vector lanes unload `ŷ·2^9` and `û′·2^9`, so encryption and decryption obtain exact `u`, `v`, `w`; KeyGen feeds `ŝ·R` (formed at the lane unload) and adds `ê` in the encoder, giving exact `t̂`. Coefficients are canonical in `[0, q)` everywhere except the CBD outputs, which are mapped to `[0, q)` when produced. Coefficient `n` of a polynomial lives in bank `n mod 8`, word `n / 8`.

Object mapping: `A` → matrix store; `S` (Decaps `ŝ`, KeyGen dk `ŝ`) and `T` (`t̂`) → 4-slot stores; `C` → compressed `u`, `v` values (Decaps input `c`, Encaps output); `Y`/`ŝ·R`/`û′` → buffers of lanes 0..3; `û` rows, KeyGen `ê` → buffers of lanes 4..7; `v̂`/`ŵ` → buffer of lane 8; PRF bytes → per-lane noise memories; `m′` → register. Secret storage (lane buffers, noise memories, `S`, seeds, `m′`, PRF seed, keys, Keccak capture) is cleared before DONE; after an error, ABORT or reset the NTT cores are also zeroed before READY.

The native core interface (`start`, `op`, `pset`, `seed[511:0]`, `abort`, `ready`, `done`, `error`, `err_code`, 64-bit AXI4-Stream in/out) is wrapped by `mlkem_axi` into the Section 4 register map.

## 4. Host interface and transaction lifecycle

The SoC uses an AXI4-Lite slave aperture for CSR and seed access. A DMA engine transfers complete objects between DMEM and the IP through AXI4-Stream; its memory port is an AXI4 master and its control registers are reached through the interconnect. All offsets below are relative to the IP aperture base assigned in the SoC address map. Each CSR word carries four consecutive FIPS 203 bytes, with the lowest-addressed byte in bits `[7:0]`. Software CSR accesses shall be aligned 32-bit transfers with all four write strobes asserted. The AXI4-Lite interface shall handle independent address/data handshakes and return protocol-correct responses, including `SLVERR` for unsupported offsets, partial write strobes, directions, or lifecycle accesses. The trusted driver alone shall map this aperture into CPU address space.

| Offset | Name | Access | Meaning |
|---:|---|---|---|
| `0x000` | `CONTROL` | WO | Write exactly one pulse: bit 0 `START`, bit 1 `ABORT`, bit 2 `ACK`. Other bits shall be zero. |
| `0x004` | `STATUS` | RO | Bit 0 `READY`, bit 1 `BUSY`, bit 2 `DONE`, bit 3 `ERROR`; all other bits zero. `DONE` and `ERROR` are mutually exclusive and remain set until `ACK` or reset. |
| `0x008` | `ERRCODE` | RO | `0` none; `1` invalid configuration; `2` length/capacity or stream framing; `3` invalid key; `4` missing seed; `5` compute failure; `6` aborted. |
| `0x00C` | `CONFIG` | RW | Bits `[1:0]`: operation `0` KeyGen, `1` Encaps, `2` Decaps. Bits `[3:2]`: set `0` ML-KEM-512, `1` ML-KEM-768, `2` ML-KEM-1024. Encoding `3` in either field is invalid; other bits shall be zero. |
| `0x010` | `IN0_LEN` | RW | Input 0 byte count. |
| `0x014` | `IN1_LEN` | RW | Input 1 byte count. |
| `0x018` | `OUT0_CAP` | RW | Output 0 capacity in bytes. |
| `0x01C` | `OUT1_CAP` | RW | Output 1 capacity in bytes. |
| `0x020–0x03C` | Reserved | — | Unmapped; accesses return `SLVERR`. |
| `0x040–0x07F` | `SEED` | WO | KeyGen `d || z` (64 bytes) or Encaps `m` (32 bytes), supplied by the trusted host driver. |

The bulk buffers retain the logical names `IN0`, `IN1`, `OUT0`, and `OUT1`, but reside in DMEM and are transferred by DMA rather than through CSR data windows. Each request has at most one input packet and one output packet:

| Operation | MM2S: DMA → IP | S2MM: IP → DMA |
|---|---|---|
| KeyGen | None; both input lengths are zero | `ek || dk` (`OUT0=ek`, `OUT1=dk`) |
| Encaps | `ek` (`IN0=ek`, `IN1_LEN=0`) | `c || K` (`OUT0=c`, `OUT1=K`) |
| Decaps | `dk || c` (`IN0=dk`, `IN1=c`) | `K` (`OUT0=K`, `OUT1_CAP=0`) |

`||` denotes concatenation in the shown order. Bytes follow FIPS order, earliest byte in the lowest stream lane. A beat transfers only on `TVALID && TREADY`; data, `TKEEP`, and `TLAST` remain stable during a stall. `TLAST` marks the final beat of each packet; only its final beat may have a partial, contiguous low-byte `TKEEP` mask. Packet length/termination shall match the selected operation. The stream width is 64 bits; every packet of Section 4 is a whole number of words, so `TKEEP` is `0xFF` on every beat and any other value is a framing error. The maximum input and output packet sizes are each 4736 bytes, for ML-KEM-1024 Decaps and KeyGen respectively. DMEM sizing shall include the active DMA buffers plus firmware data/stack; the CPU shall not modify active buffers.

`CONFIG` and the four byte-count registers reset to zero and may be written only while `READY=1`; `ERRCODE` resets to zero. The driver shall program exact FIPS 203 input lengths, zero for unused inputs, capacities at least as large as the expected outputs, and zero for unused outputs. `START` shall reject invalid configuration, lengths/capacities, or incomplete seed-word coverage; the active request shall additionally check received input bytes and packet framing before releasing any result. Decaps requires no seed. A failure to obtain random bytes in the host driver shall prevent `START` and be reported to its caller; `ERRCODE=4` covers an incomplete seed window submitted to the IP.

The driver shall check `READY`, prepare DMEM input/output buffers, write `SEED`, configuration and counts, and configure the DMA. It shall arm S2MM before output can arrive, issue `START`, then launch MM2S when the request has input. Simple DMA without scatter-gather is sufficient. `START` atomically latches the request and makes `BUSY=1`; another `START` while busy shall return `SLVERR` and leave the active request intact. The IP shall accept stream input only for that request and release output only after required checks and KEM computation succeed. It shall set `DONE` after the final output beat is accepted and secret scratch/input/seed clearing completes. On failure it shall invalidate private output state, clear secret scratch/input/seed storage, then set `ERROR` and the code. A correctly sized ciphertext that fails the Decaps re-encryption comparison still completes with `DONE=1` and the implicit-rejection `K`.

`ACK` is accepted only after `DONE` or `ERROR`; it clears the outcome, code and internal buffer-valid tracking before `READY` returns. `ABORT` is accepted while busy, invalidates the result, clears secret storage and then reports `ERROR` with code `6`; software uses `ACK` to return to `READY`. Reset invalidates results immediately and clears secret storage before asserting `READY`; `READY=0` during reset and clearing. Seed writes are accepted only while `READY=1`. The driver shall use device-memory ordering for CSR access and the platform's cache-coherency/maintenance rules for DMA buffers. `DONE` or `ERROR` asserts the IP interrupt until acknowledged; DMA completion/errors also reach the CPU through the platform interrupt controller. The CPU may execute other work after submission. It shall use outputs only after both IP success and all DMA transfers used by that request complete successfully. On error or timeout, the driver shall stop DMA, abort/reset the IP as needed, discard partial output and resynchronize the streams before submitting another request. Firmware shall protect and erase secret buffers under its control, including `dk` and `K`; IP clearing does not clear DMEM.

The host randomness service shall provide independent fresh 32-byte `d` and `z` for each KeyGen and a fresh 32-byte `m` for each Encaps, using a NIST-approved RBG with at least the strength in Section 2. The deployed application cannot choose these bytes. For a FIPS-conformance claim, the claimed cryptographic-module boundary must include and control this generation step; the SoC release shall identify the actual provider, its approval basis, seeding/health behavior, and failure path. This specification does not assume that K26 contains a qualified TRNG. Deterministic seed injection is restricted to simulation or an isolated validation build. One accelerator clock domain is the starting point; the SoC build shall document its clock/reset constraints and any required clock crossing.

### 4.1 Reserved PL TRNG/RBG hard-IP hook (optional, inactive)

The following randomness-adapter boundary is retained as an optional later PL hard-IP interface; it is not required by the DMA baseline. It is **not an instantiated TRNG in this checkout**. The initial design uses the host service and `SEED` window above; the reserved path stays inactive. When a suitable hard IP is integrated, the adapter shall supply the KEM controller with approved **RBG output**, whether the IP itself provides it or a TRNG entropy source feeds a separately assessed conditioning/DRBG construction. Raw TRNG words shall not be treated as FIPS 203 `d`, `z`, or `m` solely because they came from a physical noise source. The source change shall also revise the trusted-driver/`SEED`-window policy so that deployed software cannot override hard-IP randomness.

The following **conceptual signals** reserve that connection. The names describe the contract; they do not prescribe RTL module or port naming. Directions are relative to the KEM controller.

Comment to carry into the future top RTL at this boundary:

```systemverilog
// Reserved hook for a future PL TRNG/RBG hard IP. Inactive in the host-seeded build.
// rng_data must carry assessed RBG output; raw TRNG entropy is not d, z, or m.
// Integrate source selection, provider-health faults, and reset before enabling it.
```

| Signal | Direction | Comment for the future top RTL |
|---|---|---|
| `rng_req` | Out | Request one fresh 32-byte value; hold until accepted. KeyGen issues separate requests for `d` and `z`, Encaps one for `m`. |
| `rng_req_ready` | In | Accept the request only on `rng_req && rng_req_ready`; no request is accepted while an earlier value is incomplete. |
| `rng_strength[1:0]` | Out | Latched set encoding from `CONFIG`; adapter must meet the corresponding 128/192/256-bit RBG strength. |
| `rng_data[31:0]` | In | One post-RBG output word, in the byte order defined for CSR/seed words; eight accepted words form one value. |
| `rng_valid` / `rng_data_ready` | In / Out | Transfer a word only when both are asserted; backpressure must not drop or repeat a word. |
| `rng_fault` | In | Report provider/health failure; abort the pending KEM operation, clear partial random data and expose no result. |

If this optional boundary is implemented, the top RTL shall comment it as a **reserved hard-IP hook** and state whether the attached hard IP supplies raw entropy or approved RBG output. Until a provider is integrated, `rng_req_ready=0`, `rng_valid=0`, and `rng_data=0`; the PL source shall not be selectable. Once integrated, verification shall cover stalled data, exactly eight accepted words per request, separate KeyGen draws, and `rng_fault` before and during delivery. No FIPS-conformance or TRNG-quality claim follows from reserving these signals.

## 5. Verification plan

Both initial verification routes below target the **same specification and acceptance cases**. Either route may establish the first RTL regression. UVM is a framework choice, not a different definition of correctness.

| Level | Initial route without UVM | Initial route with UVM |
|---|---|---|
| Module adapters | Self-checking SystemVerilog testbenches and Python/C reference functions; directed valid/ready stalls and error cases. | Agents for each active interface, constrained sequences, scoreboards and assertions using the same reference functions. |
| PL KEM top | Deterministic `d,z,m` injected only in simulation; run all 3 × 3 operation/set combinations, official FIPS 203 vectors and independent software reference comparisons. | Equivalent sequences and oracle in a UVM environment; coverage records operation/set cross, errors, stalls and reset positions. |
| SoC | CPU firmware submits requests through AXI4-Lite/DMA, compares byte outputs in DMEM with reference vectors and exercises interrupt completion/recovery. | The same firmware test remains required; UVM SoC simulation may run before board testing. |

The shared minimum regression shall include:

1. KeyGen, Encaps and Decaps for each parameter set; successful Encaps/Decaps key agreement and exact `ek/dk/c/K` byte comparison against a FIPS 203 reference.
2. Noncanonical `ek`, wrong `ek/dk/c` lengths, wrong stored `H(ek)`, unsupported operation/set and insufficient output capacity.
3. A ciphertext of valid length chosen to fail re-encryption comparison: compare every byte, return the fallback key, and do not expose a rejection flag or error status.
4. Host RBG-provider failure before `START`, incomplete seed coverage, unit/DMA failure, reset/abort during work, a second request while busy, and producer/consumer stalls; ensure no stale or partial output.
5. Every CSR/seed and stream access rule in Section 4, packet framing, MMIO ordering, DMA-buffer coherency/ownership, interrupt completion while the CPU runs other work, output clearing, software timeout, and recovery after an error on the actual SoC.

The simulation oracle shall be independent of RTL algorithms and ROM contents. Seeds, vector provenance, dependency revisions, and commands to reproduce results shall be saved. Functional coverage is complete only when the nine operation/set combinations and each listed error class have executed and passed. For the SoC product, simulation alone is insufficient: the CPU-driven test must run on the integrated platform. A UVM regression does not waive that test.

## 6. Completion evidence and open decisions

The SoC release shall contain the integrated RTL and dependency revisions, build scripts and constraints, generated hardware image, firmware/driver source, the frozen host interface description, test vectors and logs, and instructions that reproduce the build and CPU-driven test. The report shall give cycle counts and end-to-end latency for all nine operation/set cases, LUT/FF/LUTRAM/BRAM/URAM/DSP utilization separately for the ML-KEM IP and whole SoC, routed timing, and a power estimate or measurement. It shall identify the platform, activity assumptions, measurement boundary, and whether power was estimated or measured. Until such reports exist for the SoC, no SoC frequency, area, power or board-operation result is claimed.

Current IP-level evidence (simulation and out-of-context implementation of `mlkem_core`, 64-bit streams, always-ready streams; cycles from `start` to `done`, including secret clearing):

| Set | KeyGen | Encaps | Decaps |
|---|---:|---:|---:|
| ML-KEM-512 | 1,900 | 3,023 | 5,707 |
| ML-KEM-768 | 2,014 | 3,142 | 5,849 |
| ML-KEM-1024 | 2,198 | 3,365 | 6,157 |

Routed out-of-context, Vivado 2025.2.1, top `mlkem_axi` (AXI wrapper included): K26 (`xck26-sfvc784-2LV-c`) meets 4.0 ns (250 MHz; WNS +0.276 ns, WHS +0.036 ns, estimated Fmax about 268 MHz) with 40,323 LUT (4,762 as distributed RAM, 825 as shift registers), 25,091 FF, 0 BRAM, 0 URAM, 0 DSP; Vivado's vectorless power estimate is 1.51 W. Details and the critical paths are in [RESULT.md](RESULT.md). These are IP measurements; they do not cover the DMA, interconnect or board.

| Decision needed before implementation of the affected boundary | Current state |
|---|---|
| Actual host RBG provider, approval/health evidence and driver binding | Contract fixed in Section 4; provider selection and qualification open |
| Optional PL TRNG/RBG hard IP and source selection | Optional inactive signal contract retained in Section 4.1; no provider selected or instantiated |
| Physical object-store banking and coefficient-domain adapters | LUTRAM/FIFO capacity follows simultaneously live objects; RTL organization open |
| Secret storage clearing implementation and reset timing | Observable behavior fixed in Section 4; RTL mechanism open |
| SoC address-map base, clock target and performance budget | Relative offsets fixed; platform assignment and measured budget open |

## 7. References and use of the literature

**Normative:** [NIST FIPS 203](https://doi.org/10.6028/NIST.FIPS.203), August 2024 final, especially Sections 3–8 and Algorithms 13–21. A release shall record the standard revision and review NIST's published errata. FIPS 202 defines the underlying SHA-3 family. The [OpenTitan documentation example](https://opentitan.org/book/doc/contributing/doc/example_ip_block.html) informs this document's overview → theory of operation → interface → verification structure only; it imposes no OpenTitan bus or RTL naming rule.

The 30 DOI entries in [Ref.txt](Ref.txt) describe complete KeyGen, Encaps and Decaps implementations, either autonomous hardware (`H`) or processor systems with hardware acceleration (`S`). A `*` in that file identifies area/resource, speed/latency and power/energy evidence for the same complete KEM design. The table below records the papers that most directly shaped this draft, in the same work → evidence → design decision form used by the [WOTS accelerator specification](https://github.com/KhoaLe-IC/wots_engine/blob/3d909447b9f24fc79caace35eae0f17f8e02a7d5/docs/WOTS_ACCELERATOR_SPEC.md). The complete list and the limits of each PPA claim remain in `Ref.txt`.

| Work | Evidence examined | Decision informed here | Limit when using its PPA |
|---|---|---|---|
| [Xing and Li, compact CCA-Kyber, 2021](https://doi.org/10.46586/tches.v2021.i2.328-356) [01] | Complete FPGA KEM, shared NTT/Keccak/storage; Artix-7 resources and operation cycles. | Keep local operation scheduling and a shared object store behind a stable command boundary (Section 3). | The paper does not give power for the same Artix-7 KEM, so it is an area–time reference only. |
| [Ni et al., ML-KEM architectural layers, 2025](https://doi.org/10.1145/3708469) [15] `*` | KeyGen/Encaps/Decaps; Artix-7 ML-KEM-512 server configuration: 10,076 LUT, 8,227 FF, 0 BRAM, 4 DSP, 270 MHz, 0.469 W estimated by Vivado. | Report every phase, total resources and the power method together; avoid treating an NTT result as KEM PPA (Sections 5–6). | This is a Vivado estimate on Artix-7, not a KV260 measurement or a target for this SoC. |
| [Nguyen et al., ML-KEM architecture, 2025](https://doi.org/10.1109/ACCESS.2025.3579379) [14] `*` | Full ML-KEM operation flow, FPGA comparison and ASIC area/frequency/energy. | Preserve FIPS 203 byte-level behavior while allowing a different physical memory organization (Sections 2–3). | Its measured energy belongs to the 180 nm ASIC, not its Artix-7 mapping. |
| [Ye et al., lattice processor, 2024](https://doi.org/10.46586/tches.v2024.i2.130-153) [21] `*` | Kyber KEM on a RISC-V/SIMD HW/SW processor; silicon-synthesis area, execution cycles and 2.01 mW at 200 MHz for Kyber-512. | Include CPU-visible transfer and software in SoC verification (Sections 4–5). | Pre-FIPS Kyber HW/SW results do not establish FIPS 203 conformance of this PL design. |
| [Kim et al., IoT PQC processor, 2024](https://doi.org/10.5573/JSTS.2024.24.1.55) [24] `*` | Table 3 reports ML-KEM-512 KeyGen+Encaps+Decaps, 5,794 cycles at 83 MHz, 0.83 mm², 7.49 KB SRAM and 16–24 mW estimated with PrimeTime. | Keep performance reports tied to a named operation/set and a declared measurement boundary (Section 6). | ASIC processor power and SRAM area cannot be converted into KV260 LUT/BRAM figures. |
| [RISQ-V, 2020](https://doi.org/10.46586/tches.v2020.i4.239-280) [22] `*` | Accelerated Kyber CCA on RISC-V; ASIC synthesis gives processor area, cycles and power/energy by parameter set. | Require an end-to-end CPU-driven test as well as PL module tests (Section 5). | The 65 nm processor result includes software and is not an autonomous KEM IP result. |
| [Unified ML-DSA/ML-KEM architecture, 2025](https://doi.org/10.1109/ACCESS.2025.3628733) [20] `*` | Complete KEM/DSA phases on Zynq UltraScale+, with total resource, 300 MHz timing and 6.86 W power. | Name the exact system boundary of a PPA report (Section 6). | The power is for the combined design, not ML-KEM alone or KV260. |

Among the checked Artix-7/KV260 studies, [15] supplies the required complete KEM PPA set including power. Other entries remain useful architecture references even where their PPA reports omit power. No qualifying KV260 paper was established. Paper architectures guide the design, while FIPS 203 is the functional authority. No paper's numerical result becomes a requirement without measurement on the integrated SoC.
