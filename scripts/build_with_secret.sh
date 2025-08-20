#!/usr/bin/env bash
# Helper: build Docker image using BuildKit and a temporary HF token file
# Usage: HF_TOKEN="$HF_TOKEN" ./scripts/build_with_secret.sh [additional docker build args]
set -euo pipefail

if [ -z "${HF_TOKEN:-}" ]; then
  echo "Please set HF_TOKEN as an environment variable before running this script. e.g. export HF_TOKEN=xxx"
  exit 2
fi

TMP_TOKEN_FILE=$(mktemp)
trap 'rm -f "$TMP_TOKEN_FILE"' EXIT
printf %s "$HF_TOKEN" > "$TMP_TOKEN_FILE"

# Allow user to pass extra docker build args, e.g. --build-arg MODEL_SNAPSHOT_URL=...
EXTRA_ARGS="$@"

echo "Building with BuildKit and secret file: $TMP_TOKEN_FILE"
DOCKER_BUILDKIT=1 docker build --secret id=hf_token,src="$TMP_TOKEN_FILE" $EXTRA_ARGS -t comfyui-serverless:latest .

echo "Build finished. Token file removed."
