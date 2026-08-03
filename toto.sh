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

RESULTS_FILE="logs/errors.txt"
echo "=== Model Errors ===" > "$RESULTS_FILE"
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

    cleanup_children
    sleep 1

    echo "[$TOTAL] Testing $i..."
    timeout 600 bash ./complete.sh "$i" 2>&1 | tee "${filename}"

    VERDICT=$(grep "VERDICT" "${filename}" | tail -1)
    if echo "$VERDICT" | grep -q "FAIL"; then
        FAILED=$((FAILED + 1))
        echo "FAIL: $i" >> "$RESULTS_FILE"
        grep -E "VERDICT|Harness|Wall Clock|Spec requests" "${filename}" >> "$RESULTS_FILE" 2>/dev/null
        echo "" >> "$RESULTS_FILE"
    else
        echo "PASS: $i" >> "$RESULTS_FILE"
        grep -E "VERDICT|Harness|Wall Clock" "${filename}" >> "$RESULTS_FILE" 2>/dev/null
        echo "" >> "$RESULTS_FILE"
    fi

    cleanup_children
    sleep 2
done

echo ""
echo "=== Done ==="
echo "Total: $TOTAL | Passed: $PASSED | Failed: $FAILED"
echo ""
echo "=== Failures ==="
grep "FAIL:" "$RESULTS_FILE" 2>/dev/null || echo "None"
echo ""
echo "=== Passes ==="
grep "PASS:" "$RESULTS_FILE" 2>/dev/null || echo "None"