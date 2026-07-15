# Image tag tracks the furiosa-llm pin in requirements-furiosa.txt.
VERSION ?= $(shell sed -n 's/^furiosa-llm==//p' requirements-furiosa.txt)
IMAGE := furiosa-rngd-validator:$(VERSION)
RUN_TESTS ?= diag,p2p,allgather,stress
VALIDATE_NPUS ?=
HF_CACHE_DIR ?= $(HOME)/.cache/huggingface

SHELL_SCRIPTS := \
	entrypoint.sh \
	scripts/lib/acs.sh \
	scripts/lib/common.sh \
	scripts/lib/html.sh \
	scripts/phases/run_diag.sh \
	scripts/phases/run_p2p.sh \
	scripts/phases/run_allgather.sh \
	scripts/phases/run_stress.sh

# Build the Docker image. Set NO_CACHE=1 to bypass the layer cache, e.g.
# to pick up a new furiosa-smi release without a toolkit version bump.
.PHONY: build
build:
	DOCKER_BUILDKIT=1 docker build --progress=plain $(if $(NO_CACHE),--no-cache) -t $(IMAGE) .

# Run the container with privileged + debugfs mounts. HF_TOKEN required when
# RUN_TESTS includes stress.
.PHONY: run
run:
	@if echo "$(RUN_TESTS)" | grep -wq stress && [ -z "$$HF_TOKEN" ]; then \
	    echo "ERROR: HF_TOKEN is required for the 'stress' phase but is not set"; \
	    exit 1; \
	fi
	docker run --rm -it --privileged \
	    -v /sys/kernel/debug:/sys/kernel/debug \
	    -v /lib/modules:/lib/modules:ro \
	    -v $(CURDIR)/outputs:/root/furiosa-rngd-validator/outputs \
	    -v $(HF_CACHE_DIR):/root/.cache/huggingface \
	    -e HF_TOKEN \
	    -e RUN_TESTS=$(RUN_TESTS) \
	    -e VALIDATE_NPUS="$(VALIDATE_NPUS)" \
	    -e P2P_BUFFER_SIZE="$(P2P_BUFFER_SIZE)" \
	    -e P2P_ACS_MODE="$(P2P_ACS_MODE)" \
	    -e ALLGATHER_GROUP_SIZES="$(ALLGATHER_GROUP_SIZES)" \
	    -e ALLGATHER_BUFFER_SIZE="$(ALLGATHER_BUFFER_SIZE)" \
	    $(IMAGE)

# Run all linters.
.PHONY: lint
lint: lint-sh lint-py lint-docker lint-yaml lint-actions

# Lint shell scripts.
.PHONY: lint-sh
lint-sh:
	# --indent 2 + --case-indent approximates the Google Shell Style Guide.
	# --diff exits non-zero on drift instead of rewriting in place.
	shfmt --indent 2 --case-indent --diff $(SHELL_SCRIPTS)
	# --external-sources lets shellcheck follow `# shellcheck source=...`
	# directives; --source-path=SCRIPTDIR resolves them relative to each
	# script's directory rather than the cwd shellcheck was invoked from.
	shellcheck --external-sources --source-path=SCRIPTDIR $(SHELL_SCRIPTS)

# Lint Python sources.
.PHONY: lint-py
lint-py:
	ruff check scripts/lib/sensor_monitor.py scripts/tools tests
	mypy

# Lint the Dockerfile.
.PHONY: lint-docker
lint-docker:
	# --check makes dockerfmt exit non-zero on drift; --newline keeps
	# a POSIX trailing newline.
	dockerfmt --check --newline Dockerfile
	# --failure-threshold error makes hadolint fail only on errors;
	# warnings and info stay informational.
	hadolint --failure-threshold error Dockerfile

# Lint YAML files.
.PHONY: lint-yaml
lint-yaml:
	yamlfmt -lint .github/
	yamllint --strict .github/

# Lint GitHub Actions workflows.
.PHONY: lint-actions
lint-actions:
	actionlint -color

# Run the test suite.
.PHONY: test
test: test-py test-sh

# Run pytest.
.PHONY: test-py
test-py:
	pytest tests/

# Run bats.
.PHONY: test-sh
test-sh:
	bats tests/

# Remove generated artifacts and tool caches.
.PHONY: clean
clean:
	rm -rf outputs/ .pytest_cache/ .mypy_cache/ .ruff_cache/
	find . -type d -name __pycache__ -exec rm -rf {} +
