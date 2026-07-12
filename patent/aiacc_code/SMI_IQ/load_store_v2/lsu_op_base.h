#ifndef LSU_OP_BASE_V2_H
#define LSU_OP_BASE_V2_H

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "../op/common/lsu_emit.h"
#include "../op/common/op_instructions_base.h"

namespace aiacc {
namespace lsu {

struct PortInfo {
    uint8_t bank{0};
    uint16_t word_offset{0};
    uint16_t word_count{255};
};

struct LsuComputeDesc {
    std::map<std::string, PortInfo> inputs;
    PortInfo output;

    uint8_t num_smc{8};
    uint8_t smc_id_en{7};
    uint64_t gr_intlv_addr{0x10000000ULL};
};

struct LsuCaseConfig {
    std::string case_name;
    std::string case_root;
    std::string hbm_init_dir;
    uint32_t seed_base{42};
};

class LsuOpBase {
public:
    virtual ~LsuOpBase() = default;

    void set_compute_desc(const LsuComputeDesc& desc) { desc_ = desc; }
    void set_case_config(const LsuCaseConfig& cfg) { cfg_ = cfg; }

    op::LsuLoadParams build_load_params(uint8_t bank, uint16_t word_offset,
                                        uint16_t word_count, uint64_t gr_base) const;
    op::LsuStoreParams build_store_params(uint8_t bank, uint16_t word_offset,
                                          uint16_t word_count, uint64_t gr_base) const;

    std::vector<op::IqInstructionFile> generate_load_iq_files() const;
    std::vector<op::IqInstructionFile> generate_store_iq_files() const;

    virtual std::vector<op::IqInstructionFile> generate_compute_iq_files() const = 0;

    virtual void generate_golden_for_smc(
        uint8_t smc_id,
        const std::map<std::string, std::vector<uint8_t>>& input_datas,
        std::vector<uint8_t>& golden_out) const = 0;

    void generate_hbm_data(uint8_t smc_id, uint32_t seed,
                           std::vector<uint8_t>& hbm_bytes) const;

    bool assemble_full_case() const;

    virtual std::string get_name() const = 0;

protected:
    LsuComputeDesc desc_;
    LsuCaseConfig cfg_;

    static uint16_t compose_ur_addr(uint8_t bank, uint16_t word_addr);
    uint16_t calc_ldb_loops(uint16_t word_count) const;
    uint8_t calc_ldbaxi_loops(uint16_t word_count) const;
    uint32_t total_input_words() const;
    uint64_t input_gr_base(const std::string& name) const;
    uint64_t store_gr_base() const;
};

} // namespace lsu
} // namespace aiacc

#endif // LSU_OP_BASE_V2_H
