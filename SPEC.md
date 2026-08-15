# ML-KEM Accelerator Integration Specification

**Document status:** Draft design contract  
**Repository status:** Integration RTL is not yet implemented  
**Normative language:** `shall`, `shall not`, `must`, and `must not` state
requirements. `should` states a recommendation. `TBD` is an unresolved design
decision. `UNVERIFIED` identifies a claim without current implementation
evidence.

## 1. Purpose and Scope

This repository is the integration point for a hardware accelerator implementing
ML-KEM KeyGen, Encaps, and Decaps for ML-KEM-512, ML-KEM-768, and ML-KEM-1024.
The accelerator combines the following independently developed IP repositories:

| IP | Responsibility |
|---|---|
| `keccak-mlkem` | Keccak-f[1600], SHAKE128, SHAKE256, SHA3-256, SHA3-512 |
| `sampler-mlkem` | `SampleNTT` rejection sampling and centered binomial sampling |
| `codec-mlkem` | coefficient compression/decompression and byte encoding/decoding |
| `polyengine-mlkem` | NTT, INTT, base multiplication/accumulation and polynomial arithmetic |
| `sequencer-mlkem` | parameter-set-aware KeyGen, Encaps, and Decaps command schedule |
| `accelerator-mlkem` | object storage, dispatch, arbitration, host interface and end-to-end control |

The first FPGA integration target is the AMD Kria KV260 Vision AI Starter Kit
with a Kria K26 SOM. ASIC implementation is a supported downstream flow, not a
claim that an ASIC implementation currently exists.

### 1.1 Normative references

- NIST FIPS 203, *Module-Lattice-Based Key-Encapsulation Mechanism Standard*.
- NIST FIPS 202, *SHA-3 Standard: Permutation-Based Hash and Extendable-Output
  Functions*.
- IEEE 1800, SystemVerilog.
- IEEE 1800.2, Universal Verification Methodology.
- AMBA AXI4-Lite and AXI4-Stream specifications when those interfaces are
  selected for the KV260 wrapper.

The exact revision of every external standard and tool shall be recorded in each
release manifest.

### 1.2 Non-goals

- This specification does not claim NIST validation or certification.
- Side-channel, masking, fault-injection, and tamper resistance are not claimed.
- A specific AXI register map, DMA architecture, clock frequency, latency, or
  resource count is not frozen until the corresponding design decision is
  reviewed and versioned.
- `ntt-mlkem` is not an integration dependency. Polynomial operations are owned
  by `polyengine-mlkem`.

## 2. Configuration

### 2.1 ML-KEM parameter sets

| Set | `k` | `eta1` | `eta2` | `du` | `dv` |
|---|---:|---:|---:|---:|---:|
| ML-KEM-512 | 2 | 3 | 2 | 10 | 4 |
| ML-KEM-768 | 3 | 2 | 2 | 10 | 4 |
| ML-KEM-1024 | 4 | 2 | 2 | 11 | 5 |

These values shall be sourced from one reviewed package or generated definition
at integration time. Duplicate, independently editable copies are prohibited.

### 2.2 Arithmetic representation

- Polynomial degree shall be `n = 256`.
- Coefficients represent elements modulo `q = 3329`.
- Every IP boundary shall state whether coefficients are canonical
  `[0, q-1]`, signed centered, lazy-reduced, Montgomery-domain, or NTT-domain.
- An IP shall not silently change coefficient domain or ordering.
- Byte and bit ordering shall match FIPS 203. The host-visible serialization and
  internal coefficient layout shall be documented separately.

The current repositories do not yet provide one shared machine-readable type and
representation package. This is a release blocker for end-to-end integration.

## 3. Top-Level Architecture

```text
Host / test harness
        |
        v
Control and data ingress/egress
        |
        v
ML-KEM sequencer ----> command dispatcher ----> Keccak
        |                     |                Sampler
        |                     |                Codec
        |                     +--------------> Polynomial engine
        |                                     
        +--------------> object store / scratch allocator
                               |
                               v
                     compare, select, zeroize
```

### 3.1 Ownership

- The sequencer owns algorithmic ordering and parameter-set iteration.
- The dispatcher owns command acceptance, destination selection, completion,
  error propagation, and prevention of overlapping command execution unless
  concurrency is explicitly proven safe.
- The object store owns physical storage and maps logical objects to storage
  locations.
- Compute IPs own only their declared transforms. They shall not infer the
  high-level ML-KEM operation from hidden global state.
- The accelerator wrapper owns host protocol compliance and software-visible
  status.

### 3.2 Logical objects

The integration shall support the logical object identifiers currently emitted
by `sequencer-mlkem`:

`A`, `S`, `E`, `T`, `Y`, `E1`, `E2`, `U`, `V`, `M`, `W`, `EK`, `DK`, `C`,
`K`, and `TEMP`.

Before RTL implementation, an object-lifetime table shall define for every
operation and parameter set:

- maximum size;
- representation and domain;
- producer and consumers;
- first and last use;
- read/write concurrency;
- zeroization requirement;
- permitted storage aliasing.

Physical slot numbers shall not be embedded in the sequencer command encoding.

## 4. Functional Requirements

| ID | Requirement |
|---|---|
| ACC-FUNC-001 | The accelerator shall support KeyGen, Encaps, and Decaps for all three FIPS 203 parameter sets. |
| ACC-FUNC-002 | A request shall latch its operation and parameter set exactly once when accepted. |
| ACC-FUNC-003 | Unsupported operation or parameter-set encodings shall terminate with an error and shall not expose stale output. |
| ACC-FUNC-004 | The dispatcher shall execute each accepted sequencer command exactly once. |
| ACC-FUNC-005 | A compute-unit error shall abort the active transaction and propagate a deterministic error status. |
| ACC-FUNC-006 | Decapsulation shall perform re-encryption, ciphertext comparison, fallback-key derivation, and final key selection without secret-dependent early termination. |
| ACC-FUNC-007 | Output bytes shall match an approved FIPS 203 reference model for identical inputs and randomness. |
| ACC-FUNC-008 | Reset or abort shall return all interfaces to idle and invalidate partial outputs. |
| ACC-FUNC-009 | Secret-bearing storage shall be zeroized according to the reviewed zeroization policy before reuse or external debug access. |
| ACC-FUNC-010 | The design shall not use uninitialized storage contents as algorithmic input. |

## 5. Internal Command Contract

The baseline command interface is the interface exposed by
`mlkem_sequencer_top`:

- `cmd_valid` / `cmd_ready` accepts one command descriptor.
- `cmd_done` reports successful completion.
- `cmd_error` reports failed completion.
- `cmd_op[4:0]` selects the operation.
- `cmd_object[3:0]`, `cmd_i[2:0]`, and `cmd_j[2:0]` identify the logical object
  and vector/matrix position.
- `cmd_param[3:0]` carries eta, encoding width, compression width, or a source
  object identifier as defined by the selected command.
- `cmd_nonce[7:0]` carries the CBD sampling nonce.
- `cmd_flags[3:0]` carries transpose, accumulation, and re-encryption flags.
- `cmd_last` marks the final output command.

### 5.1 Handshake requirements

| ID | Requirement |
|---|---|
| ACC-CMD-001 | A command transfers only on a cycle where `cmd_valid && cmd_ready` is true. |
| ACC-CMD-002 | All command fields shall remain stable while `cmd_valid` is asserted and `cmd_ready` is deasserted. |
| ACC-CMD-003 | After transfer, the sequencer shall not issue the next command until the dispatcher returns `cmd_done` or `cmd_error`. |
| ACC-CMD-004 | `cmd_done` and `cmd_error` shall be mutually exclusive. |
| ACC-CMD-005 | Completion shall correspond to the most recently accepted command; out-of-order completion is not supported by the baseline contract. |
| ACC-CMD-006 | Reserved command, object, parameter, and flag encodings shall produce a deterministic integration error. |

The command encoding shall be imported from one shared versioned definition.
Copying macros into multiple repositories without compatibility checking is not
an acceptable release mechanism.

## 6. Compute-IP Adaptation

The current IPs do not expose one common transaction protocol. Integration shall
use explicit adapters where necessary; compute RTL shall not be rewritten solely
to resemble a bus protocol.

### 6.1 Keccak adapter

The adapter shall:

- select SHAKE128, SHAKE256, SHA3-256, or SHA3-512 as required by the command;
- prepare padding and complete absorb blocks;
- support variable-length XOF squeeze for rejection sampling;
- prevent stale state from crossing transactions;
- expose only mode-valid output bytes.

### 6.2 Sampler adapter

The adapter shall:

- route SHAKE128 XOF bytes to `SampleNTT`;
- route SHAKE256 PRF output to centered binomial sampling;
- propagate eta and nonce exactly;
- continue requesting XOF blocks until 256 accepted coefficients are produced;
- preserve coefficient order.

### 6.3 Codec adapter

The adapter shall bind the selected `d` value to the correct encode, decode,
compress, or decompress operation and shall enforce legal widths for the active
parameter set.

### 6.4 Polynomial-engine adapter

The adapter shall define:

- memory load/store sequencing;
- coefficient representation at every command boundary;
- NTT/INTT scaling and ordering;
- base-multiplication source/destination operands;
- accumulation initialization and carry-over rules;
- add/sub/reduction behavior.

No command may be integrated until its domain and memory-side effects are
traceable to the polynomial-engine specification.

## 7. Host Interface

The compute core shall remain separable from the host wrapper.

### 7.1 KV260 baseline

The intended prototype architecture is:

```text
Arm processing system
    | AXI4-Lite control/status
    | AXI4-Stream or AXI memory/DMA data path
    v
Programmable-logic ML-KEM accelerator
```

The final interface choice is `TBD`. Before implementation, the host-interface
specification shall freeze:

- register offsets and reset values;
- access type and side effects;
- command submission and completion semantics;
- input/output buffer ownership and alignment;
- interrupt behavior;
- timeout and recovery behavior;
- endianness;
- maximum transfer sizes;
- illegal-access response.

The KV260 is an evaluation target. Board validation does not establish ASIC
signoff, FIPS validation, or production security.

## 8. Clock, Reset, CDC, and RDC

| ID | Requirement |
|---|---|
| ACC-CLK-001 | Every release shall identify all clocks, generated clocks, frequencies, uncertainty assumptions, and relationships. |
| ACC-RST-001 | Reset assertion/deassertion behavior shall be defined per clock domain. Asynchronous deassertion into functional logic is prohibited unless specifically analyzed. |
| ACC-CDC-001 | All clock-domain crossings shall use reviewed structures and pass structural CDC analysis. |
| ACC-RDC-001 | Reset-domain crossings shall pass RDC analysis or carry reviewed waivers. |
| ACC-CLK-002 | False-path and multicycle exceptions shall have endpoint-level justification and shall not be used to hide functional timing paths. |

The baseline architecture should use one PL clock until a measured need for
multiple domains exists.

## 9. Performance and Resource Requirements

Performance and resource targets are not yet measured.

Each implementation release shall report:

- cycle count and wall-clock latency for every operation and parameter set;
- sustained throughput under documented host and memory assumptions;
- LUT, FF, BRAM, URAM, and DSP utilization;
- maximum object-store footprint;
- dynamic and static power with activity assumptions;
- critical path and fully routed timing summary.

The architecture objective is to minimize BRAM, URAM, and DSP usage and may use
LUTRAM where timing, capacity, and port requirements permit. This objective does
not authorize inference directives that silently change behavior or block ASIC
portability.

## 10. Security Requirements

| ID | Requirement |
|---|---|
| ACC-SEC-001 | Secret-dependent early exit is prohibited in decapsulation compare/select behavior. |
| ACC-SEC-002 | Debug and host readback shall not expose secret intermediate objects. |
| ACC-SEC-003 | Reset, abort, and transaction completion shall follow the reviewed zeroization policy. |
| ACC-SEC-004 | Randomness inputs and trust boundaries shall be documented; no internal entropy claim shall be made without a dedicated entropy-source design and validation. |
| ACC-SEC-005 | Fault response shall not release partially computed or stale keys. |

Power/EM side-channel resistance, masking, formal non-interference, and
fault-injection resistance are currently out of scope and shall be reported as
`NOT CLAIMED`.

## 11. Verification and Traceability

The normative verification strategy is defined in
[`docs/VERIFICATION_PLAN.md`](docs/VERIFICATION_PLAN.md). Every requirement in
this file shall map to one or more tests, assertions, formal properties, or
reviewed analysis artifacts.

Minimum end-to-end references:

- an approved FIPS 203 software implementation;
- NIST known-answer or validation vectors when licensing and format permit;
- independent per-IP reference models;
- deterministic seeds and reproducible regressions.

Passing unit tests is not sufficient for integration closure.

## 12. Implementation and Release

FPGA and ASIC signoff gates are defined in
[`docs/IMPLEMENTATION_SIGNOFF.md`](docs/IMPLEMENTATION_SIGNOFF.md).

A release shall include:

- RTL and dependency revisions;
- generated-definition provenance;
- build/file list and tool versions;
- requirements-to-verification matrix;
- regression and coverage reports;
- lint, CDC, and RDC reports;
- synthesis and timing reports;
- implementation DRC and unconstrained-path status;
- known issues and reviewed waivers;
- reproducible build instructions.

## 13. Open Decisions

| ID | Decision | Status |
|---|---|---|
| ACC-OPEN-001 | Accelerator top-level module and pin-level interface | TBD |
| ACC-OPEN-002 | AXI4-Lite register map | TBD |
| ACC-OPEN-003 | Bulk data path: stream, DMA, or shared memory | TBD |
| ACC-OPEN-004 | Object-store banking and LUTRAM/BRAM mapping | TBD |
| ACC-OPEN-005 | Shared machine-readable command/type package | TBD |
| ACC-OPEN-006 | Zeroization policy and verification method | TBD |
| ACC-OPEN-007 | Target PL clock and performance budgets | TBD |
| ACC-OPEN-008 | ASIC technology, libraries, corners, and DFT architecture | TBD |

