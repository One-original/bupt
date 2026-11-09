/**
 * @file add_op.cpp
 * @brief Add 算子核心实现
 * 功能：out = input + alpha * other
 */
 #include "add_op.h"
 #include <iostream>
 #include <iomanip>
 #include <cstring>
 #include <algorithm>
 #include <stdexcept>
 #include <type_traits>
 #include <map>
#include <set>
 #include "../../iq/iq_id_defs.h"
 #include "../../app/fp16_utils.h"
 #include "ur_code_extractor.h"
 
 #include "add_op_constants.h"
 #include "add_op_bank_conflict.h"
 #include "add_op_ur_inst.h"
 #include "add_op_rtovr_inst.h"
 #include "add_op_compute_inst.h"
 
 namespace aiacc {
 namespace op {
 
 /**
  * @brief Internal constants/helpers for instruction packing.
  *
  * Centralizing these values makes the bit/delay logic easier to audit.
  */
 namespace {
constexpr uint8_t kMaxDlyField = 7;  ///< 3-bit DLY field max value
constexpr uint32_t kRtovrPorts = 40;
constexpr uint32_t kRtovrBitsPerPort = 7;
constexpr uint32_t kRtovrTotalBits = kRtovrPorts * kRtovrBitsPerPort;  // 280
constexpr uint32_t kRtovrMsbBitIndex = kRtovrTotalBits - 1;            // 279
constexpr uint32_t kSmiRtovrIqBase = 28;  // smi_top maps RtoVR output k to IQ ID 28+k.

inline uint32_t rtovr_writeback_cycle(uint32_t uwr_route_start_cycle) {
    return uwr_route_start_cycle + 1;
}

struct AddSteadyStateSchedule {
    // 流水线排空深度：上游/中间 IQ 需要多运行 kPipelineDrain 拍，
    // 让最后的 in-flight beats 通过 RtoVR 寄存器边界传播到 UR-W。
    // 经验值 = 仿真对比中不匹配的拍数（UR-R → RtoVR×3 + FPMUL + FPADD 的尾部排空）。
    static constexpr uint32_t kPipelineDrain = 9;

    AddSteadyStateSchedule() {
        // --- 硬件延迟参数 (按用户反馈配置) ---
        const uint32_t kFpmulLat = 4;
        const uint32_t kFpaddLat = 4;
        const uint32_t kRtovrLat = 1;

        // --- Stage 1: FPMUL 输入 (alpha, other) ---
        ur_r1 = 0; // alpha
        ur_r2 = 0; // other
        rtovr_fpmul_s0 = 0;
        rtovr_fpmul_s1 = 0;

        // FPMUL launch is aligned by the steady-state timing model.
        fpmul = rtovr_fpmul_s0 + kRtovrLat;

        // --- Stage 2: FPADD 输入 (input, fpmul_d) ---
        // fpmul_d 在 fpmul + kFpmulLat 时刻产出
        uint32_t fpmul_d_ready = fpmul + kFpmulLat;
        
        // 为了对齐 fpmul_d，ur_r0 (input) 也选择在此时刻读取
        ur_r0 = fpmul_d_ready;
        rtovr_fpadd_s0 = fpmul_d_ready;
        rtovr_fpadd_s1 = fpmul_d_ready;

        // FPADD 采样时刻：
        // 总结中提到 FPADD 首拍采样需要额外 1 拍缓冲，即 latch + 2
        fpadd = rtovr_fpadd_s0 + kRtovrLat + 1;

        // --- Stage 3: UVR 写回 (fpadd_d) ---
        // fpadd_d 在 fpadd + kFpaddLat 时刻产出
        uint32_t fpadd_d_ready = fpadd + kFpaddLat;
        
        rtovr_uwr0 = fpadd_d_ready;
        
        // ur_w0 write enable must lag the UVR route long enough for UVR_WDATA_0 to settle.
        // Waveform shows UR-W can otherwise fire while UVR_WDATA_0 is still zero.
        ur_w0 = rtovr_writeback_cycle(rtovr_uwr0);
    }

    uint32_t ur_r1;
    uint32_t ur_r2;
    uint32_t rtovr_fpmul_s0;
    uint32_t rtovr_fpmul_s1;
    uint32_t fpmul;
    uint32_t ur_r0;
    uint32_t rtovr_fpadd_s0;
    uint32_t rtovr_fpadd_s1;
    uint32_t fpadd;
    uint32_t rtovr_uwr0;
    uint32_t ur_w0;
};

template <typename EmitDummyFn>
uint8_t emit_dummy_for_long_delay(uint32_t& total_dly, EmitDummyFn&& emit_dummy) {
     while (total_dly > kMaxDlyField) {
         emit_dummy();
         total_dly -= 8;  // delay(7) + execute(1)
     }
     return static_cast<uint8_t>(total_dly);
 }

 template <typename EmitLongDummyFn, typename EmitPreciseDummyFn>
 void consume_startup_delay(uint32_t& total_dly,
                            EmitLongDummyFn&& emit_long_dummy,
                            EmitPreciseDummyFn&& emit_precise_dummy) {
     emit_dummy_for_long_delay(total_dly, std::forward<EmitLongDummyFn>(emit_long_dummy));
     if (total_dly > 0) {
         emit_precise_dummy(static_cast<uint8_t>(total_dly - 1));
         total_dly = 0;
     }
 }
 
 /**
  * @brief Compute minimum DLY >= base_dly such that first-fire cycle
  *        satisfies (total_dly % num_slots == target_slot).
  *
  * In EMBED mode the first-fire cycle equals total_dly (after dummy
  * expansion). For the port to land on the correct time-slot within
  * the EMBED period, total_dly % num_slots must equal the port's slot.
  */
 inline uint32_t align_dly_to_slot(uint32_t base_dly, uint8_t target_slot, uint8_t num_slots) {
    if (num_slots <= 1) return base_dly;
    const uint32_t slot = static_cast<uint32_t>(target_slot % num_slots);
    uint32_t aligned = base_dly;
    while ((aligned % num_slots) != slot) ++aligned;
    return aligned;
}
 
 /**
  * @brief Extract 7-bit RtoVR port code from packed words.
  */
 } // namespace
 
 // ============================================================================
 // 静态辅助函数：指令生成实现
 // ============================================================================
 
 static void gen_ur_insts_impl(const AddOpParams& params, AddOpInstructions& result) {
     if (result.para_num_slots == 1) {
         // 无冲突：单 slot 模式
         iq::UrCru ur_read_cru;
         gen_ur_read_inst(params, 0, ur_read_cru);
         result.para_ur_read_crus.push_back(ur_read_cru);
         
         iq::UrCru ur_write_cru;
         gen_ur_write_inst(params, 0, ur_write_cru);
         result.para_ur_write_crus.push_back(ur_write_cru);
     } else {
         // 有冲突：多 slot 模式
         // EMBED 模式下，每个 UR 端口有自己的 IQ 文件和独立时序。
         // CRU[0] 必须包含所有端口的 RE/WE=1，供 get_iq_files 提取每个端口的 CODE。
         // 时序错开由各 IQ 的 DLY prefix 控制，不在 CRU 层面区分 slot。
         {
             iq::UrCru ur_read_cru;
             gen_ur_read_inst(params, 0, ur_read_cru);  // 统一 CRU，所有端口 RE=1
             result.para_ur_read_crus.push_back(ur_read_cru);
             
             iq::UrCru ur_write_cru;
             gen_ur_write_inst(params, 0, ur_write_cru);  // 统一 CRU，WE=1
             result.para_ur_write_crus.push_back(ur_write_cru);
         }
     }
 }
 
 static void gen_float_compute_impl(const AddOpParams& params, AddOpInstructions& result) {
     // Stage1: alpha, other → FPMUL
     {
         iq::RtoVrCru rtovr_cru;
         gen_rtovr_to_fpmul(rtovr_cru);
         uint32_t rtovr_words[10];
         iq::RtoVrIq::pack_cru_rtovr_words(rtovr_cru, rtovr_words);
         result.para_rtovr_stage1.assign(rtovr_words, rtovr_words + 9);
     }
     
     // Stage2: input, fpmul_d → FPADD
     {
         iq::RtoVrCru rtovr_cru;
         gen_rtovr_to_fpadd(rtovr_cru);
         uint32_t rtovr_words[10];
         iq::RtoVrIq::pack_cru_rtovr_words(rtovr_cru, rtovr_words);
         result.para_rtovr_stage2.assign(rtovr_words, rtovr_words + 9);
     }
     
     // Stage3: fpadd_d → UVR_WDATA
     {
         iq::RtoVrCru rtovr_cru;
         gen_rtovr_fpadd_to_ur(rtovr_cru);
         uint32_t rtovr_words[10];
         iq::RtoVrIq::pack_cru_rtovr_words(rtovr_cru, rtovr_words);
         result.para_rtovr_stage3.assign(rtovr_words, rtovr_words + 9);
     }
     
     // 生成 FPMUL 和 FPADD 指令
     {
         iq::FpMulCru fpmul_cru;
         gen_fpmul_inst(params, fpmul_cru);
         result.para_fpmul_inst = iq::FpMulIq::pack_cru_fpmul(fpmul_cru);
     }
     {
         iq::FpAddCru fpadd_cru;
         gen_fpadd_inst(params, fpadd_cru);
         result.para_fpadd_inst = iq::FpAddIq::pack_cru_fpadd(fpadd_cru);
     }
 }
 
 AddOpInstructions AddOp::compile(const AddOpParams& para_params) {
     AddOpInstructions result;
     result.para_dtype = para_params.para_dtype;
     
     // ========================================================================
     // 1. 解决 Bank 冲突，分配时间槽（slot）
     // ========================================================================
     // 临时屏蔽 bank conflict 调度，只按单 slot 非冲突路径处理
    // result.para_num_slots = aiacc::op::compute_slot_allocation(
    //     para_params, result.para_slot_accesses, result.para_port_slots);
    result.para_num_slots = 1;
    result.para_slot_accesses.clear();
    result.para_slot_accesses.resize(1);
    result.para_slot_accesses[0].input_slot = 0;
    result.para_slot_accesses[0].other_slot = 0;
    result.para_slot_accesses[0].alpha_slot = 0;
    result.para_slot_accesses[0].output_slot = 0;
    result.para_slot_accesses[0].has_compute = true;
    for (int i = 0; i < 4; ++i) result.para_port_slots[i] = 0;

     // 保存 bank 信息供 get_iq_files 使用
     result.para_input_bank  = para_params.para_input_bank;
     result.para_other_bank  = para_params.para_other_bank;
     result.para_alpha_bank  = para_params.para_alpha_bank;
     result.para_output_bank = para_params.para_output_bank;
     
    /*
    // DEBUG PRINTS
    std::cout << "[DEBUG] num_slots: " << (int)result.para_num_slots << std::endl;
    for (int i = 0; i < 3; ++i) {
        std::cout << "[DEBUG] port[" << i << "] slot: " << (int)result.para_port_slots[i] << std::endl;
    }
    */

    // 已临时关闭 Bank conflict 路径，只验证非冲突单 slot 行为。
     
     // 2. 计算循环参数
     const uint32_t total_elems = para_params.get_total_elements();
     const uint32_t elems_per_word = para_params.get_elems_per_word();
     const uint32_t total_steps = para_params.get_word_count();
     
     result.para_total_steps = total_steps;
     result.para_total_elements = total_elems;
     
     // 嵌套循环：外层 = N*C*H，内层 = W
     const uint32_t w_steps = (para_params.para_w + elems_per_word - 1) / elems_per_word;
     const uint32_t outer_loops = para_params.para_n * para_params.para_c * para_params.para_h;
     result.para_embed_loops = outer_loops;
     result.para_inner_loops = w_steps;
     
     // 3. 生成 UR 读写指令
     gen_ur_insts_impl(para_params, result);
     
     // 4. 生成浮点计算指令
     gen_float_compute_impl(para_params, result);
     
     return result;
 }
 
 // ============================================================================
 // IQ 文件序列化：将微指令打包成二进制文件
 // ============================================================================
 // gen_fpadd_inst / gen_intadd_inst 在 add_op_compute_inst.cpp 中实现（自由函数）
 
 // ==========================================
 // 辅助函数实现
 // ==========================================
 
 // 辅助函数：从 RtoVR CRU 提取实际使用的端口列表
 static std::vector<uint8_t> extract_active_rtovr_ports(const std::vector<uint32_t>& rtovr_words) {
     std::vector<uint8_t> active_ports;
     if (rtovr_words.empty()) return active_ports;
     
     // RtoVR CRU 格式：40个端口，每个端口 7 bits (1 valid + 6 select)
     // 280 bits total，存储在 rtovr_words[0..8] 中
     // 注意：pack_cru_rtovr_words 使用逆序压入 (Group 0 在 Bit 279:273)
     // 所以 port k 的 LSB 位于 bit (279 - 7*k - 6) = (273 - 7*k)
     for (uint8_t port = 0; port < kRtovrPorts; ++port) {
         // 计算 port 的 LSB 位置（valid 位）
         int msb = static_cast<int>(kRtovrMsbBitIndex) - static_cast<int>(kRtovrBitsPerPort) * port;
         int lsb = msb - 6;  // valid 位在 LSB
         
         int word_idx = lsb / 32;
         int bit_in_word = lsb % 32;
         
         if (word_idx >= (int)rtovr_words.size()) break;
         
         // 提取 valid 位（每个端口的第一位，在 LSB）
         bool valid = (rtovr_words[word_idx] >> bit_in_word) & 0x1;
         if (valid) {
             active_ports.push_back(port);
         }
     }
     
     return active_ports;
 }
 
 std::vector<IqInstructionFile> AddOpInstructions::get_iq_files() const {
     // ========================================================================
     // 3. 根据 slot 分配方案生成 IQ 指令文件
     // ========================================================================
     // 关键点：
     //   1. 根据 para_slot_accesses 判断每个 slot 是否需要生成指令
     //      - 例如：如果 slot 0 分配了读 input，就生成 slot 0 的读指令
     //      - 如果 slot 1 没有分配读 input，就不生成 slot 1 的读指令
     // 
     //   2. 设置延迟（DLY）实现时间分片
     //      - DLY = slot_id：让不同 slot 的指令在不同时间执行
     //      - 例如：slot 0 的 DLY=0，slot 1 的 DLY=1，slot 2 的 DLY=2
     //      - 这样硬件会按顺序执行，避免同时访问同一 bank
     // 
     //   3. 计算指令的延迟要匹配计算 slot
     //      - 计算在最后一个 slot 执行，所以计算指令的 DLY = compute_slot + 延迟
     // ========================================================================
     std::vector<IqInstructionFile> files;
     
     // 辅助函数：序列化微指令头部（41 bits）
     constexpr uint32_t BITS_EMBED = 3, BITS_EMBED_END = 6, BITS_LOOPS = 10;
     constexpr uint32_t BITS_COND = 7, BITS_DLY = 3, BITS_INC = 4, BITS_INC_EMBED = 6;
     constexpr uint32_t MASK_EMBED = (1u << BITS_EMBED) - 1;
     constexpr uint32_t MASK_EMBED_END = (1u << BITS_EMBED_END) - 1;
     constexpr uint32_t MASK_LOOPS = (1u << BITS_LOOPS) - 1;
     constexpr uint32_t MASK_COND = (1u << BITS_COND) - 1;
     constexpr uint32_t MASK_DLY = (1u << BITS_DLY) - 1;
     constexpr uint32_t MASK_INC = (1u << BITS_INC) - 1;
     constexpr uint32_t MASK_INC_EMBED = (1u << BITS_INC_EMBED) - 1;
     constexpr uint8_t kNoEmbed = MASK_EMBED;  // 3'b111 bypasses smi_iq_iic EMBED mode.
 
     auto serialize_header_bits = [](uint8_t vld, uint8_t jump, uint8_t embed, uint16_t loops,
                                     uint8_t cond, uint8_t dly, uint8_t inc,
                                     uint8_t embed_end_bits, uint8_t inc_embed_bits) -> uint64_t {
         uint64_t bits = 0;
         uint32_t pos = 0;
 
         uint8_t embed_end = (embed == 0) ? (embed_end_bits & MASK_EMBED_END) : 0u;
        uint8_t inc_embed = (embed == 0) ? (inc_embed_bits & MASK_INC_EMBED) : 0u;
 
         // Pack bits starting from LSB
         bits |= (uint64_t)(inc_embed & MASK_INC_EMBED) << pos; pos += BITS_INC_EMBED;
         bits |= (uint64_t)(inc & MASK_INC) << pos; pos += BITS_INC;
         bits |= (uint64_t)(dly & MASK_DLY) << pos; pos += BITS_DLY;
         bits |= (uint64_t)(cond & MASK_COND) << pos; pos += BITS_COND;
         bits |= (uint64_t)(loops & MASK_LOOPS) << pos; pos += BITS_LOOPS;
         bits |= (uint64_t)(embed_end & MASK_EMBED_END) << pos; pos += BITS_EMBED_END;
         bits |= (uint64_t)(embed & MASK_EMBED) << pos; pos += BITS_EMBED;
         bits |= (uint64_t)(jump & 1u) << pos; pos += 1;
         bits |= (uint64_t)(vld & 1u) << pos; pos += 1;
         
         return bits;
     };
 
     // Adjusted Code Serialization: Pack MSB Byte First
     auto serialize_code = [](uint64_t code, uint16_t code_bits) -> std::vector<uint8_t> {
         std::vector<uint8_t> bytes;
         uint16_t num_bytes = (code_bits + 7) / 8;
         for (int i = num_bytes - 1; i >= 0; --i) { // Start from MSB Byte
             bytes.push_back((code >> (i * 8)) & 0xFF);
         }
         return bytes;
     };
     
     // make_instruction with Bit Packing support
    // Ensures that Header (41 bits) and Code (variable width) are correctly aligned.
    // Total bits = 41 + code_bits. Final bytes are Big-Endian (MSB byte first).
    auto make_instruction = [&](uint8_t vld, uint8_t jump, uint8_t embed, uint16_t loops, 
                                uint8_t cond, uint8_t dly, int8_t inc,
                                uint8_t embed_end_bits, uint8_t inc_embed_bits,
                                const std::vector<uint8_t>& code_bytes,
                                int code_bits) -> std::vector<uint8_t> {
        
        uint64_t h = serialize_header_bits(vld, jump, embed, loops, cond, dly, inc, embed_end_bits, inc_embed_bits);
        
        int total_width = 41 + code_bits;
        int num_bytes = (total_width + 7) / 8;
        std::vector<uint8_t> ret(num_bytes, 0);

        // Pack CODE (lower bits)
        // code_bytes are Big-Endian (MSB byte first).
        uint32_t current_bit = 0;
        for (int i = (int)code_bytes.size() - 1; i >= 0 && current_bit < (uint32_t)code_bits; --i) {
            uint8_t byte = code_bytes[i];
            for (int b = 0; b < 8 && current_bit < (uint32_t)code_bits; ++b) {
                if ((byte >> b) & 1) {
                    int byte_idx = num_bytes - 1 - (current_bit / 8);
                    ret[byte_idx] |= (1 << (current_bit % 8));
                }
                current_bit++;
            }
        }

        // Pack HEADER (starting from code_bits)
        for (int i = 0; i < 41; ++i) {
            if ((h >> i) & 1) {
                int bit_pos = code_bits + i;
                int byte_idx = num_bytes - 1 - (bit_pos / 8);
                ret[byte_idx] |= (1 << (bit_pos % 8));
            }
        }

        return ret;
    };
     
     // 不使用 embed，不做 slot 推导，直接固定关键拍点。
     const AddSteadyStateSchedule schedule{};
     const bool use_bc_embed = false;
     const bool use_nested = false;
     const uint16_t loops_inner = (para_total_steps >= 1) ? (para_total_steps - 1) : 0;
     // 上游/中间 IQ 多运行 kPipelineDrain 拍，让 pipeline 排空到 UR-W。
     // UR-W0 仍使用 loops_inner，只写 para_total_steps 个有效结果。
     const uint16_t loops_drain = loops_inner + AddSteadyStateSchedule::kPipelineDrain;
     const uint8_t inc_inner = 1u;
     
     // 生成 UR 读端口 0: input
    {
        constexpr uint16_t kUrReadCodeBits = 17;
        IqInstructionFile file;
        file.para_iq_id = 16;
        file.para_iq_name = "ur-r0";
        file.para_width_bits = 41 + kUrReadCodeBits;
 
         uint32_t code = aiacc::op::extract_ur_read_port0_code(para_ur_read_crus[0]);
         auto code_bytes = serialize_code(code, kUrReadCodeBits);
         auto zero_code = serialize_code(0, kUrReadCodeBits);  // RE=0 NOP code

         // ur-r0 (input) 供 FPADD_S0，由 steady-state timing model 统一推导。
         uint32_t total_dly = schedule.ur_r0;

         // spec: NOP(vld=0) 不支持 DLY，用 LOOPS 消耗等待周期；每条 NOP 消耗 8 周期（DLY=7+执行1）
         const uint8_t dly = emit_dummy_for_long_delay(total_dly, [&]() {
             // vld=0: NOP 指令，DLY=0，LOOPS=7（执行8次，消耗8个周期）
             auto nop = make_instruction(0, 0, kNoEmbed, 7, 0, 0, 0, 0, 0, zero_code, kUrReadCodeBits);
             file.para_data.insert(file.para_data.end(), nop.begin(), nop.end());
         });
 
        auto inst = make_instruction(1, 0, 0, loops_drain, 0, dly, inc_inner, 0u, 0u, code_bytes, kUrReadCodeBits);
         file.para_data.insert(file.para_data.end(), inst.begin(), inst.end());
 
         // spec: JUMP=1 时 CODE[41:40]=2'b11 表示队列最后一个可执行指令（结束标志）
         // CODE 需要至少 43bit：[42]=符号位, [41:40]=条件, [39:8]=期望数据, [7:0]=偏移
         // 使用 IQ 自身的 code_bits 宽度截断存储，高位对齐 2'b11 到 [41:40]
         auto end_code = serialize_code(0, kUrReadCodeBits);
         auto end_inst = make_instruction(0, 1, kNoEmbed, 0, 0, 0, 0, 0u, 0u, end_code, kUrReadCodeBits);
         file.para_data.insert(file.para_data.end(), end_inst.begin(), end_inst.end());
         files.push_back(file);
     }
     
     // 生成 UR 读端口 1: other
     {
        constexpr uint16_t kUrReadCodeBits = 17;
         IqInstructionFile file;
         file.para_iq_id = 17;
         file.para_iq_name = "ur-r1";
         file.para_width_bits = 41 + kUrReadCodeBits;
 
         uint32_t code = aiacc::op::extract_ur_read_port1_code(para_ur_read_crus[0]);
         auto code_bytes = serialize_code(code, kUrReadCodeBits);
         auto zero_code = serialize_code(0, kUrReadCodeBits);
 
         // ur-r1 (alpha broadcast) 先读，由 steady-state timing model 统一推导。
         uint32_t total_dly = schedule.ur_r1;
         // spec: NOP(vld=0) 不支持 DLY，用 LOOPS 消耗等待周期
         const uint8_t dly = emit_dummy_for_long_delay(total_dly, [&]() {
             auto nop = make_instruction(0, 0, kNoEmbed, 7, 0, 0, 0, 0, 0, zero_code, kUrReadCodeBits);
             file.para_data.insert(file.para_data.end(), nop.begin(), nop.end());
         });
 
         auto inst = make_instruction(1, 0, kNoEmbed, loops_drain, 0, dly, 0, 0u, 0u, code_bytes, kUrReadCodeBits);
         file.para_data.insert(file.para_data.end(), inst.begin(), inst.end());
 
         // spec: JUMP CODE[41:40]=2'b11 表示队列结束，high bits 对齐到 [41:40]
         auto end_code = serialize_code(0, kUrReadCodeBits);
         auto end_inst = make_instruction(0, 1, kNoEmbed, 0, 0, 0, 0, 0u, 0u, end_code, kUrReadCodeBits);
         file.para_data.insert(file.para_data.end(), end_inst.begin(), end_inst.end());
         files.push_back(file);
     }
     
     // 生成 UR 读端口 2: alpha (广播，INC=0)
     {
        constexpr uint16_t kUrReadCodeBits = 17;
         IqInstructionFile file;
         file.para_iq_id = 18;
         file.para_iq_name = "ur-r2";
         file.para_width_bits = 41 + kUrReadCodeBits;
 
         uint32_t code = aiacc::op::extract_ur_read_port2_code(para_ur_read_crus[0]);
         auto code_bytes = serialize_code(code, kUrReadCodeBits);
         auto zero_code = serialize_code(0, kUrReadCodeBits);
 
         // ur-r2 (other) 先读，由 steady-state timing model 统一推导。
         uint32_t total_dly = schedule.ur_r2;
         // spec: NOP(vld=0) 不支持 DLY，用 LOOPS 消耗等待周期
         const uint8_t dly = emit_dummy_for_long_delay(total_dly, [&]() {
             auto nop = make_instruction(0, 0, kNoEmbed, 7, 0, 0, 0, 0, 0, zero_code, kUrReadCodeBits);
             file.para_data.insert(file.para_data.end(), nop.begin(), nop.end());
         });
 
        auto inst = make_instruction(1, 0, 0, loops_drain, 0, dly, inc_inner, 0u, 0u, code_bytes, kUrReadCodeBits);
         file.para_data.insert(file.para_data.end(), inst.begin(), inst.end());
 
         // spec: JUMP CODE[41:40]=2'b11 表示队列最后一个可执行指令
         auto end_code = serialize_code(0, kUrReadCodeBits);
         auto end_inst = make_instruction(0, 1, kNoEmbed, 0, 0, 0, 0, 0u, 0u, end_code, kUrReadCodeBits);
         file.para_data.insert(file.para_data.end(), end_inst.begin(), end_inst.end());
         files.push_back(file);
     }
        // 生成 RtoVR 路由指令
    auto append_rtovr_inst = [&](uint8_t port, uint8_t select, uint32_t total_dly) {
        IqInstructionFile file;
        file.para_iq_id = kSmiRtovrIqBase + port;
        file.para_iq_name = "rtovr-" + std::to_string(port);
        file.para_width_bits = 41 + 7; // Header 41b + Code 7b (per port)

        const uint8_t port_code = static_cast<uint8_t>(((select & 0x3Fu) << 1) | 1u);
        auto code_bytes = serialize_code(port_code, 7);
        auto zero_code = serialize_code(0, 7);
        const bool zero_dly_main = (port == RTOVR_OUT_UVR_WDATA_0);

        if (zero_dly_main) {
            consume_startup_delay(total_dly,
                                  [&]() {
                                      auto nop = make_instruction(1, 0, kNoEmbed, 0, 0, kMaxDlyField, 0, 0, 0, zero_code, 7);
                                      file.para_data.insert(file.para_data.end(), nop.begin(), nop.end());
                                  },
                                  [&](uint8_t precise_dly) {
                                      auto precise_nop = make_instruction(1, 0, kNoEmbed, 0, 0, precise_dly, 0, 0, 0, zero_code, 7);
                                      file.para_data.insert(file.para_data.end(), precise_nop.begin(), precise_nop.end());
                                  });
            auto inst = make_instruction(1, 0, kNoEmbed, loops_drain, 0, 0, 0, 0u, 0u, code_bytes, 7);
            file.para_data.insert(file.para_data.end(), inst.begin(), inst.end());
        } else {
            const uint8_t dly = emit_dummy_for_long_delay(total_dly, [&]() {
                auto nop = make_instruction(1, 0, kNoEmbed, 0, 0, kMaxDlyField, 0, 0, 0, zero_code, 7);
                file.para_data.insert(file.para_data.end(), nop.begin(), nop.end());
            });
            auto inst = make_instruction(1, 0, kNoEmbed, loops_drain, 0, dly, 0, 0u, 0u, code_bytes, 7);
            file.para_data.insert(file.para_data.end(), inst.begin(), inst.end());
        }
        // spec: JUMP CODE[41:40]=2'b11 表示队列最后一个可执行指令
        auto rtovr_end_code = serialize_code(3ull << 40, 7);
        auto end_inst = make_instruction(0, 1, kNoEmbed, 0, 0, 0, 0, 0u, 0u, rtovr_end_code, 7);
        file.para_data.insert(file.para_data.end(), end_inst.begin(), end_inst.end());
        files.push_back(file);
    };

    append_rtovr_inst(RTOVR_OUT_DVR_FPMUL_S0, RTOVR_IN_UR_RDATA_1, schedule.rtovr_fpmul_s0);
    append_rtovr_inst(RTOVR_OUT_DVR_FPMUL_S1, RTOVR_IN_UR_RDATA_2, schedule.rtovr_fpmul_s1);
    append_rtovr_inst(RTOVR_OUT_DVR_FPADD_S0, RTOVR_IN_UR_RDATA_0, schedule.rtovr_fpadd_s0);
    append_rtovr_inst(RTOVR_OUT_DVR_FPADD_S1, RTOVR_IN_DR_FPMUL_D, schedule.rtovr_fpadd_s1);
    append_rtovr_inst(RTOVR_OUT_UVR_WDATA_0, RTOVR_IN_DR_FPADD_D, schedule.rtovr_uwr0);
     
     // 生成计算单元指令
     {
         // FPMUL：41+3=44 bit，仿真器取低 44 位，故 6 字节/条右对齐（12 个 hex 字符/行）
        {
            IqInstructionFile file;
            file.para_iq_id = 7;
            file.para_iq_name = "fpmul";
            file.para_width_bits = 41 + 8;

            auto code_bytes = serialize_code(para_fpmul_inst, 8);
            auto zero_fpmul_code = serialize_code(0, 8);

            // fpmul 发起拍由 steady-state timing model 统一推导。
            uint32_t total_dly = schedule.fpmul;
            const uint8_t fpmul_dly = emit_dummy_for_long_delay(total_dly, [&]() {
                auto nop = make_instruction(0, 0, kNoEmbed, 7, 0, 0, 0, 0, 0, zero_fpmul_code, 8);
                file.para_data.insert(file.para_data.end(), nop.begin(), nop.end());
            });

            auto inst = make_instruction(1, 0, kNoEmbed, loops_drain, 0, fpmul_dly, 0, 0u, 0u, code_bytes, 8);
            file.para_data.insert(file.para_data.end(), inst.begin(), inst.end());
             // spec: JUMP CODE[41:40]=2'b11 表示队列最后一个可执行指令
             auto fpmul_end_code = serialize_code(0, 8);
             auto end_inst = make_instruction(0, 1, kNoEmbed, 0, 0, 0, 0, 0u, 0u, fpmul_end_code, 8);
             file.para_data.insert(file.para_data.end(), end_inst.begin(), end_inst.end());
             files.push_back(file);
         }
         
         // FPADD：DLY=7 使 cycle 7 执行，整体相对当前调度再晚一拍。
        // 与 smc_simulator 对齐：Code 5b (valid, src_prec, dst_prec, update_st, is_sub)
        {
            IqInstructionFile file;
            file.para_iq_id = 8;
            file.para_iq_name = "fpadd";
            file.para_width_bits = 41 + 10;

            auto code_bytes = serialize_code(para_fpadd_inst, 10);
            auto zero_fpadd_code = serialize_code(0, 10);

            // fpadd 发起拍由 steady-state timing model 统一推导。
            uint32_t total_dly = schedule.fpadd;
            const uint8_t fpadd_dly = emit_dummy_for_long_delay(total_dly, [&]() {
                auto nop = make_instruction(0, 0, kNoEmbed, 7, 0, 0, 0, 0, 0, zero_fpadd_code, 10);
                file.para_data.insert(file.para_data.end(), nop.begin(), nop.end());
            });

            auto inst = make_instruction(1, 0, kNoEmbed, loops_drain, 0, fpadd_dly, 0, 0u, 0u, code_bytes, 10);
            file.para_data.insert(file.para_data.end(), inst.begin(), inst.end());
             // spec: JUMP CODE[41:40]=2'b11 表示队列最后一个可执行指令
             auto fpadd_end_code = serialize_code(0, 10);
             auto end_inst = make_instruction(0, 1, kNoEmbed, 0, 0, 0, 0, 0u, 0u, fpadd_end_code, 10);
             file.para_data.insert(file.para_data.end(), end_inst.begin(), end_inst.end());
             files.push_back(file);
         }
         
     }
     
     // 生成 UR 写端口指令（仿真器取每行低 69 位，VLD=bit68、CODE=bit27-0，故 9 字节/条右对齐）
     {
         IqInstructionFile file;
         file.para_iq_id = 20;
         file.para_iq_name = "ur-w0";
         file.para_width_bits = 41 + 33;
 
         // 仿真器 load_hex 取每行整数的低 69 位，VLD=bit68，CODE=bit27-0。必须 9 字节/条、大端、右对齐。
         auto serialize_ur_wdata_inst = [&](uint8_t vld, uint8_t jump, uint8_t embed, uint16_t loops,
                                            uint8_t cond, uint8_t dly, uint8_t inc,
                                            uint8_t embed_end_bits, uint8_t inc_embed_bits,
                                            uint64_t code_33) -> std::vector<uint8_t> {
             uint64_t header = serialize_header_bits(vld, jump, embed, loops, cond, dly, inc, embed_end_bits, inc_embed_bits);
             unsigned __int128 inst_74 = (static_cast<unsigned __int128>(header) << 33) |
                                         static_cast<unsigned __int128>(code_33 & 0x1FFFFFFFFull);
             std::vector<uint8_t> bytes;
             for (int i = 9; i >= 0; --i)
                 bytes.push_back(static_cast<uint8_t>((inst_74 >> (i * 8)) & 0xFF));
             return bytes;
         };
 
         uint64_t code = aiacc::op::extract_ur_write_port0_code(para_ur_write_crus[0]);
        // UR-W0 写回拍由 steady-state timing model 统一推导。
        uint32_t total_dly = schedule.ur_w0;
         
        // 用 vld=1(we=0) 的哑指令消耗启动延迟，确保 steady-state 主写指令 dly=0。
        // spec: NOP(vld=0) 不支持 DLY 且 IQUnit 忽略其 LOOPS；
        // 必须用 vld=1 指令的 DLY 字段来真正等待。
        consume_startup_delay(total_dly,
                              [&]() {
                                  auto dummy = serialize_ur_wdata_inst(1, 0, kNoEmbed, 0, 0, kMaxDlyField, 0, 0, 0, 0);
                                  file.para_data.insert(file.para_data.end(), dummy.begin(), dummy.end());
                              },
                              [&](uint8_t precise_dly) {
                                  auto precise_dummy = serialize_ur_wdata_inst(1, 0, kNoEmbed, 0, 0, precise_dly, 0, 0, 0, 0);
                                  file.para_data.insert(file.para_data.end(), precise_dummy.begin(), precise_dummy.end());
                              });
         
         auto inst = serialize_ur_wdata_inst(1, 0, 0, loops_inner, 0, 0, inc_inner, 0u, 0u, code);
         file.para_data.insert(file.para_data.end(), inst.begin(), inst.end());
         
         // spec: JUMP CODE[41:40]=2'b11 表示队列最后一个可执行指令
         // JUMP 不支持 LOOPS/DLY，直接紧跟在数据指令后面
         auto end_inst = serialize_ur_wdata_inst(0, 1, kNoEmbed, 0, 0, 0, 0, 0u, 0u, 0);
         file.para_data.insert(file.para_data.end(), end_inst.begin(), end_inst.end());
         files.push_back(file);
     }
     
     return files;
 }
 
 // ============================================================================
 // OpBase 接口实现
 // ============================================================================
 
 std::string AddOp::get_name() const {
     return "FusedScaleAdd";
 }
 
 OpInstructionsBase* AddOp::compile(const app::AppOperatorRequest& req) {
     AddOpParams params;
     params.para_n = req.para_dimensions.para_n;
     params.para_c = req.para_dimensions.para_c;
     params.para_h = req.para_dimensions.para_h;
     params.para_w = req.para_dimensions.para_w;
     
     // 解析数据类型
     if (!req.para_inputs.empty()) {
         const auto& first_input = req.para_inputs.begin()->second;
         switch (first_input.para_dtype) {
             case app::AppDataType::FLOAT32: params.para_dtype = AddDataType::FP32; break;
             case app::AppDataType::FLOAT16: params.para_dtype = AddDataType::FP16; break;
             default: params.para_dtype = AddDataType::FP32; break;
         }
     }
     
     // UR 存储布局：默认分离布局便于仿真；layout_mode=="bank_conflict" 时用同 bank 不同 addr 测冲突。
     if (req.para_layout_mode == "bank_conflict") {
         // 计算每个 tensor 需要的 UR word 数（无 padding，紧凑排列）
         const uint32_t words_needed = params.get_word_count();
         
         // 读取每个 tensor 独立的 bank 分配
         int ib = (req.para_bc_input_bank  >= 0) ? req.para_bc_input_bank  : 0;
         int ob = (req.para_bc_other_bank  >= 0) ? req.para_bc_other_bank  : 0;
         int ab = (req.para_bc_alpha_bank  >= 0) ? req.para_bc_alpha_bank  : 0;
         int xb = (req.para_bc_output_bank >= 0) ? req.para_bc_output_bank : 1;
         
         params.para_input_bank  = ib;
         params.para_other_bank  = ob;
         params.para_alpha_bank  = ab;
         params.para_output_bank = xb;
         
         // 按 bank 顺序分配地址（同 bank 连续排列）
         std::map<int, uint32_t> bank_next;  // bank -> next available address
         params.para_input_addr  = bank_next[ib]; bank_next[ib] += words_needed;
         params.para_other_addr  = bank_next[ob]; bank_next[ob] += words_needed;
         params.para_alpha_addr  = bank_next[ab]; bank_next[ab] += 1;
         params.para_output_addr = bank_next[xb]; bank_next[xb] += words_needed;
     } else {
         params.para_input_bank = 0;  params.para_input_addr = 0;
         params.para_other_bank = 1;  params.para_other_addr = 0;
         params.para_alpha_bank = 2;  params.para_alpha_addr = 0;
         params.para_output_bank = 3; params.para_output_addr = 0;
     }
 
     AddOpInstructions* insts = new AddOpInstructions();
     *insts = compile(params);
     return insts;
 }
 
 bool AddOp::calculate_golden(const app::AppOperatorRequest& req, 
                             std::vector<uint8_t>& golden_bin) {
     golden_bin.clear();
     
     const auto& inputs = req.para_inputs;
     const auto& params = req.para_parameters;
     
     std::vector<float> input_f32, other_f32, alpha_f32;
     app::AppDataType dtype = app::AppDataType::FLOAT32;
     
     if (inputs.find("input_tensor") != inputs.end()) {
         dtype = inputs.at("input_tensor").para_dtype;
         input_f32 = inputs.at("input_tensor").para_data_f32;
     }
     if (inputs.find("other_tensor") != inputs.end()) {
         other_f32 = inputs.at("other_tensor").para_data_f32;
     }
     if (params.find("alpha") != params.end()) {
         alpha_f32 = params.at("alpha").para_data_f32;
     }
     
     const uint32_t w = req.para_dimensions.para_w;
     size_t n = std::min(input_f32.size(), other_f32.size());
     
     for (size_t i = 0; i < n; ++i) {
         float a = (!alpha_f32.empty() && w > 0) ? alpha_f32[i % w] : 1.0f;
         float out;
         
         if (dtype == app::AppDataType::FLOAT16) {
             // Match hardware fp16 precision: each intermediate result is rounded to fp16.
             // HW pipeline: fp16_mul(alpha, other) -> fp16_add(input, mul_result)
             // Use double for intermediate arithmetic to match Python simulator (fp64 internal).
             double a_fp16 = static_cast<double>(app::float16_to_float32(app::float32_to_float16(a)));
             double other_fp16 = static_cast<double>(app::float16_to_float32(app::float32_to_float16(other_f32[i])));
             double input_fp16 = static_cast<double>(app::float16_to_float32(app::float32_to_float16(input_f32[i])));
             double mul_result_d = a_fp16 * other_fp16;
             double mul_fp16 = static_cast<double>(app::float16_to_float32(app::float32_to_float16(static_cast<float>(mul_result_d))));
             double add_result_d = input_fp16 + mul_fp16;
             out = static_cast<float>(app::float16_to_float32(app::float32_to_float16(static_cast<float>(add_result_d))));
         } else {
             out = input_f32[i] + a * other_f32[i];
         }
         
         if (dtype == app::AppDataType::FLOAT32) {
             uint32_t bits; memcpy(&bits, &out, sizeof(float));
             golden_bin.push_back(bits & 0xFF);
             golden_bin.push_back((bits >> 8) & 0xFF);
             golden_bin.push_back((bits >> 16) & 0xFF);
             golden_bin.push_back((bits >> 24) & 0xFF);
         } else {
             uint16_t bits = app::float32_to_float16(out);
             golden_bin.push_back(bits & 0xFF);
             golden_bin.push_back((bits >> 8) & 0xFF);
         }
     }
     
     return true;
 }
 
 void AddOp::fill_random_request(app::AppOperatorRequest& req, 
                                 std::mt19937& rng,
                                 std::uniform_real_distribution<float>& data_dist,
                                 const std::string& dtype_str) {
     req.para_operator = "FusedScaleAdd";
     
     app::AppDataType target_type = app::AppDataType::FLOAT32;
     if (dtype_str == "fp16") target_type = app::AppDataType::FLOAT16;
     else if (dtype_str == "fp32") target_type = app::AppDataType::FLOAT32;
 
     uint32_t total = req.para_dimensions.para_n * req.para_dimensions.para_c * 
                      req.para_dimensions.para_h * req.para_dimensions.para_w;
 
     // 生成 input_tensor
     app::AppTensorDesc input_desc;
     input_desc.para_name = "input_tensor";
     input_desc.para_dtype = target_type;
     input_desc.para_shape = {req.para_dimensions.para_n, req.para_dimensions.para_c,
                              req.para_dimensions.para_h, req.para_dimensions.para_w};
     for (uint32_t i = 0; i < total; ++i) {
         input_desc.para_data_f32.push_back(data_dist(rng));
     }
     req.para_inputs["input_tensor"] = input_desc;
 
     // 生成 other_tensor
     app::AppTensorDesc other_desc = input_desc;
     other_desc.para_name = "other_tensor";
     other_desc.para_data_f32.clear();
     for (uint32_t i = 0; i < total; ++i) {
         other_desc.para_data_f32.push_back(data_dist(rng));
     }
     req.para_inputs["other_tensor"] = other_desc;
 
     // 生成 alpha（长度为 W）
     app::AppTensorDesc alpha_desc;
     alpha_desc.para_name = "alpha";
     alpha_desc.para_dtype = target_type;
     alpha_desc.para_shape = {req.para_dimensions.para_w};
     std::uniform_real_distribution<float> alpha_dist(0.1f, 2.0f);
     for (uint32_t i = 0; i < req.para_dimensions.para_w; ++i) {
         alpha_desc.para_data_f32.push_back(alpha_dist(rng));
     }
     req.para_parameters["alpha"] = alpha_desc;
 }
 
 bool AddOp::generate_data(const app::AppOperatorRequest& req, 
                          std::vector<uint8_t>& input_bin, 
                          std::vector<uint8_t>& other_bin, 
                          std::vector<uint8_t>& alpha_bin) {
     input_bin.clear();
     other_bin.clear();
     alpha_bin.clear();
     
     auto write_tensor_data = [](std::vector<uint8_t>& bin, const app::AppTensorDesc& tensor) {
         if (tensor.para_dtype == app::AppDataType::FLOAT32) {
             for (float v : tensor.para_data_f32) {
                 uint32_t bits; memcpy(&bits, &v, sizeof(float));
                 bin.push_back(bits & 0xFF);
                 bin.push_back((bits >> 8) & 0xFF);
                 bin.push_back((bits >> 16) & 0xFF);
                 bin.push_back((bits >> 24) & 0xFF);
             }
         } else if (tensor.para_dtype == app::AppDataType::FLOAT16) {
             for (float v : tensor.para_data_f32) {
                 uint16_t bits = app::float32_to_float16(v);
                 bin.push_back(bits & 0xFF);
                 bin.push_back((bits >> 8) & 0xFF);
             }
         }
     };
     
     if (req.para_inputs.find("input_tensor") != req.para_inputs.end()) {
         write_tensor_data(input_bin, req.para_inputs.at("input_tensor"));
     }
     if (req.para_inputs.find("other_tensor") != req.para_inputs.end()) {
         write_tensor_data(other_bin, req.para_inputs.at("other_tensor"));
     }
     
     const auto& params = req.para_parameters;
     if (params.find("alpha") != params.end()) {
         write_tensor_data(alpha_bin, params.at("alpha"));
     }
     
     return true;
 }
 
 std::vector<uint8_t> AddOpInstructions::serialize() const {
     std::vector<uint8_t> result;
     auto iq_files = get_iq_files();
     for (const auto& file : iq_files) {
         result.insert(result.end(), file.para_data.begin(), file.para_data.end());
     }
     return result;
 }
 
 // 自动注册算子
 REGISTER_OP(AddOp);
 
 } // namespace op
 } // namespace aiacc
 
