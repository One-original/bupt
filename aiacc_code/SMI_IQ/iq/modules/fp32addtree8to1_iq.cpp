#include "fp32addtree8to1_iq.h"

namespace aiacc {
namespace iq {

uint8_t Fp32AddTree8To1Iq::pack_cru_fp32addtree8to1(const Fp32AddTree8To1Cru& para_cru) {
    uint8_t code = 0;
    // Bit 0: 指令有效
    code |= (para_cru.para_inst_valid ? 1u : 0u) << 0;
    // Bit 1-2: 目的寄存器编码
    code |= (para_cru.para_dst_reg_enc & 0x3u) << 1;
    return code;
}

MicroInstruction Fp32AddTree8To1Iq::make_micro_inst(const Fp32AddTree8To1Cru& para_cru) {
    MicroInstruction inst{};
    inst.vld = para_cru.para_inst_valid;
    inst.code = pack_cru_fp32addtree8to1(para_cru);
    return inst;
}

} // namespace iq
} // namespace aiacc
