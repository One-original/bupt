#ifndef SHIFTDOWN_IQ_H
#define SHIFTDOWN_IQ_H

/**
 * @file shiftdown_iq.h
 * @brief SHIFTDOWN 模块 IQ：下行数据移位
 * 
 * 对齐 cells/shift_down/vsrc/shift_down.v:
 * crd_shiftdn_in[133:0] = {vld, data[127:0], smc_id[4:0]}
 */

#include <cstdint>
#include "../smi_iq_base.h"

namespace aiacc {
namespace iq {

struct ShiftDownCru {
    bool para_vld{false};
    uint8_t para_data[16]{};  // 128-bit data
    uint8_t para_smc_id{0};   // 5-bit
};

class ShiftDownIq : public SmiIqBase {
public:
    explicit ShiftDownIq(SmiIqHandle* para_handle) : SmiIqBase(para_handle) {}

    // 134-bit 太大，需要特殊处理
    static void pack_crd_shiftdown(const ShiftDownCru& para_cru, uint32_t out_words[5]);
    static MicroInstruction make_micro_inst(const ShiftDownCru& para_cru);
};

} // namespace iq
} // namespace aiacc

#endif
