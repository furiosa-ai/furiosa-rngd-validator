FROM ubuntu:24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ENV FURIOSA_SKIP_PERT_DEPLOY=1
ENV RUN_TESTS=diag,p2p,stress

ENV HOME=/root
ENV VALIDATION_DIR=$HOME/furiosa-server-validation-tool
WORKDIR $VALIDATION_DIR

ENV OUTPUT_DIR=$VALIDATION_DIR/outputs

RUN apt-get update && apt-get install -y --no-install-recommends \
    sudo \
    bash \
    pciutils \
    python3 \
    python3-venv \
    ca-certificates \
    jq \
    curl \
    gnupg \
    wget \
    vim \
    git \
    && rm -rf /var/lib/apt/lists/*

# Add FuriosaAI repository and install furiosa-toolkit-rngd
RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/cloud.google.gpg \
    && echo "deb [arch=$(dpkg --print-architecture)] http://asia-northeast3-apt.pkg.dev/projects/furiosa-ai $(. /etc/os-release && echo "$VERSION_CODENAME") main" | tee /etc/apt/sources.list.d/furiosa.list \
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
