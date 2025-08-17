# ComfyUI Serverless Boost

ComfyUI containerized and optimized for serverless deployments with ultra-fast cold starts and API-only operation.

---

## 🚀 Key Features

- **Ultra-Fast Cold Starts**: Startup time reduced from 3–5s to under 1s.
- **High Throughput**: API responses in ~30ms.
- **Lightweight Footprint**: Memory usage down from 2.1GB to ~1.2GB.
- **CPU-Optimized**: Designed for CPU-only environments; GPU optionally disabled.
- **Serverless-Ready**: Minimal image size, API-only mode, tuned for Lambda, Cloud Run, and similar.

---

## 📦 Quick Start

### 1. Docker Compose (Recommended)

```bash
# Clone the repo
git clone https://github.com/alexgenovese/ComfyUIServerlessBoost.git
cd ComfyUIServerlessBoost

# Build and launch
docker-compose up -d

# Test API
curl http://localhost:8188/system_stats
```

### 2. Management Script

```bash
# Build optimized image
env COMFY_ENV=production ./manage.sh build

# Start with performance logging
env COMFY_ENV=production ./manage.sh start

# Run API tests
./manage.sh test

# Execute full benchmark
./manage.sh benchmark
```

### 3. Manual Docker

```bash
# Build image
docker build -t comfyui-serverless-boost .

# Run container
docker run -d \
  --name comfyui-api \
  -p 8188:8188 \
  -e CUDA_VISIBLE_DEVICES="" \
  comfyui-serverless-boost

# Verify
curl http://localhost:8188/system_stats
```

---

## 🛠️ Configuration

### Environment Variables

```bash
# Python optimizations
PYTHONUNBUFFERED=1         # Unbuffered logging
PYTHONDONTWRITEBYTECODE=1  # Skip .pyc files
PYTHONOPTIMIZE=2           # Maximize runtime optimizations

# Thread limits
OMP_NUM_THREADS=1          # Single-threaded OpenMP
MKL_NUM_THREADS=1          # Single-threaded MKL

# Cache paths
TORCH_HOME=/tmp/torch     # PyTorch cache
HF_HOME=/tmp/huggingface # HuggingFace cache

# Force CPU-only
CUDA_VISIBLE_DEVICES="" # Disable GPU
```

### Recommended Startup Flags

```bash
--cpu                    # Force CPU mode
--cpu-vae                # Run VAE on CPU
--force-fp16             # Enable low-precision FP16
--fast                   # Fast startup
--disable-smart-memory   # Disable advanced memory manager
--disable-xformers       # Turn off xformers
--quiet                  # Suppress server logs
```

---

## 🌐 API Endpoints

| Endpoint         | Method | Description                       |
|------------------|--------|-----------------------------------|
| `/system_stats`  | GET    | Retrieve system and device stats  |
| `/object_info`   | GET    | List available nodes and classes  |
| `/queue`         | GET    | Check processing queue status     |
| `/prompt`        | POST   | Submit a workflow JSON payload    |
| `/history`       | GET    | Get past workflow executions      |

#### Examples

```bash
# System stats
curl http://localhost:8188/system_stats

# Submit a prompt
curl -X POST http://localhost:8188/prompt \
     -H "Content-Type: application/json" \
     -d '{ "prompt": { ... } }'
```

---

## 🏗️ Architecture & Build

This project uses a multi-stage Docker build for lean runtime images.

```dockerfile
# Stage 1: Build dependencies & pre-compile
FROM python:3.10-slim AS builder
RUN pip install --no-cache-dir -r requirements.txt
RUN python -m compileall .

# Stage 2: Runtime image
FROM python:3.10-slim
COPY --from=builder /usr/local/lib/python3.10/site-packages /usr/local/lib/python3.10/site-packages
COPY --from=builder . /app
WORKDIR /app
ENTRYPOINT ["python", "main.py"]
``` 

---

## 📊 Monitoring & Healthchecks

- **Healthcheck**: `curl -f http://localhost:8188/system_stats`
- **Logs**: `docker logs comfyui-api --tail 50`
- **Metrics**: `docker stats comfyui-api`

---

## 🚀 Deployment Examples

### Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: comfyui-api
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: comfyui
        image: comfyui-serverless-boost
        env: ...
        livenessProbe: ...
```

### AWS Lambda / Cloud Run

Use the optimized image to achieve sub-second cold starts and reduced billing costs.

---

## 🤝 Contributing

Contributions are welcome! Please fork, branch, and submit a pull request:

1. Fork the repo
2. Create a feature branch
3. Commit your changes
4. Open a Pull Request

---

## 📄 License

This project is Apache 2.0 licensed. See [LICENSE](LICENSE) for details.
