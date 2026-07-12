#ifndef FP16MUL_IQ_H
#define FP16MUL_IQ_H

/**
 * @file fp16mul_iq.h
 * @brief FP16MUL 模块 IQ：32 路并行 FP16 乘法，输出 FP32
 * 
 * 对齐 cells/fp16mul/vsrc/fp16mul.v:
 * - cru_fp16mul_s0123[1:0]: S0-S3 控制信号
 * - cru_fp16mul_s4567[3:0]: S4-S7 控制信号
 * - cru_fp16mul[2:0]: 乘法控制信号
 */

#include <cstdint>
#include "../smi_iq_base.h"

namespace aiacc {
namespace iq {

enum class Fp16MulOp {
    CALC,   // 乘法计算
    S4567,  // S4567 寄存器写入
    S0123   // S0123 寄存器写入
};


struct  Fp16MulCru {
    // 1. 乘法计算控制 (CRU-FP16MUL)
    bool para_mul_valid{false};        // Bit 0
    bool para_mul_src0_enc{false};     // Bit 1: 0 源寄存器编码
    bool para_mul_src1_enc{false};     // Bit 2: 1 源寄存器编码

    // 2. S4567 寄存器写入控制 (CRU-FP16MUL-S4567)
    bool para_s4567_valid{false};      // Bit 0
    bool para_s4567_high{false};       // Bit 1: 寄存器编码高位
    uint8_t para_s4567_low{0};         // Bit 2: 寄存器编码低位 (2 bits, 0-3)

    // 3. S0123 寄存器写入控制 (CRU-FP16MUL-S0123)
    bool para_s0123_valid{false};      // Bit 0
    bool para_s0123_high{false};       // Bit 1: 寄存器编码高位
};

class Fp16MulIq : public SmiIqBase {
public:
    explicit Fp16MulIq(SmiIqHandle* para_handle) : SmiIqBase(para_handle) {}

    // 主打包函数，组合 3 个子指令，弃用
    // static uint16_t pack_cru_fp16mul(const Fp16MulCru& para_cru);
    static MicroInstruction make_micro_inst(const Fp16MulCru& para_cru, Fp16MulOp op_type);
    // 分别打包三个子指令
    static uint8_t pack_cru_fp16mul_calc(const Fp16MulCru& para_cru);
    static uint8_t pack_cru_fp16mul_s4567(const Fp16MulCru& para_cru);
    static uint8_t pack_cru_fp16mul_s0123(const Fp16MulCru& para_cru);
};

} // namespace iq
} // namespace aiacc

#endif
