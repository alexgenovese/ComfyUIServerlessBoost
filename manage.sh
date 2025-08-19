#!/bin/bash

# ComfyUI Serverless - Script di Gestione Ottimizzato
# Utilizzo: ./manage.sh [build|start|stop|test|benchmark]

set -e

IMAGE_NAME="comfyui-serverless-optimized"
CONTAINER_NAME="comfyui-serverless-api"
PORT="8188"
BUILD_SNAPSHOT=""

function build() {
    echo "🔨 Building ottimizzato ComfyUI Serverless..."
    
    # Check for snapshot URL parameter
    if [ -n "$2" ]; then
        BUILD_SNAPSHOT="$2"
        echo "📋 Using snapshot from parameter: $BUILD_SNAPSHOT"
    fi
    
    # If BUILD_SNAPSHOT is a local file path, copy it to build context as models_snapshot.json
    if [ -n "$BUILD_SNAPSHOT" ] && [ -f "$BUILD_SNAPSHOT" ]; then
        echo "📁 Using local snapshot file: $BUILD_SNAPSHOT"
        # Create a minimal models folder and place snapshot inside for build context
        mkdir -p ./models
        cp "$BUILD_SNAPSHOT" ./models/models_snapshot.json
        echo "Placed local snapshot in ./models/models_snapshot.json (will be copied into image)"
        BUILD_ARG=""
        MODEL_IMPORT_ARG="--build-arg MODEL_IMPORT=0"
    elif [ -n "$BUILD_SNAPSHOT" ]; then
        echo "🌐 Using snapshot URL: $BUILD_SNAPSHOT"
        # Validate URL format
        if [[ "$BUILD_SNAPSHOT" =~ ^https?:// ]]; then
            echo "✅ Valid URL format detected"
            BUILD_ARG="--build-arg MODEL_SNAPSHOT_URL=$BUILD_SNAPSHOT"
            MODEL_IMPORT_ARG="--build-arg MODEL_IMPORT=1"
        else
            echo "❌ Invalid URL format. Must start with http:// or https://"
            exit 1
        fi
    else
        BUILD_ARG=""
        MODEL_IMPORT_ARG="--build-arg MODEL_IMPORT=0"
    fi

    time docker build $BUILD_ARG $MODEL_IMPORT_ARG -t $IMAGE_NAME .
    # Cleanup local copy if created
    # Cleanup any temporary models snapshot in build context
    [ -d ./models ] && rm -rf ./models || true
    echo "✅ Build completato!"
}

function start() {
    echo "🚀 Avvio ComfyUI Serverless ottimizzato..."
    
    # Stop container esistente se presente
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
    
    # Avvio con timing
    echo "⏱️  Misurazione cold start..."
    time docker run -d \
        --name $CONTAINER_NAME \
        -p $PORT:$PORT \
        -e CUDA_VISIBLE_DEVICES="" \
        $IMAGE_NAME
    
    echo "⏳ Attesa inizializzazione API..."
    sleep 3
    
    # Test connessione
    if curl -s http://localhost:$PORT/system_stats > /dev/null; then
        echo "✅ ComfyUI API attiva su http://localhost:$PORT"
        echo "📊 Statistiche sistema:"
        curl -s http://localhost:$PORT/system_stats | jq '.system | {version: .comfyui_version, python: .python_version, pytorch: .pytorch_version}'
    else
        echo "❌ Errore: API non raggiungibile"
        docker logs $CONTAINER_NAME --tail 20
        exit 1
    fi
}

function stop() {
    echo "🛑 Arresto ComfyUI Serverless..."
    docker stop $CONTAINER_NAME 2>/dev/null || echo "Container non in esecuzione"
    docker rm $CONTAINER_NAME 2>/dev/null || echo "Container non esistente"
    echo "✅ Stop completato!"
}

function test() {
    echo "🧪 Test API ComfyUI..."
    
    echo "1. Test system_stats:"
    time curl -s http://localhost:$PORT/system_stats | jq '.system.os, .devices[0].type'
    
    echo -e "\n2. Test object_info (primi 3 nodi):"
    curl -s http://localhost:$PORT/object_info | jq 'keys[:3]'
    
    echo -e "\n3. Test queue:"
    curl -s http://localhost:$PORT/queue | jq '.'
    
    echo -e "\n✅ Test completati con successo!"
}

function import_snapshot() {
    local snapshot_url="$2"
    
    if [ -z "$snapshot_url" ]; then
        echo "❌ Errore: URL snapshot richiesto"
        echo "Utilizzo: $0 import-snapshot <URL_SNAPSHOT>"
        exit 1
    fi
    
    # Validate URL format
    if [[ ! "$snapshot_url" =~ ^https?:// ]]; then
        echo "❌ Errore: URL non valido. Deve iniziare con http:// o https://"
        exit 1
    fi
    
    echo "📥 Importazione snapshot da: $snapshot_url"
    
    # Check if container is running
    if ! docker ps | grep -q $CONTAINER_NAME; then
        echo "❌ Errore: Container $CONTAINER_NAME non in esecuzione"
        echo "Avvia prima il container con: $0 start"
        exit 1
    fi
    
    # Download snapshot to temp file
    temp_snapshot="/tmp/comfyui_snapshot_$(date +%s).json"
    echo "⬇️  Download snapshot..."
    
    if curl -L -f -s -o "$temp_snapshot" "$snapshot_url"; then
        echo "✅ Snapshot scaricato: $temp_snapshot"
        
        # Copy to container
        docker cp "$temp_snapshot" "$CONTAINER_NAME:/comfyui/models_snapshot.json"
        
        # Import models
        echo "📦 Importazione modelli..."
        docker exec "$CONTAINER_NAME" /comfyui/venv/bin/python /comfyui/scripts/import_models.py /comfyui/models_snapshot.json /comfyui/models
        
        if [ $? -eq 0 ]; then
            echo "✅ Importazione completata con successo!"
            
            # Show imported models summary
            echo "📊 Riepilogo modelli importati:"
            docker exec "$CONTAINER_NAME" find /comfyui/models -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" | head -10
        else
            echo "⚠️  Importazione completata con alcuni errori"
        fi
        
        # Cleanup temp file
        rm -f "$temp_snapshot"
    else
        echo "❌ Errore: impossibile scaricare lo snapshot da $snapshot_url"
        exit 1
    fi
}

function benchmark() {
    echo "📊 Benchmark Performance ComfyUI Serverless"
    echo "=============================================="
    
    # Stop container se esiste
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
    
    echo "🔥 Test Cold Start (3 iterazioni):"
    for i in {1..3}; do
        echo "Iterazione $i:"
        
        # Misura avvio container
        echo -n "  Container start: "
        start_time=$(date +%s.%N)
        docker run -d --name $CONTAINER_NAME -p $PORT:$PORT -e CUDA_VISIBLE_DEVICES="" $IMAGE_NAME > /dev/null
        end_time=$(date +%s.%N)
        echo "$(echo "$end_time - $start_time" | bc)s"
        
        # Attesa e test API
        sleep 2
        echo -n "  API first response: "
        time curl -s http://localhost:$PORT/system_stats > /dev/null 2>&1
        
        # Memory usage
        echo -n "  Memory usage: "
        docker stats --no-stream --format "{{.MemUsage}}" $CONTAINER_NAME
        
        # Cleanup
        docker stop $CONTAINER_NAME > /dev/null
        docker rm $CONTAINER_NAME > /dev/null
        echo ""
    done
    
    echo "✅ Benchmark completato!"
}

function usage() {
    echo "ComfyUI Serverless - Gestione Ottimizzata"
    echo "========================================="
    echo "Utilizzo: $0 [comando] [parametri]"
    echo ""
    echo "Comandi disponibili:"
    echo "  build [snapshot_url]    - Build dell'immagine Docker ottimizzata"
    echo "                           (opzionale: URL snapshot per import durante build)"
    echo "  start                   - Avvio del container con misurazione performance"
    echo "  stop                    - Arresto del container"
    echo "  test                    - Test delle API"
    echo "  benchmark               - Benchmark completo delle performance"
    echo "  import-snapshot <url>   - Importa snapshot da URL in container esistente"
    echo ""
    echo "Esempi:"
    echo "  $0 build"
    echo "  $0 build https://example.com/my-snapshot.json"
    echo "  $0 start"
    echo "  $0 import-snapshot https://raw.githubusercontent.com/user/repo/main/snapshot.json"
    echo "  $0 test"
    echo "  $0 benchmark"
    echo ""
    echo "Snapshot URL supportati:"
    echo "  - Raw GitHub URLs"
    echo "  - Direct HTTP/HTTPS links to JSON files"
    echo "  - ComfyUI Manager snapshot exports"
}

# Main
case "${1:-}" in
    build)
        build "$@"
        ;;
    start)
        start
        ;;
    stop)
        stop
        ;;
    test)
        test
        ;;
    benchmark)
        benchmark
        ;;
    import-snapshot)
        import_snapshot "$@"
        ;;
    *)
        usage
        exit 1
        ;;
esac
