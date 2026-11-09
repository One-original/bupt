#include "intadd_iq.h"

/**
 * @file intadd_iq.cpp
 * @brief INTADD 模块 IQ 实现：将 IntAddCru 按位打包，并生成用于 push 的 MicroInstruction。
 */

namespace aiacc {
namespace iq {

uint16_t IntAddIq::pack_cru_intadd(const IntAddCru& para_cru) {
    uint16_t code = 0;

    // [Bit 0] inst_valid: ‘b1：指令有效 ‘b0：指令无效
    code |= (uint16_t)(para_cru.para_inst_valid ? 1u : 0u) << 0;

    // [Bit 1-2] precision_s0: 源寄存器 0 的精度
    code |= (uint16_t)(para_cru.para_precision_s0 & 0x3u) << 1;

    // [Bit 3-4] precision_s1: 源寄存器 1 的精度
    code |= (uint16_t)(para_cru.para_precision_s1 & 0x3u) << 3;

    // [Bit 5-6] precision_s2: 源寄存器 2 的精度
    code |= (uint16_t)(para_cru.para_precision_s2 & 0x3u) << 5;

    // [Bit 7] sign_s0: 源寄存器 0 符号
    code |= (uint16_t)(para_cru.para_sign_s0 ? 1u : 0u) << 7;

    // [Bit 8] sign_s1: 源寄存器 1 符号
    code |= (uint16_t)(para_cru.para_sign_s1 ? 1u : 0u) << 8;

    // [Bit 9] sign_s2: 源寄存器 2 符号
    code |= (uint16_t)(para_cru.para_sign_s2 ? 1u : 0u) << 9;

    // [Bit 10] sign_d: 目的寄存器符号
    code |= (uint16_t)(para_cru.para_sign_d ? 1u : 0u) << 10;

    // [Bit 11] update_st: 是否更新状态寄存器
    code |= (uint16_t)(para_cru.para_update_st ? 1u : 0u) << 11;

    // [Bit 12] is_sub: 加减法
    code |= (uint16_t)(para_cru.para_is_sub ? 1u : 0u) << 12;

    return code;
}

MicroInstruction IntAddIq::make_micro_inst(const IntAddCru& para_cru) {
    MicroInstruction inst{};
    inst.vld = para_cru.para_inst_valid;
    inst.code = pack_cru_intadd(para_cru);
    return inst;
}

} // namespace iq
} // namespace aiacc
