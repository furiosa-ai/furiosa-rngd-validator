# Furiosa RNGD Validator

Validates a Furiosa RNGD-based server before production deployment. Three independent phases — `diag` (hardware diagnostics), `p2p` (NPU-to-NPU bandwidth), `stress` (LLM serving) — run in a single invocation. Each run writes one report tree: `index.html` for humans (phase reports embedded inline as collapsible sections), `summary.json` for tooling.

**Sections:**

- Setup: [Quick start](#quick-start-docker), [Prerequisites](#prerequisites)
- Run: [Running](#running)
- Interpret: [Outputs](#outputs), [Phases](#phases)
- Tune & debug: [Configuration](#configuration), [Troubleshooting](#troubleshooting)

## Quick start (Docker)

Requires [Docker](https://docs.docker.com/engine/install/) on the host. Run as root.

```bash
export HF_TOKEN=your_huggingface_token
make build && make run
```

`make run` writes the report tree to `./outputs/run_<TIMESTAMP>/`; open `index.html` first, or check `summary.json:overall_status`. If something fails, see [Troubleshooting](#troubleshooting).

## Prerequisites

### Common

- Furiosa RNGD driver loaded with `debugfs` mounted at `/sys/kernel/debug` (verify with `ls /sys/kernel/debug/rngd/mgmt*`).
- Root user — the phases read `debugfs`, drive `setpci`, and capture `dmesg`.
- A [Hugging Face access token](https://huggingface.co/settings/tokens) with terms-of-use accepted for both `stress`-phase models:
  - [`meta-llama/Llama-3.1-8B-Instruct`](https://huggingface.co/meta-llama/Llama-3.1-8B-Instruct)
  - [`Qwen/Qwen2.5-0.5B-Instruct`](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct)

### With Docker

Docker engine on the host. The image carries everything else.

### Without Docker

As root, replicate the `Dockerfile` runtime on a Debian-based distribution (Ubuntu 24.04 verified):

- From the distribution's APT repository: `ca-certificates curl git gnupg jq libpython3.12t64 pciutils python3-venv wget`.
- From the Furiosa APT repository: `furiosa-toolkit-rngd`. See `Dockerfile` for the exact source line.
- From PyPI, install the Python dependencies in a venv using `requirements.txt` (it already includes the Furiosa private PyPI extra-index URL):

```bash
cd /path/to/furiosa-rngd-validator
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Running

Pick one of two routes.

### With Docker

```bash
export HF_TOKEN=your_huggingface_token
make build   # docker build -t furiosa-rngd-validator:<VERSION> .
make run     # docker run with privileged + debugfs + outputs mounts, forwarding HF_TOKEN and RUN_TESTS
```

To run a subset of phases: `RUN_TESTS=diag,stress make run`.

The Makefile encapsulates the full `docker run` invocation (mounts, environment, image tag). Inspect it if you need to deviate.

### Without Docker

```bash
cd /path/to/furiosa-rngd-validator
source venv/bin/activate
export HF_TOKEN=your_huggingface_token
bash entrypoint.sh                       # all phases
RUN_TESTS=stress bash entrypoint.sh      # subset
```

## Outputs

Every run writes one timestamped tree under `outputs/`:

```
outputs/run_<TIMESTAMP>/
├── index.html        # entry point — open this first (all phase reports embedded inline)
├── summary.json      # machine-readable summary
├── diag/             # PF_result.log, diag.yaml, dmesg_*.log, exit_code.txt
├── p2p/              # PF_result.log, lspci-*, dmesg_*.log, exit_code.txt
├── stress/           # PF_result.log, sensor_log_*.csv, dmesg_*.log, per-model results, exit_code.txt
└── logs/stress/      # per-model per-NPU serve.log / fixed.log / sharegpt.log
```

`index.html` embeds each phase's PASS/FAIL report inline as a collapsible section (failed phases are expanded by default). `summary.json` carries the same machine-readably, plus host metadata:

```json
{
  "hostname": "host01",
  "vendor": "Supermicro",
  "model": "AS-2025BV-WTRT",
  "generated_at": "2026-05-12 14:00:00",
  "run_dir": "/root/furiosa-rngd-validator/outputs/run_20260512_140000",
  "overall_status": "pass",
  "phases": [
    {"phase": "diag",   "exit_code": 0, "status": "pass"},
    {"phase": "p2p",    "exit_code": 0, "status": "pass"},
    {"phase": "stress", "exit_code": 0, "status": "pass"}
  ]
}
```

`overall_status` is `pass` only when every executed phase exited 0, `fail` if any non-zero, and `unknown` if a phase did not record an exit code.

## Phases

Each phase tests a different aspect of the server and applies its own pass criterion. They run in fixed order `diag → p2p → stress`; the subset is selected by `RUN_TESTS` (default `diag,p2p,stress`).

### `diag` — hardware diagnostics

Runs `rngd-diag` to capture per-NPU sensor readings, PCIe link state, AER counters, and power-sense values, then compares against fixed thresholds:

| Item | Pass condition |
|---|---|
| Sensors `ta`, `npu_ambient`, `hbm`, `soc`, `pe` | 10.0 – 80.0 °C |
| Sensor `p_rms_total` | 30.0 – 60.0 W |
| `power_sense.value` | 2.0 or 3.0 |
| PCIe link speed | 32 GT/s |
| PCIe link width | x16 |
| AER `total_err_fatal` | 0 |

**Pass:** `rngd-diag` completes without error. Threshold violations are flagged in `PF_result.html` but do not fail the phase — inspect the report for per-NPU status.

### `p2p` — NPU-to-NPU bandwidth

Runs `furiosa-hal-bench p2p` between every NPU pair **twice**: once after disabling ACS on all upstream PCI bridges, once after re-enabling it. On exit the host's original ACS state is restored. The two passes are reported side-by-side so the effect of ACS can be compared. There is no built-in throughput or latency threshold; operators apply their own target spec for the host platform.

**Pass:** `furiosa-hal-bench` completes without error in both passes.

### `stress` — LLM serving stress

For each model in `STRESS_MODELS`, the phase:

- launches `furiosa-llm serve` on every detected NPU in parallel,
- polls `/v1/models` until each is ready,
- runs the fixed-length benchmark across all NPUs concurrently, then
- runs the ShareGPT benchmark across all NPUs concurrently.

A background sensor monitor samples SoC, HBM, and power into `sensor_log_*.csv` for the full duration.

**Pass:** the fixed-length and ShareGPT benchmarks both complete cleanly on every NPU.

## Configuration

Two layers of knobs tune a run. `RUN_TESTS` and `HF_TOKEN` are set on the command line; the rest default in `scripts/config.env`. Override any by exporting before invocation, or by passing `-e VAR=value` to Docker.

| Variable | Default | Purpose |
|---|---|---|
| `RUN_TESTS` | `diag,p2p,stress` | Comma-separated phase list |
| `HF_TOKEN` | — (required for `stress`) | Hugging Face token for model downloads |
| `STRESS_MODELS` | `Llama-3.1-8B-Instruct:meta-llama,Qwen2.5-0.5B-Instruct:Qwen` | Stress-phase `name:org` pairs |
| `SERVE_READY_MAX_ATTEMPTS` | `30` | `furiosa-llm serve` readiness probe attempts |
| `SERVE_READY_INTERVAL` | `60` | Seconds between readiness probes |

P2P buffer size, stress base port, and sensor poll interval also live in `scripts/config.env`.

## Troubleshooting

Five common failure modes.

**No NPUs detected** — `/sys/kernel/debug/rngd/mgmt<N>` is missing. Confirm the driver is loaded; for Docker, confirm `-v /sys/kernel/debug:/sys/kernel/debug` and `--privileged` are present (`make run` already passes them).

**`HF_TOKEN` is not set** — Export `HF_TOKEN` in the shell before running.

**Stress phase hangs at "Model on port X not ready"** — `furiosa-llm serve` takes minutes on first run (compilation + weight download). The default budget is `SERVE_READY_MAX_ATTEMPTS × SERVE_READY_INTERVAL` = 30 × 60 s = 30 min; tune those env vars for your environment.

**ACS not restored after a `p2p` abort** — `run_p2p.sh` saves the host's ACS state before disabling it and installs an `EXIT/INT/TERM` trap that restores it on exit, so a normal abort returns ACS to its pre-run state. A `SIGKILL` (e.g. `docker kill`) bypasses the trap and can leave ACS in a non-original state; reboot to re-apply the firmware ACS configuration.

**First stress run downloads `vllm` and `ShareGPT_V3_unfiltered_cleaned_split.json` into `scripts/`.** Non-Docker runs reuse them on subsequent runs. Docker runs use `--rm` and re-download each time; for repeated or air-gapped Docker use, bake the artifacts into the image. For air-gapped non-Docker use, prime the caches on a connected host first and copy them over.

---

For development setup (lint, tests, adding a phase), see [CONTRIBUTING.md](CONTRIBUTING.md). For third-party component attributions, see [NOTICE](NOTICE).
