SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(THIS_DIR)/../..)
OUT := $(THIS_DIR)/out

CXX ?= g++
CXXFLAGS ?= -std=c++17 -O0 -Wall -Wextra

SOFTMAX_SRCS := $(THIS_DIR)/softmax.cpp
SOFTMAX_BIN_DIR := $(OUT)/bin
SOFTMAX_BIN := $(SOFTMAX_BIN_DIR)/softmax

.PHONY: help build softmax run verify clean d3-% d2-% d1-% d0-% row-% smc-% split-% seed-% out-%

help:
	@echo "8-SMC Softmax generator"
	@echo "  make softmax d3-1 d2-32 d1-1 d0-1148 row-0 seed-1"
	@echo "  make softmax d3-2 d2-4 d1-1 d0-16 row-3 seed-1"

$(OUT):
	mkdir -p $(OUT)

$(SOFTMAX_BIN_DIR): | $(OUT)
	mkdir -p $(SOFTMAX_BIN_DIR)

$(SOFTMAX_BIN): $(SOFTMAX_SRCS) | $(SOFTMAX_BIN_DIR)
	$(CXX) $(CXXFLAGS) -DSOFTMAX_STANDALONE \
		$(SOFTMAX_SRCS) -o $(SOFTMAX_BIN)

build: $(SOFTMAX_BIN)

softmax run: $(SOFTMAX_BIN)
	@d3="1"; d2="32"; d1="1"; d0="1148"; row_id="0"; smc_num="8"; split=""; seed="1"; \
	outdir="$(OUT)/softmax"; \
	for g in $(MAKECMDGOALS); do \
		case $$g in \
			d3-*) d3=$${g#d3-};; \
			d2-*) d2=$${g#d2-};; \
			d1-*) d1=$${g#d1-};; \
			d0-*) d0=$${g#d0-};; \
			row-*) row_id=$${g#row-};; \
			smc-*) smc_num=$${g#smc-};; \
			split-*) split=$${g#split-};; \
			seed-*) seed=$${g#seed-};; \
			out-*) outdir=$${g#out-};; \
		esac; \
	done; \
	split_flag=""; \
	if [ -n "$$split" ]; then split_flag="--split $$split"; fi; \
	$(SOFTMAX_BIN) --d3 $$d3 --d2 $$d2 --d1 $$d1 --d0 $$d0 --row-id $$row_id --smc-num $$smc_num \
		$$split_flag --seed $$seed --output $$outdir

verify:
	python3 $(THIS_DIR)/verify_softmax.py $(OUT)/softmax

d3-% d2-% d1-% d0-% row-% smc-% split-% seed-% out-%:
	@:

clean:
	rm -rf $(OUT)
