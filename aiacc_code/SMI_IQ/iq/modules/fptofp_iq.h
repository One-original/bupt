#ifndef FPTOFP_IQ_H
#define FPTOFP_IQ_H

/**
 * @file fptofp_iq.h
 * @brief FPtoFP 模块 IQ：浮点类型转换
 * 
 * 对齐 cells/FPtoFP/vsrc/fptofp_array.v:
 * cru_fptofp[4:0] = {src_pos, dest_precision, src_precision, instruction_valid}
 */

#include <cstdint>
#include "../smi_iq_base.h"

namespace aiacc {
namespace iq {


struct FpToFpCru {
    bool para_inst_valid{false};
    bool para_src_is_32b{true};   // 1=FP32, 0=FP16
    bool para_dst_is_32b{true};   // 1=FP32, 0=FP16
    bool para_src_high{false};    // 1=高位, 0=低位
    bool para_dst_high{false};    // [新增1.29] Bit 4: 目的数据位置 (1=高位, 0=低位)
};

class FpToFpIq : public SmiIqBase {
public:
    explicit FpToFpIq(SmiIqHandle* para_handle) : SmiIqBase(para_handle) {}

    static uint8_t pack_cru_fptofp(const FpToFpCru& para_cru);
    static MicroInstruction make_micro_inst(const FpToFpCru& para_cru);
};

} // namespace iq
} // namespace aiacc

#endif
