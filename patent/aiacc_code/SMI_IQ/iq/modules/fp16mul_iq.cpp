#include "fp16mul_iq.h"

namespace aiacc {
namespace iq {

// 1. 打包乘法计算控制微指令 (3 bit)
uint8_t Fp16MulIq::pack_cru_fp16mul_calc(const Fp16MulCru& para_cru) {
    // | src1 (Bit 2) | src0 (Bit 1) | valid (Bit 0) |
    uint8_t code = 0;
    code |= (para_cru.para_mul_valid ? 1u : 0u) << 0;
    code |= (para_cru.para_mul_src0_enc ? 1u : 0u) << 1;
    code |= (para_cru.para_mul_src1_enc ? 1u : 0u) << 2;
    return code;
}

// 2. 打包 S4567 寄存器写入控制微指令 (4 bit)
uint8_t Fp16MulIq::pack_cru_fp16mul_s4567(const Fp16MulCru& para_cru) {
    // | low (Bit 2-3) | high (Bit 1) | valid (Bit 0) |
    uint8_t code = 0;
    code |= (para_cru.para_s4567_valid ? 1u : 0u) << 0;
    code |= (para_cru.para_s4567_high ? 1u : 0u) << 1;
    code |= (para_cru.para_s4567_low & 0x3u) << 2; // 2 bits width
    return code;
}

// 3. 打包 S0123 寄存器写入控制微指令 (2 bit)
uint8_t Fp16MulIq::pack_cru_fp16mul_s0123(const Fp16MulCru& para_cru) {
    // | high (Bit 1) | valid (Bit 0) |
    uint8_t code = 0;
    code |= (para_cru.para_s0123_valid ? 1u : 0u) << 0;
    code |= (para_cru.para_s0123_high ? 1u : 0u) << 1;
    return code;
}

MicroInstruction Fp16MulIq::make_micro_inst(const Fp16MulCru& para_cru, Fp16MulOp op_type) {
    MicroInstruction inst{};
    switch (op_type) {
        case Fp16MulOp::CALC:
            // 乘法
            inst.vld = para_cru.para_mul_valid;
            inst.code = pack_cru_fp16mul_calc(para_cru);
            break;
        case Fp16MulOp::S4567:
            // S4567
            inst.vld = para_cru.para_s4567_valid;
            inst.code = pack_cru_fp16mul_s4567(para_cru);
            break;
        case Fp16MulOp::S0123:
            // S0123
            inst.vld = para_cru.para_s0123_valid;
            inst.code = pack_cru_fp16mul_s0123(para_cru);
            break;
    }
    return inst;
}

} // namespace iq
} // namespace aiacc
