#include "lsu_op_base.h"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>

namespace aiacc {
namespace lsu {

uint16_t LsuOpBase::compose_ur_addr(uint8_t bank, uint16_t word_addr) {
    return static_cast<uint16_t>(((bank & 0x7u) << 12) | ((word_addr & 0xFFu) << 4));
}

uint16_t LsuOpBase::calc_ldb_loops(uint16_t word_count) const {
    return (word_count > 0) ? static_cast<uint16_t>(word_count - 1) : 0;
}

uint8_t LsuOpBase::calc_ldbaxi_loops(uint16_t word_count) const {
    uint32_t bursts = (word_count + 15) / 16;
    return static_cast<uint8_t>((bursts > 0) ? (bursts - 1) : 0);
}

uint32_t LsuOpBase::total_input_words() const {
    uint32_t total = 0;
    for (auto& [name, port] : desc_.inputs) {
        total += port.word_count;
    }
    return total;
}

uint64_t LsuOpBase::input_gr_base(const std::string& name) const {
    uint64_t offset = 0;
    for (auto& [n, port] : desc_.inputs) {
        if (n == name) return offset;
        offset += static_cast<uint64_t>(port.word_count + 1) * 16;
    }
    return offset;
}

uint64_t LsuOpBase::store_gr_base() const {
    uint64_t offset = 0;
    for (auto& [name, port] : desc_.inputs) {
        offset += static_cast<uint64_t>(port.word_count + 1) * 16;
    }
    return offset;
}

op::LsuLoadParams LsuOpBase::build_load_params(uint8_t bank, uint16_t word_offset,
                                                uint16_t word_count, uint64_t gr_base) const {
    op::LsuLoadParams p{};
    p.para_ur_addr = compose_ur_addr(bank, word_offset);
    p.para_ldb_loops = calc_ldb_loops(word_count);
    p.para_ldbaxi_loops = calc_ldbaxi_loops(word_count);
    p.para_brst = 0x0F;
    p.para_line_byte_cnt = 0x0F;
    p.para_line_stride = 1;
    p.para_smc_id_en = desc_.smc_id_en;
    p.para_gr_base_addr = gr_base;
    p.para_gr_intlv_addr = desc_.gr_intlv_addr;
    p.para_ldb_inc = 0x0010;
    p.para_ldbaxi_inc = 0x0100;
    p.para_ldb_vld = true;
    p.para_ldbaxi_vld = true;
    return p;
}

op::LsuStoreParams LsuOpBase::build_store_params(uint8_t bank, uint16_t word_offset,
                                                  uint16_t word_count, uint64_t gr_base) const {
    op::LsuStoreParams p{};
    p.para_ur_addr = compose_ur_addr(bank, word_offset);
    p.para_stb_loops = calc_ldb_loops(word_count);
    p.para_stbaxi_loops = calc_ldbaxi_loops(word_count);
    p.para_brst = 0x0F;
    p.para_line_byte_cnt = 0x0F;
    p.para_line_stride = 1;
    p.para_smc_id_en = desc_.smc_id_en;
    p.para_gr_base_addr = gr_base;
    p.para_gr_intlv_addr = desc_.gr_intlv_addr;
    p.para_stb_inc = 0x0010;
    p.para_stbaxi_inc = 0x0100;
    p.para_stb_vld = true;
    p.para_stbaxi_vld = true;
    p.para_tid = 2;
    return p;
}

std::vector<op::IqInstructionFile> LsuOpBase::generate_load_iq_files() const {
    std::vector<op::IqInstructionFile> all;
    for (auto& [name, port] : desc_.inputs) {
        uint64_t gr_base = input_gr_base(name);
        auto p = build_load_params(port.bank, port.word_offset, port.word_count, gr_base);
        auto files = op::emit_load_iq_files(p);
        for (auto& f : files) all.push_back(std::move(f));
    }
    return all;
}

std::vector<op::IqInstructionFile> LsuOpBase::generate_store_iq_files() const {
    auto p = build_store_params(desc_.output.bank, desc_.output.word_offset,
                                desc_.output.word_count, store_gr_base());
    return op::emit_store_iq_files(p);
}

void LsuOpBase::generate_hbm_data(uint8_t smc_id, uint32_t seed,
                                   std::vector<uint8_t>& hbm_bytes) const {
    std::mt19937 rng(seed + smc_id * 1000);
    std::uniform_real_distribution<float> dist(0.5f, 2.0f);

    // Contiguous: all input segments back-to-back, no gap in HBM data
    // gr_base for segment N = sum of (prev_word_count + 1) * 16
    // This +1 is an addressing offset, NOT a gap in data
    uint32_t total_words = 0;
    for (auto& [name, port] : desc_.inputs) {
        total_words += port.word_count;
    }

    hbm_bytes.resize(total_words * 16, 0);

    for (uint32_t i = 0; i < total_words * 4; ++i) {
        float val = dist(rng);
        uint32_t bits;
        std::memcpy(&bits, &val, 4);
        uint32_t byte_off = i * 4;
        hbm_bytes[byte_off + 0] = static_cast<uint8_t>(bits & 0xFF);
        hbm_bytes[byte_off + 1] = static_cast<uint8_t>((bits >> 8) & 0xFF);
        hbm_bytes[byte_off + 2] = static_cast<uint8_t>((bits >> 16) & 0xFF);
        hbm_bytes[byte_off + 3] = static_cast<uint8_t>((bits >> 24) & 0xFF);
    }
}

static void mkdir_p(const std::string& path) {
    (void)system((std::string("mkdir -p \"") + path + "\"").c_str());
}

static void write_hex_file(const std::string& path, const std::vector<uint8_t>& data,
                           uint32_t line_width_bytes) {
    std::ofstream ofs(path);
    if (!ofs) return;
    uint32_t lines = static_cast<uint32_t>(data.size()) / line_width_bytes;
    for (uint32_t l = 0; l < lines; ++l) {
        for (int b = static_cast<int>(line_width_bytes) - 1; b >= 0; --b) {
            uint8_t byte = data[l * line_width_bytes + b];
            ofs << std::hex << std::setfill('0') << std::setw(2)
                << static_cast<unsigned>(byte);
        }
        ofs << "\n";
    }
}

static void write_zero_bank(const std::string& path, uint32_t lines) {
    std::ofstream ofs(path);
    if (!ofs) return;
    std::string zero_line(32, '0');
    for (uint32_t i = 0; i < lines; ++i) {
        ofs << zero_line << "\n";
    }
}

static std::string iq_filename_from_name(uint32_t /*id*/, const std::string& raw_name) {
    if (raw_name == "ldbaxi") return "ldb_axi";
    if (raw_name == "stbaxi") return "stb_axi";
    if (raw_name == "ur_rdata_0") return "ur-r0";
    if (raw_name == "ur_rdata_1") return "ur-r1";
    if (raw_name == "ur_rdata_2") return "ur-r2";
    if (raw_name == "ur_rdata_3") return "ur-r3";
    if (raw_name == "ur_wdata_0") return "ur-w0";
    if (raw_name == "ur_wdata_1") return "ur-w1";
    if (raw_name == "ur_wdata_2") return "ur-w2";
    if (raw_name == "ur_wdata_3") return "ur-w3";
    return raw_name;
}

bool LsuOpBase::assemble_full_case() const {
    const std::string case_root = cfg_.case_root;

    auto load_iqs = generate_load_iq_files();
    auto compute_iqs = generate_compute_iq_files();
    auto store_iqs = generate_store_iq_files();

    for (uint8_t smc = 0; smc < desc_.num_smc; ++smc) {
        std::string smc_dir = case_root + "/smc_" + std::to_string(smc);
        mkdir_p(smc_dir + "/ur_data");
        mkdir_p(smc_dir + "/output_bank");

        for (int b = 0; b < 8; ++b) {
            write_zero_bank(smc_dir + "/ur_data/bank" + std::to_string(b) + ".hex", 256);
        }

        if (smc == 0) {
            struct IqFileEntry {
                std::vector<uint8_t> data;
                uint32_t width_bits{0};
            };
            std::map<std::string, IqFileEntry> file_map;

            auto collect_iq = [&](const std::vector<op::IqInstructionFile>& files) {
                for (auto& f : files) {
                    std::string fname = iq_filename_from_name(f.para_iq_id, f.para_iq_name);
                    auto& entry = file_map[fname];
                    entry.data.insert(entry.data.end(), f.para_data.begin(), f.para_data.end());
                    if (entry.width_bits == 0) entry.width_bits = f.para_width_bits;
                }
            };
            collect_iq(load_iqs);
            collect_iq(compute_iqs);
            collect_iq(store_iqs);

            for (auto& [fname, entry] : file_map) {
                std::string path = smc_dir + "/iq_" + fname + ".hex";
                std::ofstream ofs(path);
                if (!ofs) continue;
                uint32_t inst_bytes = (entry.width_bits + 7) / 8;
                if (inst_bytes == 0) inst_bytes = static_cast<uint32_t>(entry.data.size());
                uint32_t num_insts = static_cast<uint32_t>(entry.data.size()) / inst_bytes;
                for (uint32_t n = 0; n < num_insts; ++n) {
                    for (uint32_t b = 0; b < inst_bytes; ++b) {
                        ofs << std::hex << std::setfill('0') << std::setw(2)
                            << static_cast<unsigned>(entry.data[n * inst_bytes + b]);
                    }
                    ofs << "\n";
                }
            }
        }

        std::vector<uint8_t> hbm_data;
        generate_hbm_data(smc, cfg_.seed_base, hbm_data);

        std::string hbm_path = cfg_.hbm_init_dir + "/memory_init" + std::to_string(smc + 1) + ".hex";
        write_hex_file(hbm_path, hbm_data, 16);

        // Extract input data segments contiguously (same as how HBM was generated)
        std::map<std::string, std::vector<uint8_t>> input_datas;
        uint32_t byte_offset = 0;
        for (auto& [name, port] : desc_.inputs) {
            uint32_t data_bytes = port.word_count * 16;
            input_datas[name] = std::vector<uint8_t>(
                hbm_data.begin() + byte_offset,
                hbm_data.begin() + byte_offset + data_bytes);
            byte_offset += data_bytes;
        }

        std::vector<uint8_t> golden;
        generate_golden_for_smc(smc, input_datas, golden);

        const uint32_t ur_bank_depth = 256;
        if (golden.size() / 16 < ur_bank_depth) {
            golden.resize(ur_bank_depth * 16, 0);
        }

        write_hex_file(smc_dir + "/output_bank/bank" + std::to_string(desc_.output.bank) + "_final.hex",
                       golden, 16);
    }

    std::cout << "[LsuOpBase] Case assembled: " << case_root << " ("
              << static_cast<int>(desc_.num_smc) << " SMCs)" << std::endl;
    return true;
}

} // namespace lsu
} // namespace aiacc
