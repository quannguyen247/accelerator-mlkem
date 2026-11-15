# Plan: area reduction to < 30k LUT / < 20k FF (0 BRAM, 0 DSP)

Goal: keep every KeyGen / Encaps / Decaps point (ML-KEM-512/768/1024) faster
than Paper 13 (Jung, OJCAS'25) and Paper 15 (Ni, TECS'25) while cutting the
area from ~58k LUT / ~42k FF (9 ntt4 lanes, PMAC 16 coef/cycle).

## Cycle budgets (planning, at 227.3 MHz: the faster of the two papers)

| Set  | KeyGen | Encaps | Decaps |
|------|--------|--------|--------|
| 512  | 1523   | 2250   | 3114   |
| 768  | 2796   | 3523   | 4546   |
| 1024 | 4387   | 5137   | 6523   |

## Result (Vivado 2025.2.1, OOC, xc7a200tfbg676-3, 4 ns, 0 BRAM / 0 DSP)

Default synthesis and implementation flow (`opt`, `place`, `phys_opt`,
`route`), `constraint/mlkem.xdc`:

| Build | LUT | of which memory | FF | Slices | WNS | Fmax | Power (vectorless) |
|-------|-----|-----------------|----|--------|-----|------|--------------------|
| 4 ns (step 5) | 31,430 | 4,972 | 19,429 | 9,415 | +0.004 ns | 250.3 MHz | 1.97 W |
| 5 ns (step 4) | 30,660 | 4,971 | 19,171 | 9,361 | +0.067 ns | 202.7 MHz | 1.59 W |

Core cycles (`make perf`; the AXI top adds 2) and µs at 250 MHz:

| Set  | KeyGen        | Encaps        | Decaps         | Paper 15 (µs)      | Paper 13 (µs)      |
|------|---------------|---------------|----------------|--------------------|--------------------|
| 512  | 1277 (5.11)   | 1803 (7.21)   | 2657 (10.63)   | 6.7 / 9.9 / 13.7   | 8.1 / 12.1 / 18.0  |
| 768  | 1813 (7.25)   | 2398 (9.59)   | 3853 (15.41)   | 12.3 / 15.5 / 20.0 | 13.9 / 18.4 / 26.1 |
| 1024 | 2605 (10.42)  | 3190 (12.76)  | 4543 (18.17)   | 19.3 / 22.6 / 28.7 | 20.7 / 27.4 / 36.0 |

Every point is 22-46 % faster than Paper 15 and 37-53 % faster than Paper 13
(Decaps-512 / 768, about 22 %, are bound by the two engines: one of them runs
three transforms in a row in the re-encryption).
AT and power stay above Paper 15 (4 DSP, 270 MHz); with 0 DSP / 0 BRAM the
multipliers and the stores are LUTs.

## Status

| Step | Change | State |
|------|--------|-------|
| 1 | PMAC 16 -> 8 coef/cycle (2+2 basemul lanes, half blocks) | DONE, tests pass |
| 2 | Lanes 9 -> 9 contexts + 2 shared ntt4 engines + job dispatcher | DONE, tests pass |
| 3 | Keccak `msg_block` removed: long-job words XORed straight into the state | DONE |
| 4 | Area trims (see "Step 3+" below) | DONE, tests pass |

`make perf` after step 1 (cycles, core):

| Set  | KeyGen | Encaps | Decaps |
|------|--------|--------|--------|
| 512  | 978    | 1348   | 2315   |
| 768  | 1469   | 1716   | 2646   |
| 1024 | 2329   | 2521   | 3596   |

Step 1 details (`rtl/modules/poly/mlkem_pmac.v`):
- `bp`, `bp1`, `b_grp` and `nxt_b` count half-blocks. They are 7 bits wide, and 64 means finished.
- Stage 1 splits `b` into `blk1 = b[6:1]` and the half bit `h1 = b[0]`.
- Stage 2 selects 48-bit halves.
- The lower-half result is held in `lo0`/`lo1`, and the block is written together with the upper half.
- `mid_any` forces the upper half of a block to be the very next group, because the output holds only one half.

Keccak:
- `sblk` and the sponge's `squeeze_data` are combinational, not registers.
- The real registers (`msg_block`, `cap` and the state) are the absorb/squeeze double buffers that keep Keccak streaming.
- Removing one of them would slow KeyGen, which is limited by the XOF, so this step is dropped.

`make perf` after step 2 (cycles, core; µs at 227.3 MHz):

| Set  | KeyGen       | Encaps       | Decaps        |
|------|--------------|--------------|---------------|
| 512  | 1224 (5.4)   | 1661 (7.3)   | 2632 (11.6)   |
| 768  | 1749 (7.7)   | 2189 (9.6)   | 3632 (16.0)   |
| 1024 | 2329 (10.2)  | 2863 (12.6)  | 4366 (19.2)   |

Step 2 as built:
- `mlkem_lane_ctx.v` (new): per logical lane noise memory, buffer and fill state.
- `mlkem_lane.v`: now a shared engine. The role (vector / row / scalar) and the
  job number are latched per job; one `mlkem_compress #(.HI(2))` serves all d.
- `mlkem_core.v`: `NENG = 2` engines; dispatcher (`pend`, `jn`, `rdy_q`,
  priority vector > scalar > row, lowest free engine); S/C store ports and
  m' are muxed by the engine's lane / C slot.
- `mlkem_pmac.v`: Decaps re-encryption takes pairs lowest first (round robin
  starved the two engines).
- Readiness `rdy_q` is cleared on go and when a lane's second job is queued
  (a stale answer parked an engine for hundreds of cycles).

## Step 3+: area trims (all tests pass after each)

- Hash: `msg_block` (1344 FF) removed; H(ek) / J words are XORed into their
  rate lane while the sponge waits (`wx_en` / `wx_word`, permutation
  `xor_only`), the pad goes with the block handshake. Encaps +90..190 cycles.
- Sponge `MASK = 0`: no per-mode output mask (callers read only their bits).
- rho / h / z / m' share registers: the hash writes rho, h into `mlkem_in`'s
  registers, the seed port writes z there, m' lives in `seed_a`.
- PMAC 4 coef/cycle: one basemul lane per row, quarter blocks; a single-row
  pair (DEC w, the last ENC/KG pair) runs both lanes on two quarters of the
  row. Stage-R registers hold only the needed halves.
- Engine constant multipliers as shift-add: Compress (x * 161271, CSD) and the
  PMAC operand scale (x * 1353 / 1441).
- S, T, C stores and row buffers: one LUTRAM copy each, read address chosen
  by the operation (the output engine and the compute side never read the
  same store in one operation).
- Fixed lane-to-engine map (engine 0: lanes 0, 3, 5, 6; engine 1: 1, 2, 4, 7,
  later 0, 2, 5, 7 / 1, 3, 4, 6, see step 5;
  lane 8 either; pick order vector, row, scalar): 5:1 context selects.
- PMAC results scaled at the PMAC output (`mlkem_scale`) instead of the
  vector operands in both engines; Decaps re-encryption takes the v row first.
- Tried and rejected: hash FIFO depth 128 (Decaps-768 deadlocks: the FIFO
  fills while the hash waits for the ciphertext); separate rho / h / z
  registers again (-176 LUT, +746 FF, +239 slices).

`make perf` now (cycles; µs at 227.3 MHz; budget = faster paper):

| Set  | KeyGen               | Encaps               | Decaps               |
|------|----------------------|----------------------|----------------------|
| 512  | 1272 (5.6) / 1523    | 1877 (8.3) / 2250    | 2760 (12.1) / 3114   |
| 768  | 1830 (8.1) / 2796    | 2548 (11.2) / 3523   | 3892 (17.1) / 4546   |
| 1024 | 2585 (11.4) / 4387   | 3355 (14.8) / 5137   | 4861 (21.4) / 6523   |

Yosys `synth_xilinx -nodsp -nobram -flatten` on `mlkem_axi` (estimate only,
Vivado not run):

| Build | Logic LUT | LUTRAM (LUTs) | SRL | FF |
|-------|-----------|---------------|-----|----|
| 9 lanes, single butterfly (Vivado: 40.3k LUT / 29.3k FF) | 43.3k | - | - | 29.0k |
| 9 ntt4 lanes, PMAC 16 | 64.7k | - | 3.3k | 42.3k |
| 2 engines + all trims (now) | 33.4k | 4.3k | 1.0k | 18.7k |

Scaling logic LUTs by the old Vivado/Yosys ratio (0.76) gives about 30-31k
total LUT in Vivado; FF stays below 20k. Remaining large blocks (hierarchical
Yosys): Keccak sponge 6.9k LUT, two engines 2 x 4.9k (ntt4 2.4k each), PMAC
4.0k, input 2.1k, output 2.0k, sampler 1.4k, core glue 5.0k. Going further
(one engine, or a two-butterfly NTT) breaks the Decaps-512 budget.

## Step 5: timing to 4 ns (250 MHz)

At 3.6 ns the 5 ns build reached 4.11 ns; three quarters of every critical
path was routing. The worst paths all had the same shape: a far register,
an address select, a fanout-96 net into a LUTRAM, the slot / source select
and the reader's register (three long nets in one cycle). Changes:

- Store reads take one cycle: `mlkem_poly_ram` `RREG = 1` registers the read
  address beside the memory (kept per memory, so equal addresses are not
  merged). The S, T, C stores and every lane buffer use it.
  - Engines: one more read stage (`na`, `la_v`, `cbd_a`), the core read
    follows the issue by a cycle, unload drain 12.
  - PMAC: sends the stage-0 block (`b[7:2]`), so the memory copy is its
    stage 1 (no extra latency).
  - Output engine: stage A (the stores take `bcnt` while `adv`), the data
    slot `rd_dslot` follows it; `secrets_read` waits until no store block is
    in stage A.
- Noise count of each engine's lane registered (like the fills).
- Keccak: the state bit's LUT takes the round output or the bit XOR its
  block bit (input net kept, clear and lane enables on the register reset
  and enables, iota on lane 0's own chi operand): 3 LUT levels.
- Rejection precount: 4 stages (popcount of 7, pairs, sum); uncertain XOF
  blocks are decided one cycle later.
- Sampler bank hit: rank below the chunk total (ranks are 0 .. total - 1).
- CBD prefetch register outside the init reset; dispatcher picks one-hot;
  PMAC `g1_cur` registered with the group; AXI buffer address one register
  per byte lane; the KeyGen ek tap no longer waits for FIFO room (196 words
  at most, the FIFO holds 256).
- Lane-to-engine map 0, 2, 5, 7 / 1, 3, 4, 6: for k = 3 the third vector NTT
  no longer waits behind the second on one engine (ML-KEM-768 -1.6..1.8 %).
- Long jobs (H(ek), J) collect their words in `cap` (free then: the sampler
  and the noise writer are done with it; cleared by a registered strobe on
  the register reset) while the previous block permutes, and absorb the
  block in one handshake; the word-XOR path of the sponge is gone. Encaps
  -4.7..5.6 %, Decaps-1024 -3.6 %, no flip-flops added (step 3 had removed
  `msg_block` and lost this overlap).
- Cross-module controls registered at the reader: the FIFO full (the FIFO
  rises it with two words free), the output engine's register-word valid
  flags and the Decaps key valid, the input accept-left flag; the
  re-encryption compare in two steps; the PMAC's next block of a pair
  computed at the group start; the precount's sums rebalanced (four counts
  of 7 per sum).

Cycles change by 0..0.6% (result table at the top).

## Area picture (Vivado, old 9-lane single-butterfly build)

Fixed part (cannot shrink much):

| Block | LUT | FF |
|---|---|---|
| hash | 7.0k | 6.1k |
| in + out | 3.4k | 2.7k |
| AXI + iobuf | 2.3k | 0.6k |
| sampler | 0.7k | 0.8k |
| FIFO + control | 1.2k | 0.9k |
| S/T/C stores (LUTRAM) | 1.7k | — |
| **Total** | **~16.3k** | **~11.1k** |

- That leaves about 13.7k LUT / 8.9k FF for NTT, PMAC and glue.
- The PMAC at 8 coefficients/cycle takes about 5k LUT, so the lanes get about 8k LUT.
- That is enough for two 4-wide ntt4 lanes (core about 2.1k + glue about 1.6k each).

## Step 2: shared lanes

Today each lane has a fixed role (`mlkem_core.v` `g_lane`, `mlkem_lane.v`):

- **Lanes 0..3 (vector):** handle poly j of s/e (KG), y (ENC) or u' (DEC).
  - Run CBD from the noise memory `nz_lane == g`, then the NTT.
  - Unload ×2^16 into the lane buffer. That buffer is the PMAC V operand `l_pm_rdata[pm_v_slot]` (fill `l_b_fill[0..3]`, epoch `v_ep`).
  - In KG, also write s^ to S store slot g.
- **Lanes 4..7 (row):** take PMAC row r = g-4, written into the lane buffer.
  - Run INTT, add e1 noise, compress into C store slot r (ENC) or compare (DEC).
  - In KG, run the NTT of e into the buffer instead; `mlkem_out` reads it as the bias (`bias_data`).
- **Lane 8 (scalar):** takes PMAC row k (ENC) or w (DEC).
  - Run INTT, add e2 + mu, compress into C slot 4 (ENC), or produce the m' bits (DEC).

The PMAC needs all k vector operands at the same time, because terms j = 0..k-1 run back to back. So the vector polys must sit in stores, not in lane memories.

Target structure:

1. **New LUTRAM stores in `mlkem_core`** (64 LUT per poly):
   - Y store, 4 slots: NTT outputs ×2^16. It replaces the vector lane buffers as the PMAC V source, with the same `fill`/`ep` interface.
   - W store, 5 slots: PMAC rows. It replaces the row/scalar lane buffers as the PMAC destination; `wr_lane_en[4..8]` become W slot write enables.
   - E store, 4 slots: the KG e^ bias for `mlkem_out`. Alternatively reuse W slots 0..3, since KG writes its PMAC result to T, not W.
2. **Generic `mlkem_lane`** (the union of the three roles) with a job input `{kind: VEC_NTT | ROW_INTT | SCL_INTT | KG_E_NTT, index}`.
   - The noise memory moves out of the lane: either one memory per noise poly (at most 2k+2), or keep it per job and let `mlkem_hash` write by job index.
3. **Job dispatcher in `mlkem_core`.** Each op has a fixed job list in dependency order, and each job goes to the first idle lane:
   - KG: VEC 0..k-1 (s), then KG_E 0..k-1 (e).
   - ENC: VEC 0..k-1 (y), then ROW 0..k-1 as each W row fills, then SCL.
   - DEC: VEC 0..k-1 (u'), SCL (w -> m'), then the ENC list (re-encryption).
   - A job starts when its input exists (fill > 0), exactly as today.
4. **Lane count as a parameter `NLANE`.** Start with 3 to keep the risk low, then go to 2.

Expected after step 2 with 2 lanes (model estimate, 227 MHz):

| Set | KeyGen (µs) | Encaps (µs) | Decaps (µs) |
|---|---|---|---|
| 512 | ~5.9 | ~7.2 | ~11.3 |
| 768 | ~8.4 | ~10.8 | ~15.2 |
| 1024 | ~11.4 | ~14.7 | ~19.4 |

- Area: about 28–30k LUT / 17–19k FF.
- Tightest point: KeyGen-512, about 12% faster than Paper 15.

## Checks after each step

1. Run `make lint`, `make test`, `make test-axi` and `make perf`.
2. Then the user runs Vivado OOC implementation for LUT, FF, Fmax and power.
