#!/usr/bin/env bash

cleanup_children() {
    pkill -f "java hashprime" 2>/dev/null || true
    pkill -f "javac hashprime" 2>/dev/null || true
    pkill -f "timeout.*curl.*localhost:11434" 2>/dev/null || true
}

trap cleanup_children EXIT INT TERM

rm -rf logs/ sandbox/
mkdir -p logs

RESULTS_FILE="logs/validation.txt"
echo "=== Model Validation Results ===" > "$RESULTS_FILE"
echo "Date: $(date)" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

# Get list of models (skip embed, ocr, and heretic)
MODELS=$(ollama list | grep -Ev 'NAME|embed|ocr|heretic' | sed -e 's/ .*//')

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

for i in $MODELS; do
    TOTAL=$((TOTAL + 1))
    safe_name=$(echo "$i" | tr ':/' '_')
    filename="logs/${safe_name}.txt"
    rawfile="logs/${safe_name}.raw.json"

    cleanup_children
    sleep 1

    echo "[$TOTAL] Testing $i..."

    # Probe model first to check tool support
    PROBE_MSG='{"model":"'"$i"'","messages":[{"role":"user","content":"Write a Java file hello.java with: public class hashprime { public static void main(String[] a) {} }"}],"stream":false,"tools":[{"type":"function","function":{"name":"write_file","description":"test","parameters":{"type":"object","properties":{"filename":{"type":"string"},"content":{"type":"string"}}}}}]}'
    
    curl -s "http://localhost:11434/api/chat" -H "Content-Type: application/json" -d "$PROBE_MSG" > "$rawfile" 2>/dev/null

    # Check if model returned an error (doesn't support tools)
    if grep -q '"does not support tools"' "$rawfile" 2>/dev/null; then
        echo "  SKIP: $i does not support tool calling"
        echo "SKIP: $i (no tool support)" >> "$RESULTS_FILE"
        echo "" >> "$RESULTS_FILE"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Run complete.sh
    timeout 600 bash ./complete.sh "$i" 2>&1 |     tee  "${filename}" | tee -a logs/toto.logs

    MODEL_RESULT=$(grep "^MODEL_RESULT:" "${filename}" | tail -1 | awk '{print $2}')
    if [ "$MODEL_RESULT" = "PASS" ]; then
        PASSED=$((PASSED + 1))
        echo "PASS: $i" >> "$RESULTS_FILE"
        grep -E "VERDICT|Harness|Wall Clock" "${filename}" >> "$RESULTS_FILE" 2>/dev/null
        echo "" >> "$RESULTS_FILE"
    else
        FAILED=$((FAILED + 1))
        echo "FAIL: $i" >> "$RESULTS_FILE"
        grep -E "VERDICT|Harness|Wall Clock|Spec requests|AUTO-FIX|EXEC" "${filename}" >> "$RESULTS_FILE" 2>/dev/null
        echo "" >> "$RESULTS_FILE"
    fi

    cleanup_children
    sleep 2
done

echo ""
echo "=== Done ==="
echo "Total: $TOTAL | Passed: $PASSED | Failed: $FAILED | Skipped: $SKIPPED"
