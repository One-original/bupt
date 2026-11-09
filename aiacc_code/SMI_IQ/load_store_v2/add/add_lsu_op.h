#ifndef ADD_LSU_OP_V2_H
#define ADD_LSU_OP_V2_H

#include "../lsu_op_base.h"
#include "../../op/add/add_op.h"

namespace aiacc {
namespace lsu {

struct AddLsuComputeConfig {
    op::AddDataType dtype{op::AddDataType::FP32};
    uint32_t n{1};
    uint32_t c{1};
    uint32_t h{1};
    uint32_t w{0};
    bool other_broadcast{false};
};

class AddLsuOp : public LsuOpBase {
public:
    AddLsuOp() = default;
    ~AddLsuOp() override = default;

    std::string get_name() const override { return "FusedScaleAdd"; }

    std::vector<op::IqInstructionFile> generate_compute_iq_files() const override;

    void generate_golden_for_smc(
        uint8_t smc_id,
        const std::map<std::string, std::vector<uint8_t>>& input_datas,
        std::vector<uint8_t>& golden_out) const override;

    // Capture-driven cases set this before assemble_full_case(). When w is
    // zero, retain the legacy FP32 synthetic-case behavior.
    void set_compute_config(const AddLsuComputeConfig& config) {
        compute_config_ = config;
    }

    static LsuComputeDesc default_compute_desc();

private:
    AddLsuComputeConfig compute_config_{};
};

} // namespace lsu
} // namespace aiacc

#endif // ADD_LSU_OP_V2_H
