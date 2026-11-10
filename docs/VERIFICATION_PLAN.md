# ML-KEM Accelerator Verification Plan

**Status:** Pre-RTL plan  
**Primary methodology:** SystemVerilog UVM  
**Scope:** End-to-end integration plus reusable IP-level environments

## 1. Objectives

Verification shall establish:

1. FIPS 203 functional equivalence for KeyGen, Encaps, and Decaps across all
   parameter sets.
2. Correct command dispatch and data movement between the five compute/control
   IPs.
3. Protocol correctness under stalls, reset, abort, and error injection.
4. Absence of stale-data release and secret-dependent early termination within
   the documented threat model.
5. Reproducible closure by requirements, assertions, functional coverage, and
   code coverage.

Verification does not by itself establish NIST validation, side-channel
resistance, or physical signoff.

## 2. Verification Levels

| Level | Target | Required evidence |
|---|---|---|
| L0 | Pure functions/reference models | unit tests and independent cross-check |
| L1 | Individual RTL IP | directed/random tests, assertions, functional/code coverage |
| L2 | Adapter plus IP | command-to-native-protocol equivalence and error tests |
| L3 | Accelerator RTL | end-to-end FIPS 203 transactions and subsystem stress |
| L4 | FPGA integration | AXI/DMA/software/hardware tests on KV260 |
| L5 | Gate/netlist | LEC, gate simulation where justified, STA-aware reset/test checks |

No level may inherit PASS solely from a lower level.

## 3. Reference Models

- The end-to-end golden model shall be an approved FIPS 203 implementation
  pinned by source revision and build options.
- Keccak references shall be cross-checked against FIPS 202 and a second
  independent implementation such as Python `hashlib` where supported.
- Polynomial arithmetic, sampling, and codec functions shall have independent
  mathematical models that expose intermediate values.
- Randomness shall be injected deterministically for comparison tests.
- Reference-model inputs and outputs shall be serialized in a documented,
  versioned vector format.

Reference code shall not be mechanically translated from RTL under test.

## 4. UVM Environment

```text
mlkem_env
  host_agent
  command_agent
  object_store_agent
  keccak_agent
  sampler_agent
  codec_agent
  polyengine_agent
  reset_error_agent
  virtual_sequencer
  reference_model
  scoreboard
  coverage_collector
```

### 4.1 Agents

- `host_agent`: programs control/status and moves input/output data.
- `command_agent`: monitors sequencer command stability, acceptance, and
  completion.
- Compute agents: active in adapter/IP verification; passive in full-system
  verification unless fault injection is enabled.
- `object_store_agent`: observes logical-to-physical mapping, access ordering,
  aliasing, and zeroization.
- `reset_error_agent`: injects resets, command errors, timeouts, and malformed
  requests at controlled phases.

Transaction classes shall represent semantic operations, not raw pin toggles
only.

### 4.2 Scoreboarding

The scoreboard shall compare:

- final `ek`, `dk`, ciphertext, and shared secret;
- ordered command stream;
- selected intermediate objects at reviewed observation points;
- object representation/domain metadata;
- error and completion status;
- constant-work schedule for valid and invalid decapsulation cases.

Multiple mismatches caused by one root event shall be grouped without hiding the
first failing transaction.

## 5. Required Tests

### 5.1 Smoke

- Reset and idle behavior.
- One deterministic KeyGen, Encaps, and Decaps per parameter set.
- Valid encapsulation/decapsulation shared-secret agreement.
- Invalid operation and parameter-set encodings.

### 5.2 Functional

- Published and generated known-answer vectors.
- Boundary-valued coefficients and encoded fields.
- All legal eta, `du`, and `dv` combinations used by FIPS 203.
- Minimum, exact-rate, and multi-rate Keccak messages.
- Rejection-sampling refill behavior.
- NTT/INTT round trips and polynomial products.
- Encode/decode and compress/decompress properties.
- Valid and modified ciphertext decapsulation paths.

### 5.3 Protocol and stress

- Random command and compute-unit backpressure.
- Maximum legal response latency.
- Back-to-back host requests according to the frozen host contract.
- Reset in every reachable control phase.
- Compute-unit error in every command class.
- Object-store port conflicts and permitted aliasing.
- Long randomized sequences with deterministic seeds.

### 5.4 Security-oriented

- Compare cycle/command traces for valid and invalid ciphertext classes.
- Verify no secret object is readable through host/debug paths.
- Verify zeroization after completion, abort, and reset.
- Verify stale output cannot be marked valid after an error.

These tests are functional checks only, not side-channel certification.

## 6. Assertions and Formal Properties

Minimum SVA/property set:

- valid/ready payload stability;
- no completion without an accepted command;
- `cmd_done` and `cmd_error` mutual exclusion;
- one outstanding baseline command;
- no overwrite of a live logical object without permitted aliasing;
- operation/parameter stability while busy;
- done/error pulse and idle-return behavior;
- bounded progress under explicit fairness assumptions;
- legal object index ranges for active parameter set;
- output validity only after successful final command;
- zeroization completion before secret slot reuse.

Formal proofs shall state assumptions explicitly. Vacuous proofs and
over-constrained environments are not closure.

## 7. Functional Coverage

Cross coverage shall include:

- operation x parameter set;
- command x logical object x relevant flags;
- parameter set x eta/du/dv;
- command x stall depth;
- phase x reset/error injection;
- valid/invalid ciphertext x select outcome;
- storage slot x producer x consumer;
- representation/domain transition;
- host transfer size/alignment x operation.

Illegal bins shall correspond to reviewed illegal behavior, not simply
uninteresting behavior.

## 8. Code Coverage

Collect statement, branch, expression, toggle, and FSM coverage where supported.
Targets shall be fixed before closure. A recommended initial gate is:

- 100% reachable FSM state and transition coverage;
- 100% safety-critical branch coverage;
- at least 95% statement and branch coverage for integration RTL;
- reviewed justification for every exclusion.

Coverage numbers below the target require a signed waiver with impact analysis.

## 9. Regression Tiers

| Tier | Contents | Trigger |
|---|---|---|
| Pre-commit | compile, lint subset, smoke tests | every RTL/DV change |
| Nightly | all IP tests, integration random tests, assertions, coverage | daily |
| Weekly | long random, formal suite, fault/reset campaign | scheduled |
| Release | pinned tools/seeds, full coverage merge, signoff reports | release candidate |
| FPGA | software plus bitstream regression on KV260 | integration release |

Every failure shall preserve seed, configuration, first mismatch, RTL revision,
and reference-model revision.

## 10. Closure Criteria

Release verification is closed only when:

- every normative requirement has PASS evidence or an approved waiver;
- all planned tests pass with reproducible logs;
- no open high-severity mismatch remains;
- assertion failures are zero;
- functional and code coverage targets are met;
- CDC/RDC/lint issues affecting behavior are resolved or waived;
- the tested RTL/file list matches the implementation release;
- known limitations are published.

Simulation PASS is not timing, power, FPGA, ASIC, or FIPS signoff.


## 11. Current Evidence (non-UVM route)

The first regression follows the "initial route without UVM" of SPEC section 5.

| Item | Status | Reproduce |
|---|---|---|
| Golden model | `vector/mlkem_gen.py`, written from FIPS 203; cross-checked against the independent `kyber-py` package for all parameter sets (KeyGen, Encaps, Decaps, implicit rejection). Confirms the NTT IP scaling and the Compress/Montgomery constants exhaustively. | `python3 Implementation/vector/mlkem_gen.py N` |
| Core regression | `tb_mlkem_core`: 3 operations × 3 sets, implicit rejection, invalid `ek`, wrong `H(ek)` in `dk`, early `TLAST`, ABORT, invalid configuration, recovery; random backpressure on both streams; all words, `TKEEP` and `TLAST` compared. | `make test STALL=<pct> SEED=<n> N=<keys per set>` |
| IP top | `tb_mlkem_axi`: requests through the register map and streams, SLVERR rules, error codes 1/2/4/6, ACK lifecycle, READY low during the post-reset clear. | `make test-axi` |
| Performance | Cycle counts per request with always-ready streams; engine timelines. | `make perf`, `make trace` |
| Lint | Verilator `-Wall` clean for the new RTL (three warning classes are disabled because they occur only inside the reused NTT/Keccak IPs). | `make lint` |

Not yet covered: UVM environment, assertions/formal properties, functional and
code coverage collection, gate-level simulation, the SoC/DMA firmware test and
board runs. The bench checks outputs, not the absence of secrets in cleared
memories.
