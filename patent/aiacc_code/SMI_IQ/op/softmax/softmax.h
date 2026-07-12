#ifndef SOFTMAX_H
#define SOFTMAX_H

/**
 * @file softmax.h
 * @brief Row-wise FP32 softmax for an NCHW-shaped tensor.
 *
 * Current hardware stage:
 * - Reduces the last dimension (d0/W).
 * - Splits one row evenly across 8 SMCs.
 * - Generates the UR -> FPADD status -> LOGICAL SELECT_GREAT -> UR
 *   local-maximum instruction schedule.
 * - Uses bank5 as expanded four-lane input and bank2 as scalar scratch.
 */

#include <array>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>
#include <random>

#include "../../hal/aiacc_smi_iq.h"
#include "../../iq/modules/ur_iq.h"
#include "../../iq/modules/rtovr_iq.h"
#include "../../iq/modules/fpadd_iq.h"
#include "../../iq/modules/logical_iq.h"
#include "../common/op_instructions_base.h"
#include "../common/op_base.h"
#include "../common/op_registry.h"
#include "../../app/app_json_parser.h"

namespace aiacc {
namespace op {

enum class SoftmaxDataType : uint8_t {
    FP32 = 0,
    FP16 = 1,
};

struct SoftmaxOpParams {
    uint32_t para_n{1};
    uint32_t para_c{1};
    uint32_t para_h{1};
    uint32_t para_w{4};

    SoftmaxDataType para_dtype{SoftmaxDataType::FP32};

    int32_t para_dim{-1};
    bool para_half_to_float{false};

    uint8_t para_input_bank{0};
    uint8_t para_input_addr{0};
    uint8_t para_output_bank{3};
    uint8_t para_output_addr{0};

    uint32_t get_elems_per_word() const {
        return (para_dtype == SoftmaxDataType::FP32) ? 4u : 8u;
    }
};

struct SoftmaxOpInstructions : public OpInstructionsBase {
    std::vector<iq::UrCru> para_ur_read_crus;
    std::vector<iq::UrCru> para_ur_write_crus;

    std::vector<std::pair<uint8_t, uint8_t>> para_rtovr_routes;
    uint16_t para_fpadd_inst{0};
    uint8_t para_logical_inst{0};

    SoftmaxDataType para_dtype{SoftmaxDataType::FP32};
    int32_t para_dim{-1};
    bool para_half_to_float{false};

    uint32_t para_row_count{0};
    uint32_t para_total_steps{0};
    uint32_t para_total_elements{0};

    std::vector<IqInstructionFile> get_iq_files() const override;
    std::string get_operator_name() const override { return "Softmax"; }
    uint32_t get_total_steps() const override { return para_total_steps; }
    uint32_t get_total_elements() const override { return para_total_elements; }
    std::vector<uint8_t> serialize() const override;
};

class SoftmaxOp : public OpBase {
public:
    SoftmaxOp() = default;
    ~SoftmaxOp() = default;

    std::string get_name() const override;
    OpInstructionsBase* compile(const app::AppOperatorRequest& req) override;
    bool calculate_golden(const app::AppOperatorRequest& req,
                          std::vector<uint8_t>& golden_bin) override;
    bool generate_data(const app::AppOperatorRequest& req,
                       std::vector<uint8_t>& input_bin,
                       std::vector<uint8_t>& other_bin,
                       std::vector<uint8_t>& alpha_bin) override;
    void fill_random_request(app::AppOperatorRequest& req,
                             std::mt19937& rng,
                             std::uniform_real_distribution<float>& data_dist,
                             const std::string& dtype_str) override;

    SoftmaxOpInstructions compile(const SoftmaxOpParams& params);

private:
    static bool parse_i32_param(const app::AppOperatorRequest& req,
                                const std::string& key,
                                int32_t& out);
};

namespace softmax {

constexpr uint32_t kSmcCount = 8;
constexpr uint32_t kUrBankCount = 8;
constexpr uint32_t kUrBankDepthWords = 256;
constexpr uint32_t kUrWordBytes = 16;

enum class ScratchAddr : uint32_t {
    LOCAL_MAX = 0,
    GLOBAL_MAX = 1,
    LOCAL_SUM = 2,
    GLOBAL_SUM = 3,
    INV_SUM = 4,
};

enum class ConstantAddr : uint32_t {
    ZERO = 0,
    ONE = 1,
    TWO = 2,
    NEG_INF = 3,
};

struct CompileOptions {
    uint32_t d3{1};
    uint32_t d2{32};
    uint32_t d1{1};
    uint32_t d0{1148};
    uint32_t smc_num{kSmcCount};
    uint32_t seed{1};
    uint32_t row_id{0};
    std::vector<uint32_t> split_elems{};

    uint32_t total_elements() const {
        return d3 * d2 * d1 * d0;
    }

    uint32_t row_count() const {
        return d3 * d2 * d1;
    }
};

struct LocalTilePlan {
    uint8_t smc_id{0};
    // Offset and element count within the selected d0 row.
    uint32_t elem_offset{0};
    uint32_t elems{0};
};

struct UrBundle {
    std::array<std::vector<uint8_t>, kUrBankCount> banks{};
};

struct CompileResult {
    CompileOptions options{};
    std::vector<LocalTilePlan> tiles{};
    std::vector<float> input{};
    std::vector<float> golden{};
    std::vector<float> local_max{};
    std::vector<float> local_sum{};
    float global_max{0.0f};
    float global_sum{0.0f};
    float inv_sum{0.0f};

    std::vector<UrBundle> initial{};
    std::vector<UrBundle> after_local_max{};
    std::vector<UrBundle> after_global_max{};
    std::vector<UrBundle> after_exp_local_sum{};
    std::vector<UrBundle> after_inv_sum{};
    std::vector<UrBundle> after_normalize{};
};

CompileResult compile_softmax(const CompileOptions& options);
void write_softmax_case(const std::string& output_dir,
                        const CompileResult& result);

} // namespace softmax

} // namespace op
} // namespace aiacc

#endif // SOFTMAX_H
