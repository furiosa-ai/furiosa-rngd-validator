# Contributing

This guide covers five topics: the development environment, the code style this project follows, the lint and test suite CI runs, the procedure for adding a new validation phase, and the commit and pull-request conventions this repository follows.

## Development environment

Most development can be done without NPU hardware. To run `make lint` and `make test` locally, install:

```bash
sudo apt-get install -y bats
# pyyaml is a decoder runtime dep, listed here because pytest collection imports the decoder.
pip install shellcheck-py ruff mypy types-PyYAML hadolint-coatl google-yamlfmt yamllint actionlint-py pytest pyyaml
```

`shfmt` and `dockerfmt` ship as pre-built binaries on their GitHub release pages; `.github/workflows/lint.yaml` shows the exact `curl` commands to install them.

The hardware-touching paths (`scripts/phases/run_*.sh` driving `furiosa-hal-bench`, `furiosa-llm serve`, `rngd-diag`, and `/sys/kernel/debug/rngd/mgmt*`) can only be exercised end-to-end on an actual Furiosa RNGD host.

## Code style

Python code follows the [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html) with a max line length of 99 characters (the alternative limit explicitly sanctioned by [PEP 8](https://peps.python.org/pep-0008/#maximum-line-length), overriding Google's 80). Bash scripts follow the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html) with its default 80-character limit. YAML files use the `.yaml` extension (rather than `.yml`) to match the official YAML specification. The ruff configuration in `pyproject.toml` enforces the Python rules; shellcheck handles most of the shell rules, but it does not enforce line length, so apply the 80-character limit by hand.

## Lint and test suite

Two Makefile targets wrap everything CI checks:

```bash
make lint   # shfmt + shellcheck + ruff + mypy --strict + dockerfmt + hadolint + yamlfmt + yamllint + actionlint
make test   # pytest + bats
```

Both run as jobs in `.github/workflows/{lint,test}.yaml`, so a green local run generally matches CI.

## Adding a new validation phase

A phase consists of one orchestrator script under `scripts/phases/` plus a single registration in `entrypoint.sh`. Four steps add a phase `<name>`:

1. **Script**: create `scripts/phases/run_<name>.sh`, using an existing phase (for example `scripts/phases/run_diag.sh`) as a template. The script should set `set -euo pipefail`, derive `SCRIPT_DIR` and `SCRIPTS_ROOT` the same way, source `$SCRIPTS_ROOT/lib/common.sh` for colors and logging and NPU detection and `capture_dmesg`, default its output directory to `$RUN_DIR/<name>`, write `PF_result.log` (plain text) and `PF_result.html` (HTML fragment, no `<html>/<head>/<body>` wrapper) via `lib/html.sh` helpers, and exit non-zero on failure. `generate_index.py` reads the fragment, embeds it inline in `index.html`, and then deletes the individual `PF_result.html` file.
2. **Registration**: add `if should_run_test "<name>"; then run_phase "<name>" "phases/run_<name>.sh"; fi` to `entrypoint.sh` alongside the existing phases. The `run_phase` helper records the phase's exit code at `$RUN_DIR/<name>/exit_code.txt` automatically.
3. **Index generator**: append `"<name>"` to the `PHASES` list in `scripts/tools/generate_index.py` so the run-level `index.html` and `summary.json` include the new phase.
4. **README**: add an H3 subsection under `## Phases` describing what the phase tests and its pass criterion, matching the format of the existing `diag`/`p2p`/`stress` subsections.

The phase is then selectable via `RUN_TESTS=<name>` and appears in every run summary.

## Commits and pull requests

Commit messages follow the [Conventional Commits](https://www.conventionalcommits.org/) format `<type>: <description>`. The types used in this repository are:

- `feat`: user-visible feature or behavior change (new phase, new CLI option, new output artifact)
- `fix`: bug fix
- `refactor`: structural change with no user-visible behavior impact
- `docs`: documentation only (README, CONTRIBUTING, NOTICE, long code comments)
- `test`: adding or changing tests
- `build`: build system changes (Dockerfile, Makefile build targets)
- `ci`: CI configuration under `.github/workflows/`
- `chore`: maintenance that does not fit the categories above

Each commit should cover a single concern; bundle a refactor and a behavior change into separate commits.

Pull requests targeting `furiosa-ai/furiosa-rngd-validator` should describe both the change and the motivation. Keep the PR in draft while the branch is still in flux, and mark it ready for review once CI is green.
