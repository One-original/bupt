#!/bin/bash
# =============================================================================
# 算子批量回归测试脚本 (用于 GitHub 上传前验证)
#
# 用法: bash scripts/run_all_ops_test.sh [num_seeds] [start_seed]
#   num_seeds  - 每个算子跑多少个随机 seed (默认: 20)
#   start_seed - 起始 seed 编号 (默认: 1)
#
# 示例:
#   bash scripts/run_all_ops_test.sh           # 每个算子跑 20 个 seed
#   bash scripts/run_all_ops_test.sh 5         # 每个算子跑 5 个 seed (快速验证)
#   bash scripts/run_all_ops_test.sh 20 100    # 从 seed=100 开始
#
# 通过注释/取消注释下面 OP_LIST 的条目来选择要测试的算子。
# =============================================================================

set -euo pipefail

# ===================== 算子配置 (注释掉不想跑的算子) =====================
# 格式: "算子名:数据类型"  或  "算子名:数据类型:layout"
# layout 可选值: bc (bank_conflict), bc4 (bank_conflict_4), 留空为默认模式
OP_LIST=(
    # --- 默认模式 ---
    #"add:fp32"
    "mul:fp32"
    #"neg:fp32"
    "div:fp32"
    #"pow:fp32"
    #"exp:fp32"
    #"cos:fp32"
    #"log:fp32"
    #"log1p:fp32"
    #"rsqrt:fp32"
    #"add:fp16"
    "mul:fp16"
    "div:fp16"
    # --- Bank Conflict 模式 ---
    #"add:fp32:bc"
    #"add:fp16:bc"
    "mul:fp32:bc"
    "mul:fp16:bc"
    #"neg:fp32:bc"
    #"add:fp32:bc4"
    "div:fp32:bc"
    "div:fp16:bc"
)
# ========================================================================

NUM_SEEDS=${1:-20}
START_SEED=${2:-1}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# 统计变量
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_RUN=0
FAILED_CASES=()

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo ""
echo "============================================================"
echo "  SMI_IQ 算子批量回归测试"
echo "============================================================"
echo "  算子数量: ${#OP_LIST[@]}"
echo "  每算子 seed 数: ${NUM_SEEDS}"
echo "  Seed 范围: ${START_SEED} ~ $((START_SEED + NUM_SEEDS - 1))"
echo "  总测试数: $(( ${#OP_LIST[@]} * NUM_SEEDS ))"
echo "============================================================"
echo ""

# 确保 tvgen 已编译
echo -e "${CYAN}[BUILD]${NC} 编译 tvgen ..."
make tvgen 2>&1 | tail -1
echo ""

# 遍历每个算子
for entry in "${OP_LIST[@]}"; do
    # 解析 "op:dtype" 或 "op:dtype:layout"
    IFS=':' read -r OP DTYPE LAYOUT <<< "$entry"
    LAYOUT=${LAYOUT:-}  # 默认为空

    # 构造 layout 显示标签
    if [ -n "$LAYOUT" ]; then
        LABEL="${OP} (${DTYPE}, layout=${LAYOUT})"
    else
        LABEL="${OP} (${DTYPE})"
    fi

    OP_PASS=0
    OP_FAIL=0

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}[OP]${NC} ${LABEL} - ${NUM_SEEDS} seeds"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    for i in $(seq 0 $((NUM_SEEDS - 1))); do
        # Generate random seed between 0 and 200000
        SEED=$(shuf -i 0-200000 -n 1)
        TOTAL_RUN=$((TOTAL_RUN + 1))
        if [ -n "$LAYOUT" ]; then
            TEST_ID="${OP}/${DTYPE}/${LAYOUT}/seed-${SEED}"
        else
            TEST_ID="${OP}/${DTYPE}/seed-${SEED}"
        fi

        echo -n "  [$((i+1))/${NUM_SEEDS}] ${TEST_ID} ... "

        # 1) 生成测试向量
        MAKE_ARGS=("${OP}" "mode-${DTYPE}" "seed-${SEED}")
        if [ -n "$LAYOUT" ]; then
            MAKE_ARGS+=("layout-${LAYOUT}")
        fi
        TVGEN_OUTPUT=$(make "${MAKE_ARGS[@]}" 2>&1) || {
            echo -e "${RED}FAIL${NC} (tvgen error)"
            OP_FAIL=$((OP_FAIL + 1))
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            FAILED_CASES+=("${TEST_ID} [tvgen error]")
            continue
        }

        # 提取额外信息（如 div 的 Newton 迭代次数）
        EXTRA_INFO=""
        if [ "$OP" = "div" ]; then
            NITERS=$(echo "$TVGEN_OUTPUT" | grep -o "Newton iters: [0-9]*" | grep -o "[0-9]*")
            if [ -n "$NITERS" ]; then
                EXTRA_INFO=" (iters=${NITERS})"
            fi
        fi

        # 2) 运行仿真 + golden 对比
        SIM_OUTPUT=$(make sim 2>&1) || {
            if echo "$SIM_OUTPUT" | grep -q "Bank Conflict ERROR"; then
                REASON="bank conflict"
            else
                REASON=$(echo "$SIM_OUTPUT" | grep -o "Mismatches: [0-9]*" || echo "sim error")
            fi
            echo -e "${RED}FAIL${NC}${EXTRA_INFO} (${REASON})"
            OP_FAIL=$((OP_FAIL + 1))
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            FAILED_CASES+=("${TEST_ID} [${REASON}]")
            continue
        }

        # 3) 检查 PASS
        if echo "$SIM_OUTPUT" | grep -q "PASS"; then
            echo -e "${GREEN}PASS${NC}${EXTRA_INFO}"
            OP_PASS=$((OP_PASS + 1))
            TOTAL_PASS=$((TOTAL_PASS + 1))
        else
            REASON=$(echo "$SIM_OUTPUT" | grep -o "Mismatches: [0-9]*" || echo "unknown")
            echo -e "${RED}FAIL${NC}${EXTRA_INFO} (${REASON})"
            OP_FAIL=$((OP_FAIL + 1))
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            FAILED_CASES+=("${TEST_ID} [${REASON}]")
        fi
    done

    # 单算子小结
    if [ ${OP_FAIL} -eq 0 ]; then
        echo -e "  ${GREEN}=> ${LABEL}: ${OP_PASS}/${NUM_SEEDS} PASS${NC}"
    else
        echo -e "  ${RED}=> ${LABEL}: ${OP_PASS} pass, ${OP_FAIL} fail${NC}"
    fi
    echo ""
done

# ======================== 总结 ========================
echo ""
echo "============================================================"
echo "  测试结果总结"
echo "============================================================"
echo "  总测试数: ${TOTAL_RUN}"
echo -e "  通过:     ${GREEN}${TOTAL_PASS}${NC}"
echo -e "  失败:     ${RED}${TOTAL_FAIL}${NC}"
echo "============================================================"

if [ ${TOTAL_FAIL} -gt 0 ]; then
    echo ""
    echo "  失败用例:"
    for c in "${FAILED_CASES[@]}"; do
        echo "    - ${c}"
    done
    echo ""
    echo "  复现命令:"
    echo "    make <op> mode-<dtype> seed-<seed> [layout-<bc|bc4>] && make sim"
    echo ""
    exit 1
else
    echo ""
    echo -e "  ${GREEN}✓ 全部通过! 可以上传 GitHub.${NC}"
    echo ""
    exit 0
fi
