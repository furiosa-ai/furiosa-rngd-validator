FROM ubuntu:24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

HEALTHCHECK NONE

ENV DEBIAN_FRONTEND=noninteractive
ENV RUN_TESTS=diag,p2p,stress

ENV HOME=/root
ENV VALIDATION_DIR=$HOME/furiosa-server-validation-tool
WORKDIR $VALIDATION_DIR

ENV OUTPUT_DIR=$VALIDATION_DIR/outputs

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

# Add FuriosaAI repository and install furiosa-toolkit-rngd.
# --fail makes curl exit non-zero on HTTP errors so a 404 fails here
# rather than letting `gpg --dearmor` consume an HTML error page.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl --fail --silent --show-error --location \
        https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /etc/apt/keyrings/furiosa.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/furiosa.gpg] https://asia-northeast3-apt.pkg.dev/projects/furiosa-ai $(. /etc/os-release && echo "$VERSION_CODENAME") main" | tee /etc/apt/sources.list.d/furiosa.list \
    && apt-get update \
    && apt-get install -y furiosa-toolkit-rngd \
    && rm -rf /var/lib/apt/lists/*

# Install furiosa-llm into an isolated venv
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
ENV PIP_EXTRA_INDEX_URL=https://asia-northeast3-python.pkg.dev/furiosa-ai/pypi/simple
RUN pip install furiosa-llm==2026.1.0 pillow pyyaml "urllib3<2" "more-itertools<11.0" \
    && pip uninstall -y torchvision

COPY entrypoint.sh $VALIDATION_DIR/entrypoint.sh
COPY scripts $VALIDATION_DIR/scripts/

ENTRYPOINT ["/root/furiosa-server-validation-tool/entrypoint.sh"]
