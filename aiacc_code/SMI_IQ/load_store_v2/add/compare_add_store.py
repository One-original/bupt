#!/usr/bin/env python3

import argparse
import json
from pathlib import Path


def read_hex_lines(path):
    return [line.strip().lower() for line in path.read_text().splitlines() if line.strip()]


def compare_exact(expected, actual):
    return next(
        (index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]),
        None,
    )


def default_layout(args):
    return {
        "input_layout": (
            ("input", 0, 0, args.word_count, args.word_count),
            ("other", 1, 256, args.word_count, args.word_count),
            ("alpha", 2, 512, 1, 16),
        ),
        "output_bank": args.output_bank,
        "output_start": args.store_start,
        "output_valid_words": args.word_count,
        "output_transfer_words": args.word_count,
    }


def manifest_layout(case_root, args):
    manifest_path = case_root / "add_lsu_manifest.json"
    if not manifest_path.is_file():
        return default_layout(args)

    manifest = json.loads(manifest_path.read_text())
    return {
        "input_layout": (
            ("input", manifest["input_bank"], manifest["input_hbm_start"],
             manifest["input_valid_words"], manifest["input_transfer_words"]),
            ("other", manifest["other_bank"], manifest["other_hbm_start"],
             manifest["other_valid_words"], manifest["other_transfer_words"]),
            ("alpha", manifest["alpha_bank"], manifest["alpha_hbm_start"],
             manifest["alpha_valid_words"], manifest["alpha_transfer_words"]),
        ),
        "output_bank": manifest["output_bank"],
        "output_start": manifest["output_hbm_start"],
        "output_valid_words": manifest["output_valid_words"],
        "output_transfer_words": manifest["output_transfer_words"],
    }


def check_segment(smc_id, name, bank, hbm, hbm_start, ur, valid_words, transfer_words):
    if len(hbm) < hbm_start + transfer_words or len(ur) < transfer_words:
        return f"smc_{smc_id} Load {name} FAIL (short dump)"
    mismatch = compare_exact(
        hbm[hbm_start:hbm_start + transfer_words], ur[:transfer_words]
    )
    if mismatch is not None:
        return (
            f"smc_{smc_id} Load {name} FAIL "
            f"(line {mismatch}: hbm={hbm[hbm_start + mismatch]} ur={ur[mismatch]})"
        )
    return (
        f"smc_{smc_id} Load {name} PASS "
        f"({valid_words} valid lines, {transfer_words} transferred, exact)"
    )


def main():
    parser = argparse.ArgumentParser(description="Check Add Load, Compute, and Store data movement.")
    parser.add_argument("case_root", type=Path)
    parser.add_argument("--store-start", type=int, default=528,
                        help="legacy synthetic-case Store HBM start")
    parser.add_argument("--word-count", type=int, default=255,
                        help="legacy synthetic-case logical word count")
    parser.add_argument("--output-bank", type=int, default=3,
                        help="legacy synthetic-case output UR bank")
    args = parser.parse_args()

    layout = manifest_layout(args.case_root, args)
    passed = 0
    failed = 0
    for smc_id in range(8):
        smc_dir = args.case_root / f"smc_{smc_id}"
        hbm_path = smc_dir / f"hbm_result_smc_{smc_id}.hex"
        output_path = smc_dir / f"ur_result_smc_{smc_id}_bank{layout['output_bank']}.hex"
        golden_path = smc_dir / "output_bank" / f"bank{layout['output_bank']}_final.hex"
        if not hbm_path.is_file() or not output_path.is_file() or not golden_path.is_file():
            print(f"smc_{smc_id} LSU FAIL (missing HBM, UR dump, or golden)")
            failed += 1
            continue

        hbm = read_hex_lines(hbm_path)
        golden = read_hex_lines(golden_path)
        smc_failed = False
        for name, bank, hbm_start, valid_words, transfer_words in layout["input_layout"]:
            ur_path = smc_dir / f"ur_result_smc_{smc_id}_bank{bank}.hex"
            if not ur_path.is_file():
                print(f"smc_{smc_id} Load {name} FAIL (missing bank{bank} dump)")
                smc_failed = True
                continue
            result = check_segment(
                smc_id, name, bank, hbm, hbm_start, read_hex_lines(ur_path),
                valid_words, transfer_words,
            )
            print(result)
            smc_failed |= " FAIL " in result

        output = read_hex_lines(output_path)
        valid_words = layout["output_valid_words"]
        transfer_words = layout["output_transfer_words"]
        if len(output) < valid_words or len(golden) < valid_words:
            print(f"smc_{smc_id} Compute FAIL (UR lines={len(output)}, golden lines={len(golden)})")
            smc_failed = True
        else:
            mismatch = compare_exact(golden[:valid_words], output[:valid_words])
            if mismatch is None:
                print(f"smc_{smc_id} Compute output PASS ({valid_words} valid lines, exact)")
            else:
                print(
                    f"smc_{smc_id} Compute output FAIL "
                    f"(line {mismatch}: golden={golden[mismatch]} ur={output[mismatch]})"
                )
                smc_failed = True

        store_start = layout["output_start"]
        if len(hbm) < store_start + transfer_words or len(golden) < valid_words:
            print(f"smc_{smc_id} Store FAIL (short HBM or golden dump)")
            smc_failed = True
        else:
            actual = hbm[store_start:store_start + valid_words]
            mismatch = compare_exact(golden[:valid_words], actual)
            if mismatch is None:
                print(f"smc_{smc_id} Store PASS ({valid_words} valid lines, exact)")
            else:
                print(
                    f"smc_{smc_id} Store FAIL "
                    f"(HBM line {store_start + mismatch}: golden={golden[mismatch]} hbm={actual[mismatch]})"
                )
                smc_failed = True

        if smc_failed:
            failed += 1
        else:
            passed += 1

    print(f"LSU Summary: pass={passed} fail={failed} total_smc_runs={passed + failed}")
    return 0 if failed == 0 and passed == 8 else 1


if __name__ == "__main__":
    raise SystemExit(main())
