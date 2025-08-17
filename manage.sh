#!/bin/bash

# ComfyUI Serverless - Script di Gestione Ottimizzato
# Utilizzo: ./manage.sh [build|start|stop|test|benchmark]

set -e

IMAGE_NAME="comfyui-serverless-optimized"
CONTAINER_NAME="comfyui-serverless-api"
PORT="8188"

function build() {
    echo "🔨 Building ottimizzato ComfyUI Serverless..."
    time docker build -t $IMAGE_NAME .
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
    echo "Utilizzo: $0 [comando]"
    echo ""
    echo "Comandi disponibili:"
    echo "  build      - Build dell'immagine Docker ottimizzata"
    echo "  start      - Avvio del container con misurazione performance"
    echo "  stop       - Arresto del container"
    echo "  test       - Test delle API"
    echo "  benchmark  - Benchmark completo delle performance"
    echo ""
    echo "Esempi:"
    echo "  $0 build && $0 start"
    echo "  $0 test"
    echo "  $0 benchmark"
}

# Main
case "${1:-}" in
    build)
        build
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
    *)
        usage
        exit 1
        ;;
esac
