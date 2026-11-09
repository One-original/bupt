#ifndef INTADD_IQ_H
#define INTADD_IQ_H

/**
 * @file intadd_iq.h
 * @brief INTADD 模块 IQ：定义控制字段 IntAddCru，并将其打包为 MicroInstruction.code。
 */

#include <cstdint>

#include "../smi_iq_base.h"

namespace aiacc {
namespace iq {

/**
 * @brief INTADD 上行指令字段（对应 `docs/intadd.md` 表4）
 * [Design Rationale]: 
 * 用强类型字段表示每一位的含义，避免在 OP 里手写魔法数字拼 bit。
 */
struct IntAddCru {
    bool para_inst_valid{false};

    // 2-bit precision per operand
    // 00:4bit, 01:8bit(暂不支持), 10:16bit(暂不支持), 11:32bit
    uint8_t para_precision_s0{0};
    uint8_t para_precision_s1{0};
    uint8_t para_precision_s2{0};

    bool para_sign_s0{false};
    bool para_sign_s1{false};
    bool para_sign_s2{false};

    // 目的寄存器符号 (dst sign) 修改高低位
    // 根据 INTADD.md，位映射如下：
    //   [0] inst_valid
    //   [1-2] precision_s0
    //   [3-4] precision_s1
    //   [5-6] precision_s2
    //   [7] sign_s0
    //   [8] sign_s1
    //   [9] sign_s2
    //   [10] sign_d
    //   [11] update_st
    //   [12] is_sub
    bool para_sign_d{false};

    bool para_update_st{false};

    // [新增] 加减法控制 (对应 Bit 12)
    // false(0): 加法
    // true (1): 减法
    bool para_is_sub{false};
};

/**
 * @brief INTADD 队列子类
 * [Design Rationale]: 
 * 负责把 IntAddCru 打包成 code（11bit cru_intadd），并生成 MicroInstruction。
 */
class IntAddIq : public SmiIqBase {
public:
    explicit IntAddIq(SmiIqHandle* para_handle) : SmiIqBase(para_handle) {}

    // LSB(Bit 0) 为 inst_valid，MSB(Bit 12) 为 is_sub
    static uint16_t pack_cru_intadd(const IntAddCru& para_cru);

    // 生成一条用于 INTADD 的 MicroInstruction（只设置 code，其它字段默认 0）。
    static MicroInstruction make_micro_inst(const IntAddCru& para_cru);
};

} // namespace iq
} // namespace aiacc

#endif
