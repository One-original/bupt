#ifndef AIACC_SMI_IQ_H
#define AIACC_SMI_IQ_H

/**
 * @file aiacc_smi_iq.h
 * @brief SMI-IQ 的 HAL 基础定义：配置参数、MicroInstruction 格式、运行时句柄，以及位宽检查工具。
 */

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace aiacc {
namespace hal {


struct SmiIqConfig {
    uint32_t para_iq_id;

    bool para_en_embed_loops;
    bool para_en_loops;
    bool para_en_cond;
    bool para_en_dly;
    bool para_en_inc;

    uint8_t para_bits_embed_loops;
    uint8_t para_bits_loops;
    uint8_t para_bits_cond;
    uint8_t para_bits_dly;
    uint8_t para_bits_inc;
    uint8_t para_bits_code;

    uint8_t para_min_high;
    uint8_t para_min_low;

    bool para_has_extra_addr;
    bool para_has_extra_data;

    uint32_t para_instq_depth;
    uint32_t para_addrq_depth;
    uint32_t para_dataq_depth;
};


struct MicroInstruction {
    bool vld{false};
    bool jump{false};

    uint8_t embed{0};
    uint16_t loops{0};
    uint8_t cond{0};
    uint8_t dly{0};
    int8_t inc{0};

    uint32_t code{0};
};

// SmiIqHandle：IQ 的运行时句柄（配置 + 当前占用 + 可选 sink）。
struct SmiIqHandle {
    // 静态配置：位宽/队列深度/enable 开关等（通常对齐 RTL 参数）。
    SmiIqConfig config{};

    // 可选寄存器/内存映射基址（当前 demo 不使用）。
    void* base_addr{nullptr};

    // 软件侧占用计数：用于队列深度保护（防止生成/写入超量）。
    uint32_t current_inst_cnt{0};
    uint32_t current_addr_cnt{0};
    uint32_t current_data_cnt{0};

    // 可选输出 sink：用于单测/调试收集 push 的 micro-insts；nullptr 表示不收集。
    std::vector<MicroInstruction>* para_sw_inst_sink{nullptr};
};

// 位宽检查工具：用于按 config 检查字段范围。
inline void check_bits_u(uint32_t value, uint8_t bits, const char* field) {
    if (bits == 0) return;
    if (bits >= 32) return;
    const uint32_t maxv = (1u << bits) - 1u;
    if (value > maxv) throw std::runtime_error(std::string("field overflow: ") + field);
}

inline void check_bits_s(int32_t value, uint8_t bits, const char* field) {
    if (bits == 0) return;
    if (bits >= 31) return;
    const int32_t minv = -(1 << (bits - 1));
    const int32_t maxv = (1 << (bits - 1)) - 1;
    if (value < minv || value > maxv) throw std::runtime_error(std::string("field overflow: ") + field);
}

} // namespace hal
} // namespace aiacc

#endif
