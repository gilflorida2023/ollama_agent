#!/usr/bin/env bash

# Create logs directory
if ! [ -d 'logs' ]; then
    echo "Created logs directory"
    mkdir -p logs 2>/dev/null
fi

# ====================== FUNCTION ======================
kill_ollama_models() {
    echo "🛑 Stopping all running Ollama models..."

    local max_attempts=30
    local attempt=0

    while true; do
        local running
        running=$(ollama ps 2>/dev/null | tail -n +2 | awk '{print $1}')

        if [ -z "$running" ]; then
            echo "✅ All Ollama models are stopped."
            return 0   # This is safe now
        fi

        echo "Found running model(s):"
        echo "$running"

        while IFS= read -r model; do
            if [ -n "$model" ]; then
                echo "Stopping: $model"
                ollama stop "$model" 2>/dev/null || true
            fi
        done <<< "$running"

        sleep 2

        ((attempt++))

        if [ $attempt -ge $max_attempts ]; then
            echo "⚠️  Reached maximum attempts. Some models may still be running."
            return 1
        fi
    done
}
# =====================================================

echo "=========================================="
echo "--> Cleanup running models"
echo "=========================================="

kill_ollama_models

echo "=========================================="
echo "--> Starting next tasks..."
echo "=========================================="

# ←←← Your other code continues here
# echo "test"

for i in $(ollama list | grep -Ev 'NAME|embed' | sed -e 's/ .*//'); do
    filename="logs/$(echo "$i" | tr ':/' '_')_$(date +'%a_%b_%d_%H_%M_%S_%Z_%Y').txt"
    echo "Writing ${filename}"
    bash ./complete.sh "$i" 2>&1 | tee "${filename}"
done
