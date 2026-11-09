#include "shiftdown_iq.h"
#include <cstring>

namespace aiacc {
namespace iq {

/**
 * @brief 打包 SHIFTDN 微指令 (134-bit)
 * 严格按照文档表格顺序排列位域 (从低位到高位):
 * 1. vld    : Bit [0]
 * 2. data   : Bit [128:1]
 * 3. smc_id : Bit [133:129]
 */
void ShiftDownIq::pack_crd_shiftdown(const ShiftDownCru& para_cru, uint32_t out_words[5]) {
    // 初始化输出数组
    std::memset(out_words, 0, 5 * sizeof(uint32_t));
    
    // --- 1. vld [Bit 0] ---
    if (para_cru.para_vld) {
        out_words[0] |= 0x1u;
    }
    
    // --- 2. data [Bit 128:1] ---
    // data 是 128 bit (16 bytes)，从第 1 位开始填充
    for (int i = 0; i < 16; ++i) {
        uint32_t byte_val = para_cru.para_data[i];
        int bit_start = 1 + i * 8; // 偏移量从 1 开始
        int word_idx = bit_start / 32;
        int bit_in_word = bit_start % 32;
        
        out_words[word_idx] |= (byte_val << bit_in_word);
        
        // 处理跨 32-bit 边界的情况
        if (bit_in_word > 24 && (word_idx + 1) < 5) {
            out_words[word_idx + 1] |= (byte_val >> (32 - bit_in_word));
        }
    }
    
    // --- 3. smc_id [Bit 133:129] ---
    // 129 / 32 = 4 (第 5 个 word), 129 % 32 = 1
    uint32_t id_val = (para_cru.para_smc_id & 0x1Fu);
    out_words[4] |= (id_val << 1); 
}

MicroInstruction ShiftDownIq::make_micro_inst(const ShiftDownCru& para_cru) {
    MicroInstruction inst{};
    inst.vld = para_cru.para_vld;
    inst.code = (para_cru.para_smc_id & 0x1Fu); 
    return inst;
}

} // namespace iq
} // namespace aiacc
