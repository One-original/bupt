#ifndef ADD_OP_H
#define ADD_OP_H

/**
 * @file add_op.h
 * @brief FusedScaleAdd 算子：out = input + alpha * other
 * 
 * 支持的数据类型：
 * - FP32×4: 浮点32位，4路并行
 * - FP16×8: 浮点16位，8路并行
 *
 * 数据流（浮点模式）：
 * 1. UR 读 input, other, alpha
 * 2. RtoVR 路由: alpha → FPMUL_S0, other → FPMUL_S1
 * 3. FPMUL: alpha * other
 * 4. RtoVR 路由: input → FPADD_S0, FPMUL_D → FPADD_S1
 * 5. FPADD: input + (alpha * other)
 * 6. RtoVR 路由: FPADD_D → UVR_WDATA
 * 7. UR 写 output
 */

#include <cstdint>
#include <vector>
#include <string>
#include <random>

#include "../../hal/aiacc_smi_iq.h"
#include "../../iq/modules/ur_iq.h"
#include "../../iq/modules/rtovr_iq.h"
#include "../../iq/modules/fpmul_iq.h"
#include "../../iq/modules/fpadd_iq.h"
#include "../common/op_instructions_base.h"
#include "../common/op_base.h"
#include "../common/op_registry.h"
#include "../../app/app_json_parser.h"

namespace aiacc {
namespace op {

// ==========================================
// 数据类型枚举
// ==========================================

enum class AddDataType : uint8_t {
    FP32 = 0,      // FP32×4: 4个32位浮点数
    FP16 = 1       // FP16×8: 8个16位浮点数
};

// ==========================================
// Add 算子参数
// ==========================================

struct AddOpParams {
    // Local tile shape consumed by the Add compute microcode.
    //
    // For the full tensor path, DRAM tensor layout is handled by load/store.
    // Add only sees the tile that has already been placed in one SMC/SubUR.
    // The current compute pipeline is flat over para_n*para_c*para_h*para_w.
    uint32_t para_n{1};
    uint32_t para_c{1};
    uint32_t para_h{1};
    uint32_t para_w{4};
    
    // 数据类型
    AddDataType para_dtype{AddDataType::FP32};
    
    // UR 存储布局
    // input 张量
    uint8_t para_input_bank{0};
    uint8_t para_input_addr{0};
    
    // other 张量
    uint8_t para_other_bank{1};
    uint8_t para_other_addr{0};
    bool para_other_broadcast{false};
    
    // alpha 参数 (广播，shape=[W])
    uint8_t para_alpha_bank{2};
    uint8_t para_alpha_addr{0};
    
    // output 张量
    uint8_t para_output_bank{3};
    uint8_t para_output_addr{0};
    
    // 辅助函数：获取每个word的元素数量
    uint32_t get_elems_per_word() const {
        switch (para_dtype) {
            case AddDataType::FP32:  return 4;   // 128bit / 32bit = 4
            case AddDataType::FP16:  return 8;   // 128bit / 16bit = 8
            default: return 4;
        }
    }

    uint32_t get_total_elements() const {
        return para_n * para_c * para_h * para_w;
    }

    uint32_t get_word_count() const {
        const uint32_t elems_per_word = get_elems_per_word();
        return (get_total_elements() + elems_per_word - 1) / elems_per_word;
    }
};

// ==========================================
// Add 算子微指令序列
// ==========================================

struct AddOpInstructions : public OpInstructionsBase {
    // 保存原始的 UrCru 结构（用于 get_iq_files 提取 CODE / print 打包）
    std::vector<iq::UrCru> para_ur_read_crus;
    std::vector<iq::UrCru> para_ur_write_crus;
    
    // RtoVR 路由指令 (240bit = 8x32bit words)
    //   阶段1: alpha,other → FPMUL
    //   阶段2: input,fpmul_d → FPADD
    //   阶段3: fpadd_d → UR_WDATA
    std::vector<uint32_t> para_rtovr_stage1;
    std::vector<uint32_t> para_rtovr_stage2;
    std::vector<uint32_t> para_rtovr_stage3;
    
    // 浮点指令
    uint16_t para_fpmul_inst{0};  // FPMUL 指令 (8bit, v0.4.15)
    uint16_t para_fpadd_inst{0};  // FPADD 指令 (10bit, v0.4.15)
    
    // 数据类型标记
    AddDataType para_dtype{AddDataType::FP32};
    
    // 统计信息
    uint32_t para_total_steps{0};
    uint32_t para_total_elements{0};
    
    // 嵌套循环参数
    uint16_t para_embed_loops{0};  // 外层循环次数 (N×C×H)
    uint16_t para_inner_loops{0};  // 内层循环次数 (W/elems_per_word)
    
    // Bank 冲突解决：多 slot 调度
    uint8_t para_num_slots{1};  // 需要的 slot 数量（1=无冲突，2+ 表示有冲突需要多 slot）
    
    // 每个 slot 的访问分配（用于多 slot 模式）
    // slot_access[slot_id] = {input_slot, other_slot, alpha_slot, output_slot}
    // 值为 0xFF 表示该 slot 不访问该 tensor
    struct SlotAccess {
        uint8_t input_slot{0xFF};   // input 在哪个 slot 被读（0xFF=不读）
        uint8_t other_slot{0xFF};   // other 在哪个 slot 被读（0xFF=不读）
        uint8_t alpha_slot{0xFF};   // alpha 在哪个 slot 被读（0xFF=不读）
        uint8_t output_slot{0xFF};  // output 在哪个 slot 被写（0xFF=不写）
        bool has_compute{false};    // 该 slot 是否执行计算
    };
    std::vector<SlotAccess> para_slot_accesses;  // 每个 slot 的访问信息
    
    // EMBED 模式：每个端口的 slot 分配（同 bank 端口分到不同 slot）
    // port_slots[0]=r0(input), [1]=r1(other), [2]=r2(alpha), [3]=w0(output)
    uint8_t para_port_slots[4] = {0, 0, 0, 0};

    // Bank 信息（用于 W0 时序计算时判断是否与读端口共享 bank）
    uint8_t para_input_bank{0};
    uint8_t para_other_bank{1};
    uint8_t para_alpha_bank{2};
    uint8_t para_output_bank{3};
    
    // 实现基类接口
    std::vector<IqInstructionFile> get_iq_files() const override;
    std::string get_operator_name() const override { return "FusedScaleAdd"; }
    uint32_t get_total_steps() const override { return para_total_steps; }
    uint32_t get_total_elements() const override { return para_total_elements; }
    std::vector<uint8_t> serialize() const override;
};

// ==========================================
// Add 算子编译器
// ==========================================

class AddOp : public OpBase {
public:
    AddOp() = default;
    ~AddOp() = default;

    // 实现 OpBase 接口
    std::string get_name() const override;
    OpInstructionsBase* compile(const app::AppOperatorRequest& req) override;
    bool calculate_golden(const app::AppOperatorRequest& req, 
                         std::vector<uint8_t>& golden_bin) override;
    bool generate_data(const app::AppOperatorRequest& req, 
                      std::vector<uint8_t>& input_bin, 
                      std::vector<uint8_t>& other_bin, 
                      std::vector<uint8_t>& alpha_bin) override;
    void fill_random_request(app::AppOperatorRequest& req, 
                             std::mt19937& rng,
                             std::uniform_real_distribution<float>& data_dist,
                             const std::string& dtype_str) override;

    // 原有方法保留，供内部使用
    AddOpInstructions compile(const AddOpParams& para_params);

private:
    // 注意：以下函数已迁移到独立模块，不再在此声明
    // - Bank 冲突解决：add_op_bank_conflict.h
    // - UR 微指令生成：add_op_ur_inst.h
    // - RtoVR 路由微指令生成：add_op_rtovr_inst.h
    // - 计算单元微指令生成：add_op_compute_inst.h
};

// ==========================================
// 辅助函数
// ==========================================

void print_add_instructions(const AddOpInstructions& para_insts);

} // namespace op
} // namespace aiacc

#endif // ADD_OP_H
