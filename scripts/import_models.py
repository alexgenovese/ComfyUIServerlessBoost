#!/usr/bin/env python3
"""
Simple importer to parse a Comfy Manager models snapshot JSON and download files
into the ComfyUI models structure during Docker build.

Usage:
    python import_models.py <snapshot.json> <dest_models_dir>

Behavior:
- Expect snapshot JSON to be a mapping of model entries with a `download_url` and
  a `path` (relative inside models) or `type` to decide destination folder.
- Downloads files with simple retry and places them in the right subfolder.
- Does not attempt to install or register models beyond placing files.

This script is intentionally small and defensive for build-time usage.
"""
import sys
import json
import os
import pathlib
import urllib.request
import shutil
import time

DEFAULT_LAYOUT = {
    "checkpoints": ["ckpt", "safetensors", "pt"],
    "vae": ["vae"],
    "diffusers": ["diffusers", "diffuser"],
    "embeddings": ["embeddings", "bin"],
    "clip": ["clip"],
    "upscale_models": ["upscale", "realesrgan"],
}


def ensure_dir(p):
    os.makedirs(p, exist_ok=True)


def download_file(url, dest, retries=3, backoff=1.5):
    tmp = str(dest) + ".tmp"
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                with open(tmp, "wb") as f:
                    shutil.copyfileobj(r, f)
            os.replace(tmp, dest)
            return True
        except Exception as e:
            print(f"Attempt {attempt} failed: {e}")
            time.sleep(backoff * attempt)
    return False


def choose_folder_by_name(filename):
    name = filename.lower()
    for folder, keywords in DEFAULT_LAYOUT.items():
        for kw in keywords:
            if kw in name:
                return folder
    return "checkpoints"


def main():
    if len(sys.argv) < 3:
        print("Usage: import_models.py <snapshot.json> <dest_models_dir>")
        sys.exit(2)

    snapshot_path = sys.argv[1]
    dest_root = sys.argv[2]

    with open(snapshot_path, "r") as f:
        data = json.load(f)

    # Accept either list or dict
    entries = []
    if isinstance(data, dict):
        # If top-level has 'models' key use it
        if "models" in data and isinstance(data["models"], list):
            entries = data["models"]
        else:
            # fallback: values of dict
            entries = list(data.values())
    elif isinstance(data, list):
        entries = data
    else:
        print("Unrecognized JSON structure in snapshot")
        sys.exit(1)

    print(f"Found {len(entries)} model entries in snapshot")

    downloaded = 0
    for entry in entries:
        # entry may have different shapes; try common keys
        url = entry.get("download_url") or entry.get("url") or entry.get("file_url") or entry.get("location")
        name = entry.get("name") or entry.get("filename") or None
        rel_path = entry.get("path") or entry.get("relative_path") or None

        if not url:
            print(f"Skipping entry with no download URL: {entry}")
            continue

        if not name:
            name = os.path.basename(url.split("?")[0])

        # decide destination folder
        if rel_path:
            dest = pathlib.Path(dest_root) / rel_path
            ensure_dir(dest.parent)
        else:
            folder = choose_folder_by_name(name)
            dest_dir = pathlib.Path(dest_root) / folder
            ensure_dir(dest_dir)
            dest = dest_dir / name

        if dest.exists():
            print(f"Already exists, skipping: {dest}")
            continue

        print(f"Downloading {name} -> {dest}")
        ok = download_file(url, dest)
        if ok:
            print(f"Downloaded: {dest}")
            downloaded += 1
        else:
            print(f"Failed to download {url}")

    print(f"Model import finished. Downloaded: {downloaded}")


if __name__ == "__main__":
    main()
