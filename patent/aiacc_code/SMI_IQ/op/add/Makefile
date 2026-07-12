SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(THIS_DIR)/../..)
OUT := $(THIS_DIR)/out

CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -I$(ROOT)/app

IQ_SRCS := $(wildcard $(ROOT)/iq/modules/*.cpp)

MULTI_ADD_STAGE1_SRCS := $(THIS_DIR)/add_op.cpp \
                         $(THIS_DIR)/add_op_multi_stage1.cpp \
                         $(THIS_DIR)/add_op_bank_conflict.cpp \
                         $(THIS_DIR)/add_op_compute_inst.cpp \
                         $(THIS_DIR)/add_op_rtovr_inst.cpp \
                         $(THIS_DIR)/add_op_ur_inst.cpp \
                         $(ROOT)/app/fp16_utils.cpp \
                         $(IQ_SRCS)

MULTI_ADD_STAGE1_BIN := $(OUT)/multi_add_stage1

.PHONY: help build stage1 run clean mode-fp32 mode-fp16 n-% c-% h-% w-% smc-% split-% alpha-% seed-% out-%

help:
	@echo "Add OP local build helper"
	@echo ""
	@echo "Build binary:"
	@echo "  make build"
	@echo ""
	@echo "Run multi-SMC Add stage1 (compiler-only):"
	@echo "  make stage1 mode-fp32 w-16 alpha-1.0 seed-1"
	@echo "  make stage1 mode-fp16 w-16 alpha-0.5 seed-123"
	@echo "  make stage1 mode-fp16 n-2 c-3 h-4 w-64 smc-8 alpha-1.0 seed-123"
	@echo "  make stage1 mode-fp32 w-16 alpha-1.0 seed-123 out-./tmp_stage1"

$(OUT):
	mkdir -p $(OUT)

$(MULTI_ADD_STAGE1_BIN): $(MULTI_ADD_STAGE1_SRCS) | $(OUT)
	$(CXX) $(CXXFLAGS) -DADD_MULTI_STAGE1_STANDALONE $(MULTI_ADD_STAGE1_SRCS) -o $(MULTI_ADD_STAGE1_BIN)
	@echo "[OK] Built: $(MULTI_ADD_STAGE1_BIN)"

build: $(MULTI_ADD_STAGE1_BIN)

stage1 run: $(MULTI_ADD_STAGE1_BIN)
	@dtype="fp32"; n="1"; c="1"; h="1"; width="32"; smc_num="8"; split=""; alpha="1.0"; seed="1"; outdir="$(OUT)/multi_smc_add_stage1"; \
	for g in $(MAKECMDGOALS); do \
		case $$g in \
			mode-*) dtype=$${g#mode-};; \
			n-*) n=$${g#n-};; \
			c-*) c=$${g#c-};; \
			h-*) h=$${g#h-};; \
			w-*) width=$${g#w-};; \
			smc-*) smc_num=$${g#smc-};; \
			split-*) split=$${g#split-};; \
			alpha-*) alpha=$${g#alpha-};; \
			seed-*) seed=$${g#seed-};; \
			out-*) outdir=$${g#out-};; \
		esac; \
	done; \
	split_flag=""; \
	if [ -n "$$split" ]; then split_flag="--split $$split"; fi; \
	echo "Running Multi-SMC Add stage1: dtype=$$dtype N=$$n C=$$c H=$$h W=$$width smc_num=$$smc_num split=$${split:-even} alpha=$$alpha seed=$$seed output=$$outdir"; \
	$(MULTI_ADD_STAGE1_BIN) --dtype $$dtype --n $$n --c $$c --h $$h --w $$width --smc-num $$smc_num $$split_flag --alpha $$alpha --seed $$seed --output $$outdir

mode-fp32 mode-fp16:
	@:
n-% c-% h-% w-% smc-% split-% alpha-% seed-% out-%:
	@:

clean:
	rm -rf $(OUT)
