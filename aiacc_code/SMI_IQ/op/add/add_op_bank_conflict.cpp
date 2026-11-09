#include "add_op_bank_conflict.h"
#include "add_op.h"
#include <iostream>

namespace aiacc {
namespace op {

// -----------------------------------------------------------------------------
// Bank 冲突解决：统计和分配
// -----------------------------------------------------------------------------

void count_bank_accesses(const AddOpParams& params,
                         std::vector<BankAccessInfo>& bank_accesses) {
    // 初始化 bank 访问统计（硬件支持 8 个 bank，3-bit 编码 0-7）
    bank_accesses.clear();
    bank_accesses.resize(8);
    for (uint8_t i = 0; i < 8; ++i) {
        bank_accesses[i].bank = i;
    }
    
    // 统计所有端口（读+写）的 bank 访问
    // UR Bank 为单端口 SRAM，同一周期内同一 Bank 只能被一个端口访问，
    // 因此读-读、读-写、写-写同 Bank 都是冲突，都需要通过 slot 分配错开。
    // tensor_id: 0=input(r0), 1=other(r1), 2=alpha(r2), 3=output(w0)
    bank_accesses[params.para_input_bank].tensor_ids.push_back(0);
    bank_accesses[params.para_other_bank].tensor_ids.push_back(1);
    bank_accesses[params.para_alpha_bank].tensor_ids.push_back(2);
    bank_accesses[params.para_output_bank].tensor_ids.push_back(3);
}

uint8_t compute_slot_allocation(const AddOpParams& params,
                                std::vector<AddOpInstructions::SlotAccess>& slot_accesses,
                                uint8_t port_slots[4]) {
    slot_accesses.clear();
    
    // 初始化 port_slots：默认全在 slot 0
    for (int i = 0; i < 4; ++i) port_slots[i] = 0;
    
    // 统计每个 bank 的访问
    std::vector<BankAccessInfo> bank_accesses;
    count_bank_accesses(params, bank_accesses);
    
    // =====================================================================
    // 图着色法分配 Slot
    // 
    // 问题本质：同一 Bank 的端口必须在不同 Slot（时间槽）执行。
    // 这等价于图着色问题：
    //   - 节点 = 端口（R0, R1, R2, W0）
    //   - 边   = 两端口共享至少一个 Bank
    //   - 颜色 = Slot 编号
    // 要求：相邻节点颜色不同
    // =====================================================================
    
    // Step 1: 构建冲突图（邻接矩阵）
    bool conflicts[4][4] = {};
    for (const auto& info : bank_accesses) {
        for (size_t i = 0; i < info.tensor_ids.size(); ++i) {
            for (size_t j = i + 1; j < info.tensor_ids.size(); ++j) {
                uint8_t a = info.tensor_ids[i];
                uint8_t b = info.tensor_ids[j];
                conflicts[a][b] = true;
                conflicts[b][a] = true;
            }
        }
    }
    
    // 检查是否有冲突
    bool has_conflict = false;
    for (int i = 0; i < 4 && !has_conflict; ++i)
        for (int j = i + 1; j < 4 && !has_conflict; ++j)
            if (conflicts[i][j]) has_conflict = true;
    
    if (!has_conflict) {
        // 无冲突：单 slot
        AddOpInstructions::SlotAccess slot0;
        slot0.input_slot = 0;
        slot0.other_slot = 0;
        slot0.alpha_slot = 0;
        slot0.output_slot = 0;
        slot0.has_compute = true;
        slot_accesses.push_back(slot0);
        return 1;
    }
    
    // Step 2: 贪心着色——按端口顺序，分配最小可用 Slot
    for (int p = 0; p < 4; ++p) {
        // 收集与端口 p 冲突的、已分配端口的 slot 集合
        std::vector<bool> used(4, false);  // 最多 4 个 slot
        for (int q = 0; q < p; ++q) {
            if (conflicts[p][q]) {
                used[port_slots[q]] = true;
            }
        }
        // 分配最小未使用 slot
        uint8_t s = 0;
        while (s < 4 && used[s]) s++;
        port_slots[p] = s;
    }
    
    // Step 3: 计算 num_slots
    uint8_t max_slot = 0;
    for (int p = 0; p < 4; ++p) {
        if (port_slots[p] > max_slot) max_slot = port_slots[p];
    }
    uint8_t num_slots = max_slot + 1;
    
    // 构建 slot_accesses（保留旧结构兼容性）
    slot_accesses.resize(num_slots);
    for (auto& slot : slot_accesses) {
        slot.input_slot = 0xFF;
        slot.other_slot = 0xFF;
        slot.alpha_slot = 0xFF;
        slot.output_slot = 0xFF;
        slot.has_compute = false;
    }
    
    // 根据 port_slots 填充 slot_accesses
    slot_accesses[port_slots[0]].input_slot = port_slots[0];
    slot_accesses[port_slots[1]].other_slot = port_slots[1];
    slot_accesses[port_slots[2]].alpha_slot = port_slots[2];
    if (port_slots[3] < num_slots) {
        slot_accesses[port_slots[3]].output_slot = port_slots[3];
    }
    
    // 计算放在最后一个读 slot 之后（所有输入都到齐后计算）
    uint8_t max_read_slot = 0;
    for (int i = 0; i < 3; ++i) {
        if (port_slots[i] > max_read_slot) max_read_slot = port_slots[i];
    }
    slot_accesses[max_read_slot].has_compute = true;
    
    std::cout << "[Info] Bank conflict: num_slots=" << (int)num_slots
              << ", port_slots=[r0=" << (int)port_slots[0]
              << ", r1=" << (int)port_slots[1]
              << ", r2=" << (int)port_slots[2]
              << ", w0=" << (int)port_slots[3] << "]\n";
    
    return num_slots;
}

} // namespace op
} // namespace aiacc
