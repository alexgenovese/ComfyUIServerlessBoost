#!/bin/bash
set -e

echo "=== Testing Snapshot Logic ==="

# Simula le variabili d'ambiente del Dockerfile
COMFY_SNAPSHOT_URL=""

# Test 1: Con file locale (simula il nostro caso)
if [ -n "${COMFY_SNAPSHOT_URL}" ]; then
    echo "COMFY_SNAPSHOT_URL provided: fetching snapshot from ${COMFY_SNAPSHOT_URL}"
    # wget -q -O /comfyui/comfy_snapshot.json "${COMFY_SNAPSHOT_URL}" || echo "Failed to fetch snapshot from URL"
    # if [ -f /comfyui/comfy_snapshot.json ]; then
    #     echo "Restoring ComfyUI snapshot from downloaded file"
    #     cd /comfyui
    #     /comfyui/venv/bin/comfy node restore-snapshot comfy_snapshot || echo "Comfy snapshot restore finished with errors"
    # fi
elif [ -f ./pip_snapshot.example.json ]; then
    echo "Using local pip_snapshot.example.json for testing"
    echo "Found pip_snapshot.example.json file:"
    ls -la pip_snapshot.example.json
    echo "File content preview (first 10 lines):"
    head -10 pip_snapshot.example.json
    echo "Would execute: comfy node restore-snapshot pip_snapshot.example"
else
    echo "No snapshot provided, skipping snapshot restore"
fi

echo "=== Test completed ==="
