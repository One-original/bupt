#include "fpadd_iq.h"

namespace aiacc {
namespace iq {

uint16_t FpAddIq::pack_cru_fpadd(const FpAddCru& para_cru) {
    uint16_t code = 0;

    // v0.4.15 / smc8_sim RTL:
    // [9:5]=smc_id_en, [4]=add_sub, [3]=update_status, [2]=dst_prec, [1]=src_prec, [0]=inst_valid
    code |= (para_cru.para_inst_valid ? 1u : 0u) << 0;
    code |= (para_cru.para_src_precision_32b ? 1u : 0u) << 1;
    code |= (para_cru.para_dst_precision_32b ? 1u : 0u) << 2;
    code |= (para_cru.para_update_status ? 1u : 0u) << 3;
    code |= (para_cru.para_is_sub ? 1u : 0u) << 4;
    code |= (static_cast<uint16_t>(para_cru.para_smc_id_en & 0x1Fu) << 5);

    return code;
}

MicroInstruction FpAddIq::make_micro_inst(const FpAddCru& para_cru) {
    MicroInstruction inst{};
    inst.vld = para_cru.para_inst_valid;
    inst.code = pack_cru_fpadd(para_cru);
    return inst;
}

} // namespace iq
} // namespace aiacc
