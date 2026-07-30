SIMULATOR ?= iverilog
TOP       ?= tb_ku115_delay_chain

BUILD_DIR := build
RTL_SRCS  := rtl/ku115_odelay4_select.sv \
             rtl/ku115_delay_chain_top.sv
TB_SRC    := sim/tb_ku115_delay_chain.sv
MODEL_SRC := sim/xilinx_ultrascale_behavioral.sv

IVERILOG_BUILD := $(BUILD_DIR)/iverilog
IVERILOG_EXE   := $(IVERILOG_BUILD)/$(TOP).vvp
VCD_FILE       := $(IVERILOG_BUILD)/$(TOP).vcd

VCS_BUILD := $(BUILD_DIR)/vcs
VCS_EXE   := $(VCS_BUILD)/simv
FSDB_FILE := $(VCS_BUILD)/$(TOP).fsdb

VCS       ?= vcs
VVP       ?= vvp
IVERILOG  ?= iverilog
VERDI     ?= verdi

VCS_OPTS  ?= -full64 -sverilog -timescale=1ns/1ps \
             -debug_access+all -kdb -lca
VERDI_OPTS ?= -nologo

.PHONY: all compile run sim run_verdi clean help

all: sim

compile:
ifeq ($(SIMULATOR),iverilog)
	@mkdir -p $(IVERILOG_BUILD)
	$(IVERILOG) -g2012 -Wall -DOPEN_SOURCE_SIM -DDUMP_VCD \
		-s $(TOP) -o $(IVERILOG_EXE) \
		$(MODEL_SRC) $(RTL_SRCS) $(TB_SRC)
else ifeq ($(SIMULATOR),vcs)
	@mkdir -p $(VCS_BUILD)
	cd $(VCS_BUILD) && $(VCS) $(VCS_OPTS) -DDUMP_FSDB \
		-top $(TOP) -o simv \
		$(addprefix ../../,$(RTL_SRCS) $(TB_SRC))
else
	$(error Unsupported SIMULATOR='$(SIMULATOR)'; use iverilog or vcs)
endif

run: compile
ifeq ($(SIMULATOR),iverilog)
	$(VVP) $(IVERILOG_EXE) +WAVE_FILE=$(abspath $(VCD_FILE))
else ifeq ($(SIMULATOR),vcs)
	cd $(VCS_BUILD) && ./simv +FSDB_FILE=$(abspath $(FSDB_FILE))
endif

sim: run

run_verdi:
	@test -f "$(FSDB_FILE)" || { \
		echo "ERROR: $(FSDB_FILE) not found; run 'make SIMULATOR=vcs sim' first."; \
		exit 1; \
	}
	$(VERDI) $(VERDI_OPTS) -dbdir $(VCS_EXE).daidir -ssf $(FSDB_FILE) &

clean:
	rm -rf $(BUILD_DIR) csrc simv* ucli.key novas.conf novas.rc verdiLog

help:
	@echo "make SIMULATOR=iverilog sim  Compile/run with Icarus; write VCD"
	@echo "make SIMULATOR=vcs sim       Compile/run with VCS; write FSDB"
	@echo "make run_verdi               Open VCS database and FSDB in Verdi"
	@echo "make clean                   Remove generated simulation files"
