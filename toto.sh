#!/usr/bin/env bash

clear

cleanup_children() {
    echo "Cleaning up child processes..."
    pkill -f "java hashprime" 2>/dev/null || true
    pkill -f "javac hashprime" 2>/dev/null || true
    pkill -f "timeout.*curl.*localhost:11434" 2>/dev/null || true
}

trap cleanup_children EXIT INT TERM

rm -rf logs/ sandbox/
mkdir -p logs

RESULTS_FILE="logs/results_summary.txt"
echo "=== Model Benchmark Results ===" > "$RESULTS_FILE"
echo "Date: $(date)" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

for i in $(ollama list | grep -Ev 'NAME|embed|ocr' | sed -e 's/ .*//'); do
    safe_name=$(echo "$i" | tr ':/' '_')
    filename="logs/${safe_name}.txt"
    echo "=========================================="
    echo "==> Testing model: $i"
    echo "==> Log: ${filename}"
    echo "=========================================="

    cleanup_children
    sleep 1

    bash ./complete.sh "$i" 2>&1 | tee "${filename}"

    echo "" >> "$RESULTS_FILE"
    echo "--- Model: $i ---" >> "$RESULTS_FILE"
    grep -E "VERDICT|Harness|passed|failed" "${filename}" >> "$RESULTS_FILE" 2>/dev/null || echo "No results found" >> "$RESULTS_FILE"
done

echo ""
echo "=== Summary ==="
cat "$RESULTS_FILE"
