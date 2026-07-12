#ifndef FP32ADDTREE5TO1_IQ_H
#define FP32ADDTREE5TO1_IQ_H

/**
 * @file fp32addtree5to1_iq.h
 * @brief FP32ADDTREE5TO1 模块 IQ：5 输入 FP32 加法树
 * 
 * 对齐 cells/fp32_addtree_5to1/vsrc/fp32_adder_tree_final.v:
 * cru_fp32addtree5to1: 1-bit 指令有效信号
 */

#include <cstdint>
#include "../smi_iq_base.h"

namespace aiacc {
namespace iq {

struct Fp32AddTree5To1Cru {
    bool para_inst_valid{false};
};

class Fp32AddTree5To1Iq : public SmiIqBase {
public:
    explicit Fp32AddTree5To1Iq(SmiIqHandle* para_handle) : SmiIqBase(para_handle) {}

    static uint8_t pack_cru_fp32addtree5to1(const Fp32AddTree5To1Cru& para_cru);
    static MicroInstruction make_micro_inst(const Fp32AddTree5To1Cru& para_cru);
};

} // namespace iq
} // namespace aiacc

#endif
