#include "add_lsu_op.h"

#include <algorithm>
#include <cstring>

#include "../../app/fp16_utils.h"

namespace aiacc {
namespace lsu {

LsuComputeDesc AddLsuOp::default_compute_desc() {
    LsuComputeDesc d;
    d.inputs["alpha"] = {2, 0, 1};
    d.inputs["input"] = {0, 0, 255};
    d.inputs["other"] = {1, 0, 255};
    d.output = {3, 0, 255};
    d.num_smc = 8;
    d.smc_id_en = 7;
    d.gr_intlv_addr = 0x10000000ULL;
    return d;
}

std::vector<op::IqInstructionFile> AddLsuOp::generate_compute_iq_files() const {
    const auto input_it = desc_.inputs.find("input");
    const auto other_it = desc_.inputs.find("other");
    const auto alpha_it = desc_.inputs.find("alpha");
    if (input_it == desc_.inputs.end() ||
        other_it == desc_.inputs.end() ||
        alpha_it == desc_.inputs.end()) {
        return {};
    }

    op::AddOpParams params;
    params.para_n = compute_config_.n;
    params.para_c = compute_config_.c;
    params.para_h = compute_config_.h;
    params.para_w = compute_config_.w;
    params.para_dtype = compute_config_.dtype;
    params.para_other_broadcast = compute_config_.other_broadcast;
    if (params.para_w == 0) {
        params.para_w = desc_.output.word_count * 4;
        params.para_dtype = op::AddDataType::FP32;
    }

    params.para_input_bank = input_it->second.bank;
    params.para_input_addr = static_cast<uint8_t>(input_it->second.word_offset);
    params.para_other_bank = other_it->second.bank;
    params.para_other_addr = static_cast<uint8_t>(other_it->second.word_offset);
    params.para_alpha_bank = alpha_it->second.bank;
    params.para_alpha_addr = static_cast<uint8_t>(alpha_it->second.word_offset);
    params.para_output_bank = desc_.output.bank;
    params.para_output_addr = static_cast<uint8_t>(desc_.output.word_offset);

    op::AddOp add_op;
    auto insts = add_op.compile(params);
    return insts.get_iq_files();
}

void AddLsuOp::generate_golden_for_smc(
    uint8_t /*smc_id*/,
    const std::map<std::string, std::vector<uint8_t>>& input_datas,
    std::vector<uint8_t>& golden_out) const {

    const auto input_it = input_datas.find("input");
    const auto other_it = input_datas.find("other");
    const auto alpha_it = input_datas.find("alpha");
    if (input_it == input_datas.end() ||
        other_it == input_datas.end() ||
        alpha_it == input_datas.end() ||
        alpha_it->second.size() < 16) {
        golden_out.clear();
        return;
    }

    const auto& input = input_it->second;
    const auto& other = other_it->second;
    const auto& alpha = alpha_it->second;

    if (compute_config_.dtype == op::AddDataType::FP16 && compute_config_.w != 0) {
        constexpr uint32_t kFp16PerUrWord = 8;
        const uint32_t num_fp16 = compute_config_.other_broadcast
            ? static_cast<uint32_t>(input.size() / sizeof(uint16_t))
            : static_cast<uint32_t>(std::min(input.size(), other.size()) / sizeof(uint16_t));
        golden_out.resize(num_fp16 * sizeof(uint16_t));
        for (uint32_t i = 0; i < num_fp16; ++i) {
            uint16_t input_bits = 0;
            uint16_t other_bits = 0;
            uint16_t alpha_bits = 0;
            const uint32_t other_index = compute_config_.other_broadcast ? 0 : i;
            std::memcpy(&input_bits, input.data() + i * sizeof(uint16_t), sizeof(uint16_t));
            std::memcpy(&other_bits,
                        other.data() + other_index * sizeof(uint16_t),
                        sizeof(uint16_t));
            std::memcpy(&alpha_bits,
                        alpha.data() + (i % kFp16PerUrWord) * sizeof(uint16_t),
                        sizeof(uint16_t));
            const float result = app::float16_to_float32(input_bits) +
                                 app::float16_to_float32(alpha_bits) *
                                     app::float16_to_float32(other_bits);
            const uint16_t result_bits = app::float32_to_float16(result);
            std::memcpy(golden_out.data() + i * sizeof(uint16_t),
                        &result_bits,
                        sizeof(uint16_t));
        }
        return;
    }

    const uint32_t num_fp32 = compute_config_.other_broadcast
        ? static_cast<uint32_t>(input.size() / sizeof(float))
        : static_cast<uint32_t>(std::min(input.size(), other.size()) / sizeof(float));
    constexpr uint32_t kFp32PerUrWord = 4;
    golden_out.resize(num_fp32 * sizeof(float));
    for (uint32_t i = 0; i < num_fp32; ++i) {
        float input_value = 0.0f;
        float other_value = 0.0f;
        float alpha_value = 0.0f;
        const uint32_t other_index = compute_config_.other_broadcast ? 0 : i;
        std::memcpy(&input_value, input.data() + i * sizeof(float), sizeof(float));
        std::memcpy(&other_value, other.data() + other_index * sizeof(float), sizeof(float));
        std::memcpy(&alpha_value,
                    alpha.data() + (i % kFp32PerUrWord) * sizeof(float),
                    sizeof(float));

        volatile float scaled = alpha_value * other_value;
        const float result = input_value + scaled;
        std::memcpy(golden_out.data() + i * sizeof(float), &result, sizeof(float));
    }
}

} // namespace lsu
} // namespace aiacc
