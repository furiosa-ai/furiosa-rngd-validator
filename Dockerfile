FROM ubuntu:24.04

ARG TARGETARCH

# ======================================================================
# Package version policy
# ======================================================================
# furiosa-smi tracks the newest APT release (deliberately unpinned);
# furiosa-toolkit-rngd tracks the newest 2026.2.x APT revision;
# Python package versions live in requirements.txt.
# Version values sit next to their consuming layers so a version bump
# does not invalidate the unrelated layers above.

# ======================================================================
# Base configuration
# ======================================================================
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

HEALTHCHECK NONE

ENV DEBIAN_FRONTEND=noninteractive
ENV RUN_TESTS=diag,p2p,stress

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
# Install furiosa-llm into an isolated venv
# ======================================================================
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# ======================================================================
# Python package installation
# ======================================================================
COPY requirements.txt $VALIDATOR_DIR/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

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
