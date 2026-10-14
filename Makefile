# AMBA APB programmable timer
#   make lint    Verilator lint (-Wall) of the RTL, with and without wait states
#   make test    build and run the self-checking testbench (Verilator, with assertions)
#   make synth   Yosys synthesis + cell statistics
#   make wave    rebuild with VCD tracing (build/apb_timer.vcd)
#   make clean

VERILATOR ?= verilator
YOSYS     ?= yosys

RTL   := rtl/apb_timer.sv
SVA   := sva/apb_timer_sva.sv
TB    := tb/timer_test.sv tb/tb_top.sv
BUILD := build

VFLAGS := --binary --timing --assert -j 0 --top-module tb_top

.PHONY: all lint test synth wave clean

all: lint test synth

lint:
	$(VERILATOR) --lint-only -Wall $(RTL)
	$(VERILATOR) --lint-only -Wall -GWAIT_STATES=2 $(RTL)
	@echo "lint OK"

test:
	@mkdir -p $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/sim $(RTL) $(SVA) $(TB) -o tb_top > $(BUILD)/build.log 2>&1 \
	    || (cat $(BUILD)/build.log; exit 1)
	$(BUILD)/sim/tb_top | tee $(BUILD)/sim.log
	@grep -q "ALL TESTS PASSED" $(BUILD)/sim.log

synth:
	@mkdir -p $(BUILD)
	$(YOSYS) -q -l $(BUILD)/synth.log -p "\
	    read_verilog -sv $(RTL); \
	    synth -top apb_timer; \
	    check -assert; \
	    tee -q -o $(BUILD)/synth_stat.txt stat"
	@echo "synthesis OK"
	@grep -E "cells$$|DFF" $(BUILD)/synth_stat.txt

wave:
	@mkdir -p $(BUILD)
	$(VERILATOR) $(VFLAGS) --trace -DDUMP -Mdir $(BUILD)/wave $(RTL) $(SVA) $(TB) -o tb_top > $(BUILD)/build.log 2>&1 \
	    || (cat $(BUILD)/build.log; exit 1)
	cd $(BUILD) && ./wave/tb_top

clean:
	rm -rf $(BUILD)
