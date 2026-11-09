#include "int8tofp16_iq.h"

namespace aiacc {
namespace iq {

uint8_t Int8ToFp16Iq::pack_cru_int8tofp16(const Int8ToFp16Cru& para_cru) {
    // cru_int8tofp16[1:0] = {signed_mode, instruction_valid}
    uint8_t code = 0;
    code |= (para_cru.para_inst_valid ? 1u : 0u);
    code |= (para_cru.para_signed_mode ? 1u : 0u) << 1;
    return code;
}

MicroInstruction Int8ToFp16Iq::make_micro_inst(const Int8ToFp16Cru& para_cru) {
    MicroInstruction inst{};
    inst.vld = para_cru.para_inst_valid;
    inst.code = pack_cru_int8tofp16(para_cru);
    return inst;
}

} // namespace iq
} // namespace aiacc
