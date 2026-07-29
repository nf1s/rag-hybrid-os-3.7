#!/bin/sh
set -e

python3 -m llama_cpp.server \
    --model /app/model.gguf \
    --host 127.0.0.1 \
    --port 8001 \
    --n_gpu_layers 0 &

for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:8001/v1/models > /dev/null 2>&1; then
        exec uvicorn app.main:app --host 0.0.0.0 --port 8000
    fi
    sleep 1
done

echo "LLM server failed to start" >&2
exit 1
