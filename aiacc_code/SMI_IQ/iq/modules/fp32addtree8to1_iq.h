#ifndef FP32ADDTREE8TO1_IQ_H
#define FP32ADDTREE8TO1_IQ_H

/**
 * @file fp32addtree8to1_iq.h
 * @brief FP32ADDTREE8TO1 模块 IQ：8 输入 FP32 加法树
 * 
 * 对齐 cells/fp32_addtree_8to1/vsrc/fp32_adder_tree_8_inputs.v:
 * cru_fp32addtree8to1: 1-bit 指令有效信号
 */

#include <cstdint>
#include "../smi_iq_base.h"

namespace aiacc {
namespace iq {


struct Fp32AddTree8To1Cru {
    bool para_inst_valid{false};
    
    // [新增] 目的寄存器编码 (Bit 1-2)
    // 范围 0-3
    uint8_t para_dst_reg_enc{0};
};


class Fp32AddTree8To1Iq : public SmiIqBase {
public:
    explicit Fp32AddTree8To1Iq(SmiIqHandle* para_handle) : SmiIqBase(para_handle) {}

    static uint8_t pack_cru_fp32addtree8to1(const Fp32AddTree8To1Cru& para_cru);
    static MicroInstruction make_micro_inst(const Fp32AddTree8To1Cru& para_cru);
};

} // namespace iq
} // namespace aiacc

#endif
