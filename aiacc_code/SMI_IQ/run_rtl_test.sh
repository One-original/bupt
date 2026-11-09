#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AIACC RTL 测试一键脚本
# 
# 用法:
#   ./run_rtl_test.sh <operator> [--lsu] [--seed N] [--rebuild]
#
# 示例:
#   ./run_rtl_test.sh mul                    # mul 纯 compute，8SMC
#   ./run_rtl_test.sh mul --lsu              # mul Load→Compute→Store，8SMC
#   ./run_rtl_test.sh bitwise_and            # bitwise_and 纯 compute
#   ./run_rtl_test.sh bitwise_and --lsu      # bitwise_and L-C-S
#   ./run_rtl_test.sh mul --seed 12345       # 指定 seed
#   ./run_rtl_test.sh mul --rebuild          # 强制 VCS rebuild（生成波形）
#
# 流程:
#   1. make tvgen（编译 tvgen）
#   2. tvgen 生成微指令 + 数据
#   3. 组装 8SMC case 目录
#   4. generate_data_list_coverage.py
#   5. run_sim_aiacc_top_f.sh RTL 仿真 + compare
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "${SCRIPT_DIR}/../8_sim" && pwd)"
LOG_DIR="${SCRIPT_DIR}/out/logs"

# 默认参数
OPERATOR=""
USE_LSU=0
SEED=$(date +%s)
REBUILD_FLAG=""
NUM_SMC=8
CAPTURE_DIR=""
CAPTURE_KIND="rope"
TILE_START=0
TILE_TOKENS=""

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lsu)      USE_LSU=1; shift;;
        --seed)     SEED="$2"; shift 2;;
        --rebuild)  REBUILD_FLAG="--rebuild"; shift;;
        --capture-dir) CAPTURE_DIR="$2"; shift 2;;
        --capture-kind) CAPTURE_KIND="$2"; shift 2;;
        --tile-start) TILE_START="$2"; shift 2;;
        --tile-tokens) TILE_TOKENS="$2"; shift 2;;
        -*)         echo "未知选项: $1"; exit 1;;
        *)          OPERATOR="$1"; shift;;
    esac
done

if [[ -z "$OPERATOR" ]]; then
    echo "错误: 请指定算子名称"
    echo "用法: $0 <operator> [--lsu] [--seed N] [--rebuild]"
    exit 1
fi

if [[ -n "$CAPTURE_DIR" ]]; then
    if [[ "$OPERATOR" != "add" ]] || [[ $USE_LSU -ne 1 ]]; then
        echo "ERROR: --capture-dir is supported only by add --lsu"
        exit 1
    fi
    if [[ -z "$TILE_TOKENS" ]] || ! [[ "$TILE_START" =~ ^[0-9]+$ ]] ||
       ! [[ "$TILE_TOKENS" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: capture mode requires --tile-start N and --tile-tokens N"
        exit 1
    fi
    if [[ "$CAPTURE_KIND" != "rope" ]] && [[ "$CAPTURE_KIND" != "epsilon" ]]; then
        echo "ERROR: --capture-kind must be rope or epsilon"
        exit 1
    fi
fi

# 算子名映射（小写→tvgen 大写名）
declare -A OP_NAME_MAP=(
    [mul]="Mul"
    [bitwise_and]="BitwiseAnd"
    [add]="FusedScaleAdd"
    [neg]="Neg"
    [exp]="Exp"
    [cos]="Cos"
    [rsqrt]="Rsqrt"
    [pow]="Pow"
)

# 算子默认 bank 配置
declare -A OP_INPUT_BANK=( [mul]=0 [bitwise_and]=0 [add]=0 [rsqrt]=0 )
declare -A OP_OTHER_BANK=( [mul]=1 [bitwise_and]=1 [add]=1 [rsqrt]=1 )
declare -A OP_OUTPUT_BANK=( [mul]=3 [bitwise_and]=2 [add]=3 [rsqrt]=5 )

TVGEN_OP="${OP_NAME_MAP[$OPERATOR]:-$OPERATOR}"
INPUT_BANK="${OP_INPUT_BANK[$OPERATOR]:-0}"
OTHER_BANK="${OP_OTHER_BANK[$OPERATOR]:-1}"
OUTPUT_BANK="${OP_OUTPUT_BANK[$OPERATOR]:-2}"

CASE_NAME="${OPERATOR}_8smc"
[[ $USE_LSU -eq 1 ]] && CASE_NAME="${OPERATOR}_8smc_lsu"
if [[ -n "$CAPTURE_DIR" ]]; then
    CASE_NAME="add_capture_${CAPTURE_KIND}_t${TILE_START}_n${TILE_TOKENS}_8smc_lsu"
fi
CASE_REL="verification_v2/${CASE_NAME}"
CASE_ABS="${RTL_DIR}/test_atomic_ops/${CASE_REL}"
TVGEN_BIN="${SCRIPT_DIR}/out/tvgen"
TVGEN_OUT="${SCRIPT_DIR}/out/${CASE_NAME}"

echo "=============================================="

echo " AIACC RTL 测试"
echo "=============================================="
echo " 算子:     $OPERATOR ($TVGEN_OP)"
echo " 模式:     $([ $USE_LSU -eq 1 ] && echo 'Load→Compute→Store' || echo '纯 Compute')"
echo " Seed:     $SEED"
echo " SMC:      $NUM_SMC"
echo " Case:     $CASE_REL"
echo " RTL dir:  $RTL_DIR"
echo " Rebuild:  $([ -n \"$REBUILD_FLAG\" ] && echo 'Yes' || echo 'No')"
if [[ -n "$CAPTURE_DIR" ]]; then
    echo " Capture:  $CAPTURE_DIR"
    echo " Kind:     $CAPTURE_KIND"
    echo " Tile:     start=$TILE_START tokens=$TILE_TOKENS"
fi
echo "=============================================="

# Step 1: 编译 tvgen
echo ""
echo "[1/5] 编译 tvgen..."
cd "$SCRIPT_DIR"
make tvgen 2>&1 | tail -2
if [[ ! -x "$TVGEN_BIN" ]]; then
    echo "错误: tvgen 编译失败"
    exit 1
fi

# Step 2: 生成微指令
echo ""
echo "[2/5] 生成微指令 ($TVGEN_OP, seed=$SEED)..."

if [[ $USE_LSU -eq 1 ]]; then
    # L-C-S 模式：用 load_store_v2 框架
    LSU_GEN="${SCRIPT_DIR}/out/gen_${OPERATOR}_lsu_case"
    LSU_SRC="${SCRIPT_DIR}/load_store_v2/${OPERATOR}/gen_*_lsu_case.cpp"
    
    # 查找对应的 gen 源文件
    LSU_MAIN=$(find "${SCRIPT_DIR}/load_store_v2" -path "*/${OPERATOR}/*" -name "gen_*_lsu_case.cpp" | head -1)
    LSU_OP_SRC=$(find "${SCRIPT_DIR}/load_store_v2" -path "*/${OPERATOR}/*" -name "*_lsu_op.cpp" | head -1)
    
    if [[ -z "$LSU_MAIN" ]] || [[ -z "$LSU_OP_SRC" ]]; then
        echo "错误: 未找到 load_store_v2/${OPERATOR}/ 下的 L-C-S 源文件"
        echo "  需要: gen_*_lsu_case.cpp 和 *_lsu_op.cpp"
        exit 1
    fi
    
    echo "  编译 L-C-S 生成器..."
    OP_SRCS=$(find op -name "*.cpp" | grep -vE "/(div|div_scalar|select|expand|Mean-dim|mul_scalar|softmax|sub|add|cos|exp|neg|pow|unsqueeze|rsqrt)/" | grep -vE "/test_" | grep -vE "_main\.cpp$" | tr '\n' ' ')
    if [[ "$OPERATOR" == "add" ]]; then
        OP_SRCS+=" $(find op/add -maxdepth 1 -name '*.cpp' ! -name 'add_op_multi_stage1.cpp' | tr '\n' ' ')"
    fi
    IQ_SRCS=$(find iq -name "*.cpp" | tr '\n' ' ')
    g++ -std=c++17 -O2 -fno-stack-protector -I"$SCRIPT_DIR" -I"$SCRIPT_DIR/app" \
        "$LSU_MAIN" load_store_v2/lsu_op_base.cpp "$LSU_OP_SRC" \
        $OP_SRCS $IQ_SRCS \
        app/tvgen_core.cpp app/tvgen_dynamic.cpp app/simulator_config_gen.cpp app/app_json_parser.cpp app/fp16_utils.cpp \
        math_utils/newton_method/newton_method.cpp math_utils/taylor_series/taylor_series.cpp \
        -o "$LSU_GEN" 2>&1 | grep -i "^.*error" && exit 1 || true
    
    echo "  生成 L-C-S case..."
    rm -rf "$CASE_ABS"
    LSU_ARGS=("$LSU_GEN" "$CASE_ABS" "${RTL_DIR}/data_engine/sram" "$SEED")
    if [[ -n "$CAPTURE_DIR" ]]; then
        LSU_ARGS+=(--capture-dir "$CAPTURE_DIR" --capture-kind "$CAPTURE_KIND" --tile-start "$TILE_START" --tile-tokens "$TILE_TOKENS")
    fi
    "${LSU_ARGS[@]}"
else
    # 纯 Compute 模式：用 tvgen + JSON
    JSON_FILE="/tmp/${CASE_NAME}_req.json"
    cat > "$JSON_FILE" <<EOF
{
    "operator": "$TVGEN_OP",
    "dimensions": {"N":1, "C":1, "H":1, "W":1020},
    "parameters": {
        "input_bank": {"shape":[1], "dtype":"int32", "data":[$INPUT_BANK]},
        "input_addr": {"shape":[1], "dtype":"int32", "data":[0]},
        "other_bank": {"shape":[1], "dtype":"int32", "data":[$OTHER_BANK]},
        "other_addr": {"shape":[1], "dtype":"int32", "data":[0]},
        "output_bank": {"shape":[1], "dtype":"int32", "data":[$OUTPUT_BANK]},
        "output_addr": {"shape":[1], "dtype":"int32", "data":[0]},
        "smc_id_en": {"shape":[1], "dtype":"int32", "data":[7]},
        "num_smc": {"shape":[1], "dtype":"int32", "data":[$NUM_SMC]}
    }
}
EOF
    "$TVGEN_BIN" --json "$JSON_FILE" --output "$TVGEN_OUT" --verbose 2>&1 | tail -3
    
    # 组装 8SMC case
    echo "  组装 8SMC case..."
    rm -rf "$CASE_ABS"
    python3 -c "
import os, shutil

case_root = '$CASE_ABS'
tvgen_out = '$TVGEN_OUT'
num_smc = $NUM_SMC
output_bank = $OUTPUT_BANK

input_bin = open(f'{tvgen_out}/input.bin', 'rb').read()
other_bin = open(f'{tvgen_out}/other.bin', 'rb').read()
golden_bin = open(f'{tvgen_out}/golden.bin', 'rb').read()

def bin_to_hex_lines(data, lb=16):
    lines = []
    for i in range(0, len(data), lb):
        lines.append(data[i:i+lb][::-1].hex())
    while len(lines) < 256: lines.append('0'*32)
    return lines

input_lines = bin_to_hex_lines(input_bin)
other_lines = bin_to_hex_lines(other_bin)
golden_lines = bin_to_hex_lines(golden_bin)

hex_dir = f'{tvgen_out}/hex_instructions'
hex_map = {}
for fn in os.listdir(hex_dir):
    if fn.endswith('.hex'):
        parts = fn.split('_', 2)
        if len(parts) >= 3:
            new_name = 'iq_' + parts[2]
            new_name = new_name.replace('ur_rdata_0','ur-r0').replace('ur_rdata_1','ur-r1')
            new_name = new_name.replace('ur_rdata_2','ur-r2').replace('ur_rdata_3','ur-r3')
            new_name = new_name.replace('ur_wdata_0','ur-w0').replace('ur_wdata_1','ur-w1')
            new_name = new_name.replace('ur_wdata_2','ur-w2').replace('ur_wdata_3','ur-w3')
            hex_map[fn] = new_name

for smc in range(num_smc):
    sd = f'{case_root}/smc_{smc}'
    os.makedirs(f'{sd}/ur_data', exist_ok=True)
    os.makedirs(f'{sd}/output_bank', exist_ok=True)
    for b in range(8):
        with open(f'{sd}/ur_data/bank{b}.hex','w') as f:
            if b == $INPUT_BANK: f.write('\n'.join(input_lines)+'\n')
            elif b == $OTHER_BANK: f.write('\n'.join(other_lines)+'\n')
            else: f.write(('0'*32+'\n')*256)
    with open(f'{sd}/output_bank/bank{output_bank}_final.hex','w') as f:
        f.write('\n'.join(golden_lines)+'\n')
    if smc == 0:
        for old, new in hex_map.items():
            shutil.copy(f'{hex_dir}/{old}', f'{sd}/{new}')

print(f'  Case: {case_root} ({num_smc} SMCs)')
"
fi

# Step 3: generate_data_list
echo ""
echo "[3/5] 生成 data_list..."
cd "$RTL_DIR"
python3 ./generate_data_list_coverage.py "$CASE_REL" --subq 0 > /dev/null 2>&1

# Step 4: RTL 仿真
echo ""
echo "[4/5] RTL 仿真..."
mkdir -p "$LOG_DIR"
RTL_LOG="${LOG_DIR}/${CASE_NAME}_rtl.log"
set +e
SKIP_GENERATE_DATA_LIST=1 bash ./run_sim_aiacc_top_f.sh $REBUILD_FLAG verification_v2 "${CASE_REL}/smc_0" -s 0 > "$RTL_LOG" 2>&1
RTL_STATUS=$?
set -e

# Step 5: 结果
echo ""
echo "[5/5] 结果:"
echo "=============================================="
SUMMARY=$(grep "Summary:" "$RTL_LOG" | tail -1 || true)
if [[ -n "$SUMMARY" ]]; then
    echo "$SUMMARY"
else
    echo "  RTL/compare failed before producing Summary (exit=$RTL_STATUS)"
    echo "  Key errors:"
    grep -Ei "fatal|error|fail|missing|not found|no such" "$RTL_LOG" | tail -20 || true
    echo "  Last 40 log lines:"
    tail -40 "$RTL_LOG"
    echo "  Log: $RTL_LOG"
fi

LSU_COMPARE_STATUS=0
if [[ "$OPERATOR" == "add" ]] && [[ $USE_LSU -eq 1 ]]; then
    LSU_COMPARE_LOG="${LOG_DIR}/${CASE_NAME}_lsu_compare.log"
    set +e
    python3 "${SCRIPT_DIR}/load_store_v2/add/compare_add_store.py" \
        "$CASE_ABS" > "$LSU_COMPARE_LOG" 2>&1
    LSU_COMPARE_STATUS=$?
    set -e
    cat "$LSU_COMPARE_LOG"
    if [[ $LSU_COMPARE_STATUS -ne 0 ]]; then
        echo "  Add LSU compare failed. Log: $LSU_COMPARE_LOG"
        exit 1
    fi
fi

if [[ $RTL_STATUS -ne 0 ]] || [[ -z "$SUMMARY" ]] ||
   [[ "$SUMMARY" != *"pass=${NUM_SMC} fail=0 skip=0"* ]]; then
    exit 1
fi

FSDB=$(find sim_output_aiacc_top_f -name "*.fsdb" 2>/dev/null | head -1)
if [[ -n "$FSDB" ]]; then
    echo "  波形: ${RTL_DIR}/${FSDB}"
fi
echo "  日志: $RTL_LOG"
echo "=============================================="
