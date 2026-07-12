#include "fptofp_iq.h"

namespace aiacc {
namespace iq {


uint8_t FpToFpIq::pack_cru_fptofp(const FpToFpCru& para_cru) {
    // cru_fptofp[4:0] = {dst_pos, src_pos, dest_precision, src_precision, instruction_valid}
    uint8_t code = 0;
    // Bit 0: 指令有效
    code |= (para_cru.para_inst_valid ? 1u : 0u) << 0;
    // Bit 1: 源寄存器精度
    code |= (para_cru.para_src_is_32b ? 1u : 0u) << 1;
    // Bit 2: 目的寄存器精度
    code |= (para_cru.para_dst_is_32b ? 1u : 0u) << 2;
    // Bit 3: 源数据位置
    code |= (para_cru.para_src_high ? 1u : 0u) << 3;
    // [新增] Bit 4: 目的数据位置
    code |= (para_cru.para_dst_high ? 1u : 0u) << 4;
    return code;
}


MicroInstruction FpToFpIq::make_micro_inst(const FpToFpCru& para_cru) {
    MicroInstruction inst{};
    inst.vld = para_cru.para_inst_valid;
    inst.code = pack_cru_fptofp(para_cru);
    return inst;
}

} // namespace iq
} // namespace aiacc
