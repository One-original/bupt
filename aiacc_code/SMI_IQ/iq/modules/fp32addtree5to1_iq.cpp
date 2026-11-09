#include "fp32addtree5to1_iq.h"

namespace aiacc {
namespace iq {

uint8_t Fp32AddTree5To1Iq::pack_cru_fp32addtree5to1(const Fp32AddTree5To1Cru& para_cru) {
    return para_cru.para_inst_valid ? 1u : 0u;
}

MicroInstruction Fp32AddTree5To1Iq::make_micro_inst(const Fp32AddTree5To1Cru& para_cru) {
    MicroInstruction inst{};
    inst.vld = para_cru.para_inst_valid;
    inst.code = pack_cru_fp32addtree5to1(para_cru);
    return inst;
}

} // namespace iq
} // namespace aiacc
