#include "add_op_compute_inst.h"
#include "add_op.h"

namespace aiacc {
namespace op {

// -----------------------------------------------------------------------------
// 计算单元微指令生成（FPMUL / FPADD）
// -----------------------------------------------------------------------------

void gen_fpmul_inst(const AddOpParams& para_params, iq::FpMulCru& para_cru) {
    para_cru.para_inst_valid = true;
    // 根据数据类型选择 16/32 bit 精度
    bool is_32b = (para_params.para_dtype == AddDataType::FP32);
    para_cru.para_src_precision_is_32b = is_32b;
    para_cru.para_dst_precision_is_32b = is_32b;
    para_cru.para_smc_id_en = 31;
}

void gen_fpadd_inst(const AddOpParams& para_params, iq::FpAddCru& para_cru) {
    para_cru.para_inst_valid = true;
    // FP32 → 32b 模式，FP16 → 16b 模式
    para_cru.para_mode_is_32b = (para_params.para_dtype == AddDataType::FP32);
    para_cru.para_update_st = false;
    para_cru.para_smc_id_en = 31;
}

} // namespace op
} // namespace aiacc
