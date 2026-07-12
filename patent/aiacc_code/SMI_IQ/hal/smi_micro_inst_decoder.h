#pragma once

/**
 * @file smi_micro_inst_decoder.h
 * @brief 软件侧 MicroInstruction 的解析/校验/打印工具（用于单测自校验与日志可读性）。
 */

#include "aiacc_smi_iq.h"

#include <cstdint>
#include <sstream>
#include <stdexcept>
#include <string>

namespace aiacc {
namespace hal {

struct DecodedMicroInstruction {
    bool vld{false};
    bool jump{false};
    uint32_t embed{0};
    uint32_t loops{0};
    uint32_t cond{0};
    uint32_t dly{0};
    int32_t inc{0};
    uint32_t code{0};
};

inline DecodedMicroInstruction decode_micro_inst(const MicroInstruction& mi) {
    DecodedMicroInstruction d{};
    d.vld = mi.vld;
    d.jump = mi.jump;
    d.embed = mi.embed;
    d.loops = mi.loops;
    d.cond = mi.cond;
    d.dly = mi.dly;
    d.inc = mi.inc;
    d.code = mi.code;
    return d;
}

inline void validate_micro_inst_or_throw(const SmiIqConfig& cfg, const MicroInstruction& mi) {
    // vld/jump are 1-bit bools

    if (cfg.para_en_embed_loops) {
        check_bits_u(mi.embed, cfg.para_bits_embed_loops, "embed");
    } else {
        if (mi.embed != 0) throw std::runtime_error("embed disabled by config");
    }

    if (cfg.para_en_loops) {
        check_bits_u(mi.loops, cfg.para_bits_loops, "loops");
    } else {
        if (mi.loops != 0) throw std::runtime_error("loops disabled by config");
    }

    if (cfg.para_en_cond) {
        check_bits_u(mi.cond, cfg.para_bits_cond, "cond");
    } else {
        if (mi.cond != 0) throw std::runtime_error("cond disabled by config");
    }

    if (cfg.para_en_dly) {
        check_bits_u(mi.dly, cfg.para_bits_dly, "dly");
    } else {
        if (mi.dly != 0) throw std::runtime_error("dly disabled by config");
    }

    if (cfg.para_en_inc) {
        check_bits_s(mi.inc, cfg.para_bits_inc, "inc");
    } else {
        if (mi.inc != 0) throw std::runtime_error("inc disabled by config");
    }

    check_bits_u(mi.code, cfg.para_bits_code, "code");
}

inline std::string micro_inst_to_string(const SmiIqConfig& cfg, const MicroInstruction& mi) {
    std::ostringstream oss;
    oss << "MicroInstruction{";
    oss << "vld=" << (mi.vld ? 1 : 0);
    oss << ", jump=" << (mi.jump ? 1 : 0);
    oss << ", embed=" << static_cast<uint32_t>(mi.embed);
    oss << ", loops=" << static_cast<uint32_t>(mi.loops);
    oss << ", cond=" << static_cast<uint32_t>(mi.cond);
    oss << ", dly=" << static_cast<uint32_t>(mi.dly);
    oss << ", inc=" << static_cast<int32_t>(mi.inc);
    oss << ", code=0x" << std::hex << mi.code << std::dec;
    oss << ", cfg_bits(code=" << static_cast<uint32_t>(cfg.para_bits_code) << ")";
    oss << "}";
    return oss.str();
}

} // namespace hal
} // namespace aiacc
