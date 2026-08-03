#!/usr/bin/env bash

clear

cleanup_children() {
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

MODELS=$(ollama list | grep -Ev 'NAME|embed|ocr' | sed -e 's/ .*//')

TOTAL=0
PASSED=0
FAILED=0

for i in $MODELS; do
    TOTAL=$((TOTAL + 1))
    safe_name=$(echo "$i" | tr ':/' '_')
    filename="logs/${safe_name}.txt"
    echo "=========================================="
    echo "==> [$TOTAL] Testing model: $i"
    echo "==> Log: ${filename}"
    echo "=========================================="

    cleanup_children
    sleep 1

    timeout 600 bash ./complete.sh "$i" > "${filename}" 2>&1
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 124 ]; then
        echo "TIMEOUT after 10 minutes for $i" >> "${filename}"
    fi

    VERDICT=$(grep "VERDICT" "${filename}" | tail -1)
    if echo "$VERDICT" | grep -q "PASS"; then
        PASSED=$((PASSED + 1))
        STATUS="PASS"
    else
        FAILED=$((FAILED + 1))
        STATUS="FAIL"
    fi

    echo "--- Model: $i [$STATUS] ---" >> "$RESULTS_FILE"
    grep -E "VERDICT|Harness|passed|failed|Wall Clock" "${filename}" >> "$RESULTS_FILE" 2>/dev/null || echo "No results found" >> "$RESULTS_FILE"
    echo "" >> "$RESULTS_FILE"

    cleanup_children
    sleep 2
done

echo ""
echo "=========================================="
echo "=== Final Summary ==="
echo "=========================================="
echo "Total models tested: $TOTAL"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""
cat "$RESULTS_FILE"