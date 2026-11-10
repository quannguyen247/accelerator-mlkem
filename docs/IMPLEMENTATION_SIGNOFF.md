# ML-KEM Accelerator Implementation and Signoff

This document defines evidence gates for FPGA prototyping and ASIC
implementation. It does not report current PPA or signoff results.

## 1. Common Front-End Gates

Before either flow:

1. Freeze RTL, generated definitions, file lists, parameters, constraints, and
   verification revisions.
2. Run syntax/elaboration for every supported configuration.
3. Close lint findings or document reviewed waivers.
4. Run structural CDC and RDC analysis.
5. Verify clock/reset intent and all timing exceptions.
6. Pass the release UVM regression and required formal properties.
7. Record tool versions, invocation scripts, environment, and checksums.

No estimated timing or resource number may be reported as measured signoff.

## 2. FPGA Flow: AMD Kria KV260

The KV260 is the evaluation platform; the programmable-logic target is the Kria
K26 SOM selected through the applicable AMD board/part definition.

### 2.1 Out-of-context IP runs

Each IP and adapter shall have an OOC run with:

- declared top, clocks, resets, and XDC;
- synthesis utilization by primitive class;
- inferred-memory report identifying LUTRAM, BRAM, and URAM;
- DSP inference report;
- unconstrained-path report;
- timing summary;
- methodology DRC report.

OOC results are diagnostic and do not establish integrated timing.

### 2.2 Integrated hardware

The integrated KV260 design shall include:

- processing-system configuration and clock/reset generation;
- reviewed AXI interconnect and host wrapper;
- address map and interrupt wiring;
- accelerator constraints;
- implementation through bitstream generation;
- exported hardware/software handoff artifact;
- software tests that exercise all parameter sets and operations.

### 2.3 FPGA signoff gates

- Place and route completes with zero unrouted or partially routed nets.
- WNS, TNS, WHS, and THS meet the release thresholds for every declared clock.
- No unconstrained functional endpoints remain.
- Critical warnings and methodology DRC violations are zero or waived.
- Clock interaction, CDC, and reset reports are reviewed.
- Utilization is within device and per-region budgets.
- Power is reported with stated activity, environment, and confidence level.
- Post-route netlist/file list matches the tested release.
- On-board KV260 results include software revision, bitstream hash, clock,
  operation, parameter set, vector set, and measured latency.

Passing behavioral simulation or synthesis alone is not FPGA signoff.

## 3. Resource-Minimization Policy

The project objective is to minimize BRAM, URAM, and DSP consumption.

- LUTRAM may be selected for small memories when read/write semantics, capacity,
  fanout, timing, and power are acceptable.
- Storage banking and lifetime reuse shall be architectural decisions, not
  tool-dependent accidents.
- Arithmetic shall not be narrowed solely because synthesis pruned bits; the
  mathematical range and downstream use must prove equivalence.
- Every optimization shall preserve a pre-optimization reference and pass
  equivalence or targeted mathematical regression.
- Resource results shall state whether they are post-synthesis or post-route.

## 4. ASIC Flow

The ASIC flow is technology- and tool-neutral until a process and library set
are selected.

### 4.1 RTL and synthesis

- Freeze synthesizable RTL and remove FPGA-only wrappers from the ASIC file list.
- Define clocks, generated clocks, resets, test modes, operating modes, and
  power intent.
- Run lint, CDC, RDC, and synthesis at all required configurations.
- Run RTL-to-synthesis logical equivalence checking.
- Review inferred memories and replace FPGA primitives with characterized SRAM
  macros or synthesizable implementations.

### 4.2 DFT

The release plan shall define:

- scan architecture and clock/reset handling;
- scan exclusions and test-point policy;
- memory BIST strategy for object storage and ROM/RAM blocks;
- test-mode constraints;
- ATPG coverage target and untestable-fault review;
- X-handling and secure-state behavior in test mode.

DFT insertion shall be followed by equivalence and timing analysis.

### 4.3 Physical implementation

- Establish floorplan, power grid, macro placement, clock tree, and congestion
  budgets.
- Complete placement, clock-tree synthesis, routing, extraction, and
  optimization.
- Close setup/hold across all required MMMC views.
- Run signal-integrity/noise, electromigration, IR-drop, antenna, density, DRC,
  and LVS checks as required by the selected technology.
- Perform post-layout equivalence and power analysis with representative
  activity.

### 4.4 ASIC release artifacts

- synthesizable RTL and generated source;
- constraints and MMMC configuration;
- UPF/CPF if low-power intent exists;
- DFT configuration and reports;
- synthesis and equivalence reports;
- netlists, SDF/SPEF and timing models;
- physical database/GDS and foundry signoff reports;
- power/activity reports;
- verification and waiver database;
- reproducible manifests and checksums.

## 5. Signoff Matrix

| Evidence | FPGA OOC | FPGA integrated | ASIC |
|---|---:|---:|---:|
| RTL/UVM regression | Required | Required | Required |
| Lint/CDC/RDC | Required | Required | Required |
| Synthesis | Required | Required | Required |
| Fully routed STA | Informative | Required | Required |
| Implementation DRC | Informative | Required | Required |
| LEC | Recommended | Recommended | Required |
| DFT/ATPG/MBIST | N/A | N/A | Required |
| Board software test | N/A | Required | N/A |
| Power with stated activity | Required | Required | Required |

Any missing item shall be labeled `UNVERIFIED`; it shall not be inferred from a
different configuration or implementation stage.

