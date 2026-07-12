#ifndef INT8TOFP16_IQ_H
#define INT8TOFP16_IQ_H

/**
 * @file int8tofp16_iq.h
 * @brief INT8toFP16 模块 IQ：32 路并行 INT8 转 FP16
 * 
 * 对齐 cells/INT8toFP16/vsrc/int8_to_fp16_array.v:
 * cru_int8tofp16[1:0] = {signed_mode, instruction_valid}
 */

#include <cstdint>
#include "../smi_iq_base.h"

namespace aiacc {
namespace iq {

struct Int8ToFp16Cru {
    bool para_inst_valid{false};
    bool para_signed_mode{true};  // 1=有符号, 0=无符号
};

class Int8ToFp16Iq : public SmiIqBase {
public:
    explicit Int8ToFp16Iq(SmiIqHandle* para_handle) : SmiIqBase(para_handle) {}

    static uint8_t pack_cru_int8tofp16(const Int8ToFp16Cru& para_cru);
    static MicroInstruction make_micro_inst(const Int8ToFp16Cru& para_cru);
};

} // namespace iq
} // namespace aiacc

#endif
