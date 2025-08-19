# syntax=docker/dockerfile:1.4

################################################################################
# Multi-stage Dockerfile per ComfyUI - organizzato in layer per categoria
# Goal: separare e documentare i layer principali per attività (base, system deps,
# app clone, python env, wheels, model import, scripts, cleanup, runtime).
################################################################################

ARG BASE_IMAGE=python:3.12-slim
FROM ${BASE_IMAGE} AS builder

# -----------------------------
# Layer: environment defaults
# -----------------------------
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV COMFYUI_VERSION=v0.2.2
ARG MODEL_SNAPSHOT_URL=""
ARG MODEL_IMPORT=0

WORKDIR /comfyui

# -----------------------------
# Layer: system packages (build-time)
# - Install OS packages required for building wheels and runtime libs
# -----------------------------
RUN --mount=type=cache,target=/var/cache/apt,id=builder-apt \
    --mount=type=cache,target=/var/lib/apt,id=builder-apt-lib \
    apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv git wget curl build-essential cmake \
        libjpeg-dev zlib1g-dev libgl1-mesa-dri libglu1-mesa libglib2.0-0 \
        libsm6 libxext6 libxrender-dev libgomp1 ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------
# Layer: clone application source
# - clone at a reproducible tag/commit
# -----------------------------
RUN git clone https://github.com/comfyanonymous/ComfyUI.git . && \
    git checkout ${COMFYUI_VERSION}

# -----------------------------
# syntax=docker/dockerfile:1.4

################################################################################
# Multi-stage Dockerfile for ComfyUI
# Stages (logical layers):
#  - build         : install system build deps, clone source
#  - pip-install   : create venv, download wheels, install python deps
#  - comfy         : app-specific setup (scripts, precompile, cleanup)
#  - runtime       : small runtime image copying only venv + app
################################################################################

ARG BASE_IMAGE=python:3.12-slim

################################################################################
# Stage: build
# - install OS build dependencies required to build wheels
# - clone the ComfyUI repo at a reproducible tag
################################################################################
FROM ${BASE_IMAGE} AS build

ENV DEBIAN_FRONTEND=noninteractive
ARG COMFYUI_VERSION=v0.2.2
WORKDIR /comfyui

RUN --mount=type=cache,target=/var/cache/apt,id=build-apt \
    --mount=type=cache,target=/var/lib/apt,id=build-apt-lib \
    apt-get update && apt-get install -y --no-install-recommends \
        git wget curl build-essential cmake python3-dev python3-venv python3-pip \
        libjpeg-dev zlib1g-dev libgl1-mesa-dri libglu1-mesa libglib2.0-0 \
        libsm6 libxext6 libxrender-dev libgomp1 ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Clone application code
RUN git clone https://github.com/comfyanonymous/ComfyUI.git . && \
    git checkout ${COMFYUI_VERSION}

# Copy models placeholder (from build context)
COPY models /comfyui/models

# Copy import helper
COPY scripts/import_models.py /comfyui/scripts/import_models.py
RUN chmod +x /comfyui/scripts/import_models.py || true

################################################################################
# Stage: pip-install
# - create virtualenv, upgrade tooling, pre-download wheels and install requirements
# - keep caches mounted for faster incremental builds
################################################################################
FROM build AS pip-install

ARG MODEL_SNAPSHOT_URL=""
ARG MODEL_IMPORT=0

# Create venv and upgrade pip tooling
RUN python3 -m pip install --upgrade pip virtualenv wheel setuptools && \
    python3 -m virtualenv /comfyui/venv && \
    /comfyui/venv/bin/pip install --upgrade pip setuptools wheel

RUN mkdir -p /comfyui/pip_wheels /comfyui/.cache/pip

# Optional: import models snapshot during build (only if MODEL_IMPORT=1)
RUN if [ "${MODEL_IMPORT}" = "1" ] && [ -n "${MODEL_SNAPSHOT_URL}" ]; then \
        echo "MODEL_IMPORT enabled: fetching models snapshot from ${MODEL_SNAPSHOT_URL}" && \
        wget -q -O /comfyui/models_snapshot.json "${MODEL_SNAPSHOT_URL}" || echo "Failed to fetch snapshot from URL"; \
        if [ -f /comfyui/models_snapshot.json ]; then \
            echo "Importing models from /comfyui/models_snapshot.json" && \
            python3 /comfyui/scripts/import_models.py /comfyui/models_snapshot.json /comfyui/models || echo "Model import finished with errors"; \
        fi; \
    else \
        echo "MODEL_IMPORT disabled or no snapshot URL provided, skipping remote model import"; \
    fi

# Pre-download wheels (best-effort)
RUN --mount=type=cache,target=/root/.cache/pip,id=pip-cache \
    /comfyui/venv/bin/pip download --dest /comfyui/pip_wheels -r requirements.txt || true

# Install runtime requirements into the venv (so runtime can just copy venv)
RUN --mount=type=cache,target=/root/.cache/pip,id=pip-cache \
    /comfyui/venv/bin/pip install --no-cache-dir --find-links /comfyui/pip_wheels -r requirements.txt || true

# Optionally install torch from wheels (best-effort)
RUN --mount=type=cache,target=/root/.cache/pip,id=pip-cache \
    if echo "${BASE_IMAGE}" | grep -q "nvidia/cuda"; then \
        /comfyui/venv/bin/pip install --no-cache-dir --find-links /comfyui/pip_wheels torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu121 || true; \
    else \
        /comfyui/venv/bin/pip install --no-cache-dir --find-links /comfyui/pip_wheels torch torchvision torchaudio || true; \
    fi

################################################################################
# Stage: comfy
# - perform app-specific setup: precompile, cleanup, create start/lazy scripts
# - this stage depends on pip-install (which has venv and installed deps)
################################################################################
FROM pip-install AS comfy

# Pre-compile Python bytecode for faster startup
RUN /comfyui/venv/bin/python -m compileall /comfyui -b -q || true

# Remove python build artifacts and repo cruft to slim the image
RUN find /comfyui -name "*.py[co]" -delete || true && \
    find /comfyui -name "__pycache__" -type d -exec rm -rf {} + || true
RUN rm -rf /comfyui/.git* /comfyui/tests /comfyui/docs || true && \
    rm -rf /comfyui/web/extensions /comfyui/web/lib || true

# Add start and lazy-install scripts
RUN mkdir -p /comfyui

# start.sh (optimized for serverless cold start)
RUN echo '#!/bin/bash' > /comfyui/start.sh && \
    echo 'set -e' >> /comfyui/start.sh && \
    echo '' >> /comfyui/start.sh && \
    echo '# Pre-warm Python and core modules for faster startup' >> /comfyui/start.sh && \
    echo 'export PYTHONPATH="/comfyui:$PYTHONPATH"' >> /comfyui/start.sh && \
    echo 'export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-}"' >> /comfyui/start.sh && \
    echo 'export PYTORCH_CUDA_ALLOC_CONF="max_split_size_mb:512"' >> /comfyui/start.sh && \
    echo 'export OMP_NUM_THREADS=1' >> /comfyui/start.sh && \
    echo 'export MKL_NUM_THREADS=1' >> /comfyui/start.sh && \
    echo '' >> /comfyui/start.sh && \
    echo '# Start lazy installer in background if requested' >> /comfyui/start.sh && \
    echo 'if [ "${LAZY_INSTALL:-0}" = "1" ]; then' >> /comfyui/start.sh && \
    echo '    echo "LAZY_INSTALL enabled: starting background installer"' >> /comfyui/start.sh && \
    echo '    /comfyui/lazy_install.sh &' >> /comfyui/start.sh && \
    echo 'fi' >> /comfyui/start.sh && \
    echo '' >> /comfyui/start.sh && \
    echo '# Launch ComfyUI API-only mode optimized for serverless' >> /comfyui/start.sh && \
    echo 'exec /comfyui/venv/bin/python -u main.py \' >> /comfyui/start.sh && \
    echo '    --listen 0.0.0.0 \' >> /comfyui/start.sh && \
    echo '    --port 8188 \' >> /comfyui/start.sh && \
    echo '    --disable-auto-launch \' >> /comfyui/start.sh && \
    echo '    --dont-print-server \' >> /comfyui/start.sh && \
    echo '    --cpu \' >> /comfyui/start.sh && \
    echo '    --cpu-vae \' >> /comfyui/start.sh && \
    echo '    --fp16-vae \' >> /comfyui/start.sh && \
    echo '    --force-fp16 \' >> /comfyui/start.sh && \
    echo '    --fast \' >> /comfyui/start.sh && \
    echo '    --disable-smart-memory \' >> /comfyui/start.sh && \
    echo '    --disable-xformers \' >> /comfyui/start.sh && \
    echo '    "$@"' >> /comfyui/start.sh
RUN chmod +x /comfyui/start.sh

# lazy_install.sh
RUN echo '#!/bin/bash' > /comfyui/lazy_install.sh && \
    echo 'set -e' >> /comfyui/lazy_install.sh && \
    echo '' >> /comfyui/lazy_install.sh && \
    echo 'echo "Starting lazy_install script"' >> /comfyui/lazy_install.sh && \
    echo 'sleep 5' >> /comfyui/lazy_install.sh && \
    echo '' >> /comfyui/lazy_install.sh && \
    echo 'VENV=/comfyui/venv' >> /comfyui/lazy_install.sh && \
    echo 'PIP="$VENV/bin/pip"' >> /comfyui/lazy_install.sh && \
    echo 'PYTHON="$VENV/bin/python"' >> /comfyui/lazy_install.sh && \
    echo '' >> /comfyui/lazy_install.sh && \
    echo 'echo "Using pip: $PIP"' >> /comfyui/lazy_install.sh && \
    echo '' >> /comfyui/lazy_install.sh && \
    echo 'echo "Checking CUDA availability"' >> /comfyui/lazy_install.sh && \
    echo 'HAS_CUDA=$($PYTHON -c "import sys; import torch; print(1 if torch.cuda.is_available() else 0)" 2>/dev/null || echo 0)' >> /comfyui/lazy_install.sh && \
    echo '' >> /comfyui/lazy_install.sh && \
    echo 'echo "CUDA available: $HAS_CUDA"' >> /comfyui/lazy_install.sh && \
    echo '' >> /comfyui/lazy_install.sh && \
    echo 'pkgs=()' >> /comfyui/lazy_install.sh && \
    echo 'if [ "$HAS_CUDA" -eq 1 ]; then' >> /comfyui/lazy_install.sh && \
    echo '    pkgs=(xformers flash-attn sageattention ninja)' >> /comfyui/lazy_install.sh && \
    echo 'else' >> /comfyui/lazy_install.sh && \
    echo '    pkgs=(ninja)' >> /comfyui/lazy_install.sh && \
    echo 'fi' >> /comfyui/lazy_install.sh && \
    echo '' >> /comfyui/lazy_install.sh && \
    echo 'for p in "${pkgs[@]}"; do' >> /comfyui/lazy_install.sh && \
    echo '    echo "Installing $p"' >> /comfyui/lazy_install.sh && \
    echo '    $PIP install --no-cache-dir --find-links /comfyui/pip_wheels "$p" || echo "failed to install $p"' >> /comfyui/lazy_install.sh && \
    echo 'done' >> /comfyui/lazy_install.sh && \
    echo '' >> /comfyui/lazy_install.sh && \
    echo 'echo "Lazy install finished"' >> /comfyui/lazy_install.sh
RUN chmod +x /comfyui/lazy_install.sh

# Remove build-only packages (best-effort)
RUN apt-get remove -y --purge build-essential cmake python3-dev || true && apt-get autoremove -y || true && apt-get clean -y || true

################################################################################
# Stage: runtime - small image copying only venv + app
################################################################################
FROM ${BASE_IMAGE} AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONOPTIMIZE=2
ENV PYTHONHASHSEED=random
ENV TORCH_HOME=/tmp/torch
ENV HF_HOME=/tmp/huggingface

WORKDIR /comfyui

RUN --mount=type=cache,target=/var/cache/apt,id=runtime-apt \
    --mount=type=cache,target=/var/lib/apt,id=runtime-apt-lib \
    apt-get update && apt-get install -y --no-install-recommends \
        git wget curl ca-certificates libglib2.0-0 libgomp1 libsm6 libxext6 \
    && rm -rf /var/lib/apt/lists/*

# Copy built app + venv from comfy stage
COPY --from=comfy /comfyui /comfyui

# Create pre-warm script for faster cold starts
RUN echo '#!/usr/bin/env python3' > /comfyui/prewarm.py && \
    echo 'import sys' >> /comfyui/prewarm.py && \
    echo 'sys.path.insert(0, "/comfyui")' >> /comfyui/prewarm.py && \
    echo 'try:' >> /comfyui/prewarm.py && \
    echo '    print("Pre-warming Python modules...")' >> /comfyui/prewarm.py && \
    echo '    import torch' >> /comfyui/prewarm.py && \
    echo '    import numpy as np' >> /comfyui/prewarm.py && \
    echo '    import PIL' >> /comfyui/prewarm.py && \
    echo '    print("Core modules loaded successfully")' >> /comfyui/prewarm.py && \
    echo '    import folder_paths' >> /comfyui/prewarm.py && \
    echo '    import model_management' >> /comfyui/prewarm.py && \
    echo '    print("ComfyUI core modules loaded")' >> /comfyui/prewarm.py && \
    echo 'except Exception as e:' >> /comfyui/prewarm.py && \
    echo '    print(f"Pre-warm completed with some errors: {e}")' >> /comfyui/prewarm.py

RUN cd /comfyui && timeout 30s /comfyui/venv/bin/python /comfyui/prewarm.py || echo "Pre-warm completed"

# Create optimized config for serverless
RUN echo 'import os' > /comfyui/extra_model_paths.yaml.py && \
    echo 'base_path = "/comfyui/models"' >> /comfyui/extra_model_paths.yaml.py && \
    echo 'checkpoints = os.path.join(base_path, "checkpoints")' >> /comfyui/extra_model_paths.yaml.py && \
    echo 'vae = os.path.join(base_path, "vae")' >> /comfyui/extra_model_paths.yaml.py

RUN mkdir -p /comfyui/models/{checkpoints,clip,configs,controlnet,diffusers,embeddings,gligen,hypernetworks,loras,style_models,unet,upscale_models,vae} && \
    mkdir -p /comfyui/input /comfyui/output /comfyui/temp && \
    touch /comfyui/models/checkpoints/.keep

RUN groupadd -r comfy && useradd -r -g comfy -m -d /home/comfy -s /bin/bash comfy || true
RUN chown -R comfy:comfy /comfyui || true

VOLUME ["/comfyui/models", "/comfyui/pip_wheels"]

EXPOSE 8188
ENV PATH="/comfyui/venv/bin:${PATH}"

USER comfy

CMD ["/comfyui/start.sh"]

