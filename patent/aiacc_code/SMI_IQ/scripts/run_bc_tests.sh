#!/bin/bash
# =============================================================================
# Bank Conflict 批量随机测试脚本
# 用法: bash scripts/run_bc_tests.sh [起始seed] [测试数量]
# 示例: bash scripts/run_bc_tests.sh 1 100    # 从 seed=1 开始跑 100 组
# =============================================================================

set -e

START_SEED=${1:-1}
NUM_TESTS=${2:-30}
DTYPE=${3:-fp32}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PASS=0
FAIL=0
TOTAL=0
FAIL_SEEDS=()

echo "=============================================="
echo " Bank Conflict 批量随机测试"
echo "=============================================="
echo " Seeds: ${START_SEED} ~ $((START_SEED + NUM_TESTS - 1))"
echo " Dtype: ${DTYPE}"
echo " Total: ${NUM_TESTS} tests"
echo "=============================================="
echo ""

# 确保 tvgen 已编译
# make tvgen 2>/dev/null || true

for i in $(seq 0 $((NUM_TESTS - 1))); do
    SEED=$((START_SEED + i))
    TOTAL=$((TOTAL + 1))

    # 生成测试向量 + 仿真
    echo -n "[${TOTAL}/${NUM_TESTS}] seed=${SEED} ... "

    # 清理旧数据 & 强制重编译
    rm -f out/tvgen

    # 生成 + 仿真，捕获输出
    OUTPUT=$(make add mode-${DTYPE} seed-${SEED} layout-bc 2>&1) || {
        echo "FAIL (tvgen error)"
        FAIL=$((FAIL + 1))
        FAIL_SEEDS+=("${SEED}:tvgen_error")
        continue
    }

    # 提取 bank 分配信息
    BANK_INFO=$(echo "$OUTPUT" | grep -o "Bank conflict layout:.*" || echo "unknown")

    SIM_OUTPUT=$(make sim 2>&1) || {
        # 检查是否是 bank conflict RuntimeError
        if echo "$SIM_OUTPUT" | grep -q "Bank Conflict ERROR"; then
            CONFLICT_MSG=$(echo "$SIM_OUTPUT" | grep "Bank Conflict ERROR" | head -1)
            echo "FAIL (${CONFLICT_MSG})"
        else
            MISMATCH=$(echo "$SIM_OUTPUT" | grep -o "Mismatches: [0-9]*" || echo "Mismatches: ?")
            echo "FAIL (${MISMATCH}) | ${BANK_INFO}"
        fi
        FAIL=$((FAIL + 1))
        FAIL_SEEDS+=("${SEED}")
        continue
    }

    # 检查结果
    if echo "$SIM_OUTPUT" | grep -q "PASS"; then
        SLOTS=$(echo "$OUTPUT" | grep -o "num_slots=[0-9]*" || echo "num_slots=1")
        echo "PASS (${SLOTS}) | ${BANK_INFO}"
        PASS=$((PASS + 1))
    else
        MISMATCH=$(echo "$SIM_OUTPUT" | grep -o "Mismatches: [0-9]*" || echo "Mismatches: ?")
        echo "FAIL (${MISMATCH}) | ${BANK_INFO}"
        FAIL=$((FAIL + 1))
        FAIL_SEEDS+=("${SEED}")
    fi
done

echo ""
echo "=============================================="
echo " 测试结果汇总"
echo "=============================================="
echo " 总测试数: ${TOTAL}"
echo " 通过:     ${PASS}"
echo " 失败:     ${FAIL}"
echo "=============================================="

if [ ${FAIL} -gt 0 ]; then
    echo ""
    echo " 失败的 seed 列表:"
    for s in "${FAIL_SEEDS[@]}"; do
        echo "   seed=${s}"
    done
    echo ""
    echo " 复现命令:"
    echo "   make add mode-${DTYPE} seed-<SEED> layout-bc && make sim"
    exit 1
else
    echo ""
    echo " ✓ 全部通过!"
    exit 0
fi
