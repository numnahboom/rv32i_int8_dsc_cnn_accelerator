TOPNAME = soc_top
RISCV_PREFIX ?= riscv64-unknown-elf
RISCV_OBJCOPY ?= $(RISCV_PREFIX)-objcopy
TRACE ?= 0
SIM_ARGS =
ifeq ($(TRACE),1)
SIM_ARGS += +trace
endif

VERILATOR = verilator
VERILATOR_COVERAGE = verilator_coverage
VERILATOR_FLAGS += -cc --exe -x-assign fast -Wall --trace --assert --coverage -I$(abspath ./vsrc)		#for sim
SIM_MAIN = $(abspath ./csrc/sim_main.cpp)
VERILATOR_INPUT = --top-module $(TOPNAME) -f input.vc $(VSRCS) $(SIM_MAIN)
VERILATOR_CFLAGS_NV += -MMD --build -cc -O3 --x-assign fast --x-initial fast --noassert		#for board

NXDC_FILES = constr/top.nxdc
BUILD_DIR = ./build
OBJ_DIR_NV = $(BUILD_DIR)/obj_dir
BIN_NV = $(BUILD_DIR)/$(TOPNAME)

$(shell mkdir -p $(BUILD_DIR))

SRC_AUTO_BIND = $(abspath $(BUILD_DIR)/auto_bind.cpp)
$(SRC_AUTO_BIND): $(NXDC_FILES)
	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $^ $@

VSRCS = $(shell find $(abspath ./vsrc) -name "*.v")
CSRCS = $(shell find $(abspath ./csrc/nvboard) -name "*.c" -or -name "*.cc" -or -name "*.cpp")
CSRCS += $(SRC_AUTO_BIND)

# include $(NVBOARD_HOME)/scripts/nvboard.mk
# include ../Makefile

all: sim

cnn-assets:
	python3 export_cnn_assets.py --model-dir ../Model --out-dir .

INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -DTOP_NAME="\"V$(TOPNAME)\""

$(BIN_NV): $(VSRCS) $(CSRCS) $(NVBOARD_ARCHIVE) | cnn-assets
	@rm -rf $(OBJ_DIR_NV)
	$(VERILATOR) $(VERILATOR_CFLAGS_NV) \
		--top-module $(TOPNAME) $^ \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		--Mdir $(OBJ_DIR_NV) --exe -o $(abspath $(BIN_NV))

nvboard: $(BIN_NV)
	@echo "Starting NVBoard simulation..."
	@$^

run: nvboard

cnn-rom:
	$(RISCV_PREFIX)-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
		-Ttext=0 -o test_cnn_custom.elf test_cnn_custom.S
	$(RISCV_OBJCOPY) -O binary test_cnn_custom.elf test_cnn_custom.bin
	python3 bin_to_rom_hex.py test_cnn_custom.bin rom.hex

sim: cnn-assets
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@echo
	@echo "-- VERILATE --"
	@rm -rf obj_dir
	
	$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INPUT)

	@echo
	@echo "-- BUILD --"

	$(MAKE) -j -C obj_dir -f ../Makefile_obj

	@echo
	@echo "-- RUN --"
	@rm -rf logs
	@mkdir -p logs
	obj_dir/Vsoc_top $(SIM_ARGS)
	@if [ -f coverage.dat ]; then mv coverage.dat logs/; fi

	@echo
	@echo "-- COVERAGE --"
	@if [ -f logs/coverage.dat ]; then \
		rm -rf logs/annotated; \
		$(VERILATOR_COVERAGE) --annotate logs/annotated logs/coverage.dat; \
	else \
		echo "coverage.dat not generated; skip coverage annotate."; \
	fi

	@echo
	@echo "-- DONE --"

syn:
	make -C /home/nahnah/ysyx-workbench/yosys-sta sta \
		DESIGN=soc_top \
		RTL_FILES=$(VSRCS) \
		SDC_FILES="/home/nahnah/ysyx-workbench/yosys-sta/scripts/default.sdc" \
		CLK_FREQ_MHZ=50 \
		CLK_PORT_NAME=clk \
		O=/home/nahnah/ysyx-workbench/npc/syn_out

show-config:
	$(VERILATOR) -V

maintainer-copy::
clean mostlyclean distclean maintainer-clean::
	-rm -rf  $(BUILD_DIR) obj_dir logs *.log *.dmp *.vpd coverage.dat core  
	-rm -rf syn_out

.PHONY: all run clean sim nvboard cnn-assets cnn-rom
