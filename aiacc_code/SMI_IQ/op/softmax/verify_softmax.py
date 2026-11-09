#!/usr/bin/env python3

import argparse
import json
import math
import struct
from pathlib import Path


def read_f32_bin(path):
    data = path.read_bytes()
    if len(data) % 4:
        raise ValueError(f"{path} is not FP32 aligned")
    return list(struct.unpack(f"<{len(data) // 4}f", data))


def read_bank(path):
    rows = [line.strip() for line in path.read_text().splitlines()
            if line.strip()]
    if len(rows) != 256:
        raise ValueError(f"{path} must contain 256 UR words")
    words = []
    for row in rows:
        if len(row) != 32:
            raise ValueError(f"{path} contains a non-128-bit row")
        words.append(bytes.fromhex(row)[::-1])
    return words


def fp32_element(words, elem_index):
    word_addr = elem_index // 4
    lane = elem_index % 4
    offset = lane * 4
    return struct.unpack("<f", words[word_addr][offset:offset + 4])[0]


def scalar(words, addr):
    return fp32_element(words, addr * 4)


def require_broadcast(label, words, addr, expected):
    for lane in range(4):
        require_close(
            f"{label}.lane{lane}",
            fp32_element(words, addr * 4 + lane),
            expected)


def close(actual, expected, atol=2e-6, rtol=2e-6):
    return abs(actual - expected) <= atol + rtol * abs(expected)


def require_close(label, actual, expected):
    if not close(actual, expected):
        raise AssertionError(
            f"{label}: actual={actual:.9g}, expected={expected:.9g}")


def bank_path(root, phase, smc, bank):
    return root / phase / f"smc_{smc}" / "ur_data" / f"bank{bank}.hex"


def verify(root):
    config = json.loads((root / "softmax_config.json").read_text())
    exchange = json.loads((root / "scalar_exchange_plan.json").read_text())
    input_values = read_f32_bin(root / "input.bin")
    golden = read_f32_bin(root / "golden.bin")
    tiles = config["tiles"]

    if config["smc_num"] != 8 or len(tiles) != 8:
        raise AssertionError("softmax case must contain exactly 8 SMCs")
    if config["shape"] != [
            config["d3"], config["d2"], config["d1"], config["d0"]]:
        raise AssertionError("shape fields are inconsistent")
    if config["row_count"] != \
            config["d3"] * config["d2"] * config["d1"]:
        raise AssertionError("row_count is inconsistent")
    if not 0 <= config["selected_row"] < config["row_count"]:
        raise AssertionError("selected_row is out of range")
    if len(input_values) != config["total_elements"] or \
            len(golden) != config["total_elements"]:
        raise AssertionError("input/golden size does not match shape")
    if any(value < 0.0 or not math.isfinite(value) for value in golden):
        raise AssertionError("golden contains an invalid probability")

    d0 = config["d0"]
    for row in range(config["row_count"]):
        begin = row * d0
        end = begin + d0
        row_input = input_values[begin:end]
        row_golden = golden[begin:end]
        require_close(f"row{row} output sum", sum(row_golden), 1.0)

        row_max = max(row_input)
        expected_exp = [math.exp(value - row_max) for value in row_input]
        expected_sum = sum(expected_exp)
        for i, value in enumerate(expected_exp):
            require_close(
                f"row{row} golden[{i}]",
                row_golden[i],
                value / expected_sum)

    global_max = exchange["exchanges"][0]["result"]
    global_sum = exchange["exchanges"][1]["global_sum"]
    inv_sum = exchange["exchanges"][1]["inv_sum"]
    selected_row_base = config["selected_row"] * d0

    for tile in tiles:
        smc = tile["smc_id"]
        offset = tile["elem_offset"]
        count = tile["elements"]
        local_input = input_values[
            selected_row_base + offset:
            selected_row_base + offset + count]

        initial_input = read_bank(
            bank_path(root, "phase_0_initial", smc, 0))
        for i, expected in enumerate(local_input):
            require_close(f"smc{smc} input[{i}]",
                          fp32_element(initial_input, i), expected)

        max_input = read_bank(
            bank_path(root, "phase_0_initial", smc, 5))
        for i, expected in enumerate(local_input):
            require_broadcast(
                f"smc{smc} max_input[{i}]",
                max_input, i, expected)
        for i in range(count, config["local_max_steps"]):
            for lane in range(4):
                actual = fp32_element(max_input, i * 4 + lane)
                if not math.isinf(actual) or actual > 0:
                    raise AssertionError(
                        f"smc{smc} max padding[{i}].lane{lane} "
                        "must be negative infinity")

        phase1_scratch = read_bank(
            bank_path(root, "phase_1_after_local_max", smc, 2))
        expected_local_max = max(local_input) if local_input else -math.inf
        actual_local_max = scalar(phase1_scratch, 0)
        if math.isinf(expected_local_max):
            if not math.isinf(actual_local_max) or actual_local_max > 0:
                raise AssertionError(f"smc{smc} inactive local max is invalid")
        else:
            require_broadcast(
                f"smc{smc} local max",
                phase1_scratch, 0, expected_local_max)

        phase2_scratch = read_bank(
            bank_path(root, "phase_2_after_global_max", smc, 2))
        require_broadcast(
            f"smc{smc} global max",
            phase2_scratch, 1, global_max)

        phase3_exp = read_bank(
            bank_path(root, "phase_3_after_exp_local_sum", smc, 1))
        phase3_scratch = read_bank(
            bank_path(root, "phase_3_after_exp_local_sum", smc, 2))
        expected_exp = [math.exp(value - global_max)
                        for value in local_input]
        for i, expected in enumerate(expected_exp):
            require_close(f"smc{smc} exp[{i}]",
                          fp32_element(phase3_exp, i), expected)
        require_broadcast(
            f"smc{smc} local sum",
            phase3_scratch, 2, sum(expected_exp))

        phase4_scratch = read_bank(
            bank_path(root, "phase_4_after_inv_sum", smc, 2))
        require_broadcast(
            f"smc{smc} global sum",
            phase4_scratch, 3, global_sum)
        require_broadcast(
            f"smc{smc} inv sum",
            phase4_scratch, 4, inv_sum)

        phase5_output = read_bank(
            bank_path(root, "phase_5_after_normalize", smc, 3))
        for i in range(count):
            require_close(f"smc{smc} output[{i}]",
                          fp32_element(phase5_output, i),
                          golden[selected_row_base + offset + i])

    print(f"[OK] verified 8-SMC softmax: {root}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case_dir", type=Path)
    args = parser.parse_args()
    verify(args.case_dir)


if __name__ == "__main__":
    main()
