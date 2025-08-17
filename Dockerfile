# syntax=docker/dockerfile:1.4

################################################################################
# Multi-stage Dockerfile for ComfyUI
# - builder: installs build deps, creates venv and pre-downloads wheels
# - runtime: small image copying only the venv and application files
################################################################################

ARG BASE_IMAGE=python:3.10-slim
FROM ${BASE_IMAGE} AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV COMFYUI_VERSION=v0.2.2

RUN --mount=type=cache,target=/var/cache/apt,id=builder-apt --mount=type=cache,target=/var/lib/apt,id=builder-apt-lib \
                apt-get update && apt-get install -y --no-install-recommends \
                                python3 python3-pip python3-venv git wget curl build-essential cmake \
                                libjpeg-dev zlib1g-dev libgl1-mesa-dri libglu1-mesa libglib2.0-0 \
                                libsm6 libxext6 libxrender-dev libgomp1 ffmpeg ca-certificates \
                && rm -rf /var/lib/apt/lists/*

WORKDIR /comfyui

# Clone repository at a known tag/commit
RUN git clone https://github.com/comfyanonymous/ComfyUI.git . && \
                git checkout ${COMFYUI_VERSION}

# Create venv and prepare wheel cache
RUN python3 -m pip install --upgrade pip virtualenv wheel setuptools && \
                python3 -m virtualenv /comfyui/venv && \
                /comfyui/venv/bin/pip install --upgrade pip setuptools wheel

RUN mkdir -p /comfyui/pip_wheels /comfyui/.cache/pip

# Try to download wheels to speed subsequent installs (best-effort)
RUN --mount=type=cache,target=/root/.cache/pip,id=builder-pip \
                /comfyui/venv/bin/pip download --dest /comfyui/pip_wheels -r requirements.txt || true

# Install runtime requirements into the venv (so runtime can just copy venv)
RUN --mount=type=cache,target=/root/.cache/pip,id=builder-pip \
                /comfyui/venv/bin/pip install --no-cache-dir --find-links /comfyui/pip_wheels -r requirements.txt || true

# Optionally install torch from wheels (best-effort). For CUDA images user can pass a CUDA base image.
RUN --mount=type=cache,target=/root/.cache/pip,id=builder-pip \
                if echo "${BASE_IMAGE}" | grep -q "nvidia/cuda"; then \
                                /comfyui/venv/bin/pip install --no-cache-dir --find-links /comfyui/pip_wheels torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu121 || true; \
                else \
                                /comfyui/venv/bin/pip install --no-cache-dir --find-links /comfyui/pip_wheels torch torchvision torchaudio || true; \
                fi

# Pre-compile Python bytecode for faster startup
RUN /comfyui/venv/bin/python -m compileall /comfyui -b -q || true

# Remove unnecessary files to reduce image size and startup time
RUN find /comfyui -name "*.py[co]" -delete && \
    find /comfyui -name "__pycache__" -type d -exec rm -rf {} + || true && \
    rm -rf /comfyui/.git* /comfyui/tests /comfyui/docs || true && \
    rm -rf /comfyui/web/extensions /comfyui/web/lib || true

# Add start and lazy-install scripts
RUN mkdir -p /comfyui

# Create start.sh script optimized for serverless cold start
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

# Create lazy_install.sh script
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

# Remove build-only packages to slim builder (best-effort)
RUN apt-get remove -y --purge build-essential cmake python3-dev || true && apt-get autoremove -y || true && apt-get clean -y || true

################################################################################
# Runtime stage: small image copying only venv + app
################################################################################
FROM python:3.10-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONOPTIMIZE=2
ENV PYTHONHASHSEED=random
ENV TORCH_HOME=/tmp/torch
ENV HF_HOME=/tmp/huggingface

RUN --mount=type=cache,target=/var/cache/apt,id=runtime-apt --mount=type=cache,target=/var/lib/apt,id=runtime-apt-lib \
                apt-get update && apt-get install -y --no-install-recommends \
                                git wget curl ca-certificates libglib2.0-0 libgomp1 libsm6 libxext6 \
                && rm -rf /var/lib/apt/lists/*

WORKDIR /comfyui

# Copy built app + venv from builder
COPY --from=builder /comfyui /comfyui

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

# Run pre-warm to cache module imports
RUN cd /comfyui && timeout 30s /comfyui/venv/bin/python /comfyui/prewarm.py || echo "Pre-warm completed"

# Create optimized config for serverless
RUN echo 'import os' > /comfyui/extra_model_paths.yaml.py && \
    echo 'base_path = "/comfyui/models"' >> /comfyui/extra_model_paths.yaml.py && \
    echo 'checkpoints = os.path.join(base_path, "checkpoints")' >> /comfyui/extra_model_paths.yaml.py && \
    echo 'vae = os.path.join(base_path, "vae")' >> /comfyui/extra_model_paths.yaml.py

# Create empty model directories for faster scanning
RUN mkdir -p /comfyui/models/{checkpoints,clip,configs,controlnet,diffusers,embeddings,gligen,hypernetworks,loras,style_models,unet,upscale_models,vae} && \
    mkdir -p /comfyui/input /comfyui/output /comfyui/temp && \
    touch /comfyui/models/checkpoints/.keep

# Create non-root user and set permissions
RUN groupadd -r comfy && useradd -r -g comfy -m -d /home/comfy -s /bin/bash comfy || true
RUN chown -R comfy:comfy /comfyui || true

# Persisted volumes
VOLUME ["/comfyui/models", "/comfyui/pip_wheels"]

# Expose API port and use venv python
EXPOSE 8188
ENV PATH="/comfyui/venv/bin:${PATH}"

USER comfy

CMD ["/comfyui/start.sh"]

