"""Decode rngd-diag YAML output into a hardware-health PASS/FAIL report.

Reads the YAML produced by `rngd-diag -o`, applies the thresholds from
thresholds.py, and writes PF_result.log and PF_result.html via render.py.
"""

import argparse
import os
import sys
from typing import Any, TextIO, cast

import yaml

from rngd_diag_decoder import render, thresholds


def check_npu_status(
    npu_id: str,
    diag_data: dict[str, Any],
    bench_data: dict[str, Any],
    stress_data: dict[str, Any],
) -> dict[str, str]:
    """Compute the PASS/FAIL row for a single NPU.

    Args:
        npu_id: The NPU identifier (e.g., "npu0").
        diag_data: The rngd-diag section for this NPU.
        bench_data: The furiosa-hal-bench section for this NPU.
        stress_data: The furiosa-stress-test section for this NPU.

    Returns:
        A dict mapping each diagnostic item (SENSORS, PWR_SENSE, PCIE,
        hal-bench READ/WRITE, STRESS_TEST) to its colored PASS/FAIL string.
    """
    results = {}

    sensors = diag_data.get('sensor', {}).get('details', {})
    sensor_vals = [
        f"Ta:{sensors.get('ta')}", f"Amb:{sensors.get('npu_ambient')}",
        f"SOC:{sensors.get('soc')}", f"PWR:{sensors.get('p_rms_total')}",
    ]
    s_errors = [
        f"{k}:{v}" for k, v in sensors.items()
        if k in thresholds.SENSOR_LIMITS
        and not (thresholds.SENSOR_LIMITS[k][0] <= v <= thresholds.SENSOR_LIMITS[k][1])
    ]
    results['SENSORS'] = (
        f"{render.GREEN}PASS{render.RESET} ({', '.join(sensor_vals)})"
        if not s_errors else
        f"{render.RED}FAIL{render.RESET} ({', '.join(s_errors)})"
    )

    p_val = diag_data.get('power_sense', {}).get('value')
    results['PWR_SENSE'] = (
        f"{render.GREEN}PASS{render.RESET}"
        if p_val in thresholds.POWER_SENSE_VALID_VALUES
        else f"{render.RED}FAIL{render.RESET} (Val:{p_val})"
    )

    pcie = diag_data.get('pcie', {})
    link = pcie.get('link', {})
    speed = link.get('speed', 'N/A')
    width = link.get('width', 'N/A')
    aer   = pcie.get('aer', {}).get('total_err_fatal', 0)
    results['PCIE'] = (
        f"{render.GREEN}PASS{render.RESET} ({speed}, {width})"
        if (
            speed == thresholds.PCIE_EXPECTED_SPEED
            and width == thresholds.PCIE_EXPECTED_WIDTH
            and aer == thresholds.PCIE_EXPECTED_AER_FATAL
        )
        else f"{render.RED}FAIL{render.RESET} (AER:{aer})"
    )

    for mode in ['read', 'write']:
        m_data = bench_data.get(mode, {}).get(npu_id, {})
        label = f"hal-bench ({mode.upper()})"
        if 'error' in m_data:
            results[label] = f"{render.RED}FAIL{render.RESET} (Busy/Error)"
        elif 'thrpt_gibs' in m_data:
            avgs = [str(round(sum(g)/len(g), 2)) for g in m_data['thrpt_gibs'] if g]
            results[label] = f"{render.GREEN}PASS{render.RESET} ({', '.join(avgs)})"
        else:
            results[label] = "NO_DATA"

    st = stress_data.get(npu_id, {})
    results['STRESS_TEST'] = (
        f"{render.GREEN}PASS{render.RESET} (QPS:{st.get('qps')})"
        if st.get('exit_code') == 0 else
        f"{render.RED}FAIL{render.RESET} (Exit:{st.get('exit_code')})"
    )

    return results


def main() -> None:
    """Parse the YAML pointed to by --yaml-file and write PF_result.{log,html}."""
    parser = argparse.ArgumentParser(
        description="Decode rngd-diag YAML output into a hardware health report.",
    )
    parser.add_argument("--yaml-file", required=True, help="path to rngd-diag YAML output")
    parser.add_argument(
        "--output-dir",
        default=".",
        help="directory to write PF_result.{log,html} (default: current directory)",
    )
    args = parser.parse_args()

    log_filename  = os.path.join(args.output_dir, "PF_result.log")
    html_filename = os.path.join(args.output_dir, "PF_result.html")

    # Logger duck-types stdout; the cast satisfies every mypy version.
    sys.stdout = cast("TextIO", render.Logger(log_filename))

    try:
        with open(args.yaml_file) as f:
            raw = yaml.safe_load(f)
    except Exception as e:
        print(f"Error opening/reading YAML: {e}")
        sys.exit(1)

    root   = raw.get('rngd_diag', {}).get('npus', {})
    bench  = raw.get('furiosa_hal_bench', {})
    stress = raw.get('furiosa_stress_test', {}).get('full', {})

    print("\n" + render.BOLD + "="*80 + render.RESET)
    print(render.BOLD + " Furiosa HW Component Health Check" + render.RESET)
    print(render.BOLD + "="*80 + render.RESET)
    print(f"{render.BOLD}{'NPU ID':<10} | {'ITEM':<15} | {'RESULT'}{render.RESET}")
    print("-" * 80)

    html_data = []
    for npu_id in sorted(root.keys()):
        report = check_npu_status(npu_id, root[npu_id], bench, stress)
        for item, res in report.items():
            print(f"{npu_id:<10} | {item:<15} | {res}")
            html_data.append((npu_id, item, res))
        print("-" * 80)

    render.generate_html_report(html_data, html_filename)
    sys.stdout.flush()


if __name__ == "__main__":
    main()
