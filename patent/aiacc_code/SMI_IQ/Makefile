# TVGen - Test Vector Generator for SMI_IQ
#
# Single-SMC examples:
#   make add mode-fp32 seed-12345
#   make mul mode-fp32 seed-12345
#
# Multi-SMC Add stage1 example:
#   make multi-add-stage1 mode-fp32 n-1 c-1 h-1 w-16 alpha-1.0

# ==============================================================================
# 1. Global configuration
# ==============================================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OUT  := $(ROOT)/out

CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -I$(ROOT)/app

# Default seed used by test-random. Normal op targets use seed-xxx from goals.
seed ?= $(shell date +%s)

# ==============================================================================
# 2. Source files
# ==============================================================================

# All operator sources for the normal TVGen path.
OP_DIRS := $(filter-out $(ROOT)/op/%_back $(ROOT)/op/div,$(wildcard $(ROOT)/op/*))
OP_SRCS := $(foreach dir,$(OP_DIRS),$(wildcard $(dir)/*.cpp))

# All IQ module sources for the normal TVGen path.
IQ_SRCS := $(wildcard $(ROOT)/iq/modules/*.cpp)

# Normal single-SMC TVGen binary sources.
TVGEN_SRCS := $(ROOT)/app/main.cpp \
              $(ROOT)/app/tvgen_core.cpp \
              $(ROOT)/app/tvgen_dynamic.cpp \
              $(ROOT)/app/simulator_config_gen.cpp \
              $(ROOT)/app/app_json_parser.cpp \
              $(ROOT)/app/fp16_utils.cpp \
              $(OP_SRCS) \
              $(ROOT)/math_utils/newton_method/newton_method.cpp \
              $(ROOT)/math_utils/taylor_series/taylor_series.cpp \
              $(IQ_SRCS)

# Standalone Multi-SMC Add stage1 generator sources.
# This target intentionally does not compile app/main.cpp; it uses the main()
# guarded by ADD_MULTI_STAGE1_STANDALONE inside add_op_multi_stage1.cpp.
MULTI_ADD_STAGE1_SRCS := $(ROOT)/op/add/add_op.cpp \
                         $(ROOT)/op/add/add_op_multi_stage1.cpp \
                         $(ROOT)/op/add/add_op_bank_conflict.cpp \
                         $(ROOT)/op/add/add_op_compute_inst.cpp \
                         $(ROOT)/op/add/add_op_rtovr_inst.cpp \
                         $(ROOT)/op/add/add_op_ur_inst.cpp \
                         $(ROOT)/app/fp16_utils.cpp \
                         $(ROOT)/iq/modules/fpmul_iq.cpp \
                         $(ROOT)/iq/modules/fpadd_iq.cpp \
                         $(ROOT)/iq/modules/rtovr_iq.cpp \
                         $(ROOT)/iq/modules/ur_iq.cpp

SOFTMAX_SRCS := $(ROOT)/op/softmax/softmax.cpp

# Use lighter optimization for the standalone generator to keep iteration fast.
MULTI_ADD_STAGE1_CXXFLAGS := -std=c++17 -O0 -Wall -Wextra -I$(ROOT)/app
SOFTMAX_CXXFLAGS := -std=c++17 -O0 -Wall -Wextra

# ==============================================================================
# 3. Output binaries and common paths
# ==============================================================================

TVGEN_BIN := $(OUT)/tvgen
MULTI_ADD_STAGE1_BIN := $(OUT)/multi_add_stage1
SOFTMAX_BIN_DIR := $(OUT)/bin
SOFTMAX_BIN := $(SOFTMAX_BIN_DIR)/softmax
SIM_CONFIG := $(OUT)/test/simulator_config.json

RTL_ROOT ?= /home/sunny/Jianyuan/aiacc/rtl
ADD_V0415_OUT ?= $(OUT)/add_v0415_smc8
ADD_V0415_RTL_CASE ?= operators/binary/math/add_v0415_smc8_smc0/acb_bundle/smc_0

# ==============================================================================
# 4. Phony targets
# ==============================================================================

SINGLE_SMC_OPS := add sub pow mul mul_scalar neg cos rsqrt div div_scalar exp log log1p mean_dim expand

.PHONY: help clean tvgen test-random sim multi-add-stage1 softmax add-v0415-smc8 install-add-v0415-rtl $(SINGLE_SMC_OPS) \
        mode-fp32 mode-fp16 mode-int32 mode-int4 seed-% n-% c-% h-% w-% smc-% alpha-% split-% row-% out-% layout-% bc

# ==============================================================================
# 5. Help
# ==============================================================================

help:
	@echo "TVGen - Test Vector Generator for SMI_IQ"
	@echo ""
	@echo "Single-SMC usage:"
	@echo "  make <op> mode-<dtype> seed-<seed> [layout-<layout>]"
	@echo ""
	@echo "Single-SMC examples:"
	@echo "  make add mode-fp32 seed-12345"
	@echo "  make mul mode-fp32 seed-12345"
	@echo "  make add mode-fp32 seed-12345 layout-bc"
	@echo ""
	@echo "Multi-SMC Add stage1 usage:"
	@echo "  make multi-add-stage1 mode-<dtype> n-<N> c-<C> h-<H> w-<W> alpha-<alpha> [OUTDIR=<path>]"
	@echo "8-SMC Softmax usage:"
	@echo "  make softmax d3-1 d2-32 d1-1 d0-1148 row-0 smc-8 seed-<seed> [OUTDIR=<path>]"
	@echo "  make add-v0415-smc8"
	@echo "  make install-add-v0415-rtl"
	@echo ""
	@echo "Multi-SMC examples:"
	@echo "  make multi-add-stage1 mode-fp32 w-16 alpha-1.0"
	@echo "  make multi-add-stage1 mode-fp16 w-16 alpha-0.5"
	@echo "  make multi-add-stage1 mode-fp16 n-2 c-3 h-4 w-64 smc-8 alpha-1.0"
	@echo ""
	@echo "Other targets:"
	@echo "  make tvgen"
	@echo "  make test-random"
	@echo "  make sim"
	@echo "  make clean"
	@echo ""
	@echo "Supported single-SMC ops: $(SINGLE_SMC_OPS)"

# ==============================================================================
# 6. Build targets
# ==============================================================================

$(OUT):
	mkdir -p $(OUT)

$(SOFTMAX_BIN_DIR): | $(OUT)
	mkdir -p $(SOFTMAX_BIN_DIR)

$(TVGEN_BIN): $(TVGEN_SRCS) | $(OUT)
	$(CXX) $(CXXFLAGS) $(TVGEN_SRCS) -o $(TVGEN_BIN)
	@echo "[OK] Built: $(TVGEN_BIN)"

$(MULTI_ADD_STAGE1_BIN): $(MULTI_ADD_STAGE1_SRCS) | $(OUT)
	$(CXX) $(MULTI_ADD_STAGE1_CXXFLAGS) -DADD_MULTI_STAGE1_STANDALONE $(MULTI_ADD_STAGE1_SRCS) -o $(MULTI_ADD_STAGE1_BIN)
	@echo "[OK] Built: $(MULTI_ADD_STAGE1_BIN)"

$(SOFTMAX_BIN): $(SOFTMAX_SRCS) | $(SOFTMAX_BIN_DIR)
	$(CXX) $(SOFTMAX_CXXFLAGS) -DSOFTMAX_STANDALONE $(SOFTMAX_SRCS) -o $(SOFTMAX_BIN)
	@echo "[OK] Built: $(SOFTMAX_BIN)"

tvgen: $(TVGEN_BIN)

# ==============================================================================
# 7. Normal single-SMC TVGen targets
# ==============================================================================

test-random: $(TVGEN_BIN)
	$(TVGEN_BIN) --random --seed $(seed) --output $(OUT)/test --verbose

$(SINGLE_SMC_OPS):
	@if [ "$(words $(MAKECMDGOALS))" -lt 3 ]; then \
		echo "Usage: make $@ mode-<dtype> seed-<seed> [layout-<layout>]"; \
		exit 1; \
	fi; \
	op=$@; \
	mode_arg=$(word 2,$(MAKECMDGOALS)); \
	seed_arg=$(word 3,$(MAKECMDGOALS)); \
	dtype=$${mode_arg#mode-}; \
	seed_value=$${seed_arg#seed-}; \
	if [ "$$dtype" != "fp32" ] && [ "$$dtype" != "fp16" ] && [ "$$dtype" != "int32" ] && [ "$$dtype" != "int4" ]; then \
		echo "Error: unknown dtype '$$dtype'"; \
		exit 1; \
	fi; \
	layout=""; \
	for g in $(MAKECMDGOALS); do \
		case $$g in layout-*) layout=$${g#layout-};; esac; \
	done; \
	layout_flag=""; \
	if [ -n "$$layout" ]; then \
		if [ "$$layout" = "bc" ]; then layout="bank_conflict"; fi; \
		if [ "$$layout" = "bc4" ]; then layout="bank_conflict_4"; fi; \
		layout_flag="--layout $$layout"; \
		echo "Running $$op test with $$dtype seed=$$seed_value layout=$$layout"; \
	else \
		echo "Running $$op test with $$dtype seed=$$seed_value"; \
	fi; \
	$(MAKE) $(TVGEN_BIN); \
	mkdir -p $(OUT); \
	$(TVGEN_BIN) --random --seed $$seed_value --operator $$op --dtype $$dtype $$layout_flag --output $(OUT)/test --verbose

# ==============================================================================
# 8. Standalone Multi-SMC Add stage1 target
# ==============================================================================

multi-add-stage1: $(MULTI_ADD_STAGE1_BIN)
	@dtype="fp32"; n="1"; c="1"; h="1"; width="16"; smc_num="2"; alpha="1.0"; seed="1"; split=""; outdir="$${OUTDIR:-$(OUT)/multi_smc_add_stage1}"; sim_dir="$${SIM_DIR:-/home/sunny/Jianyuan/aiacc/8_sim}"; \
	for g in $(MAKECMDGOALS); do \
		case $$g in \
			mode-*) dtype=$${g#mode-};; \
			n-*) n=$${g#n-};; \
			c-*) c=$${g#c-};; \
			h-*) h=$${g#h-};; \
			w-*) width=$${g#w-};; \
			smc-*) smc_num=$${g#smc-};; \
			alpha-*) alpha=$${g#alpha-};; \
			seed-*) seed=$${g#seed-};; \
			split-*) split=$${g#split-};; \
			out-*) outdir=$${g#out-};; \
		esac; \
	done; \
	split_flag=""; \
	if [ -n "$$split" ]; then split_flag="--split $$split"; fi; \
	echo "Running Multi-SMC Add: dtype=$$dtype N=$$n C=$$c H=$$h W=$$width smc_num=$$smc_num split=$${split:-even} alpha=$$alpha seed=$$seed output=$$outdir sim_dir=$$sim_dir"; \
	if [ -z "$$outdir" ] || [ "$$outdir" = "/" ]; then \
		echo "Error: invalid output directory '$$outdir'"; \
		exit 1; \
	fi; \
	rm -rf "$$outdir"; \
	$(MULTI_ADD_STAGE1_BIN) --dtype $$dtype --n $$n --c $$c --h $$h --w $$width --smc-num $$smc_num $$split_flag --alpha $$alpha --seed $$seed --output $$outdir --sim-dir $$sim_dir

softmax: $(SOFTMAX_BIN)
	@d3="1"; d2="32"; d1="1"; d0="1148"; row_id="0"; smc_num="8"; seed="1"; split=""; outdir="$${OUTDIR:-$(OUT)/softmax}"; \
	for g in $(MAKECMDGOALS); do \
		case $$g in \
			w-*) echo "Error: Softmax uses d3/d2/d1/d0 and reduces d0"; exit 1;; \
			d3-*) d3=$${g#d3-};; \
			d2-*) d2=$${g#d2-};; \
			d1-*) d1=$${g#d1-};; \
			d0-*) d0=$${g#d0-};; \
			row-*) row_id=$${g#row-};; \
			smc-*) smc_num=$${g#smc-};; \
			seed-*) seed=$${g#seed-};; \
			split-*) split=$${g#split-};; \
			out-*) outdir=$${g#out-};; \
		esac; \
	done; \
	split_flag=""; \
	if [ -n "$$split" ]; then split_flag="--split $$split"; fi; \
	echo "Running 8-SMC Softmax: shape=[$$d3,$$d2,$$d1,$$d0] row=$$row_id split=$${split:-even} seed=$$seed output=$$outdir"; \
	$(SOFTMAX_BIN) --d3 $$d3 --d2 $$d2 --d1 $$d1 --d0 $$d0 --row-id $$row_id --smc-num $$smc_num $$split_flag --seed $$seed --output $$outdir

add-v0415-smc8: $(MULTI_ADD_STAGE1_BIN)
	@outdir="$${OUTDIR:-$(ADD_V0415_OUT)}"; \
	echo "Running Add v0.4.15 8-SMC smoke data: output=$$outdir"; \
	rm -rf "$$outdir"; \
	$(MULTI_ADD_STAGE1_BIN) --dtype fp32 --w 32 --smc-num 8 --alpha 1.0 --output "$$outdir"

install-add-v0415-rtl: add-v0415-smc8
	@src="$(ADD_V0415_OUT)"; \
	dst="$(RTL_ROOT)/test_atomic_ops/$(ADD_V0415_RTL_CASE)"; \
	echo "Install smc0 add case to $$dst"; \
	rm -rf "$$dst"; \
	mkdir -p "$$dst/ur_data" "$$dst/output_bank"; \
	cp "$$src/smc0_iq/iq_7_fpmul.hex"     "$$dst/iq_fpmul.hex"; \
	cp "$$src/smc0_iq/iq_8_fpadd.hex"     "$$dst/iq_fpadd.hex"; \
	cp "$$src/smc0_iq/iq_16_ur-r0.hex"    "$$dst/iq_ur_r0.hex"; \
	cp "$$src/smc0_iq/iq_17_ur-r1.hex"    "$$dst/iq_ur_r1.hex"; \
	cp "$$src/smc0_iq/iq_18_ur-r2.hex"    "$$dst/iq_ur_r2.hex"; \
	cp "$$src/smc0_iq/iq_20_ur-w0.hex"    "$$dst/iq_ur_w0.hex"; \
	cp "$$src/smc0_iq/iq_27_rtovr-3.hex"  "$$dst/iq_rtovr_3.hex"; \
	cp "$$src/smc0_iq/iq_28_rtovr-4.hex"  "$$dst/iq_rtovr_4.hex"; \
	cp "$$src/smc0_iq/iq_29_rtovr-5.hex"  "$$dst/iq_rtovr_5.hex"; \
	cp "$$src/smc0_iq/iq_30_rtovr-6.hex"  "$$dst/iq_rtovr_6.hex"; \
	cp "$$src/smc0_iq/iq_59_rtovr-35.hex" "$$dst/iq_rtovr_35.hex"; \
	cp "$$src/smc0_ur/bank0_input.hex"       "$$dst/ur_data/bank0.hex"; \
	cp "$$src/smc0_ur/bank1_other.hex"       "$$dst/ur_data/bank1.hex"; \
	cp "$$src/smc0_ur/bank2_alpha.hex"       "$$dst/ur_data/bank2.hex"; \
	cp "$$src/smc0_ur/bank3_output_zero.hex" "$$dst/ur_data/bank3.hex"; \
	DST="$$dst" SRC="$$src" python3 -c "import os; from pathlib import Path; src=Path(os.environ['SRC']); dst=Path(os.environ['DST']); zero='0'*32; [(dst/'ur_data'/f'bank{i}.hex').write_text((zero+'\\n')*256) for i in range(4,8)]; lines=[x.strip() for x in (src/'golden.hex').read_text().splitlines() if x.strip()] if (src/'golden.hex').exists() else []; first=lines[0] if lines else zero; (dst/'output_bank'/'bank3_final.hex').write_text('\\n'.join([first]+[zero]*255)+'\\n')"
	@cd "$(RTL_ROOT)" && python3 generate_data_list_coverage.py operators
	@echo "[OK] Installed and generated data_list. Run: cd $(RTL_ROOT) && ./run_sim_aiacc_top.sh operators $(ADD_V0415_RTL_CASE)"

# ==============================================================================
# 9. Simulation target for normal single-SMC output
# ==============================================================================

sim:
	@if [ ! -f $(SIM_CONFIG) ]; then \
		echo "Error: $(SIM_CONFIG) not found. Run e.g. make add mode-fp32 seed-12345 first."; \
		exit 1; \
	fi; \
	cd "$(ROOT)/../.." && PYTHONPATH="$(ROOT)/../..:$(ROOT)/..:$$PYTHONPATH" \
		python3 smc_simulator/run_sim.py "$(abspath $(SIM_CONFIG))" --verify --quiet --log "$(abspath $(OUT))/test/verify.log"

# ==============================================================================
# 10. Dummy goal targets for command-line pseudo arguments
# ==============================================================================

mode-fp32 mode-fp16 mode-int32 mode-int4 bc:
	@:

seed-%:
	@:

w-%:
	@:

n-%:
	@:

c-%:
	@:

h-%:
	@:

d3-% d2-% d1-% d0-%:
	@:

row-%:
	@:

smc-%:
	@:

alpha-%:
	@:

split-%:
	@:

out-%:
	@:

layout-%:
	@:

# ==============================================================================
# 11. Clean
# ==============================================================================

clean:
	@rm -rf $(OUT)
