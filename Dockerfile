FROM ubuntu:24.04

ARG TARGETARCH

# ======================================================================
# Package version policy
# ======================================================================
# furiosa-smi tracks the newest APT release (deliberately unpinned);
# furiosa-toolkit-rngd tracks the newest 2026.2.x APT revision;
# Python package versions live in `requirements-furiosa.txt` and `requirements-vllm.txt`.
# Version values sit next to their consuming layers so a version bump
# does not invalidate the unrelated layers above.

# ======================================================================
# Base configuration
# ======================================================================
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

HEALTHCHECK NONE

ENV DEBIAN_FRONTEND=noninteractive
ENV RUN_TESTS=diag,p2p,allgather,stress

ENV HOME=/root
ENV VALIDATOR_DIR=$HOME/furiosa-rngd-validator
WORKDIR $VALIDATOR_DIR

ENV OUTPUT_DIR=$VALIDATOR_DIR/outputs

# ======================================================================
# Install common basic packages
# ======================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    libpython3.12t64 \
    pciutils \
    python3-venv \
    wget \
    && rm -rf /var/lib/apt/lists/*

# ======================================================================
# Add FuriosaAI repository and install furiosa-toolkit-rngd.
# ======================================================================
# --fail makes curl exit non-zero on HTTP errors so a 404 fails here
# rather than letting `gpg --dearmor` consume an HTML error page.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl --fail --silent --show-error --location \
        https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /etc/apt/keyrings/furiosa.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/furiosa.gpg] https://asia-northeast3-apt.pkg.dev/projects/furiosa-ai $(. /etc/os-release && echo "$VERSION_CODENAME") main" | tee /etc/apt/sources.list.d/furiosa.list

# ======================================================================
# Install FuriosaAI packages
# ======================================================================
ENV FURIOSA_TOOLKIT_RNGD_VERSION=2026.2.*
RUN apt-get update \
    && apt-get install -y \
        furiosa-smi \
        furiosa-toolkit-rngd="$FURIOSA_TOOLKIT_RNGD_VERSION" \
    && rm -rf /var/lib/apt/lists/*

# ======================================================================
# Python package installation — two isolated venvs
# ======================================================================
# furiosa_venv: furiosa-llm and its transitive deps (incl. transformers==5.1.0).
# vllm_venv:    vllm and its deps (requires transformers!=5.1.*); kept separate
#               so the two incompatible transformers pins never conflict.
ENV FURIOSA_VENV=/opt/furiosa_venv
ENV VLLM_VENV=/opt/vllm_venv
ENV PATH="$FURIOSA_VENV/bin:$PATH"

COPY requirements-furiosa.txt $VALIDATOR_DIR/requirements-furiosa.txt
RUN python3 -m venv "$FURIOSA_VENV" \
    && "$FURIOSA_VENV/bin/pip" install --no-cache-dir -r requirements-furiosa.txt
COPY requirements-vllm.txt $VALIDATOR_DIR/requirements-vllm.txt
RUN python3 -m venv "$VLLM_VENV" \
    && "$VLLM_VENV/bin/pip" install --no-cache-dir -r requirements-vllm.txt

# ======================================================================
# Copy application files
# ======================================================================
COPY entrypoint.sh $VALIDATOR_DIR/entrypoint.sh
COPY scripts $VALIDATOR_DIR/scripts/

# Keep only the arch-appropriate rngd-diag binary to reduce image size.
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        rm -f "$VALIDATOR_DIR/scripts/bin/rngd-diag-amd64"; \
    elif [ "$TARGETARCH" = "amd64" ]; then \
        rm -f "$VALIDATOR_DIR/scripts/bin/rngd-diag-arm64"; \
    fi

ENTRYPOINT ["/root/furiosa-rngd-validator/entrypoint.sh"]
