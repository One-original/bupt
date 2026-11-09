#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <map>
#include <regex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "add_lsu_op.h"

namespace {

constexpr uint32_t kSmcCount = 8;
constexpr uint32_t kUrBankDepth = 256;
constexpr uint32_t kAxiBurstWords = 16;
constexpr uint32_t kRopeHeads = 32;
constexpr uint32_t kRopeHeadDim = 64;
constexpr uint32_t kRopeHeadsPerSmc = kRopeHeads / kSmcCount;
constexpr uint32_t kFp16Bytes = 2;
constexpr uint32_t kFp32Bytes = 4;

struct CaptureOptions {
    std::string capture_dir;
    std::string capture_kind{"rope"};
    uint32_t tile_start{0};
    uint32_t tile_tokens{1};
};

uint32_t align_up_words(uint32_t words, uint32_t alignment) {
    return ((words + alignment - 1u) / alignment) * alignment;
}

const std::vector<std::string>& add_input_order() {
    static const std::vector<std::string> order = {"input", "other", "alpha"};
    return order;
}

std::vector<uint8_t> read_binary(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("cannot open capture file: " + path.string());
    }
    input.seekg(0, std::ios::end);
    const auto size = input.tellg();
    input.seekg(0, std::ios::beg);
    if (size < 0) {
        throw std::runtime_error("cannot determine capture file size: " + path.string());
    }
    std::vector<uint8_t> data(static_cast<size_t>(size));
    if (!data.empty()) {
        input.read(reinterpret_cast<char*>(data.data()), static_cast<std::streamsize>(data.size()));
    }
    if (!input && !data.empty()) {
        throw std::runtime_error("cannot read capture file: " + path.string());
    }
    return data;
}

std::filesystem::path find_capture_tensor(const std::filesystem::path& capture_dir,
                                          const std::string& suffix) {
    if (!std::filesystem::is_directory(capture_dir)) {
        throw std::runtime_error("capture directory does not exist: " + capture_dir.string());
    }
    for (const auto& entry : std::filesystem::directory_iterator(capture_dir)) {
        if (!entry.is_regular_file()) continue;
        const std::string name = entry.path().filename().string();
        if (name.size() >= suffix.size() &&
            name.compare(name.size() - suffix.size(), suffix.size(), suffix) == 0) {
            return entry.path();
        }
    }
    throw std::runtime_error("capture tensor not found in " + capture_dir.string() + ": *" + suffix);
}

float read_other_scalar(const std::filesystem::path& capture_dir) {
    const auto scalars_path = capture_dir / "scalars.txt";
    std::ifstream input(scalars_path);
    if (!input) {
        throw std::runtime_error("epsilon capture requires scalars.txt with other scalar");
    }
    const std::string text((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());
    const std::regex pattern(
        R"(other[^+\-0-9]*([+\-]?[0-9]*\.?[0-9]+([eE][+\-]?[0-9]+)?))");
    std::smatch match;
    if (!std::regex_search(text, match, pattern)) {
        throw std::runtime_error("cannot parse other scalar from scalars.txt");
    }
    return std::stof(match[1].str());
}

void append_fp32(std::vector<uint8_t>& output, float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    output.push_back(static_cast<uint8_t>(bits & 0xffu));
    output.push_back(static_cast<uint8_t>((bits >> 8) & 0xffu));
    output.push_back(static_cast<uint8_t>((bits >> 16) & 0xffu));
    output.push_back(static_cast<uint8_t>((bits >> 24) & 0xffu));
}

std::vector<uint8_t> make_fp32_word(float value) {
    std::vector<uint8_t> word;
    word.reserve(16);
    for (uint32_t lane = 0; lane < 4; ++lane) append_fp32(word, value);
    return word;
}

void write_hex_lines(const std::filesystem::path& path,
                     const std::vector<uint8_t>& bytes,
                     uint32_t min_lines) {
    std::ofstream output(path, std::ios::trunc);
    if (!output) {
        throw std::runtime_error("cannot write hex file: " + path.string());
    }
    const uint32_t actual_lines = static_cast<uint32_t>((bytes.size() + 15u) / 16u);
    const uint32_t lines = std::max(actual_lines, min_lines);
    for (uint32_t line = 0; line < lines; ++line) {
        for (int byte = 15; byte >= 0; --byte) {
            const size_t index = static_cast<size_t>(line) * 16u + static_cast<size_t>(byte);
            const uint8_t value = index < bytes.size() ? bytes[index] : 0;
            output << std::hex << std::setfill('0') << std::setw(2)
                   << static_cast<unsigned>(value);
        }
        output << '\n';
    }
}

std::vector<uint8_t> pack_rope_tile(const std::vector<uint8_t>& source,
                                    uint32_t smc_id,
                                    uint32_t tile_start,
                                    uint32_t tile_tokens) {
    const uint32_t local_elements = tile_tokens * kRopeHeadsPerSmc * kRopeHeadDim;
    std::vector<uint8_t> packed(static_cast<size_t>(local_elements) * kFp16Bytes);
    size_t destination = 0;
    for (uint32_t token = 0; token < tile_tokens; ++token) {
        for (uint32_t local_head = 0; local_head < kRopeHeadsPerSmc; ++local_head) {
            const uint32_t global_head = smc_id * kRopeHeadsPerSmc + local_head;
            const size_t source_element =
                (static_cast<size_t>(tile_start + token) * kRopeHeads + global_head) *
                kRopeHeadDim;
            const size_t source_byte = source_element * kFp16Bytes;
            const size_t copy_bytes = static_cast<size_t>(kRopeHeadDim) * kFp16Bytes;
            if (source_byte + copy_bytes > source.size()) {
                throw std::runtime_error("capture tensor is smaller than requested RoPE tile");
            }
            std::copy_n(source.begin() + static_cast<std::ptrdiff_t>(source_byte),
                        copy_bytes,
                        packed.begin() + static_cast<std::ptrdiff_t>(destination));
            destination += copy_bytes;
        }
    }
    return packed;
}

std::vector<uint8_t> pack_epsilon_input_tile(const std::vector<uint8_t>& source,
                                             uint32_t smc_id,
                                             uint32_t tile_start,
                                             uint32_t tile_elements) {
    const uint32_t words = (tile_elements + 3u) / 4u;
    std::vector<uint8_t> packed(static_cast<size_t>(words) * 16u, 0);
    const uint32_t lanes = words * 4u;
    const uint32_t total_elements = static_cast<uint32_t>(source.size() / kFp32Bytes);
    const uint32_t local_start = tile_start + smc_id * tile_elements;
    for (uint32_t lane = 0; lane < lanes; ++lane) {
        const uint32_t source_element = local_start + lane;
        if (lane < tile_elements && source_element < total_elements) {
            std::copy_n(source.begin() + static_cast<std::ptrdiff_t>(source_element * kFp32Bytes),
                        kFp32Bytes,
                        packed.begin() + static_cast<std::ptrdiff_t>(lane * kFp32Bytes));
        }
    }
    return packed;
}

std::vector<uint8_t> pack_epsilon_golden_tile(const std::vector<uint8_t>& source,
                                              uint32_t smc_id,
                                              uint32_t tile_start,
                                              uint32_t tile_elements,
                                              float scalar) {
    const uint32_t words = (tile_elements + 3u) / 4u;
    std::vector<uint8_t> packed;
    packed.reserve(static_cast<size_t>(words) * 16u);
    const uint32_t lanes = words * 4u;
    const uint32_t total_elements = static_cast<uint32_t>(source.size() / kFp32Bytes);
    const uint32_t local_start = tile_start + smc_id * tile_elements;
    for (uint32_t lane = 0; lane < lanes; ++lane) {
        const uint32_t source_element = local_start + lane;
        if (lane < tile_elements && source_element < total_elements) {
            packed.insert(packed.end(),
                          source.begin() + static_cast<std::ptrdiff_t>(source_element * kFp32Bytes),
                          source.begin() + static_cast<std::ptrdiff_t>((source_element + 1) * kFp32Bytes));
        } else {
            append_fp32(packed, scalar);
        }
    }
    return packed;
}

std::vector<uint8_t> make_fp16_one_word() {
    std::vector<uint8_t> alpha(16, 0);
    for (size_t index = 0; index < alpha.size(); index += 2) {
        alpha[index] = 0x00;
        alpha[index + 1] = 0x3c;  // IEEE-754 FP16 1.0, little-endian.
    }
    return alpha;
}

std::vector<std::pair<uint32_t, uint64_t>> make_lsu_header(
    uint8_t vld,
    uint8_t jump,
    uint16_t loops,
    uint8_t dly,
    uint16_t inc) {
    return {
        {1, vld}, {1, jump}, {3, 0}, {6, 0}, {10, loops},
        {7, 0}, {3, dly}, {13, inc}, {6, 0},
    };
}

std::vector<uint8_t> pack_msb_instruction(
    const std::vector<std::pair<uint32_t, uint64_t>>& fields) {
    uint32_t total_bits = 0;
    for (const auto& field : fields) total_bits += field.first;
    std::vector<uint8_t> bytes((total_bits + 7) / 8, 0);
    const uint32_t leading_pad_bits = static_cast<uint32_t>(bytes.size() * 8) - total_bits;
    uint32_t bit_pos = 0;
    for (const auto& field : fields) {
        for (uint32_t i = 0; i < field.first; ++i) {
            const uint32_t src_bit = field.first - 1 - i;
            if (((field.second >> src_bit) & 1ULL) == 0) continue;
            const uint32_t dst_bit = leading_pad_bits + bit_pos + i;
            bytes[dst_bit / 8] |= static_cast<uint8_t>(1u << (7 - (dst_bit % 8)));
        }
        bit_pos += field.first;
    }
    return bytes;
}

std::vector<uint8_t> make_lsu_end_instruction(uint32_t code_bits) {
    auto fields = make_lsu_header(1, 1, 0, 0, 0);
    fields.push_back({code_bits, 0});
    return pack_msb_instruction(fields);
}

std::string iq_filename(const std::string& raw_name) {
    if (raw_name == "ldbaxi") return "ldb_axi";
    if (raw_name == "stbaxi") return "stb_axi";
    return raw_name;
}

bool write_iq_files(const std::string& smc_dir,
                    const std::vector<aiacc::op::IqInstructionFile>& files) {
    struct IqFileEntry {
        std::vector<uint8_t> data;
        uint32_t width_bits{0};
    };
    std::map<std::string, IqFileEntry> grouped;
    for (const auto& file : files) {
        auto& entry = grouped[iq_filename(file.para_iq_name)];
        entry.data.insert(entry.data.end(), file.para_data.begin(), file.para_data.end());
        if (entry.width_bits == 0) entry.width_bits = file.para_width_bits;
    }
    for (const auto& item : grouped) {
        const std::string path = smc_dir + "/iq_" + item.first + ".hex";
        std::ofstream output(path, std::ios::trunc);
        if (!output) return false;
        const uint32_t inst_bytes = (item.second.width_bits + 7u) / 8u;
        if (inst_bytes == 0 || item.second.data.size() % inst_bytes != 0) return false;
        auto data = item.second.data;
        if (item.second.width_bits > 50) {
            auto end_inst = make_lsu_end_instruction(item.second.width_bits - 50u);
            data.insert(data.end(), end_inst.begin(), end_inst.end());
        }
        for (size_t offset = 0; offset < data.size(); offset += inst_bytes) {
            for (uint32_t byte = 0; byte < inst_bytes; ++byte) {
                output << std::hex << std::setfill('0') << std::setw(2)
                       << static_cast<unsigned>(data[offset + byte]);
            }
            output << '\n';
        }
    }
    return true;
}

bool rewrite_add_lsu_iq(const std::string& case_root,
                        const aiacc::lsu::LsuComputeDesc& desc,
                        const aiacc::lsu::AddLsuOp& op) {
    std::vector<aiacc::op::IqInstructionFile> files;
    uint64_t gr_word_offset = 0;
    for (const auto& name : add_input_order()) {
        const auto port_it = desc.inputs.find(name);
        if (port_it == desc.inputs.end()) return false;
        const auto& port = port_it->second;
        const uint32_t transfer_words = align_up_words(port.word_count, kAxiBurstWords);
        auto params = op.build_load_params(
            port.bank, port.word_offset, transfer_words, gr_word_offset * 16u);
        auto input_files = aiacc::op::emit_load_iq_files(params);
        files.insert(files.end(), input_files.begin(), input_files.end());
        gr_word_offset += transfer_words;
    }
    const uint32_t store_words = align_up_words(desc.output.word_count, kAxiBurstWords);
    auto store_params = op.build_store_params(
        desc.output.bank, desc.output.word_offset, store_words, gr_word_offset * 16u);
    auto store_files = aiacc::op::emit_store_iq_files(store_params);
    files.insert(files.end(), store_files.begin(), store_files.end());
    return write_iq_files(case_root + "/smc_0", files);
}

bool align_synthetic_hbm_inputs(const std::string& hbm_dir,
                                const aiacc::lsu::LsuComputeDesc& desc) {
    const std::string zero_line(32, '0');
    for (uint32_t smc = 0; smc < desc.num_smc; ++smc) {
        const std::filesystem::path path =
            std::filesystem::path(hbm_dir) / ("memory_init" + std::to_string(smc + 1u) + ".hex");
        std::ifstream input(path);
        if (!input) return false;
        std::vector<std::string> source_lines;
        std::string line;
        while (std::getline(input, line)) {
            if (!line.empty()) source_lines.push_back(line);
        }
        std::map<std::string, std::vector<std::string>> segments;
        size_t source_offset = 0;
        for (const auto& entry : desc.inputs) {
            const size_t end = source_offset + entry.second.word_count;
            if (end > source_lines.size()) return false;
            segments[entry.first] = std::vector<std::string>(
                source_lines.begin() + static_cast<std::ptrdiff_t>(source_offset),
                source_lines.begin() + static_cast<std::ptrdiff_t>(end));
            source_offset = end;
        }
        if (source_offset != source_lines.size()) return false;
        std::vector<std::string> aligned_lines;
        for (const auto& name : add_input_order()) {
            const auto port = desc.inputs.find(name);
            if (port == desc.inputs.end()) return false;
            aligned_lines.insert(aligned_lines.end(), segments[name].begin(), segments[name].end());
            aligned_lines.insert(aligned_lines.end(),
                                 align_up_words(port->second.word_count, kAxiBurstWords) -
                                     port->second.word_count,
                                 zero_line);
        }
        std::ofstream output(path, std::ios::trunc);
        if (!output) return false;
        for (const auto& output_line : aligned_lines) output << output_line << '\n';
    }
    return true;
}

aiacc::lsu::LsuComputeDesc make_rope_desc(uint32_t tile_tokens) {
    const uint32_t local_elements = tile_tokens * kRopeHeadsPerSmc * kRopeHeadDim;
    if (local_elements % 8 != 0) {
        throw std::runtime_error("RoPE tile does not fit an FP16 128-bit UR word");
    }
    const uint32_t words = local_elements / 8;
    if (words == 0 || words > kUrBankDepth) {
        throw std::runtime_error("RoPE tile requires more than one UR bank");
    }
    aiacc::lsu::LsuComputeDesc desc;
    desc.inputs["alpha"] = {2, 0, 1};
    desc.inputs["input"] = {0, 0, static_cast<uint16_t>(words)};
    desc.inputs["other"] = {1, 0, static_cast<uint16_t>(words)};
    desc.output = {3, 0, static_cast<uint16_t>(words)};
    desc.num_smc = kSmcCount;
    desc.smc_id_en = 7;
    desc.gr_intlv_addr = 0x10000000ULL;
    return desc;
}

aiacc::lsu::LsuComputeDesc make_epsilon_desc(uint32_t tile_elements) {
    const uint32_t words = (tile_elements + 3u) / 4u;
    if (words == 0 || words > kUrBankDepth) {
        throw std::runtime_error("epsilon tile requires more than one UR bank");
    }
    aiacc::lsu::LsuComputeDesc desc;
    desc.inputs["alpha"] = {2, 0, 1};
    desc.inputs["input"] = {0, 0, static_cast<uint16_t>(words)};
    desc.inputs["other"] = {1, 0, 1};
    desc.output = {3, 0, static_cast<uint16_t>(words)};
    desc.num_smc = kSmcCount;
    desc.smc_id_en = 7;
    desc.gr_intlv_addr = 0x10000000ULL;
    return desc;
}

void write_capture_manifest(const std::filesystem::path& case_root,
                            const CaptureOptions& options,
                            const std::string& mode,
                            uint32_t total_tokens,
                            uint32_t input_valid_words,
                            uint32_t other_valid_words,
                            uint32_t alpha_valid_words,
                            uint32_t output_valid_words,
                            uint32_t input_transfer_words,
                            uint32_t other_transfer_words,
                            uint32_t alpha_transfer_words,
                            uint32_t other_start_word,
                            uint32_t alpha_start_word,
                            uint32_t output_start_word,
                            uint32_t output_transfer_words,
                            bool other_broadcast) {
    std::ofstream output(case_root / "add_lsu_manifest.json", std::ios::trunc);
    if (!output) throw std::runtime_error("cannot write Add capture manifest");
    output << "{\n"
           << "  \"mode\": \"" << mode << "\",\n"
           << "  \"capture_dir\": \"" << options.capture_dir << "\",\n"
           << "  \"capture_kind\": \"" << options.capture_kind << "\",\n"
           << "  \"tile_start\": " << options.tile_start << ",\n"
           << "  \"tile_tokens\": " << options.tile_tokens << ",\n"
           << "  \"capture_tokens\": " << total_tokens << ",\n"
           << "  \"smc_count\": " << kSmcCount << ",\n"
           << "  \"input_bank\": 0,\n"
           << "  \"other_bank\": 1,\n"
           << "  \"alpha_bank\": 2,\n"
           << "  \"output_bank\": 3,\n"
           << "  \"input_hbm_start\": 0,\n"
           << "  \"other_hbm_start\": " << other_start_word << ",\n"
           << "  \"alpha_hbm_start\": " << alpha_start_word << ",\n"
           << "  \"output_hbm_start\": " << output_start_word << ",\n"
           << "  \"input_valid_words\": " << input_valid_words << ",\n"
           << "  \"other_valid_words\": " << other_valid_words << ",\n"
           << "  \"alpha_valid_words\": " << alpha_valid_words << ",\n"
           << "  \"output_valid_words\": " << output_valid_words << ",\n"
           << "  \"input_transfer_words\": " << input_transfer_words << ",\n"
           << "  \"other_transfer_words\": " << other_transfer_words << ",\n"
           << "  \"alpha_transfer_words\": " << alpha_transfer_words << ",\n"
           << "  \"output_transfer_words\": " << output_transfer_words << ",\n"
           << "  \"other_broadcast\": " << (other_broadcast ? "true" : "false") << "\n"
           << "}\n";
}

void write_capture_rope_case(const std::string& case_root,
                             const std::string& hbm_dir,
                             const CaptureOptions& options,
                             const aiacc::lsu::LsuComputeDesc& desc) {
    const std::filesystem::path capture_dir(options.capture_dir);
    const auto input = read_binary(find_capture_tensor(capture_dir, "-self.bin"));
    const auto other = read_binary(find_capture_tensor(capture_dir, "-other.bin"));
    const auto golden = read_binary(find_capture_tensor(capture_dir, "-return.bin"));

    const size_t bytes_per_token = static_cast<size_t>(kRopeHeads) * kRopeHeadDim * kFp16Bytes;
    if (input.size() != other.size() || input.size() != golden.size() ||
        input.size() % bytes_per_token != 0) {
        throw std::runtime_error("RoPE capture tensors have incompatible sizes");
    }
    const uint32_t total_tokens = static_cast<uint32_t>(input.size() / bytes_per_token);
    if (options.tile_tokens == 0 || options.tile_start >= total_tokens ||
        options.tile_tokens > total_tokens - options.tile_start) {
        throw std::runtime_error("RoPE tile is outside the captured sequence");
    }

    const uint32_t valid_words = desc.output.word_count;
    const uint32_t transfer_words = align_up_words(valid_words, kAxiBurstWords);
    const uint32_t alpha_transfer_words = kAxiBurstWords;
    const uint32_t other_start_word = transfer_words;
    const uint32_t other_transfer_words = transfer_words;
    const uint32_t alpha_start_word = other_start_word + other_transfer_words;
    const uint32_t output_start_word = alpha_start_word + alpha_transfer_words;
    const uint32_t output_transfer_words = transfer_words;
    const auto alpha = make_fp16_one_word();

    for (uint32_t smc = 0; smc < kSmcCount; ++smc) {
        const auto packed_input = pack_rope_tile(input, smc, options.tile_start, options.tile_tokens);
        const auto packed_other = pack_rope_tile(other, smc, options.tile_start, options.tile_tokens);
        const auto packed_golden = pack_rope_tile(golden, smc, options.tile_start, options.tile_tokens);
        if (packed_input.size() != static_cast<size_t>(valid_words) * 16u ||
            packed_other.size() != static_cast<size_t>(valid_words) * 16u ||
            packed_golden.size() != static_cast<size_t>(valid_words) * 16u) {
            throw std::runtime_error("RoPE tile packing does not match the L-C-S descriptor");
        }

        std::vector<uint8_t> hbm(
            static_cast<size_t>(output_start_word + output_transfer_words) * 16u, 0);
        std::copy(packed_input.begin(), packed_input.end(), hbm.begin());
        std::copy(packed_other.begin(), packed_other.end(),
                  hbm.begin() + static_cast<std::ptrdiff_t>(other_start_word * 16u));
        std::copy(alpha.begin(), alpha.end(),
                  hbm.begin() + static_cast<std::ptrdiff_t>(alpha_start_word * 16u));

        const std::filesystem::path hbm_path =
            std::filesystem::path(hbm_dir) / ("memory_init" + std::to_string(smc + 1u) + ".hex");
        write_hex_lines(hbm_path, hbm, 0);
        const std::filesystem::path golden_path =
            std::filesystem::path(case_root) / ("smc_" + std::to_string(smc)) /
            "output_bank" / "bank3_final.hex";
        write_hex_lines(golden_path, packed_golden, kUrBankDepth);
    }

    write_capture_manifest(case_root, options, "capture_rope_fp16", total_tokens,
                           valid_words, valid_words, 1, valid_words,
                           transfer_words, other_transfer_words, alpha_transfer_words,
                           other_start_word, alpha_start_word, output_start_word,
                           output_transfer_words, false);
}

void write_capture_epsilon_case(const std::string& case_root,
                                const std::string& hbm_dir,
                                const CaptureOptions& options,
                                const aiacc::lsu::LsuComputeDesc& desc) {
    const std::filesystem::path capture_dir(options.capture_dir);
    const auto input = read_binary(find_capture_tensor(capture_dir, "-self.bin"));
    const auto golden = read_binary(find_capture_tensor(capture_dir, "-return.bin"));
    const float other_scalar = read_other_scalar(capture_dir);

    if (input.size() != golden.size() || input.size() % kFp32Bytes != 0) {
        throw std::runtime_error("epsilon capture tensors must be matching FP32 vectors");
    }
    const uint32_t total_elements = static_cast<uint32_t>(input.size() / kFp32Bytes);
    if (options.tile_tokens == 0 || options.tile_start >= total_elements) {
        throw std::runtime_error("epsilon tile is outside the captured vector");
    }

    const uint32_t valid_words = desc.output.word_count;
    const uint32_t input_transfer_words = align_up_words(valid_words, kAxiBurstWords);
    const uint32_t other_transfer_words = kAxiBurstWords;
    const uint32_t alpha_transfer_words = kAxiBurstWords;
    const uint32_t other_start_word = input_transfer_words;
    const uint32_t alpha_start_word = other_start_word + other_transfer_words;
    const uint32_t output_start_word = alpha_start_word + alpha_transfer_words;
    const uint32_t output_transfer_words = input_transfer_words;
    const auto other = make_fp32_word(other_scalar);
    const auto alpha = make_fp32_word(1.0f);

    for (uint32_t smc = 0; smc < kSmcCount; ++smc) {
        const auto packed_input =
            pack_epsilon_input_tile(input, smc, options.tile_start, options.tile_tokens);
        const auto packed_golden =
            pack_epsilon_golden_tile(golden, smc, options.tile_start,
                                     options.tile_tokens, other_scalar);
        if (packed_input.size() != static_cast<size_t>(valid_words) * 16u ||
            packed_golden.size() != static_cast<size_t>(valid_words) * 16u) {
            throw std::runtime_error("epsilon tile packing does not match the L-C-S descriptor");
        }

        std::vector<uint8_t> hbm(
            static_cast<size_t>(output_start_word + output_transfer_words) * 16u, 0);
        std::copy(packed_input.begin(), packed_input.end(), hbm.begin());
        std::copy(other.begin(), other.end(),
                  hbm.begin() + static_cast<std::ptrdiff_t>(other_start_word * 16u));
        std::copy(alpha.begin(), alpha.end(),
                  hbm.begin() + static_cast<std::ptrdiff_t>(alpha_start_word * 16u));

        const std::filesystem::path hbm_path =
            std::filesystem::path(hbm_dir) / ("memory_init" + std::to_string(smc + 1u) + ".hex");
        write_hex_lines(hbm_path, hbm, 0);
        const std::filesystem::path golden_path =
            std::filesystem::path(case_root) / ("smc_" + std::to_string(smc)) /
            "output_bank" / "bank3_final.hex";
        write_hex_lines(golden_path, packed_golden, kUrBankDepth);
    }

    write_capture_manifest(case_root, options, "capture_epsilon_fp32_scalar", total_elements,
                           valid_words, 1, 1, valid_words,
                           input_transfer_words, other_transfer_words, alpha_transfer_words,
                           other_start_word, alpha_start_word, output_start_word,
                           output_transfer_words, true);
}

}  // namespace

int main(int argc, char* argv[]) {
    std::string case_root = "../8_sim/test_atomic_ops/verification_v2/add_lsu_v2_test";
    std::string hbm_dir = "../8_sim/data_engine/sram";
    uint32_t seed = 12345;
    CaptureOptions capture;
    std::vector<std::string> positional;

    for (int index = 1; index < argc; ++index) {
        const std::string arg = argv[index];
        auto require_value = [&](const char* option) -> std::string {
            if (++index >= argc) throw std::runtime_error(std::string("missing value for ") + option);
            return argv[index];
        };
        if (arg == "--capture-dir") capture.capture_dir = require_value("--capture-dir");
        else if (arg == "--capture-kind") capture.capture_kind = require_value("--capture-kind");
        else if (arg == "--tile-start") capture.tile_start = static_cast<uint32_t>(std::stoul(require_value("--tile-start")));
        else if (arg == "--tile-tokens") capture.tile_tokens = static_cast<uint32_t>(std::stoul(require_value("--tile-tokens")));
        else if (arg == "--help" || arg == "-h") {
            std::cout << "Usage: " << argv[0]
                      << " [case_root] [hbm_dir] [seed]"
                      << " [--capture-dir DIR --capture-kind rope|epsilon --tile-start N --tile-tokens N]\n";
            return 0;
        } else {
            positional.push_back(arg);
        }
    }
    if (!positional.empty()) case_root = positional[0];
    if (positional.size() > 1) hbm_dir = positional[1];
    if (positional.size() > 2) seed = static_cast<uint32_t>(std::stoul(positional[2]));
    if (positional.size() > 3) throw std::runtime_error("too many positional arguments");

    try {
        aiacc::lsu::AddLsuOp op;
        aiacc::lsu::LsuComputeDesc desc;
        if (capture.capture_dir.empty()) {
            desc = aiacc::lsu::AddLsuOp::default_compute_desc();
        } else if (capture.capture_kind == "rope") {
            desc = make_rope_desc(capture.tile_tokens);
            op.set_compute_config({aiacc::op::AddDataType::FP16,
                                   capture.tile_tokens,
                                   kRopeHeadsPerSmc,
                                   1,
                                   kRopeHeadDim,
                                   false});
        } else if (capture.capture_kind == "epsilon") {
            desc = make_epsilon_desc(capture.tile_tokens);
            const uint32_t words = desc.output.word_count;
            op.set_compute_config({aiacc::op::AddDataType::FP32,
                                   1,
                                   1,
                                   1,
                                   words * 4u,
                                   true});
        } else {
            throw std::runtime_error("unsupported --capture-kind: " + capture.capture_kind);
        }
        op.set_compute_desc(desc);
        op.set_case_config({capture.capture_dir.empty() ? "add_lsu_v2_test" : "add_capture_" + capture.capture_kind,
                            case_root, hbm_dir, seed});

        if (!op.assemble_full_case()) {
            std::cerr << "ERROR: assemble_full_case failed" << std::endl;
            return 1;
        }
        if (capture.capture_dir.empty()) {
            if (!align_synthetic_hbm_inputs(hbm_dir, desc)) {
                std::cerr << "ERROR: cannot align synthetic Add HBM input" << std::endl;
                return 1;
            }
        } else {
            if (capture.capture_kind == "rope") {
                write_capture_rope_case(case_root, hbm_dir, capture, desc);
            } else if (capture.capture_kind == "epsilon") {
                write_capture_epsilon_case(case_root, hbm_dir, capture, desc);
            }
        }
        if (!rewrite_add_lsu_iq(case_root, desc, op)) {
            std::cerr << "ERROR: cannot rewrite Add L-C-S IQ" << std::endl;
            return 1;
        }

        std::cout << "SUCCESS: Add L-C-S case at " << case_root;
        if (!capture.capture_dir.empty()) {
            std::cout << " (capture=" << capture.capture_dir
                      << ", kind=" << capture.capture_kind
                      << ", tile_start=" << capture.tile_start
                      << ", tile_tokens=" << capture.tile_tokens << ")";
        }
        std::cout << std::endl;
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "ERROR: " << error.what() << std::endl;
        return 1;
    }
}
