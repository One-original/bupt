#ifndef HEX_CONVERTER_H
#define HEX_CONVERTER_H

#include <vector>
#include <string>
#include <fstream>
#include <iomanip>
#include <algorithm>
#include <sstream>

namespace aiacc {
namespace tools {

class HexConverter {
public:
    static bool write_instruction_hex(const std::string& path, 
                                      const std::vector<uint8_t>& data, 
                                      size_t width_bytes,
                                      size_t width_bits = 0) {
        std::ofstream file(path);
        if (!file.is_open()) return false;
        
        file << std::hex << std::setfill('0');
        
        // Ensure width is valid
        if (width_bytes == 0) width_bytes = 1;

        // Process in chunks of width_bytes; each chunk is written as a single
        // big-endian integer with exactly width_bytes bytes, matching the
        // logical instruction width (ceil(width_bits/8)).
        for (size_t i = 0; i < data.size(); i += width_bytes) {
            for (size_t j = 0; j < width_bytes; ++j) {
                if (i + j < data.size()) {
                    file << std::setw(2) << static_cast<int>(data[i + j]);
                }
            }
            file << "\n";
        }
        return true;
    }

    static bool write_memory_hex(const std::string& path, 
                                 const std::vector<uint8_t>& data, 
                                 size_t width_bytes = 16) {
        std::ofstream file(path);
        if (!file.is_open()) return false;
        
        file << std::hex << std::setfill('0');
        
        // Memory data (e.g. floats) is usually Little Endian in the binary stream.
        // F0 (4 bytes), F1 (4 bytes), F2, F3.
        // Simulator expects a single large integer where F0 is LSB.
        // Hex string prints MSB first.
        // So we need to print [F3, F2, F1, F0].
        // We need to reverse the chunk of 16 bytes.
        
        for (size_t i = 0; i < data.size(); i += width_bytes) {
            // Collect chunk
            std::vector<uint8_t> chunk;
            for (size_t j = 0; j < width_bytes; ++j) {
                if (i + j < data.size()) {
                    chunk.push_back(data[i + j]);
                } else {
                    chunk.push_back(0); // Padding
                }
            }
            
            // Reverse for Hex printing (Little Endian stream -> Big Endian Hex String)
            std::reverse(chunk.begin(), chunk.end());
            
            for (uint8_t byte : chunk) {
                file << std::setw(2) << static_cast<int>(byte);
            }
            file << "\n";
        }
        return true;
    }
    
    // Split global RtoVR instruction (240-bit payload) into per-port instructions (7-bit payload)
    // Returns a map of port_id -> list of hex strings (one per instruction)
    static bool split_rtovr_instructions(const std::vector<uint8_t>& data,
                                         size_t header_bits,
                                         size_t payload_bits, 
                                         std::vector<std::vector<std::string>>& port_hex_lines) {
        
        size_t total_bits = header_bits + payload_bits;
        size_t total_bytes = (total_bits + 7) / 8;
        
        if (data.size() % total_bytes != 0) return false;
        
        port_hex_lines.resize(40); // 40 ports
        
        size_t num_insts = data.size() / total_bytes;
        
        for (size_t k = 0; k < num_insts; ++k) {
            const uint8_t* inst_ptr = &data[k * total_bytes];
            const uint8_t* code_bytes = inst_ptr + 6;  // Payload (payload_bits/8) 字节，大端（按 word 大端写出）
            
            // Extract Header (assuming bits [total-1 : payload_bits])
            // In C++ bitstream (Big Endian Bytes):
            // Byte 0 (MSB).. contain Header.
            // Payload is at the end (LSB).
            
            // We need to parse the whole instruction as a large integer to do bit extraction accurately
            // because bit boundaries might not align with bytes.
            
            // Convert instruction bytes to a customized BigInt (vector<uint8_t>) or simple extraction?
            // Since we just need to reconstruct Header + NewPayload, and Header is MSB.
            // Inst: [Header][Payload]
            // We can treat Header and Payload as separate byte blocks if aligned?
            // 41 bits header, 240 bits payload = 281 bits.
            // 281 % 8 != 0. 36 bytes = 288 bits. Alignment padding?
            // "add_op" uses vector<uint8_t>.
            // serialize_header -> 6 bytes (48 bits). Last few bits are 0.
            // serialize_code -> 30 bytes (240 bits).
            // make_instruction joins them.
            // So Header is 6 bytes. Payload is 30 bytes.
            // Total 36 bytes.
            // Inst in memory: [Header Bytes][Code Bytes]
            // BUT, `make_instruction` builds `bits` for header (64bit uint).
            // It packs LSB of header to LSB of `bits`.
            // Then it writes bytes Big Endian.
            // So Header Byte 0 has VLD (MSB).
            
            // Important: `add_op` packs Header, then Appends Code.
            // `header.insert(end, code.begin, code.end)`
            // So in file: H0 H1 H2 H3 H4 H5 C0 C1 ... C29.
            // H0 is MSB of Header.
            // C0 is MSB of Code.
            
            // Code Packing in `add_op` (serialize_code) was changed to Big Endian.
            // So C0 is MSB of 240-bit code.
            // C29 is LSB of 240-bit code.
            
            // RtoVR mapping: Port 0 is usually LSB of the 240-bit integer.
            // LSB of 240-bit integer is in C29 (last byte).
            
            // Port 0 (6 bits): From C29 (bits 0-5).
            // Port 1 (6 bits): From mixed C29/C28...
            
            // 从 payload 中取单个 bit（bit_idx = C++ pack 的全局位 0..279）
            // serialize_rtovr_code 按 32-bit word 大端写出：code_bytes[0..3]=word0(31:24,23:16,15:8,7:0)，故
            // 全局位 g 落在 word g/32，bit_in_word=g%32，对应 byte_idx = (g/32)*4 + (3 - g/8%4)，bit_in_byte = g%8
            auto get_payload_bit = [&](int bit_idx) -> uint8_t {
                if (bit_idx < 0 || bit_idx >= static_cast<int>(payload_bits)) {
                    return 0;
                }
                int word_idx    = bit_idx / 32;
                int bit_in_word = bit_idx % 32;
                int byte_idx    = word_idx * 4 + (3 - bit_in_word / 8);
                // For 280-bit payload we serialize word[0..7] (32 bytes) + word[8] bytes j=2..0 (3 bytes),
                // i.e. we omit word[8] byte j=3 (padding bits 287:280). Adjust index for word_idx==8.
                if (word_idx == 8) byte_idx -= 1;
                int bit_in_byte = bit_in_word % 8;
                int payload_bytes = static_cast<int>((payload_bits + 7) / 8);
                if (byte_idx >= payload_bytes) return 0;
                uint8_t byte = code_bytes[byte_idx];
                return (byte >> bit_in_byte) & 0x1u;
            };
            
            // Process Header: Just copy the hex string of the first 6 bytes?
            // But Simulator expects a single integer. The new instruction will have e.g. 48 bits (41+7).
            // Original header was 41 bits valid in 48 bits container.
            // We need to keep the 41 bits aligned to MSB of the new container?
            // Simulator: `vld = (inst >> (total - 1))`.
            // If total=48. VLD is Bit 47.
            // Our Header Bytes H0..H5. H0's MSB is VLD.
            // So if we just take H0..H5 and treat it as the upper part of the new instruction, it should work.
            // Current H0-H5 represents 48 bits. VLD is at Bit 40 (0-based) relative to 48 bits?
            // No, `add_op` puts VLD at Bit 40 of the header `bits` variable.
            // And writes 6 bytes (48 bits).
            // So VLD is at Bit 40.
            // Wait, 48 bits total. Bits 41-47 are 0?
            // In `serialize_header`: `bits |= vld << pos`. pos was incremented. Max pos around 40.
            // `bytes` written from `bits`: `bits >> 40`.
            // Byte 0 corresponds to bits 47..40 of `bits` variable.
            // Wait, my `serialize_header` loop: `for (i=5; i>=0)`.
            // H0 = bits[47:40].
            // If vld is at pos 40. Then H0's LSB is vld?
            // Let's re-verify `add_op.cpp`.
            
            /*
            bits |= vld << 40;
            ...
            for (i=5; i>=0) bytes.push_back((bits >> i*8) & FF);
            i=5 -> bits[47:40].
            Since vld is at 40. bits[47:41] are 0. bits[40] is vld.
            So H0 = 00000001 (if vld=1).
            */
            
            // So VLD is H0's LSB (Bit 0).
            // In a 48-bit integer (H0..H5), this bit is Bit 40.
            
            // New Instruction for Simulator: 41 bits Header + 7 bits Payload = 48 bits.
            // Simulator expects VLD at `total_bits - 1` = 47.
            // Mismatch!
            // Simulator `total_bits` calculation: 41 + CodeBits.
            // If we feed 7 bits code. Total = 48.
            // Simulator checks Bit 47.
            // But our Header (from add_op) puts VLD at Bit 40.
            
            // So we must shifting the Header to align VLD to Bit 47.
            // Shift left by 7 bits?
            // Or just reconstruct user header bits?
            
            // To be safe, let's extract raw header fields fields and repack? Too complex.
            // Easier: bits[40] is VLD. We want it at bits[47].
            // Actually, we can just take the 41-bit header integer and shift it.
            // `header_int` (from H0..H5) has value `header_bits`.
            // `new_inst = (header_int << 7) | new_payload`.
            // `header_int`'s VLD is at bit 40.
            // `header_int << 7` puts VLD at bit 47.
            // This matches Simulator expectation for 48-bit instruction!
            
            // Extract Header Int
            uint64_t header_int = 0;
            for (int b = 0; b < 6; ++b) {
                header_int = (header_int << 8) | *(inst_ptr + b);
            }
            // `header_int` currently has some garbage high bits if we considered it 48 bits but `add_op` only filled up to 41.
            // Actually `add_op` fills `bits` (64bit) up to ~41 bits. High bits are 0.
            // So `header_int` is clean.
            // BUT wait. `add_op` produced 6 bytes.
            // H0 contains bits 47..40.
            // If `vld` at 40. H0 = 0x01.
            // `header_int` will be 0x01......
            // VLD is indeed at bit 40 of this integer.
            
            for (int p = 0; p < 40; ++p) {
                // 按 C++ pack_cru_rtovr_words 规则反取 7-bit：端口 p 对应 msb=payload_bits-1-7*p, lsb=msb-6
                int msb = static_cast<int>(payload_bits) - 1 - 7 * p;
                int lsb = msb - 6;

                uint8_t cw = 0;
                for (int b = 0; b < 7; ++b) {
                    int bit_idx = lsb + b;    // 0..279
                    if (get_payload_bit(bit_idx)) {
                        cw |= static_cast<uint8_t>(1u << b);
                    }
                }

                uint8_t vld = cw & 0x1u;
                uint8_t src = (cw >> 1) & 0x3Fu;

                // 仿真器用 CODE：LSB=vld，其上 6bit=src
                uint8_t payload_code = static_cast<uint8_t>((src << 1) | vld);

                // 组合 48-bit 指令：Header(高 header_bits) | CODE(低 7bit)
                uint64_t header_mask = (header_bits >= 64)
                    ? ~0ULL
                    : ((1ULL << header_bits) - 1ULL);
                uint64_t new_inst = ((header_int & header_mask) << 7) | payload_code;

                std::stringstream ss;
                ss << std::hex << std::setfill('0') << std::setw(12) << new_inst; // 48 bits = 12 hex chars
                port_hex_lines[p].push_back(ss.str());
            }
        }
        return true;
    }
};

} // namespace tools
} // namespace aiacc

#endif
