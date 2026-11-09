#include "add_op.h"

#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cstdint>
#include <array>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <random>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <vector>

namespace aiacc { namespace op { namespace multi_smc_add_stage1 {

static uint32_t epw(AddDataType t) { return t == AddDataType::FP16 ? 8u : 4u; }
static uint32_t bpe(AddDataType t) { return t == AddDataType::FP16 ? 2u : 4u; }
static const char* dtype_name(AddDataType t) { return t == AddDataType::FP16 ? "fp16" : "fp32"; }

struct SmcIqBundle { uint8_t smc_id{0}; AddOpParams params{}; std::vector<IqInstructionFile> iq_files; };
struct UrBundle { std::array<std::vector<uint8_t>, 8> banks{}; };
struct LocalTilePlan {
    uint8_t smc_id{0};
    uint32_t elem_offset{0};
    uint32_t elems{0};
    uint32_t d3_begin{0};
    uint32_t d3_end{0};
    uint32_t d3_sub{0};
    uint32_t d2{1};
    uint32_t d1{1};
    uint32_t d0{1};
};
struct DramRegion {
    std::string name{};
    uint64_t base_addr{0};
    uint64_t bytes{0};
};
struct LoadStoreTransfer {
    std::string op{};
    std::string tensor{};
    uint8_t smc_id{0};
    uint8_t ur_bank{0};
    uint32_t ur_addr{0};
    uint32_t elem_offset{0};
    uint32_t elems{0};
    uint64_t dram_addr{0};
    uint32_t bytes{0};
    uint32_t words{0};
};
struct CompileOptions {
    AddOpParams base_params{};
    float alpha_scalar{1.0f};
    uint32_t seed{1};
    uint32_t smc_num{8};
    std::vector<uint32_t> split_elems{};
};
struct CompileResult {
    std::vector<SmcIqBundle> smcs{};
    std::vector<UrBundle> urs{};
    std::vector<LocalTilePlan> tiles{};
    std::vector<DramRegion> dram_regions{};
    std::vector<LoadStoreTransfer> load_ops{};
    std::vector<LoadStoreTransfer> store_ops{};
    app::AppOperatorRequest req{};
    std::vector<uint8_t> input_bin, other_bin, alpha_bin, golden_bin;
};

static constexpr uint32_t kBankWordBytes = 16;
static constexpr uint32_t kBankDepthWords = 256;

static uint32_t tensor_elems(const AddOpParams& p) {
    const uint64_t n = p.para_n;
    const uint64_t c = p.para_c;
    const uint64_t h = p.para_h;
    const uint64_t w = p.para_w;
    if (n == 0 || c == 0 || h == 0 || w == 0) throw std::invalid_argument("N/C/H/W must be non-zero");
    const uint64_t total = n * c * h * w;
    if (total > std::numeric_limits<uint32_t>::max()) throw std::invalid_argument("N*C*H*W exceeds uint32_t range");
    return static_cast<uint32_t>(total);
}

static LocalTilePlan make_local_tile(uint8_t smc_id, uint32_t elem_offset, uint32_t elems, AddDataType dtype) {
    const uint32_t d0 = epw(dtype);
    if ((elems % d0) != 0) throw std::invalid_argument("local tile elements must align to D0");
    LocalTilePlan t;
    t.smc_id = smc_id;
    t.elem_offset = elem_offset;
    t.elems = elems;
    t.d3_begin = elem_offset / d0;
    t.d3_sub = elems / d0;
    t.d3_end = t.d3_begin + t.d3_sub;
    t.d2 = 1;
    t.d1 = 1;
    t.d0 = d0;
    return t;
}

static std::vector<uint32_t> make_even_split(uint32_t total_elems, uint32_t smc_num) {
    if (smc_num == 0) throw std::invalid_argument("smc_num must be non-zero");
    if (total_elems % smc_num != 0) throw std::invalid_argument("N*C*H*W must divide smc_num for even split; use split-* for custom split");
    return std::vector<uint32_t>(smc_num, total_elems / smc_num);
}

static void validate(const AddOpParams& p, const std::vector<uint32_t>& split) {
    const uint32_t total = tensor_elems(p);
    if (split.empty()) throw std::invalid_argument("split is empty");
    if (split.size() > 32) throw std::invalid_argument("SMC count exceeds 32");
    uint32_t sum = 0, e = epw(p.para_dtype);
    for (uint32_t elems : split) {
        if (elems == 0) throw std::invalid_argument("split element counts must be non-zero");
        if ((elems % e) != 0) throw std::invalid_argument("each split element count must align to elems_per_word");
        if (static_cast<uint64_t>(elems) * bpe(p.para_dtype) > kBankDepthWords * kBankWordBytes) {
            throw std::invalid_argument("each split exceeds one UR bank capacity");
        }
        if (sum > std::numeric_limits<uint32_t>::max() - elems) throw std::invalid_argument("split element count overflow");
        sum += elems;
    }
    if (sum != total) throw std::invalid_argument("split element counts must sum to N*C*H*W");
}

static std::vector<uint8_t> slice(const std::vector<uint8_t>& v, uint32_t elem0, uint32_t elems, AddDataType t) {
    uint32_t s = elem0 * bpe(t), n = elems * bpe(t);
    if (s + n > v.size()) throw std::runtime_error("slice exceeds data size");
    return std::vector<uint8_t>(v.begin() + s, v.begin() + s + n);
}
static std::vector<uint8_t> first_word(const std::vector<uint8_t>& v) {
    if (v.size() < 16) throw std::runtime_error("alpha is shorter than one 128-bit word");
    return std::vector<uint8_t>(v.begin(), v.begin() + 16);
}
static std::vector<uint8_t> zeros(uint32_t elems, AddDataType t) { return std::vector<uint8_t>(elems * bpe(t), 0); }

static std::vector<uint8_t> make_bank_image(const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> image(kBankDepthWords * kBankWordBytes, 0);
    const size_t n = std::min(image.size(), payload.size());
    std::copy(payload.begin(), payload.begin() + n, image.begin());
    return image;
}

static uint64_t align_up(uint64_t v, uint64_t a) {
    if (a == 0) throw std::invalid_argument("align value must be non-zero");
    return ((v + a - 1) / a) * a;
}

static void build_load_store_plan(CompileResult& r, AddDataType dtype) {
    const uint32_t elem_bytes = bpe(dtype);
    const uint64_t input_bytes = r.input_bin.size();
    const uint64_t other_bytes = r.other_bin.size();
    const uint64_t alpha_bytes = 16;
    const uint64_t output_bytes = r.golden_bin.size();

    uint64_t next = 0;
    const uint64_t input_base = next;
    next = align_up(input_base + input_bytes, kBankWordBytes);
    const uint64_t other_base = next;
    next = align_up(other_base + other_bytes, kBankWordBytes);
    const uint64_t alpha_base = next;
    next = align_up(alpha_base + alpha_bytes, kBankWordBytes);
    const uint64_t output_base = next;

    r.dram_regions.push_back({"input_tensor", input_base, input_bytes});
    r.dram_regions.push_back({"other_tensor", other_base, other_bytes});
    r.dram_regions.push_back({"alpha_scalar", alpha_base, alpha_bytes});
    r.dram_regions.push_back({"output_tensor", output_base, output_bytes});

    for (const LocalTilePlan& t : r.tiles) {
        const uint32_t bytes = t.elems * elem_bytes;
        if ((bytes % kBankWordBytes) != 0) throw std::runtime_error("tile bytes must align to 128-bit words");
        const uint32_t words = bytes / kBankWordBytes;

        r.load_ops.push_back({"load", "input_tensor", t.smc_id, 0, 0, t.elem_offset, t.elems,
                              input_base + static_cast<uint64_t>(t.elem_offset) * elem_bytes, bytes, words});
        r.load_ops.push_back({"load", "other_tensor", t.smc_id, 1, 0, t.elem_offset, t.elems,
                              other_base + static_cast<uint64_t>(t.elem_offset) * elem_bytes, bytes, words});
        r.load_ops.push_back({"load", "alpha_scalar", t.smc_id, 2, 0, 0, epw(dtype),
                              alpha_base, static_cast<uint32_t>(alpha_bytes), 1});
        r.store_ops.push_back({"store", "output_tensor", t.smc_id, 3, 0, t.elem_offset, t.elems,
                               output_base + static_cast<uint64_t>(t.elem_offset) * elem_bytes, bytes, words});
    }
}

static app::AppOperatorRequest make_tvgen_req(const CompileOptions& opt) {
    app::AppOperatorRequest req;
    req.para_operator = "FusedScaleAdd";
    req.para_dimensions.para_n = opt.base_params.para_n;
    req.para_dimensions.para_c = opt.base_params.para_c;
    req.para_dimensions.para_h = opt.base_params.para_h;
    req.para_dimensions.para_w = opt.base_params.para_w;
    req.para_layout_mode = "default";
    std::mt19937 rng(opt.seed);
    std::uniform_real_distribution<float> dist(-10.0f, 10.0f);
    AddOp add;
    add.fill_random_request(req, rng, dist, dtype_name(opt.base_params.para_dtype));
    auto it = req.para_parameters.find("alpha");
    if (it == req.para_parameters.end()) throw std::runtime_error("AddOp TVGen path did not create alpha");
    std::fill(it->second.para_data_f32.begin(), it->second.para_data_f32.end(), opt.alpha_scalar);
    return req;
}

CompileResult compile_multi_local_add(const CompileOptions& opt) {
    const uint32_t total = tensor_elems(opt.base_params);
    std::vector<uint32_t> split = opt.split_elems.empty() ? make_even_split(total, opt.smc_num) : opt.split_elems;
    validate(opt.base_params, split);
    AddOp add;
    CompileResult r;
    r.req = make_tvgen_req(opt);
    if (!add.generate_data(r.req, r.input_bin, r.other_bin, r.alpha_bin)) throw std::runtime_error("AddOp::generate_data failed");
    if (!add.calculate_golden(r.req, r.golden_bin)) throw std::runtime_error("AddOp::calculate_golden failed");
    uint32_t off = 0;
    for (uint32_t i = 0; i < split.size(); ++i) {
        LocalTilePlan tile = make_local_tile(static_cast<uint8_t>(i), off, split[i], opt.base_params.para_dtype);
        AddOpParams p = opt.base_params;
        p.para_n = 1;
        p.para_c = 1;
        p.para_h = 1;
        p.para_w = tile.elems;
        AddOpInstructions inst = add.compile(p);
        r.smcs.push_back({static_cast<uint8_t>(i), p, inst.get_iq_files()});
        r.tiles.push_back(tile);
        UrBundle u;
        u.banks[0] = make_bank_image(slice(r.input_bin, off, split[i], opt.base_params.para_dtype));
        u.banks[1] = make_bank_image(slice(r.other_bin, off, split[i], opt.base_params.para_dtype));
        u.banks[2] = make_bank_image(first_word(r.alpha_bin));
        u.banks[3] = make_bank_image({});
        u.banks[4] = make_bank_image({});
        u.banks[5] = make_bank_image({});
        u.banks[6] = make_bank_image({});
        u.banks[7] = make_bank_image({});
        r.urs.push_back(std::move(u));
        off += split[i];
    }
    return r;
}

} } }

#ifdef ADD_MULTI_STAGE1_STANDALONE
namespace {
using namespace aiacc::op;
using aiacc::op::multi_smc_add_stage1::CompileOptions;
using aiacc::op::multi_smc_add_stage1::CompileResult;
using aiacc::op::multi_smc_add_stage1::DramRegion;
using aiacc::op::multi_smc_add_stage1::LoadStoreTransfer;
using aiacc::op::multi_smc_add_stage1::LocalTilePlan;
using aiacc::op::multi_smc_add_stage1::SmcIqBundle;
using aiacc::op::multi_smc_add_stage1::UrBundle;
using aiacc::op::multi_smc_add_stage1::compile_multi_local_add;

static std::string lower(std::string s) { std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c){ return (char)std::tolower(c); }); return s; }
static AddDataType parse_dtype(const std::string& s) { auto d = lower(s); if (d == "fp16" || d == "float16") return AddDataType::FP16; if (d == "fp32" || d == "float32") return AddDataType::FP32; throw std::invalid_argument("bad dtype: " + s); }
static const char* dname(AddDataType t) { return t == AddDataType::FP16 ? "fp16" : "fp32"; }
static uint32_t se_pw(AddDataType t) { return t == AddDataType::FP16 ? 8u : 4u; }
static uint32_t se_bpe(AddDataType t) { return t == AddDataType::FP16 ? 2u : 4u; }
static std::string jp(const std::string& a, const std::string& b) { return a.empty() ? b : (a.back() == '/' ? a + b : a + "/" + b); }
static void mkdirs(const std::string& p) { std::string cur; for (char c: p) { cur += c; if (c == '/' && cur.size() > 1 && mkdir(cur.c_str(),0755) && errno != EEXIST) throw std::runtime_error("mkdir failed: "+cur); } if (!p.empty() && mkdir(p.c_str(),0755) && errno != EEXIST) throw std::runtime_error("mkdir failed: "+p); }
static void bin(const std::string& p, const std::vector<uint8_t>& d) { std::ofstream o(p, std::ios::binary); if(!o) throw std::runtime_error("open failed: "+p); o.write((const char*)d.data(), (std::streamsize)d.size()); }
static void hexrows(const std::string& p, const std::vector<uint8_t>& d, uint32_t row) { if(row == 0 || d.size()%row) throw std::runtime_error("unaligned hex rows: "+p); std::ofstream o(p); if(!o) throw std::runtime_error("open failed: "+p); o<<std::hex<<std::setfill('0'); for(uint32_t off=0; off<d.size(); off+=row){ for(uint32_t i=0;i<row;++i) o<<std::setw(2)<<(uint32_t)d[off+i]; o<<'\n'; } }
static void mem_hexrows(const std::string& p, const std::vector<uint8_t>& d, uint32_t row) { if(row == 0 || d.size()%row) throw std::runtime_error("unaligned memory hex rows: "+p); std::ofstream o(p); if(!o) throw std::runtime_error("open failed: "+p); o<<std::hex<<std::setfill('0'); for(uint32_t off=0; off<d.size(); off+=row){ for(uint32_t i=0;i<row;++i) o<<std::setw(2)<<(uint32_t)d[off + row - 1 - i]; o<<'\n'; } }
static std::string normalize_iq_name(std::string s) { std::replace(s.begin(), s.end(), '-', '_'); return s; }
static std::string flat_iq_filename(const IqInstructionFile& f) {
    if (f.para_iq_name == "fpmul" || f.para_iq_name == "fpadd") {
        return "iq_" + f.para_iq_name + ".hex";
    }
    if (f.para_iq_name.rfind("rtovr-", 0) == 0) {
        return "iq_" + f.para_iq_name + ".hex";
    }
    if (f.para_iq_name == "ur-r0") return "iq_ur-r0.hex";
    if (f.para_iq_name == "ur-r1") return "iq_ur-r1.hex";
    if (f.para_iq_name == "ur-r2") return "iq_ur-r2.hex";
    if (f.para_iq_name == "ur-w0") return "iq_ur-w0.hex";
    return f.get_filename_no_ext() + ".hex";
}
static void write_flat_iq_files(const std::string& dir, const SmcIqBundle& b) {
    mkdirs(dir);
    for (const auto& f : b.iq_files) {
        const std::string path = jp(dir, flat_iq_filename(f));
        hexrows(path, f.para_data, (f.para_width_bits + 7u) / 8u);
    }
}
static void write_ur_flat(const std::string& dir, const UrBundle& u) {
    std::string ur_dir = jp(dir, "ur_data");
    mkdirs(ur_dir);
    for (uint32_t i = 0; i < u.banks.size(); ++i) {
        const std::string path = jp(ur_dir, "bank" + std::to_string(i) + ".hex");
        mem_hexrows(path, u.banks[i], 16);
    }
}
static void write_simulator_config(const std::string& dir) {
    std::ofstream o(jp(dir, "simulator_config.json"));
    if(!o) throw std::runtime_error("open failed: simulator_config.json");
    o << "{\n"
      << "  \"operator\": \"FusedScaleAdd\",\n"
      << "  \"settings\": {\n"
      << "    \"output_banks\": [3],\n"
      << "    \"output_start_addr\": 0\n"
      << "  }\n"
      << "}\n";
}
static std::vector<uint8_t> pad_to_word(const std::vector<uint8_t>& d) {
    std::vector<uint8_t> out = d;
    while ((out.size() % 16) != 0) out.push_back(0);
    return out;
}
static void write_dram_images(const std::string& case_dir, const CompileResult& r) {
    const std::string dram_dir = jp(case_dir, "dram_data");
    mkdirs(dram_dir);
    const std::vector<uint8_t> alpha_word = aiacc::op::multi_smc_add_stage1::first_word(r.alpha_bin);
    bin(jp(dram_dir, "input_tensor.bin"), r.input_bin);
    bin(jp(dram_dir, "other_tensor.bin"), r.other_bin);
    bin(jp(dram_dir, "alpha_scalar.bin"), alpha_word);
    bin(jp(dram_dir, "output_golden.bin"), r.golden_bin);
    mem_hexrows(jp(dram_dir, "input_tensor.hex"), pad_to_word(r.input_bin), 16);
    mem_hexrows(jp(dram_dir, "other_tensor.hex"), pad_to_word(r.other_bin), 16);
    mem_hexrows(jp(dram_dir, "alpha_scalar.hex"), pad_to_word(alpha_word), 16);
    mem_hexrows(jp(dram_dir, "output_golden.hex"), pad_to_word(r.golden_bin), 16);
}
static void write_transfer_json(std::ofstream& o, const LoadStoreTransfer& t, bool comma) {
    o << "    {\"op\": \"" << t.op << "\""
      << ", \"tensor\": \"" << t.tensor << "\""
      << ", \"smc_id\": " << static_cast<uint32_t>(t.smc_id)
      << ", \"ur_bank\": " << static_cast<uint32_t>(t.ur_bank)
      << ", \"ur_addr\": " << t.ur_addr
      << ", \"elem_offset\": " << t.elem_offset
      << ", \"elements\": " << t.elems
      << ", \"dram_addr\": " << t.dram_addr
      << ", \"dram_addr_hex\": \"0x" << std::hex << std::uppercase << t.dram_addr << std::dec << std::nouppercase << "\""
      << ", \"bytes\": " << t.bytes
      << ", \"words_128b\": " << t.words
      << "}";
    if (comma) o << ",";
    o << "\n";
}
static void write_load_store_plan(const std::string& case_dir, const CompileResult& r, AddDataType dtype) {
    std::ofstream o(jp(case_dir, "load_store_plan.json"));
    if(!o) throw std::runtime_error("open failed: load_store_plan.json");
    o << "{\n"
      << "  \"mode\": \"planned_load_add_store_contiguous_d3_split\",\n"
      << "  \"note\": \"The current 8_sim case still preloads UR directly; this file defines the DRAM load/store transfers for the next RTL integration step.\",\n"
      << "  \"dtype\": \"" << dname(dtype) << "\",\n"
      << "  \"element_bytes\": " << se_bpe(dtype) << ",\n"
      << "  \"ur_word_bytes\": 16,\n"
      << "  \"dram_regions\": [\n";
    for (size_t i = 0; i < r.dram_regions.size(); ++i) {
        const DramRegion& d = r.dram_regions[i];
        o << "    {\"name\": \"" << d.name << "\""
          << ", \"base_addr\": " << d.base_addr
          << ", \"base_addr_hex\": \"0x" << std::hex << std::uppercase << d.base_addr << std::dec << std::nouppercase << "\""
          << ", \"bytes\": " << d.bytes
          << "}";
        if (i + 1 != r.dram_regions.size()) o << ",";
        o << "\n";
    }
    o << "  ],\n"
      << "  \"load_ops\": [\n";
    for (size_t i = 0; i < r.load_ops.size(); ++i) {
        write_transfer_json(o, r.load_ops[i], i + 1 != r.load_ops.size());
    }
    o << "  ],\n"
      << "  \"compute_op\": {\"op\": \"add\", \"input_bank\": 0, \"other_bank\": 1, \"alpha_bank\": 2, \"output_bank\": 3},\n"
      << "  \"store_ops\": [\n";
    for (size_t i = 0; i < r.store_ops.size(); ++i) {
        write_transfer_json(o, r.store_ops[i], i + 1 != r.store_ops.size());
    }
    o << "  ]\n"
      << "}\n";
}
static void write_flat_case(const std::string& case_dir, const SmcIqBundle& b, const UrBundle& u, const std::vector<uint8_t>& golden) {
    mkdirs(case_dir);
    write_flat_iq_files(case_dir, b);
    write_ur_flat(case_dir, u);
    bin(jp(case_dir, "golden.bin"), golden);
    write_simulator_config(case_dir);
}
static void write_multi_smc_case(const std::string& case_root, const CompileResult& r) {
    if (r.smcs.empty() || r.urs.empty() || r.tiles.empty()) throw std::runtime_error("empty multi-SMC result");
    const uint32_t local_elems = r.tiles[0].elems;
    const uint32_t local_d3 = r.tiles[0].d3_sub;
    const uint32_t tile_d2 = r.tiles[0].d2;
    const uint32_t tile_d1 = r.tiles[0].d1;
    const uint32_t tile_d0 = r.tiles[0].d0;
    for (size_t i = 1; i < r.tiles.size(); ++i) {
        if (r.tiles[i].elems != local_elems || r.tiles[i].d3_sub != local_d3 ||
            r.tiles[i].d2 != tile_d2 || r.tiles[i].d1 != tile_d1 || r.tiles[i].d0 != tile_d0) {
            throw std::runtime_error("8_sim single-run mode requires equal split element counts");
        }
    }
    const auto& dims = r.req.para_dimensions;
    const uint64_t total_elems = static_cast<uint64_t>(dims.para_n) *
                                 static_cast<uint64_t>(dims.para_c) *
                                 static_cast<uint64_t>(dims.para_h) *
                                 static_cast<uint64_t>(dims.para_w);
    mkdirs(case_root);
    for (size_t i = 0; i < r.urs.size(); ++i) {
        const std::string smc_dir = jp(case_root, "smc_" + std::to_string(i));
        mkdirs(smc_dir);
        if (i == 0) {
            write_flat_iq_files(smc_dir, r.smcs[0]);
            write_simulator_config(smc_dir);
        }
        write_ur_flat(smc_dir, r.urs[i]);
    }
    bin(jp(case_root, "golden.bin"), r.golden_bin);
    write_simulator_config(case_root);
    std::ofstream cfg(jp(case_root, "multi_smc_config.json"));
    if(!cfg) throw std::runtime_error("open failed: multi_smc_config.json");
    cfg << "{\n"
        << "  \"mode\": \"single_run_8_smc_local_ur\",\n"
        << "  \"layout_mode\": \"compute_only_contiguous_d3_split\",\n"
        << "  \"data_path\": \"direct_ur_preload_add_only\",\n"
        << "  \"split_dim\": \"D3\",\n"
        << "  \"smc_num\": " << r.smcs.size() << ",\n"
        << "  \"n\": " << dims.para_n << ",\n"
        << "  \"c\": " << dims.para_c << ",\n"
        << "  \"h\": " << dims.para_h << ",\n"
        << "  \"w\": " << dims.para_w << ",\n"
        << "  \"total_elements\": " << total_elems << ",\n"
        << "  \"tprime_d3\": " << (total_elems / tile_d0) << ",\n"
        << "  \"tprime_d2\": " << tile_d2 << ",\n"
        << "  \"tprime_d1\": " << tile_d1 << ",\n"
        << "  \"tprime_d0\": " << tile_d0 << ",\n"
        << "  \"local_d3\": " << local_d3 << ",\n"
        << "  \"local_d2\": " << tile_d2 << ",\n"
        << "  \"local_d1\": " << tile_d1 << ",\n"
        << "  \"local_d0\": " << tile_d0 << ",\n"
        << "  \"local_elements\": " << local_elems << ",\n"
        << "  \"local_w\": " << local_elems << ",\n"
        << "  \"output_bank\": 3,\n"
        << "  \"tiles\": [\n";
    for (size_t i = 0; i < r.tiles.size(); ++i) {
        const LocalTilePlan& t = r.tiles[i];
        cfg << "    {\"smc_id\": " << static_cast<uint32_t>(t.smc_id)
            << ", \"elem_offset\": " << t.elem_offset
            << ", \"elements\": " << t.elems
            << ", \"d3_begin\": " << t.d3_begin
            << ", \"d3_end\": " << t.d3_end
            << ", \"d3_sub\": " << t.d3_sub
            << ", \"d2\": " << t.d2
            << ", \"d1\": " << t.d1
            << ", \"d0\": " << t.d0
            << "}";
        if (i + 1 != r.tiles.size()) cfg << ",";
        cfg << "\n";
    }
    cfg << "  ]\n"
        << "}\n";
}
static void regenerate_data_list_with_script(const std::string& sim_dir, const std::string& rel_case_path) {
    const std::string script = jp(sim_dir, "generate_data_list_coverage.py");
    std::string cmd = "python3 '" + script + "' '" + rel_case_path + "'";
    if (std::system(cmd.c_str()) != 0) {
        throw std::runtime_error("failed to regenerate data_list via generate_data_list_coverage.py: " + rel_case_path);
    }
}
static void write_output_bank(const std::string& sim_case_dir, const UrBundle& u, const std::vector<uint8_t>& golden) {
    std::string out_dir = jp(sim_case_dir, "output_bank");
    mkdirs(out_dir);
    std::vector<uint8_t> zero_bank(256 * 16, 0);
    std::vector<uint8_t> golden_bank = aiacc::op::multi_smc_add_stage1::make_bank_image(golden);
    for (uint32_t i = 0; i < 8; ++i) {
        const std::vector<uint8_t>& src = (i < 3) ? u.banks[i] : (i == 3 ? golden_bank : zero_bank);
        mem_hexrows(jp(out_dir, "bank" + std::to_string(i) + "_final.hex"), src, 16);
    }
}
static void remove_dir(const std::string& path) {
    std::string cmd = "rm -rf '" + path + "'";
    if (std::system(cmd.c_str()) != 0) throw std::runtime_error("failed to clean directory: " + path);
}

static std::vector<uint32_t> parse_split(std::string s) {
    std::replace(s.begin(), s.end(), '-', ',');
    std::vector<uint32_t> out; size_t pos = 0;
    while (pos < s.size()) { size_t comma = s.find(',', pos); std::string tok = s.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos); if(tok.empty()) throw std::invalid_argument("empty split item"); out.push_back((uint32_t)std::stoul(tok)); if(comma == std::string::npos) break; pos = comma + 1; }
    return out;
}

static CompileOptions args(int argc, char** argv, std::string& out, std::string& sim_dir) {
    CompileOptions o; o.base_params.para_n=1; o.base_params.para_c=1; o.base_params.para_h=1; o.base_params.para_w=32; o.base_params.para_dtype=AddDataType::FP32; out="out/multi_smc_add_stage1"; sim_dir="./out/sim";
    for(int i=1;i<argc;++i){ std::string a=argv[i]; auto val=[&](){ if(i+1>=argc) throw std::invalid_argument("missing value for "+a); return std::string(argv[++i]); };
        if(a=="--help"||a=="-h"){ std::cout<<"Usage: "<<argv[0]<<" [--dtype fp32|fp16] [--n N] [--c C] [--h H] [--w W] [--smc-num N] [--split E0,E1,...] [--alpha A] [--seed S] [--output DIR] [--sim-dir DIR]\n"; std::exit(0); }
        else if(a=="--dtype") o.base_params.para_dtype=parse_dtype(val());
        else if(a=="--n") o.base_params.para_n=(uint32_t)std::stoul(val());
        else if(a=="--c") o.base_params.para_c=(uint32_t)std::stoul(val());
        else if(a=="--h") o.base_params.para_h=(uint32_t)std::stoul(val());
        else if(a=="--w") o.base_params.para_w=(uint32_t)std::stoul(val());
        else if(a=="--smc-num") o.smc_num=(uint32_t)std::stoul(val());
        else if(a=="--split") o.split_elems=parse_split(val());
        else if(a=="--alpha") o.alpha_scalar=std::stof(val());
        else if(a=="--seed") o.seed=(uint32_t)std::stoul(val());
        else if(a=="--output") out=val();
        else if(a=="--sim-dir") sim_dir=val();
        else throw std::invalid_argument("unknown arg: "+a);
    }
    if (!o.split_elems.empty()) o.smc_num = (uint32_t)o.split_elems.size();
    return o;
}
}

int main(int argc, char** argv) {
    try {
        std::string out, sim_dir; auto opt = args(argc, argv, out, sim_dir); auto r = compile_multi_local_add(opt); mkdirs(out);
        const std::string bundle_dir = jp(sim_dir, "test_atomic_ops/operators/binary/math/add/acb_bundle");
        const std::string rel_case_root = "operators/binary/math/add/acb_bundle";
        remove_dir(bundle_dir);
        write_multi_smc_case(bundle_dir, r);
        regenerate_data_list_with_script(sim_dir, rel_case_root);
        for (size_t i = 0; i < r.tiles.size(); ++i) {
            const auto& t = r.tiles[i];
            const std::vector<uint8_t> local_golden =
                aiacc::op::multi_smc_add_stage1::slice(
                    r.golden_bin, t.elem_offset, t.elems, opt.base_params.para_dtype);
            write_output_bank(jp(bundle_dir, "smc_" + std::to_string(i)), r.urs[i], local_golden);
        }
        std::cout << "[OK] Multi-SMC local Add prepared under " << sim_dir << "/test_atomic_ops/operators/binary/math/add/acb_bundle/\n"
                  << "     SMC count: " << r.smcs.size() << "\n"
                  << "     tensor shape: N=" << opt.base_params.para_n << " C=" << opt.base_params.para_c
                  << " H=" << opt.base_params.para_h << " W=" << opt.base_params.para_w << "\n"
                  << "     compute layout: T'[D3,D2,D1,D0] contiguous D3 split, local tile=["
                  << r.tiles[0].d3_sub << "," << r.tiles[0].d2 << "," << r.tiles[0].d1 << "," << r.tiles[0].d0 << "]\n"
                  << "     compute IQ shape per SMC: N=1 C=1 H=1 W=" << r.tiles[0].elems << "\n"
                  << "     output layout: sibling smc_0..smc_" << (r.smcs.size() - 1) << " with ur_data/bank*.hex\n";
        return 0;
    } catch(const std::exception& e) { std::cerr << "[ERROR] " << e.what() << "\n"; return 1; }
}
#endif
