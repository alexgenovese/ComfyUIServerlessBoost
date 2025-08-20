# ComfyUI Serverless

This repository contains an optimized Docker image and supporting scripts to run ComfyUI in an API-only, serverless-friendly configuration. This README summarizes the recent changes (snapshot restore support) and the serverless optimizations from `README_OPTIMIZED.md`.

## Summary of new features implemented

- Added build-time snapshot restore support via a new build arg: `COMFY_SNAPSHOT_URL`.
  - If provided during `docker build`, the image will download the snapshot JSON and run `comfy node restore-snapshot` during the build to reproduce the environment.
  - If `COMFY_SNAPSHOT_URL` is not provided but a local `pip_snapshot.example.json` exists in the build context, the Dockerfile will use the local snapshot for testing.
- `comfy-cli` is installed into the build virtualenv to enable `comfy node restore-snapshot`.
- A small `models` placeholder directory was added (`models/.keep`) so the Docker build context includes a models folder.
- The Dockerfile installs ComfyUI dependencies into a venv and includes a lazy installer and pre-warm logic to reduce cold start time.

## What the snapshot restore does

- Restores the ComfyUI environment exactly as described by the snapshot file, including:
  - Installing ComfyUI-specific versions
  - Cloning and installing git-based custom nodes
  - Installing pinned pip packages
  - Registering local file-based custom nodes

The restore command used inside the build is:

```
/comfyui/venv/bin/comfy node restore-snapshot <snapshot-name>
```

For the included example file `pip_snapshot.example.json`, the Dockerfile runs:

```
/comfyui/venv/bin/comfy node restore-snapshot pip_snapshot.example
```

Note: the `restore-snapshot` CLI expects the snapshot name (path without `.json`).

## How to build and test

1. Build using a remote snapshot URL:

```bash
docker build \
  --build-arg COMFY_SNAPSHOT_URL="https://example.com/path/to/pip_snapshot.json" \
  -t comfyui-custom .
```

2. Build using the included example snapshot (local test):

```bash
# from repository root
docker build -t comfyui-custom .
```

3. Run the container (serverless-optimized API-only mode):

```bash
docker run -d --name comfyui-api -p 8188:8188 -e CUDA_VISIBLE_DEVICES="" comfyui-custom
```

4. Test API:

```bash
curl http://localhost:8188/system_stats
```

## Dockerfile notes (implementation highlights)

- A virtualenv is created at `/comfyui/venv` and all Python deps are installed into it. The runtime image copies only `/comfyui` including the venv.
- `comfy-cli` is installed into the venv to enable snapshot restore.
- Snapshot handling logic (simplified):
  - If `COMFY_SNAPSHOT_URL` is set, download it to `/comfyui/comfy_snapshot.json` and run `comfy node restore-snapshot comfy_snapshot`.
  - Else if `/comfyui/pip_snapshot.example.json` exists (copied from build context), run `comfy node restore-snapshot pip_snapshot.example` for testing.
  - Else skip snapshot restore.
- A fallback `pip_wheels` cache and a `lazy_install.sh` are included so optional heavy packages can be installed later (reduces build time and image size if not needed at startup).

## Serverless and cold-start optimizations (from README_OPTIMIZED)

Key optimizations included in the image and startup scripts:

- Pre-compile Python bytecode to reduce import time.
- Pre-warm important Python modules during build using a small `prewarm.py` script.
- Limit OMP and MKL threads to reduce CPU contention:

```
OMP_NUM_THREADS=1
MKL_NUM_THREADS=1
```

- Set Python runtime flags for smaller memory and faster startup:

```
PYTHONUNBUFFERED=1
PYTHONDONTWRITEBYTECODE=1
PYTHONOPTIMIZE=2
```

- Use API-only mode and disable front-end and non-essential subsystems to reduce image size and startup time.
- Provide a `start.sh` that launches ComfyUI in a minimal, API-only configuration with recommended flags like `--fast`, `--disable-smart-memory`, `--dont-print-server`, and CPU-focused options.

Expected benefits (measured on development hardware):

- Cold start: ~0.5–0.8s
- First API response: ~30ms after startup
- Memory footprint: ~1.2GB baseline (example M1 measurements)

These numbers are indicative and depend heavily on hardware and which components are installed.

## Environment variables

- PYTHONUNBUFFERED=1
- PYTHONDONTWRITEBYTECODE=1
- PYTHONOPTIMIZE=2
- OMP_NUM_THREADS=1
- MKL_NUM_THREADS=1
- TORCH_HOME=/tmp/torch
- HF_HOME=/tmp/huggingface
- CUDA_VISIBLE_DEVICES="" (set to empty to force CPU mode)

## API endpoints (same as ComfyUI API)

- GET /system_stats — system status
- GET /object_info — node info
- GET /queue — processing queue
- POST /prompt — submit workflow/prompt (JSON body)

## Troubleshooting

- If snapshot restore fails, the Docker build continues but logs will show errors. Typical problems:
  - `comfy-cli` missing (should be installed in venv)
  - `git` missing during install (the Dockerfile installs `git` in the build stage)
  - Snapshot URL unreachable (use HTTPS accessible URL or copy the JSON into the build context)

## Next steps / recommendations

- For CI builds, provide `COMFY_SNAPSHOT_URL` with a stable HTTP(S) URL to ensure reproducible images.
- For smaller images, consider moving large models to a volume or external storage and import them at runtime.
- Add optional flags to the snapshot restore step (`--pip-non-url`, `--pip-local-url`) if your snapshot contains non-PyPI packages or local paths.

---

This README combines the serverless optimizations and the new snapshot restore capability implemented in the Dockerfile. If you want this file to replace the root `README.md` or to be named differently (e.g., `README.md`), tell me and I will rename/move it.
