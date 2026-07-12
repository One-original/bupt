#include "softmax.h"

#ifndef SOFTMAX_STANDALONE

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>

#include "../../iq/iq_id_defs.h"
#include "../../app/fp16_utils.h"
#include "../add/ur_code_extractor.h"

namespace aiacc {
namespace op {

namespace {
constexpr uint8_t RTOVR_IN_UR_RDATA_0 = 30;
constexpr uint8_t RTOVR_IN_UR_RDATA_1 = 31;
constexpr uint8_t RTOVR_IN_DR_FPADD_ST = 5;
constexpr uint8_t RTOVR_IN_DR_LOGIC_D = 10;
constexpr uint8_t RTOVR_OUT_DVR_FPADD_S0 = 5;
constexpr uint8_t RTOVR_OUT_DVR_FPADD_S1 = 6;
constexpr uint8_t RTOVR_OUT_DVR_LOGIC_S0 = 11;
constexpr uint8_t RTOVR_OUT_DVR_LOGIC_S1 = 12;
constexpr uint8_t RTOVR_OUT_DVR_LOGIC_ST = 13;
constexpr uint8_t RTOVR_OUT_UVR_WDATA_0 = 35;

constexpr uint8_t kLocalMaxPeriod = 14;
constexpr uint8_t kMaxInputBank = 5;
constexpr uint8_t kScratchBank = 2;
constexpr uint8_t kLocalMaxAddr = 0;

uint64_t serialize_header_bits(uint8_t vld, uint8_t jump, uint8_t embed, uint16_t loops,
                               uint8_t cond, uint8_t dly, uint8_t inc,
                               uint8_t embed_end_bits, uint8_t inc_embed_bits) {
    constexpr uint32_t BITS_EMBED = 3, BITS_EMBED_END = 6, BITS_LOOPS = 10;
    constexpr uint32_t BITS_COND = 7, BITS_DLY = 3, BITS_INC = 4, BITS_INC_EMBED = 6;
    constexpr uint32_t MASK_EMBED = (1u << BITS_EMBED) - 1;
    constexpr uint32_t MASK_EMBED_END = (1u << BITS_EMBED_END) - 1;
    constexpr uint32_t MASK_LOOPS = (1u << BITS_LOOPS) - 1;
    constexpr uint32_t MASK_COND = (1u << BITS_COND) - 1;
    constexpr uint32_t MASK_DLY = (1u << BITS_DLY) - 1;
    constexpr uint32_t MASK_INC = (1u << BITS_INC) - 1;
    constexpr uint32_t MASK_INC_EMBED = (1u << BITS_INC_EMBED) - 1;

    uint64_t bits = 0;
    uint32_t pos = 0;

    uint8_t embed_end = (embed == 0) ? (embed_end_bits & MASK_EMBED_END) : 0u;
    uint8_t inc_embed = (embed == 0) ? (inc_embed_bits & MASK_INC_EMBED) : 0u;

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
}

std::vector<uint8_t> serialize_code(uint64_t code, uint16_t code_bits) {
    std::vector<uint8_t> bytes;
    uint16_t num_bytes = (code_bits + 7) / 8;
    for (int i = num_bytes - 1; i >= 0; --i) {
        bytes.push_back((code >> (i * 8)) & 0xFF);
    }
    return bytes;
}

std::vector<uint8_t> make_instruction(uint8_t vld, uint8_t jump, uint8_t embed, uint16_t loops,
                                      uint8_t cond, uint8_t dly, int8_t inc,
                                      uint8_t embed_end_bits, uint8_t inc_embed_bits,
                                      const std::vector<uint8_t>& code_bytes,
                                      int code_bits) {
    uint64_t h = serialize_header_bits(vld, jump, embed, loops, cond, dly, inc,
                                       embed_end_bits, inc_embed_bits);

    int total_width = 41 + code_bits;
    int num_bytes = (total_width + 7) / 8;
    std::vector<uint8_t> ret(num_bytes, 0);

    uint32_t current_bit = 0;
    for (int i = (int)code_bytes.size() - 1; i >= 0 && current_bit < (uint32_t)code_bits; --i) {
        uint8_t byte = code_bytes[i];
        for (int b = 0; b < 8 && current_bit < (uint32_t)code_bits; ++b) {
            if ((byte >> b) & 1u) {
                int byte_idx = num_bytes - 1 - (current_bit / 8);
                ret[byte_idx] |= (1 << (current_bit % 8));
            }
            current_bit++;
        }
    }

    for (int i = 0; i < 41; ++i) {
        if ((h >> i) & 1u) {
            int bit_pos = code_bits + i;
            int byte_idx = num_bytes - 1 - (bit_pos / 8);
            ret[byte_idx] |= (1 << (bit_pos % 8));
        }
    }

    return ret;
}

std::vector<uint8_t> serialize_ur_wdata_inst(uint8_t vld, uint8_t jump, uint8_t embed, uint16_t loops,
                                             uint8_t cond, uint8_t dly, uint8_t inc,
                                             uint8_t embed_end_bits, uint8_t inc_embed_bits,
                                             uint32_t code_28) {
    uint64_t header = serialize_header_bits(vld, jump, embed, loops, cond, dly, inc,
                                            embed_end_bits, inc_embed_bits);
    unsigned __int128 inst_69 = (static_cast<unsigned __int128>(header) << 28) |
                                static_cast<unsigned __int128>(code_28 & 0x0FFFFFFFu);
    std::vector<uint8_t> bytes;
    for (int i = 8; i >= 0; --i) {
        bytes.push_back(static_cast<uint8_t>((inst_69 >> (i * 8)) & 0xFF));
    }
    return bytes;
}

inline size_t idx_nchw(size_t n, size_t c, size_t h, size_t w,
                       size_t C, size_t H, size_t W) {
    return ((n * C + c) * H + h) * W + w;
}

void write_fp32(std::vector<uint8_t>& out, float v) {
    uint32_t bits;
    std::memcpy(&bits, &v, sizeof(float));
    out.push_back(bits & 0xFFu);
    out.push_back((bits >> 8) & 0xFFu);
    out.push_back((bits >> 16) & 0xFFu);
    out.push_back((bits >> 24) & 0xFFu);
}

void write_fp16(std::vector<uint8_t>& out, float v) {
    uint16_t bits = app::float32_to_float16(v);
    out.push_back(bits & 0xFFu);
    out.push_back((bits >> 8) & 0xFFu);
}

void softmax_axis_3(const std::vector<float>& in, std::vector<float>& out,
                    uint32_t N, uint32_t C, uint32_t H, uint32_t W) {
    for (uint32_t n = 0; n < N; ++n) {
        for (uint32_t c = 0; c < C; ++c) {
            for (uint32_t h = 0; h < H; ++h) {
                float max_v = -INFINITY;
                for (uint32_t w = 0; w < W; ++w) {
                    max_v = std::max(max_v, in[idx_nchw(n, c, h, w, C, H, W)]);
                }
                float sum = 0.0f;
                for (uint32_t w = 0; w < W; ++w) {
                    float e = std::exp(in[idx_nchw(n, c, h, w, C, H, W)] - max_v);
                    out[idx_nchw(n, c, h, w, C, H, W)] = e;
                    sum += e;
                }
                float inv = (sum == 0.0f) ? 0.0f : (1.0f / sum);
                for (uint32_t w = 0; w < W; ++w) {
                    out[idx_nchw(n, c, h, w, C, H, W)] *= inv;
                }
            }
        }
    }
}

void softmax_axis_2(const std::vector<float>& in, std::vector<float>& out,
                    uint32_t N, uint32_t C, uint32_t H, uint32_t W) {
    for (uint32_t n = 0; n < N; ++n) {
        for (uint32_t c = 0; c < C; ++c) {
            for (uint32_t w = 0; w < W; ++w) {
                float max_v = -INFINITY;
                for (uint32_t h = 0; h < H; ++h) {
                    max_v = std::max(max_v, in[idx_nchw(n, c, h, w, C, H, W)]);
                }
                float sum = 0.0f;
                for (uint32_t h = 0; h < H; ++h) {
                    float e = std::exp(in[idx_nchw(n, c, h, w, C, H, W)] - max_v);
                    out[idx_nchw(n, c, h, w, C, H, W)] = e;
                    sum += e;
                }
                float inv = (sum == 0.0f) ? 0.0f : (1.0f / sum);
                for (uint32_t h = 0; h < H; ++h) {
                    out[idx_nchw(n, c, h, w, C, H, W)] *= inv;
                }
            }
        }
    }
}

void softmax_axis_1(const std::vector<float>& in, std::vector<float>& out,
                    uint32_t N, uint32_t C, uint32_t H, uint32_t W) {
    for (uint32_t n = 0; n < N; ++n) {
        for (uint32_t h = 0; h < H; ++h) {
            for (uint32_t w = 0; w < W; ++w) {
                float max_v = -INFINITY;
                for (uint32_t c = 0; c < C; ++c) {
                    max_v = std::max(max_v, in[idx_nchw(n, c, h, w, C, H, W)]);
                }
                float sum = 0.0f;
                for (uint32_t c = 0; c < C; ++c) {
                    float e = std::exp(in[idx_nchw(n, c, h, w, C, H, W)] - max_v);
                    out[idx_nchw(n, c, h, w, C, H, W)] = e;
                    sum += e;
                }
                float inv = (sum == 0.0f) ? 0.0f : (1.0f / sum);
                for (uint32_t c = 0; c < C; ++c) {
                    out[idx_nchw(n, c, h, w, C, H, W)] *= inv;
                }
            }
        }
    }
}

void softmax_axis_0(const std::vector<float>& in, std::vector<float>& out,
                    uint32_t N, uint32_t C, uint32_t H, uint32_t W) {
    for (uint32_t c = 0; c < C; ++c) {
        for (uint32_t h = 0; h < H; ++h) {
            for (uint32_t w = 0; w < W; ++w) {
                float max_v = -INFINITY;
                for (uint32_t n = 0; n < N; ++n) {
                    max_v = std::max(max_v, in[idx_nchw(n, c, h, w, C, H, W)]);
                }
                float sum = 0.0f;
                for (uint32_t n = 0; n < N; ++n) {
                    float e = std::exp(in[idx_nchw(n, c, h, w, C, H, W)] - max_v);
                    out[idx_nchw(n, c, h, w, C, H, W)] = e;
                    sum += e;
                }
                float inv = (sum == 0.0f) ? 0.0f : (1.0f / sum);
                for (uint32_t n = 0; n < N; ++n) {
                    out[idx_nchw(n, c, h, w, C, H, W)] *= inv;
                }
            }
        }
    }
}

} // namespace

std::string SoftmaxOp::get_name() const {
    return "Softmax";
}

bool SoftmaxOp::parse_i32_param(const app::AppOperatorRequest& req,
                                const std::string& key,
                                int32_t& out) {
    auto it = req.para_parameters.find(key);
    if (it == req.para_parameters.end()) return false;
    if (!it->second.para_data_i32.empty()) {
        out = it->second.para_data_i32[0];
        return true;
    }
    if (!it->second.para_data_f32.empty()) {
        out = static_cast<int32_t>(it->second.para_data_f32[0]);
        return true;
    }
    return false;
}

SoftmaxOpInstructions SoftmaxOp::compile(const SoftmaxOpParams& params) {
    SoftmaxOpInstructions insts;
    insts.para_dtype = params.para_dtype;
    insts.para_dim = params.para_dim;
    insts.para_half_to_float = params.para_half_to_float;

    if (params.para_dtype != SoftmaxDataType::FP32) {
        throw std::runtime_error(
            "Softmax local-max IQ currently supports FP32 only");
    }
    const int32_t normalized_dim =
        params.para_dim < 0 ? params.para_dim + 4 : params.para_dim;
    if (normalized_dim != 3) {
        throw std::runtime_error(
            "Softmax local-max IQ currently reduces the last dimension only");
    }

    const uint32_t row_count =
        params.para_n * params.para_c * params.para_h;
    const uint32_t row_elems = params.para_w;
    const uint32_t local_max_steps = (row_elems + 7u) / 8u;
    if (local_max_steps == 0 || local_max_steps > 256) {
        throw std::runtime_error(
            "Softmax local-max supports d0 in [1, 2048] per pass");
    }

    insts.para_row_count = row_count;
    insts.para_total_steps = local_max_steps;
    insts.para_total_elements = row_elems;

    iq::UrCru ur_read;
    ur_read.para_vld = true;
    ur_read.para_raddr[0].bank = kMaxInputBank;
    ur_read.para_raddr[0].addr_word = 0;
    ur_read.para_re[0] = true;
    ur_read.para_raddr[1].bank = kScratchBank;
    ur_read.para_raddr[1].addr_word = kLocalMaxAddr;
    ur_read.para_re[1] = true;
    ur_read.para_re[2] = false;
    ur_read.para_re[3] = false;
    ur_read.para_we[0] = false;
    ur_read.para_we[1] = false;
    ur_read.para_we[2] = false;
    ur_read.para_we[3] = false;
    insts.para_ur_read_crus.push_back(ur_read);

    iq::UrCru ur_write;
    ur_write.para_vld = true;
    ur_write.para_re[0] = false;
    ur_write.para_re[1] = false;
    ur_write.para_re[2] = false;
    ur_write.para_re[3] = false;
    ur_write.para_waddr[0].bank = kScratchBank;
    ur_write.para_waddr[0].addr_word = kLocalMaxAddr;
    ur_write.para_we[0] = true;
    ur_write.para_wbe[0] = 0xFFFF;
    ur_write.para_we[1] = false;
    ur_write.para_we[2] = false;
    ur_write.para_we[3] = false;
    insts.para_ur_write_crus.push_back(ur_write);

    insts.para_rtovr_routes = {
        {RTOVR_OUT_DVR_FPADD_S0, RTOVR_IN_UR_RDATA_0},
        {RTOVR_OUT_DVR_FPADD_S1, RTOVR_IN_UR_RDATA_1},
        {RTOVR_OUT_DVR_LOGIC_S0, RTOVR_IN_UR_RDATA_0},
        {RTOVR_OUT_DVR_LOGIC_S1, RTOVR_IN_UR_RDATA_1},
        {RTOVR_OUT_DVR_LOGIC_ST, RTOVR_IN_DR_FPADD_ST},
        {RTOVR_OUT_UVR_WDATA_0, RTOVR_IN_DR_LOGIC_D},
    };

    iq::FpAddCru fpadd;
    fpadd.para_inst_valid = true;
    fpadd.para_src_precision_32b = true;
    fpadd.para_dst_precision_32b = true;
    fpadd.para_update_status = true;
    fpadd.para_is_sub = false;
    fpadd.para_smc_id_en = 7;
    insts.para_fpadd_inst = iq::FpAddIq::pack_cru_fpadd(fpadd);

    iq::LogicalCru logical;
    logical.para_inst_valid = true;
    logical.para_precision_32b = true;
    logical.para_opcode = iq::LogicalOp::SELECT_GREAT;
    insts.para_logical_inst =
        iq::LogicalIq::pack_cru_logical(logical);

    return insts;
}

OpInstructionsBase* SoftmaxOp::compile(const app::AppOperatorRequest& req) {
    SoftmaxOpParams p;
    p.para_n = req.para_dimensions.para_n;
    p.para_c = req.para_dimensions.para_c;
    p.para_h = req.para_dimensions.para_h;
    p.para_w = req.para_dimensions.para_w;

    if (p.para_n == 0 || p.para_c == 0 || p.para_h == 0 || p.para_w == 0) {
        throw std::runtime_error("Softmax: dimensions cannot be zero");
    }

    auto it_in = req.para_inputs.find("input_tensor");
    if (it_in == req.para_inputs.end()) {
        throw std::runtime_error("Softmax: missing input_tensor");
    }
    p.para_dtype = (it_in->second.para_dtype == app::AppDataType::FLOAT16)
        ? SoftmaxDataType::FP16
        : SoftmaxDataType::FP32;

    int32_t dim = -1;
    if (parse_i32_param(req, "dim", dim)) {
        p.para_dim = dim;
    }

    int32_t half_to_float = 0;
    if (parse_i32_param(req, "half_to_float", half_to_float)) {
        p.para_half_to_float = (half_to_float != 0);
    }

    int32_t input_bank = 0, output_bank = 3, input_addr = 0, output_addr = 0;
    parse_i32_param(req, "input_bank", input_bank);
    parse_i32_param(req, "output_bank", output_bank);
    parse_i32_param(req, "input_addr", input_addr);
    parse_i32_param(req, "output_addr", output_addr);

    p.para_input_bank = static_cast<uint8_t>(input_bank & 0x7);
    p.para_output_bank = static_cast<uint8_t>(output_bank & 0x7);
    p.para_input_addr = static_cast<uint8_t>(input_addr & 0xFF);
    p.para_output_addr = static_cast<uint8_t>(output_addr & 0xFF);

    auto* insts = new SoftmaxOpInstructions();
    *insts = compile(p);
    return insts;
}

std::vector<IqInstructionFile> SoftmaxOpInstructions::get_iq_files() const {
    std::vector<IqInstructionFile> files;

    if (para_total_steps == 0 || para_ur_read_crus.empty() ||
        para_ur_write_crus.empty()) {
        return files;
    }
    const uint16_t outer_loops =
        static_cast<uint16_t>(para_total_steps - 1);

    auto slot_is_active = [](uint8_t slot,
                             const std::vector<uint8_t>& active_slots) {
        return std::find(
                   active_slots.begin(), active_slots.end(), slot) !=
               active_slots.end();
    };

    auto append_slotted_file =
        [&](uint32_t iq_id, const std::string& name, uint16_t code_bits,
            uint64_t code, const std::vector<uint8_t>& active_slots,
            uint8_t outer_inc, bool address_uses_outer_loop) {
            IqInstructionFile file;
            file.para_iq_id = iq_id;
            file.para_iq_name = name;
            file.para_width_bits = 41 + code_bits;

            const auto code_bytes = serialize_code(code, code_bits);
            const auto zero_code = serialize_code(0, code_bits);
            auto outer = make_instruction(
                1, 0, 1u, outer_loops, 0, 0, outer_inc,
                0u, 0u, zero_code, code_bits);
            file.para_data.insert(
                file.para_data.end(), outer.begin(), outer.end());

            for (uint8_t slot = 0; slot < kLocalMaxPeriod; ++slot) {
                const bool active = slot_is_active(slot, active_slots);
                const uint8_t embed_end =
                    slot + 1 == kLocalMaxPeriod ? 0x01u : 0u;
                const uint8_t inc_embed =
                    active && address_uses_outer_loop ? 0x01u : 0u;
                auto body = make_instruction(
                    1, 0, 0u, 0, 0, 0, 0,
                    embed_end, inc_embed,
                    active ? code_bytes : zero_code, code_bits);
                file.para_data.insert(
                    file.para_data.end(), body.begin(), body.end());
            }

            auto end = make_instruction(
                1, 1, 0u, 0, 0, 0, 0,
                0u, 0u, zero_code, code_bits);
            file.para_data.insert(
                file.para_data.end(), end.begin(), end.end());
            files.push_back(std::move(file));
        };

    append_slotted_file(
        iq::IQ_ID_UR_RDATA_0, "ur-r0", 12,
        aiacc::op::extract_ur_read_port0_code(para_ur_read_crus[0]),
        {0, 5}, 1, true);
    append_slotted_file(
        iq::IQ_ID_UR_RDATA_1, "ur-r1", 12,
        aiacc::op::extract_ur_read_port1_code(para_ur_read_crus[0]),
        {0, 5}, 0, true);

    for (const auto& route : para_rtovr_routes) {
        const uint8_t target = route.first;
        const uint8_t source = route.second;
        std::vector<uint8_t> active_slots;
        if (target == RTOVR_OUT_DVR_FPADD_S0 ||
            target == RTOVR_OUT_DVR_FPADD_S1) {
            active_slots = {2};
        } else if (target == RTOVR_OUT_DVR_LOGIC_S0 ||
                   target == RTOVR_OUT_DVR_LOGIC_S1 ||
                   target == RTOVR_OUT_DVR_LOGIC_ST) {
            active_slots = {7};
        } else {
            active_slots = {9};
        }
        append_slotted_file(
            iq::IQ_ID_RTOVR_BASE + target,
            "rtovr-" + std::to_string(target), 7,
            static_cast<uint8_t>((source << 1) | 1u),
            active_slots, 0, false);
    }

    append_slotted_file(
        iq::IQ_ID_FPADD, "fpadd", 10, para_fpadd_inst,
        {3}, 0, false);
    append_slotted_file(
        iq::IQ_ID_LOGIC, "logic", 6, para_logical_inst,
        {8}, 0, false);

    {
        IqInstructionFile file;
        file.para_iq_id = iq::IQ_ID_UR_WDATA_0;
        file.para_iq_name = "ur-w0";
        file.para_width_bits = 41 + 28;
        const uint32_t code =
            aiacc::op::extract_ur_write_port0_code(
                para_ur_write_crus[0]);

        auto outer = serialize_ur_wdata_inst(
            1, 0, 1u, outer_loops, 0, 0, 0, 0u, 0u, 0);
        file.para_data.insert(
            file.para_data.end(), outer.begin(), outer.end());
        for (uint8_t slot = 0; slot < kLocalMaxPeriod; ++slot) {
            const uint8_t embed_end =
                slot + 1 == kLocalMaxPeriod ? 0x01u : 0u;
            auto body = serialize_ur_wdata_inst(
                1, 0, 0u, 0, 0, 0, 0,
                embed_end, 0u, slot == 10 ? code : 0u);
            file.para_data.insert(
                file.para_data.end(), body.begin(), body.end());
        }
        auto end = serialize_ur_wdata_inst(
            1, 1, 0u, 0, 0, 0, 0, 0u, 0u, 0);
        file.para_data.insert(
            file.para_data.end(), end.begin(), end.end());
        files.push_back(std::move(file));
    }

    return files;
}

std::vector<uint8_t> SoftmaxOpInstructions::serialize() const {
    std::vector<uint8_t> result;
    auto iq_files = get_iq_files();
    for (const auto& f : iq_files) {
        result.insert(result.end(), f.para_data.begin(), f.para_data.end());
    }
    return result;
}

bool SoftmaxOp::calculate_golden(const app::AppOperatorRequest& req,
                                 std::vector<uint8_t>& golden_bin) {
    golden_bin.clear();

    auto it = req.para_inputs.find("input_tensor");
    if (it == req.para_inputs.end()) return false;

    const auto& in_desc = it->second;
    const auto& in = in_desc.para_data_f32;

    const uint32_t N = req.para_dimensions.para_n;
    const uint32_t C = req.para_dimensions.para_c;
    const uint32_t H = req.para_dimensions.para_h;
    const uint32_t W = req.para_dimensions.para_w;
    const size_t total = static_cast<size_t>(N) * C * H * W;

    if (in.size() < total) return false;

    int32_t dim = -1;
    parse_i32_param(req, "dim", dim);
    if (dim < 0) dim += 4;
    if (dim < 0 || dim > 3) return false;

    int32_t half_to_float = 0;
    parse_i32_param(req, "half_to_float", half_to_float);
    const bool out_fp32 = (in_desc.para_dtype == app::AppDataType::FLOAT32) || (half_to_float != 0);

    std::vector<float> out(total, 0.0f);

    switch (dim) {
        case 0: softmax_axis_0(in, out, N, C, H, W); break;
        case 1: softmax_axis_1(in, out, N, C, H, W); break;
        case 2: softmax_axis_2(in, out, N, C, H, W); break;
        case 3: softmax_axis_3(in, out, N, C, H, W); break;
        default: return false;
    }

    for (size_t i = 0; i < total; ++i) {
        if (out_fp32) write_fp32(golden_bin, out[i]);
        else write_fp16(golden_bin, out[i]);
    }

    return true;
}

bool SoftmaxOp::generate_data(const app::AppOperatorRequest& req,
                              std::vector<uint8_t>& input_bin,
                              std::vector<uint8_t>& other_bin,
                              std::vector<uint8_t>& alpha_bin) {
    input_bin.clear();
    other_bin.clear();
    alpha_bin.clear();

    auto it = req.para_inputs.find("input_tensor");
    if (it == req.para_inputs.end()) return false;

    const auto& tensor = it->second;
    if (tensor.para_dtype == app::AppDataType::FLOAT16) {
        for (float v : tensor.para_data_f32) {
            uint16_t bits = app::float32_to_float16(v);
            input_bin.push_back(bits & 0xFFu);
            input_bin.push_back((bits >> 8) & 0xFFu);
        }
    } else {
        for (float v : tensor.para_data_f32) {
            uint32_t bits;
            std::memcpy(&bits, &v, sizeof(float));
            input_bin.push_back(bits & 0xFFu);
            input_bin.push_back((bits >> 8) & 0xFFu);
            input_bin.push_back((bits >> 16) & 0xFFu);
            input_bin.push_back((bits >> 24) & 0xFFu);
        }
    }
    return true;
}

void SoftmaxOp::fill_random_request(app::AppOperatorRequest& req,
                                    std::mt19937& rng,
                                    std::uniform_real_distribution<float>& data_dist,
                                    const std::string& dtype_str) {
    req.para_operator = "Softmax";

    app::AppDataType dtype = app::AppDataType::FLOAT32;
    if (dtype_str == "fp16") dtype = app::AppDataType::FLOAT16;

    uint32_t total = req.para_dimensions.para_n * req.para_dimensions.para_c *
                     req.para_dimensions.para_h * req.para_dimensions.para_w;

    app::AppTensorDesc input;
    input.para_name = "input_tensor";
    input.para_dtype = dtype;
    input.para_shape = {req.para_dimensions.para_n, req.para_dimensions.para_c,
                        req.para_dimensions.para_h, req.para_dimensions.para_w};

    for (uint32_t i = 0; i < total; ++i) {
        input.para_data_f32.push_back(data_dist(rng));
    }
    req.para_inputs["input_tensor"] = input;

    app::AppTensorDesc dim_desc;
    dim_desc.para_name = "dim";
    dim_desc.para_dtype = app::AppDataType::INT32;
    dim_desc.para_shape = {1};
    dim_desc.para_data_i32 = {-1};
    req.para_parameters["dim"] = dim_desc;

    app::AppTensorDesc htf_desc;
    htf_desc.para_name = "half_to_float";
    htf_desc.para_dtype = app::AppDataType::INT32;
    htf_desc.para_shape = {1};
    htf_desc.para_data_i32 = {0};
    req.para_parameters["half_to_float"] = htf_desc;
}

REGISTER_OP(SoftmaxOp);

} // namespace op
} // namespace aiacc

#endif // SOFTMAX_STANDALONE

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <random>
#include <sstream>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/types.h>
#include <utility>

namespace aiacc {
namespace op {
namespace softmax {
namespace {

constexpr uint32_t kInputBank = 0;
constexpr uint32_t kExpBank = 1;
constexpr uint32_t kScratchBank = 2;
constexpr uint32_t kOutputBank = 3;
constexpr uint32_t kConstantBank = 4;
constexpr uint32_t kMaxInputBank = 5;

std::string join_path(const std::string& base, const std::string& name) {
    if (base.empty()) {
        return name;
    }
    if (base.back() == '/') {
        return base + name;
    }
    return base + "/" + name;
}

void make_dirs(const std::string& path) {
    std::string current;
    for (char ch : path) {
        current += ch;
        if (ch == '/' && current.size() > 1 &&
            mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) {
            throw std::runtime_error("failed to create directory " + current);
        }
    }
    if (!path.empty() && mkdir(path.c_str(), 0755) != 0 && errno != EEXIST) {
        throw std::runtime_error("failed to create directory " + path);
    }
}

uint32_t scratch_addr(ScratchAddr addr) {
    return static_cast<uint32_t>(addr);
}

uint32_t constant_addr(ConstantAddr addr) {
    return static_cast<uint32_t>(addr);
}

std::vector<uint8_t> make_empty_bank() {
    return std::vector<uint8_t>(kUrBankDepthWords * kUrWordBytes, 0);
}

UrBundle make_empty_ur() {
    UrBundle ur;
    for (auto& bank : ur.banks) {
        bank = make_empty_bank();
    }
    return ur;
}

void write_fp32_element(std::vector<uint8_t>& bank,
                        uint32_t elem_index,
                        float value) {
    const uint32_t word_addr = elem_index / 4;
    const uint32_t lane = elem_index % 4;
    if (word_addr >= kUrBankDepthWords) {
        throw std::out_of_range("UR element exceeds bank depth");
    }
    const size_t offset =
        static_cast<size_t>(word_addr) * kUrWordBytes + lane * sizeof(float);
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    bank[offset + 0] = static_cast<uint8_t>(bits & 0xffu);
    bank[offset + 1] = static_cast<uint8_t>((bits >> 8) & 0xffu);
    bank[offset + 2] = static_cast<uint8_t>((bits >> 16) & 0xffu);
    bank[offset + 3] = static_cast<uint8_t>((bits >> 24) & 0xffu);
}

void write_fp32_broadcast_word(std::vector<uint8_t>& bank,
                               uint32_t word_addr,
                               float value) {
    if (word_addr >= kUrBankDepthWords) {
        throw std::out_of_range("UR word exceeds bank depth");
    }
    for (uint32_t lane = 0; lane < 4; ++lane) {
        write_fp32_element(bank, word_addr * 4 + lane, value);
    }
}

float read_fp32_element(const std::vector<uint8_t>& bank,
                        uint32_t elem_index) {
    const uint32_t word_addr = elem_index / 4;
    const uint32_t lane = elem_index % 4;
    if (word_addr >= kUrBankDepthWords) {
        throw std::out_of_range("UR element exceeds bank depth");
    }
    const size_t offset =
        static_cast<size_t>(word_addr) * kUrWordBytes + lane * sizeof(float);
    const uint32_t bits =
        static_cast<uint32_t>(bank[offset + 0]) |
        (static_cast<uint32_t>(bank[offset + 1]) << 8) |
        (static_cast<uint32_t>(bank[offset + 2]) << 16) |
        (static_cast<uint32_t>(bank[offset + 3]) << 24);
    float value = 0.0f;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

std::vector<uint32_t> make_even_split(uint32_t row_elems,
                                      uint32_t smc_num) {
    if (smc_num == 0 || smc_num > 32) {
        throw std::invalid_argument("smc_num must be in [1, 32]");
    }
    std::vector<uint32_t> split(smc_num, row_elems / smc_num);
    for (uint32_t i = 0; i < row_elems % smc_num; ++i) {
        ++split[i];
    }
    return split;
}

void validate_options(const CompileOptions& options,
                      const std::vector<uint32_t>& split) {
    if (options.d3 == 0 || options.d2 == 0 ||
        options.d1 == 0 || options.d0 == 0) {
        throw std::invalid_argument("softmax d3/d2/d1/d0 must be non-zero");
    }
    if (options.smc_num != kSmcCount) {
        throw std::invalid_argument("softmax is fixed to 8 SMCs");
    }
    if (options.row_id >= options.row_count()) {
        throw std::invalid_argument("row_id must be smaller than d3*d2*d1");
    }
    if (split.size() != options.smc_num) {
        throw std::invalid_argument("split count must equal smc_num");
    }

    uint64_t total = 0;
    for (uint32_t elems : split) {
        if (elems > kUrBankDepthWords) {
            throw std::invalid_argument(
                "bank5 expanded max layout supports at most "
                "256 elements per SMC and row");
        }
        total += elems;
    }
    if (total != options.d0) {
        throw std::invalid_argument(
            "split elements must sum to d0, because SMCs split one row");
    }
}

std::vector<LocalTilePlan> make_tiles(const std::vector<uint32_t>& split) {
    std::vector<LocalTilePlan> tiles;
    uint32_t offset = 0;
    for (uint32_t i = 0; i < split.size(); ++i) {
        tiles.push_back(
            {static_cast<uint8_t>(i), offset, split[i]});
        offset += split[i];
    }
    return tiles;
}

void write_binary_floats(const std::string& path,
                         const std::vector<float>& values) {
    std::ofstream out(path, std::ios::binary);
    if (!out) {
        throw std::runtime_error("failed to open " + path);
    }
    out.write(reinterpret_cast<const char*>(values.data()),
              static_cast<std::streamsize>(values.size() * sizeof(float)));
}

void write_memory_hex(const std::string& path,
                      const std::vector<uint8_t>& data) {
    if (data.size() % kUrWordBytes != 0) {
        throw std::runtime_error("UR image is not 128-bit aligned");
    }
    std::ofstream out(path);
    if (!out) {
        throw std::runtime_error("failed to open " + path);
    }
    out << std::hex << std::setfill('0');
    for (size_t offset = 0; offset < data.size(); offset += kUrWordBytes) {
        for (uint32_t i = 0; i < kUrWordBytes; ++i) {
            out << std::setw(2)
                << static_cast<uint32_t>(
                       data[offset + kUrWordBytes - 1 - i]);
        }
        out << '\n';
    }
}

void write_ur_snapshot(const std::string& root,
                       const std::vector<UrBundle>& snapshot) {
    for (size_t smc = 0; smc < snapshot.size(); ++smc) {
        const std::string ur_dir = join_path(
            join_path(root, "smc_" + std::to_string(smc)), "ur_data");
        make_dirs(ur_dir);
        for (uint32_t bank = 0; bank < kUrBankCount; ++bank) {
            write_memory_hex(
                join_path(
                    ur_dir, "bank" + std::to_string(bank) + ".hex"),
                snapshot[smc].banks[bank]);
        }
    }
}

void write_local_output(const std::string& root,
                        const CompileResult& result) {
    for (size_t i = 0; i < result.tiles.size(); ++i) {
        const LocalTilePlan& tile = result.tiles[i];
        std::vector<float> local(tile.elems, 0.0f);
        for (uint32_t j = 0; j < tile.elems; ++j) {
            local[j] = read_fp32_element(
                result.after_normalize[i].banks[kOutputBank], j);
        }
        const std::string smc_dir =
            join_path(root, "smc_" + std::to_string(i));
        make_dirs(smc_dir);
        write_binary_floats(join_path(smc_dir, "output.bin"), local);
    }
}

void write_config_json(const std::string& root,
                       const CompileResult& result) {
    std::ofstream out(join_path(root, "softmax_config.json"));
    if (!out) {
        throw std::runtime_error("failed to write softmax_config.json");
    }
    uint32_t local_max_steps = 0;
    for (const LocalTilePlan& tile : result.tiles) {
        local_max_steps = std::max(local_max_steps, tile.elems);
    }
    out << "{\n"
        << "  \"operator\": \"Softmax\",\n"
        << "  \"mode\": \"softmax_8_smc_compute_only\",\n"
        << "  \"dtype\": \"fp32\",\n"
        << "  \"dim\": -1,\n"
        << "  \"shape\": ["
        << result.options.d3 << ", "
        << result.options.d2 << ", "
        << result.options.d1 << ", "
        << result.options.d0 << "],\n"
        << "  \"d3\": " << result.options.d3 << ",\n"
        << "  \"d2\": " << result.options.d2 << ",\n"
        << "  \"d1\": " << result.options.d1 << ",\n"
        << "  \"d0\": " << result.options.d0 << ",\n"
        << "  \"total_elements\": "
        << result.options.total_elements() << ",\n"
        << "  \"row_count\": " << result.options.row_count() << ",\n"
        << "  \"selected_row\": " << result.options.row_id << ",\n"
        << "  \"smc_num\": " << result.options.smc_num << ",\n"
        << "  \"local_max_steps\": " << local_max_steps << ",\n"
        << "  \"layout\": \"packed_fp32_4_lanes_per_128b_word\",\n"
        << "  \"bank_layout\": {\n"
        << "    \"bank0\": \"input\",\n"
        << "    \"bank1\": \"exp_buffer\",\n"
        << "    \"bank2\": \"scalar_scratch\",\n"
        << "    \"bank3\": \"output\",\n"
        << "    \"bank4\": \"constants\",\n"
        << "    \"bank5\": \"local_max_broadcast_input\"\n"
        << "  },\n"
        << "  \"scratch_addr\": {\n"
        << "    \"local_max\": 0,\n"
        << "    \"global_max\": 1,\n"
        << "    \"local_sum\": 2,\n"
        << "    \"global_sum\": 3,\n"
        << "    \"inv_sum\": 4\n"
        << "  },\n"
        << "  \"constant_addr\": {\n"
        << "    \"zero\": 0,\n"
        << "    \"one\": 1,\n"
        << "    \"two\": 2,\n"
        << "    \"negative_infinity\": 3\n"
        << "  },\n"
        << "  \"tiles\": [\n";
    for (size_t i = 0; i < result.tiles.size(); ++i) {
        const LocalTilePlan& tile = result.tiles[i];
        out << "    {\"smc_id\": " << static_cast<uint32_t>(tile.smc_id)
            << ", \"elem_offset\": " << tile.elem_offset
            << ", \"elements\": " << tile.elems
            << ", \"packed_words\": " << (tile.elems + 3) / 4
            << "}";
        if (i + 1 != result.tiles.size()) {
            out << ',';
        }
        out << '\n';
    }
    out << "  ]\n"
        << "}\n";
}

void write_exchange_json(const std::string& root,
                         const CompileResult& result) {
    std::ofstream out(join_path(root, "scalar_exchange_plan.json"));
    if (!out) {
        throw std::runtime_error("failed to write scalar_exchange_plan.json");
    }
    auto write_json_float = [&out](float value) {
        if (std::isfinite(value)) {
            out << value;
        } else {
            out << "null";
        }
    };

    out << std::setprecision(9)
        << "{\n"
        << "  \"transport\": \"host_or_testbench_stage_injection\",\n"
        << "  \"note\": \"Replace the two exchanges with the confirmed "
           "cross-SMC RTL path later.\",\n"
        << "  \"exchanges\": [\n"
        << "    {\n"
        << "      \"after_phase\": \"local_max\",\n"
        << "      \"collect\": {\"bank\": 2, \"addr\": 0, "
           "\"operation\": \"max\"},\n"
        << "      \"local_values\": [";
    for (size_t i = 0; i < result.local_max.size(); ++i) {
        if (i != 0) {
            out << ", ";
        }
        write_json_float(result.local_max[i]);
    }
    out << "],\n"
        << "      \"result\": ";
    write_json_float(result.global_max);
    out << ",\n"
        << "      \"broadcast\": {\"bank\": 2, \"addr\": 1}\n"
        << "    },\n"
        << "    {\n"
        << "      \"after_phase\": \"exp_local_sum\",\n"
        << "      \"collect\": {\"bank\": 2, \"addr\": 2, "
           "\"operation\": \"sum\"},\n"
        << "      \"local_values\": [";
    for (size_t i = 0; i < result.local_sum.size(); ++i) {
        if (i != 0) {
            out << ", ";
        }
        write_json_float(result.local_sum[i]);
    }
    out << "],\n"
        << "      \"global_sum\": ";
    write_json_float(result.global_sum);
    out << ",\n"
        << "      \"inv_sum\": ";
    write_json_float(result.inv_sum);
    out << ",\n"
        << "      \"broadcast\": {\"bank\": 2, \"global_sum_addr\": 3, "
           "\"inv_sum_addr\": 4}\n"
        << "    }\n"
        << "  ]\n"
        << "}\n";
}

void write_phase_program_json(const std::string& root,
                              const CompileResult& result) {
    std::ofstream out(join_path(root, "phase_program.json"));
    if (!out) {
        throw std::runtime_error("failed to write phase_program.json");
    }
    out << "{\n"
        << "  \"phases\": [\n"
        << "    {\"id\": 1, \"name\": \"local_max\", "
           "\"per_element\": \"bank2[0] = max(bank2[0], bank5[i])\", "
           "\"units\": [\"UR\", \"FPADD_STATUS\", \"LOGICAL_SELECT_GREAT\"]},\n"
        << "    {\"id\": 2, \"name\": \"global_max_exchange\", "
           "\"external_exchange\": true},\n"
        << "    {\"id\": 3, \"name\": \"exp_local_sum\", "
           "\"per_element\": \"bank1[i] = exp(bank0[i] - bank2[1]); "
           "bank2[2] += bank1[i]\", "
           "\"units\": [\"UR\", \"FPADD\", \"EXP\", \"FPADD\"]},\n"
        << "    {\"id\": 4, \"name\": \"global_sum_inv_exchange\", "
           "\"external_exchange\": true, "
           "\"reciprocal\": \"inv_sum = 1 / global_sum\"},\n"
        << "    {\"id\": 5, \"name\": \"normalize\", "
           "\"per_element\": \"bank3[i] = bank1[i] * bank2[4]\", "
           "\"units\": [\"UR\", \"FPMUL\", \"UR\"]}\n"
        << "  ],\n"
        << "  \"local_max_iq_schedule\": {\n"
        << "    \"period_cycles\": 14,\n"
        << "    \"iterations\": ";
    uint32_t local_max_steps = 0;
    for (const LocalTilePlan& tile : result.tiles) {
        local_max_steps = std::max(local_max_steps, tile.elems);
    }
    out << local_max_steps << ",\n"
        << "    \"cycles\": [\n"
        << "      {\"cycle\": 0, \"action\": \"read bank5[i] and bank2[0]\"},\n"
        << "      {\"cycle\": 2, \"action\": \"route operands to FPADD\"},\n"
        << "      {\"cycle\": 3, \"action\": \"FPADD compare/update status\"},\n"
        << "      {\"cycle\": 5, \"action\": \"reread bank5[i] and bank2[0]\"},\n"
        << "      {\"cycle\": 7, \"action\": \"route operands/status to LOGICAL\"},\n"
        << "      {\"cycle\": 8, \"action\": \"LOGICAL SELECT_GREAT\"},\n"
        << "      {\"cycle\": 9, \"action\": \"route LOGICAL result to UR write\"},\n"
        << "      {\"cycle\": 10, \"action\": \"write bank2[0]\"}\n"
        << "    ]\n"
        << "  },\n"
        << "  \"loop_counts\": [\n";
    for (size_t i = 0; i < result.tiles.size(); ++i) {
        out << "    {\"smc_id\": " << i
            << ", \"valid_elements\": " << result.tiles[i].elems << "}";
        if (i + 1 != result.tiles.size()) {
            out << ',';
        }
        out << '\n';
    }
    out << "  ]\n"
        << "}\n";
}

#ifdef SOFTMAX_STANDALONE
std::vector<uint32_t> parse_split(const std::string& text) {
    std::vector<uint32_t> split;
    std::stringstream stream(text);
    std::string item;
    while (std::getline(stream, item, ',')) {
        if (item.empty()) {
            throw std::invalid_argument("split contains an empty item");
        }
        split.push_back(static_cast<uint32_t>(std::stoul(item)));
    }
    return split;
}

CompileOptions parse_args(int argc, char** argv, std::string& output_dir) {
    CompileOptions options;
    output_dir = "out/softmax";
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto value = [&]() -> std::string {
            if (i + 1 >= argc) {
                throw std::invalid_argument("missing value for " + arg);
            }
            return argv[++i];
        };

        if (arg == "--help" || arg == "-h") {
            std::cout
                << "Usage: " << argv[0]
                << " [--d3 D3] [--d2 D2] [--d1 D1] [--d0 D0]"
                << " [--smc-num 8]"
                << " [--split E0,E1,...,E7] [--seed S]"
                << " [--row-id ROW]"
                << " [--output DIR]\n";
            std::exit(0);
        } else if (arg == "--d3") {
            options.d3 = static_cast<uint32_t>(std::stoul(value()));
        } else if (arg == "--d2") {
            options.d2 = static_cast<uint32_t>(std::stoul(value()));
        } else if (arg == "--d1") {
            options.d1 = static_cast<uint32_t>(std::stoul(value()));
        } else if (arg == "--d0") {
            options.d0 = static_cast<uint32_t>(std::stoul(value()));
        } else if (arg == "--smc-num") {
            options.smc_num = static_cast<uint32_t>(std::stoul(value()));
        } else if (arg == "--split") {
            options.split_elems = parse_split(value());
        } else if (arg == "--seed") {
            options.seed = static_cast<uint32_t>(std::stoul(value()));
        } else if (arg == "--row-id") {
            options.row_id = static_cast<uint32_t>(std::stoul(value()));
        } else if (arg == "--output") {
            output_dir = value();
        } else {
            throw std::invalid_argument("unknown argument: " + arg);
        }
    }
    return options;
}
#endif

} // namespace

CompileResult compile_softmax(const CompileOptions& options) {
    std::vector<uint32_t> split;
    if (options.split_elems.empty()) {
        split = make_even_split(options.d0, options.smc_num);
    } else {
        split = options.split_elems;
    }
    validate_options(options, split);

    CompileResult result;
    result.options = options;
    result.options.split_elems = split;
    result.tiles = make_tiles(split);
    result.local_max.assign(options.smc_num,
                            -std::numeric_limits<float>::infinity());
    result.local_sum.assign(options.smc_num, 0.0f);

    std::mt19937 rng(options.seed);
    std::uniform_real_distribution<float> distribution(-8.0f, 8.0f);
    result.input.resize(options.total_elements());
    for (float& value : result.input) {
        value = distribution(rng);
    }
    result.golden.assign(options.total_elements(), 0.0f);
    for (uint32_t row = 0; row < options.row_count(); ++row) {
        const size_t row_base = static_cast<size_t>(row) * options.d0;
        float row_max = -std::numeric_limits<float>::infinity();
        for (uint32_t i = 0; i < options.d0; ++i) {
            row_max = std::max(row_max, result.input[row_base + i]);
        }
        float row_sum = 0.0f;
        for (uint32_t i = 0; i < options.d0; ++i) {
            const float value = std::exp(result.input[row_base + i] - row_max);
            result.golden[row_base + i] = value;
            row_sum += value;
        }
        const float inv_row_sum = row_sum == 0.0f ? 0.0f : 1.0f / row_sum;
        for (uint32_t i = 0; i < options.d0; ++i) {
            result.golden[row_base + i] *= inv_row_sum;
        }
    }

    result.initial.resize(options.smc_num);
    const size_t selected_row_base =
        static_cast<size_t>(options.row_id) * options.d0;
    uint32_t local_max_steps = 0;
    for (const LocalTilePlan& tile : result.tiles) {
        local_max_steps = std::max(local_max_steps, tile.elems);
    }
    for (size_t smc = 0; smc < result.tiles.size(); ++smc) {
        UrBundle ur = make_empty_ur();
        const LocalTilePlan& tile = result.tiles[smc];
        for (uint32_t i = 0; i < tile.elems; ++i) {
            const float value =
                result.input[selected_row_base + tile.elem_offset + i];
            write_fp32_element(
                ur.banks[kInputBank], i, value);
            write_fp32_broadcast_word(
                ur.banks[kMaxInputBank], i, value);
        }
        for (uint32_t i = tile.elems; i < local_max_steps; ++i) {
            write_fp32_broadcast_word(
                ur.banks[kMaxInputBank], i,
                -std::numeric_limits<float>::infinity());
        }
        write_fp32_broadcast_word(
            ur.banks[kScratchBank],
            scratch_addr(ScratchAddr::LOCAL_MAX),
            -std::numeric_limits<float>::infinity());
        write_fp32_broadcast_word(
            ur.banks[kScratchBank],
            scratch_addr(ScratchAddr::LOCAL_SUM), 0.0f);
        write_fp32_broadcast_word(
            ur.banks[kConstantBank],
            constant_addr(ConstantAddr::ZERO), 0.0f);
        write_fp32_broadcast_word(
            ur.banks[kConstantBank],
            constant_addr(ConstantAddr::ONE), 1.0f);
        write_fp32_broadcast_word(
            ur.banks[kConstantBank],
            constant_addr(ConstantAddr::TWO), 2.0f);
        write_fp32_broadcast_word(
            ur.banks[kConstantBank],
            constant_addr(ConstantAddr::NEG_INF),
            -std::numeric_limits<float>::infinity());
        result.initial[smc] = std::move(ur);
    }

    result.after_local_max = result.initial;
    for (size_t smc = 0; smc < result.tiles.size(); ++smc) {
        const LocalTilePlan& tile = result.tiles[smc];
        float local_max = -std::numeric_limits<float>::infinity();
        for (uint32_t i = 0; i < tile.elems; ++i) {
            local_max = std::max(
                local_max,
                read_fp32_element(
                    result.after_local_max[smc].banks[kMaxInputBank], i * 4));
        }
        result.local_max[smc] = local_max;
        write_fp32_broadcast_word(
            result.after_local_max[smc].banks[kScratchBank],
            scratch_addr(ScratchAddr::LOCAL_MAX), local_max);
    }

    result.global_max = -std::numeric_limits<float>::infinity();
    for (float value : result.local_max) {
        result.global_max = std::max(result.global_max, value);
    }
    result.after_global_max = result.after_local_max;
    for (UrBundle& ur : result.after_global_max) {
        write_fp32_broadcast_word(
            ur.banks[kScratchBank],
            scratch_addr(ScratchAddr::GLOBAL_MAX),
            result.global_max);
    }

    result.after_exp_local_sum = result.after_global_max;
    for (size_t smc = 0; smc < result.tiles.size(); ++smc) {
        const LocalTilePlan& tile = result.tiles[smc];
        float local_sum = 0.0f;
        for (uint32_t i = 0; i < tile.elems; ++i) {
            const float input =
                read_fp32_element(
                    result.after_exp_local_sum[smc].banks[kInputBank], i);
            const float exp_value = std::exp(input - result.global_max);
            write_fp32_element(
                result.after_exp_local_sum[smc].banks[kExpBank], i,
                exp_value);
            local_sum += exp_value;
        }
        result.local_sum[smc] = local_sum;
        write_fp32_broadcast_word(
            result.after_exp_local_sum[smc].banks[kScratchBank],
            scratch_addr(ScratchAddr::LOCAL_SUM), local_sum);
    }

    result.global_sum = 0.0f;
    for (float value : result.local_sum) {
        result.global_sum += value;
    }
    result.inv_sum =
        result.global_sum == 0.0f ? 0.0f : 1.0f / result.global_sum;

    result.after_inv_sum = result.after_exp_local_sum;
    for (UrBundle& ur : result.after_inv_sum) {
        write_fp32_broadcast_word(
            ur.banks[kScratchBank],
            scratch_addr(ScratchAddr::GLOBAL_SUM),
            result.global_sum);
        write_fp32_broadcast_word(
            ur.banks[kScratchBank],
            scratch_addr(ScratchAddr::INV_SUM), result.inv_sum);
    }

    result.after_normalize = result.after_inv_sum;
    for (size_t smc = 0; smc < result.tiles.size(); ++smc) {
        const LocalTilePlan& tile = result.tiles[smc];
        for (uint32_t i = 0; i < tile.elems; ++i) {
            const float exp_value =
                read_fp32_element(
                    result.after_normalize[smc].banks[kExpBank], i);
            const float output = exp_value * result.inv_sum;
            write_fp32_element(
                result.after_normalize[smc].banks[kOutputBank], i,
                output);
            const float expected =
                result.golden[selected_row_base + tile.elem_offset + i];
            if (std::fabs(output - expected) > 2e-6f) {
                throw std::runtime_error(
                    "selected-row staged output does not match golden");
            }
        }
    }

    return result;
}

void write_softmax_case(const std::string& output_dir,
                        const CompileResult& result) {
    if (output_dir.empty()) {
        throw std::invalid_argument("output directory cannot be empty");
    }
    const std::string root = output_dir;
    make_dirs(root);

    write_binary_floats(join_path(root, "input.bin"), result.input);
    write_binary_floats(join_path(root, "golden.bin"), result.golden);
    write_config_json(root, result);
    write_exchange_json(root, result);
    write_phase_program_json(root, result);

    write_ur_snapshot(join_path(root, "phase_0_initial"), result.initial);
    write_ur_snapshot(join_path(root, "phase_1_after_local_max"),
                      result.after_local_max);
    write_ur_snapshot(join_path(root, "phase_2_after_global_max"),
                      result.after_global_max);
    write_ur_snapshot(join_path(root, "phase_3_after_exp_local_sum"),
                      result.after_exp_local_sum);
    write_ur_snapshot(join_path(root, "phase_4_after_inv_sum"),
                      result.after_inv_sum);
    write_ur_snapshot(join_path(root, "phase_5_after_normalize"),
                      result.after_normalize);
    write_local_output(
        join_path(root, "phase_5_after_normalize"), result);
}

#ifdef SOFTMAX_STANDALONE
int run_standalone(int argc, char** argv) {
    std::string output_dir;
    const CompileOptions options = parse_args(argc, argv, output_dir);
    const CompileResult result = compile_softmax(options);
    write_softmax_case(output_dir, result);

    std::cout << std::setprecision(9)
              << "[OK] 8-SMC softmax case generated\n"
              << "     output: " << output_dir << '\n'
              << "     shape: ["
              << options.d3 << ", " << options.d2 << ", "
              << options.d1 << ", " << options.d0 << "]\n"
              << "     selected_row: " << options.row_id
              << " / " << options.row_count() << '\n'
              << "     global_max: " << result.global_max << '\n'
              << "     global_sum: " << result.global_sum << '\n'
              << "     inv_sum: " << result.inv_sum << '\n';
    return 0;
}
#endif

} // namespace softmax
} // namespace op
} // namespace aiacc

#ifdef SOFTMAX_STANDALONE
int main(int argc, char** argv) {
    try {
        return aiacc::op::softmax::run_standalone(
            argc, argv);
    } catch (const std::exception& error) {
        std::cerr << "[ERROR] " << error.what() << '\n';
        return 1;
    }
}
#endif
