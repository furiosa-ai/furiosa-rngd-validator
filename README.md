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

- Host architecture: `x86_64` or `aarch64`.
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
- From the Furiosa APT repository: `furiosa-smi` and `furiosa-toolkit-rngd`. See `Dockerfile` for the exact source line and version pins.
- From PyPI, install the Python dependencies into two separate venvs. The Furiosa toolchain and vllm have conflicting dependencies, so they must not share a venv.

```bash
cd /path/to/furiosa-rngd-validator

# Furiosa venv (furiosa-llm serve)
python3 -m venv furiosa_venv
furiosa_venv/bin/pip install -r requirements-furiosa.txt

# vllm venv (benchmark client)
python3 -m venv vllm_venv
vllm_venv/bin/pip install -r requirements-vllm.txt
```

Point the scripts at these venvs via `FURIOSA_VENV` / `VLLM_VENV` (see `scripts/config.env` for defaults).

## Running

Pick one of two routes.

### With Docker

```bash
export HF_TOKEN=your_huggingface_token
make build   # docker build -t furiosa-rngd-validator:<VERSION> .
make run     # docker run --privileged, mounting debugfs + /lib/modules + outputs + HF cache, forwarding HF_TOKEN, RUN_TESTS, VALIDATE_NPUS
```

To run a subset of phases: `RUN_TESTS=diag,stress make run`.

To test only specific NPUs instead of all detected ones, set `VALIDATE_NPUS` as a comma-separated list of indices:

```bash
VALIDATE_NPUS=0 make run              # NPU 0 only
VALIDATE_NPUS=0,2 make run            # NPUs 0 and 2
```

`VALIDATE_NPUS` is honoured by the `diag`, `p2p`, and `stress` phases. Omit it to run on all detected NPUs (default). Selecting a single NPU makes `p2p` skip (it needs a pair) and report `SKIP` rather than fail.

`make run` mounts a host Hugging Face cache into the container so weights survive across runs; it defaults to `$HOME/.cache/huggingface`. Point `HF_CACHE_DIR` elsewhere to reuse weights that already live under a different path:

```bash
HF_CACHE_DIR=/data/hf-cache make run
```


The Makefile encapsulates the full `docker run` invocation (mounts, environment, image tag). Inspect it if you need to deviate.

### Without Docker

```bash
cd /path/to/furiosa-rngd-validator
source furiosa_venv/bin/activate                       # furiosa-llm + python3 for the diag/p2p/report steps
export FURIOSA_VENV="$PWD/furiosa_venv" VLLM_VENV="$PWD/vllm_venv"
export HF_TOKEN=your_huggingface_token

bash entrypoint.sh                            # all phases
RUN_TESTS=stress bash entrypoint.sh           # subset
VALIDATE_NPUS=0 bash entrypoint.sh            # NPU 0 only
```

`scripts/config.env` defaults `FURIOSA_VENV` and `VLLM_VENV` to the in-container paths (`/opt/furiosa_venv` and `/opt/vllm_venv`), so a local install must point them at the venvs created above -- hence the export line. If your venvs live elsewhere, set those two variables to their absolute paths instead.

## Outputs

Every run writes one timestamped tree under `outputs/`:

```
outputs/run_<TIMESTAMP>/
├── index.html        # entry point — open this first (all phase reports embedded inline)
├── summary.json      # machine-readable summary
├── diag/             # PF_result.log, diag.yaml, dmesg_*.log, exit_code.txt
├── p2p/              # PF_result.log, lspci-*, dmesg_*.log, exit_code.txt
├── stress/           # PF_result.log, sensor_log_*.csv, dmesg_*.log, per-model results, exit_code.txt
└── logs/stress/      # per-model per-NPU serve.log / random.log / sharegpt.log
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

Each phase's `status` is one of `pass` (exit 0), `skip` (exit 75 — phase could not run, e.g. `p2p` with fewer than 2 NPUs), `fail` (any other non-zero), or `unknown` (no exit code recorded). `overall_status` rolls these up worst-wins with severity `fail` > `unknown` > `skip` > `pass`, so it is `pass` only when every executed phase passed or skipped.

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

Set `P2P_ACS_MODE=disable` (or `enable`) to run only that one sequence. A single-mode run does **not** restore ACS afterward — it leaves ACS in the requested state, so `P2P_ACS_MODE=disable` leaves ACS disabled on exit. Only the default both-passes run restores the pre-run state.

**Pass:** `furiosa-hal-bench` completes without error in both passes. **Skip:** fewer than 2 NPUs are selected — the phase exits 75 and is reported `SKIP` (no pair to benchmark).

### `stress` — LLM serving stress

For each model in `STRESS_MODELS`, the phase:

- launches `furiosa-llm serve` on every detected NPU in parallel,
- polls `/v1/models` until each is ready,
- runs the random benchmark across all NPUs concurrently, then
- runs the ShareGPT benchmark across all NPUs concurrently.

A background sensor monitor samples SoC, HBM, and power into `sensor_log_*.csv` for the full duration.

**Pass:** the random and ShareGPT benchmarks both complete cleanly on every NPU.

## Configuration

Two layers of knobs tune a run. `RUN_TESTS` and `HF_TOKEN` are set on the command line; the rest default in `scripts/config.env`. Override any by exporting before invocation, or by passing `-e VAR=value` to Docker.

| Variable | Default | Purpose |
|---|---|---|
| `RUN_TESTS` | `diag,p2p,stress` | Comma-separated phase list |
| `HF_TOKEN` | — (required for `stress`) | Hugging Face token for model downloads |
| `STRESS_MODELS` | `Llama-3.1-8B-Instruct:meta-llama,Qwen2.5-0.5B-Instruct:Qwen` | Stress-phase `name:org` pairs |
| `STRESS_REVISION` | `v2026.2` | `furiosa-llm` model artifact revision |
| `STRESS_RANDOM_TRIPLES` | `1024:1024:128,…,31744:1024:1` | Random-benchmark `in_len:out_len:concurrency` triples |
| `SERVE_READY_MAX_ATTEMPTS` | `30` | `furiosa-llm serve` readiness probe attempts |
| `SERVE_READY_INTERVAL` | `60` | Seconds between readiness probes |

P2P buffer size (`P2P_BUFFER_SIZE`), stress base port (`STRESS_BASE_PORT`), and sensor poll interval (`SENSOR_POLL_INTERVAL`) also live in `scripts/config.env`.

## Troubleshooting

Five common failure modes.

**No NPUs detected** — `/sys/kernel/debug/rngd/mgmt<N>` is missing. Confirm the driver is loaded; for Docker, confirm `-v /sys/kernel/debug:/sys/kernel/debug` and `--privileged` are present (`make run` already passes them).

**`HF_TOKEN` is not set** — Export `HF_TOKEN` in the shell before running.

**Stress phase hangs at "Model on port X not ready"** — `furiosa-llm serve` takes minutes on first run (compilation + weight download). The default budget is `SERVE_READY_MAX_ATTEMPTS × SERVE_READY_INTERVAL` = 30 × 60 s = 30 min; tune those env vars for your environment.

**ACS not restored after a `p2p` abort** — `run_p2p.sh` saves the host's ACS state before disabling it and installs an `EXIT/INT/TERM` trap that restores it on exit, so a normal abort returns ACS to its pre-run state. A `SIGKILL` (e.g. `docker kill`) bypasses the trap and can leave ACS in a non-original state. The pre-run per-bridge values are written to `<run_dir>/p2p/acs_init_state` before anything is changed, so re-apply the ACS configuration manually with `sudo bash scripts/lib/acs.sh --mode restore <run_dir>/p2p/acs_init_state`.

**`p2p` fails with "ACS \<mode\> sequence failed on one or more bridges"** — a bridge rejected the `ACSCtl` write (see the preceding `WARN:` lines for which). The sequence still walks every remaining bridge, so only the named bridges are left at their previous value; the phase then fails rather than benchmarking a host that is not fully in the requested ACS state.

**`p2p` fails with "ACS restore FAILED"** — a bridge rejected the write that would return it to its pre-run `ACSCtl` value, so it is still at the benchmark's value and has lost the isolation the firmware configured. The phase fails even if the benchmark itself passed. `PF_result.log` ends with the exact retry command — re-apply the ACS configuration manually before using this host.

**`<run_dir>/p2p/acs_init_state` left behind** — not a failure mode in itself, but the marker of one: the file holds the per-bridge `ACSCtl` values from before the run and is removed only when the phase passes. Any run that failed or was interrupted keeps it, including a `P2P_ACS_MODE=disable`/`enable` run that set ACS as asked and then failed in the test — that path deliberately skips the restore, so this file is the only way back. Roll back with `sudo bash scripts/lib/acs.sh --mode restore <run_dir>/p2p/acs_init_state`.

**First stress run downloads `vllm` and `ShareGPT_V3_unfiltered_cleaned_split.json` into `scripts/`.** Non-Docker runs reuse them on subsequent runs. Docker runs use `--rm` and re-download each time; for repeated or air-gapped Docker use, bake the artifacts into the image. For air-gapped non-Docker use, prime the caches on a connected host first and copy them over.

---

For development setup (lint, tests, adding a phase), see [CONTRIBUTING.md](CONTRIBUTING.md). For third-party component attributions, see [NOTICE](NOTICE).
