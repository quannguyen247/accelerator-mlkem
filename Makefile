PYTHON ?= python3
N ?= 1
STALL ?= 30
SEED ?= 1
VIVADO_HOME ?=
PART ?= xc7a200tfbg676-3
VIVADO := $(if $(VIVADO_HOME),$(VIVADO_HOME)/bin/,)vivado

BUILD := build
VEC := vector
TB := testbench/tb_mlkem_core.sv
INC := rtl/utils
RTL := $(wildcard rtl/modules/*/*.v rtl/modules/*/*/*.v)

.PHONY: vectors test test-axi perf trace sim-iverilog lint project package impl clean

vectors:
	$(PYTHON) $(VEC)/mlkem_gen.py $(N)

# QuestaSim regression of mlkem_core with random request/result port stalls
test: vectors
	mkdir -p $(BUILD)
	cd $(BUILD) && vlib work > /dev/null && \
	vlog -quiet -sv $(addprefix +incdir+../,$(INC)) $(addprefix ../,$(RTL) $(TB)) && \
	vsim -c -quiet tb_mlkem_core +VEC=../$(VEC) +STALL=$(STALL) +SEED=$(SEED) \
		-do "run -all; quit -f" | tee sim.log
	grep -Fq '*** ALL TESTS PASSED ***' $(BUILD)/sim.log

# Always-ready request/result ports: cycle counts per operation
perf: vectors
	mkdir -p $(BUILD)
	cd $(BUILD) && vlib work > /dev/null && \
	vlog -quiet -sv $(addprefix +incdir+../,$(INC)) $(addprefix ../,$(RTL) $(TB)) && \
	vsim -c -quiet tb_mlkem_core +VEC=../$(VEC) +PERF -do "run -all; quit -f" | tee perf.log
	grep -Fq '*** ALL TESTS PASSED ***' $(BUILD)/perf.log

# Engine timeline per request (simulation-only monitor)
trace: vectors
	mkdir -p $(BUILD)
	cd $(BUILD) && vlib work > /dev/null && \
	vlog -quiet -sv $(addprefix +incdir+../,$(INC)) $(addprefix ../,$(RTL) $(TB)) \
		../testbench/tb_mlkem_trace.sv && \
	vsim -c -quiet tb_mlkem_core tb_mlkem_trace +VEC=../$(VEC) +PERF +TRACE \
		-do "run -all; quit -f" | tee trace.log

# IP top (SPEC section 4): AXI4-Lite registers + AXI4 request/result buffer,
# random VALID/READY stalls on the AXI4 master
test-axi: vectors
	mkdir -p $(BUILD)
	cd $(BUILD) && vlib work > /dev/null && \
	vlog -quiet -sv $(addprefix +incdir+../,$(INC)) $(addprefix ../,$(RTL)) \
		../testbench/tb_mlkem_axi.sv && \
	vsim -c -quiet tb_mlkem_axi +VEC=../$(VEC) +STALL=$(STALL) +SEED=$(SEED) \
		-do "run -all; quit -f" | tee sim_axi.log
	grep -Fq '*** ALL TESTS PASSED ***' $(BUILD)/sim_axi.log

sim-iverilog: vectors
	mkdir -p $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb.vvp $(addprefix -I,$(INC)) $(RTL) $(TB)
	vvp -n $(BUILD)/tb.vvp +VEC=$(VEC) +STALL=$(STALL) +SEED=$(SEED) | tee $(BUILD)/sim_iverilog.log
	grep -Fq '*** ALL TESTS PASSED ***' $(BUILD)/sim_iverilog.log

# EOFNEWLINE, IMPLICITSTATIC and CASEINCOMPLETE occur only in the NTT and Keccak cores.
lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
		-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-VARHIDDEN -Wno-BLKSEQ -Wno-SYMRSVDWORD \
		-Wno-EOFNEWLINE -Wno-IMPLICITSTATIC -Wno-CASEINCOMPLETE \
		--top-module mlkem_axi $(addprefix -I,$(INC)) $(RTL)

# Vivado project of the IP top (project/mlkem_top), packaged IPs (project/ip_repo/mlkem_core, ntt_core)
project:
	$(VIVADO) -mode batch -nojournal -nolog -source scripts/create_project.tcl -tclargs $(PART)

package:
	mkdir -p $(BUILD)
	$(VIVADO) -mode batch -nojournal -nolog -source scripts/package_ip.tcl

# Synthesis and implementation of project/mlkem_top (out of context, constraint/mlkem.xdc);
# routed reports in build/impl
impl:
	mkdir -p $(BUILD)/impl
	$(VIVADO) -mode batch -nojournal -log $(BUILD)/impl/impl.log -source scripts/run_project.tcl

clean:
	rm -rf $(BUILD)
