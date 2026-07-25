#!/usr/bin/env bash

# Exit immediately if an unhandled command error occurs
set -e

# 1. Target model passed as parameter ($1) or fallback to default
MODEL="${1:-qwen2.5-coder:7b}"
SPEC_FILE="prompt.hashprime.info"
OLLAMA_URL="http://localhost:11434/api/chat"

# Maximum tool-call turns allowed per model
MAX_STEPS=10
STEP_COUNT=0

# Metrics Tracking Counters
TOTAL_PROMPT_TOKENS=0
TOTAL_EVAL_TOKENS=0
TOTAL_DURATION_NS=0

echo "=========================================="
echo "--> Preloading/Warming model into memory: $MODEL..."
echo "=========================================="

# Pre-warm model weights into VRAM
JSON_PAYLOAD=$(jq -c -n --arg model "$MODEL" '{
  model: $model,
  messages: [{role: "user", content: "hi"}],
  keep_alive: "5m"
}')

curl -s "$OLLAMA_URL" \
     -H "Content-Type: application/json" \
     -d "$JSON_PAYLOAD" \
     > /dev/null

echo "✅ Model preloaded successfully."

echo "=========================================="
echo "--> Running evaluation for model: $MODEL"
echo "=========================================="

if [ ! -f "$SPEC_FILE" ]; then
    echo "Error: $SPEC_FILE not found."
    exit 1
fi

# Clean up build artifacts from previous runs
rm -f *.class hashprime.java hashprime_large.java

echo "--> Reading specification file..."
SPEC_TEXT=$(cat "$SPEC_FILE")

SYSTEM_PROMPT="You are an automated software engineer. You MUST execute actions by issuing function calls for write_file, javac, and java. Test N=11 and N=1000, then stop."

# Initialize conversation history
MESSAGES=$(jq -n \
  --arg sys "$SYSTEM_PROMPT" \
  --arg spec "$SPEC_TEXT" \
  '[
    {role: "system", content: $sys},
    {role: "user", content: $spec}
  ]')

# Available tool schema
TOOLS='[
  {
    "type": "function",
    "function": {
      "name": "write_file",
      "description": "Writes Java source code to disk.",
      "parameters": {
        "type": "object",
        "properties": {
          "filename": { "type": "string" },
          "content": { "type": "string" }
        },
        "required": ["filename", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "javac",
      "description": "Compiles a Java source file.",
      "parameters": {
        "type": "object",
        "properties": {
          "filename": { "type": "string" }
        },
        "required": ["filename"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "java",
      "description": "Runs a compiled Java class.",
      "parameters": {
        "type": "object",
        "properties": {
          "class_name": { "type": "string" },
          "args": { 
            "type": "array", 
            "items": { "type": "string" }
          }
        },
        "required": ["class_name"]
      }
    }
  }
]'

echo "--> Starting Ollama Agent Loop (Max Steps: $MAX_STEPS)..."

while true; do
    # Build payload
    PAYLOAD=$(jq -n \
      --arg model "$MODEL" \
      --argjson messages "$MESSAGES" \
      --argjson tools "$TOOLS" \
      '{model: $model, messages: $messages, tools: $tools, stream: false}')

    # Send request to Ollama
    RESPONSE=$(curl -s "$OLLAMA_URL" -H "Content-Type: application/json" -d "$PAYLOAD")

    # Accumulate Performance & Token Metrics
    P_TOKENS=$(echo "$RESPONSE" | jq -r '.prompt_eval_count // 0')
    E_TOKENS=$(echo "$RESPONSE" | jq -r '.eval_count // 0')
    DUR_NS=$(echo "$RESPONSE" | jq -r '.total_duration // 0')

    TOTAL_PROMPT_TOKENS=$((TOTAL_PROMPT_TOKENS + P_TOKENS))
    TOTAL_EVAL_TOKENS=$((TOTAL_EVAL_TOKENS + E_TOKENS))
    TOTAL_DURATION_NS=$((TOTAL_DURATION_NS + DUR_NS))

    # Record assistant response in conversation history
    ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
    MESSAGES=$(echo "$MESSAGES" | jq --argjson msg "$ASSISTANT_MSG" '. + [$msg]')

    # -------------------------------------------------------------
    # UNIFIED MULTI-FORMAT TOOL EXTRACTOR (Python Stream Parser)
    # -------------------------------------------------------------
    TOOL_CALLS_ARRAY=$(python3 -c '
import sys, json, re

try:
    data = json.load(sys.stdin)
except Exception:
    print("[]")
    sys.exit(0)

tool_calls = []

# 1. Check Native Tool Calls
native = data.get("message", {}).get("tool_calls", [])
if native:
    for tc in native:
        func = tc.get("function", {})
        tool_calls.append({"name": func.get("name"), "arguments": func.get("arguments")})

# 2. Check Embedded Multi-Line JSON Objects
if not tool_calls:
    content = data.get("message", {}).get("content", "") or ""
    decoder = json.JSONDecoder()
    pos = 0
    while pos < len(content):
        match = content.find("{", pos)
        if match == -1:
            break
        try:
            obj, end = decoder.raw_decode(content[match:])
            if isinstance(obj, dict) and "name" in obj:
                args = obj.get("arguments", {})
                tool_calls.append({"name": obj["name"], "arguments": args})
            pos = match + end
        except Exception:
            pos = match + 1

# 3. Check XML Tags (Fallback for Heretic / Claude-style models)
if not tool_calls:
    content = data.get("message", {}).get("content", "") or ""
    
    # <write_file filename="..." content="...">
    for fn, cnt in re.findall(r"<write_file\s+filename=\"([^\"]+)\"\s+content=\"([^\"]+)\"", content, re.DOTALL):
        tool_calls.append({"name": "write_file", "arguments": {"filename": fn, "content": cnt}})
    
    # <javac filename="...">
    for fn in re.findall(r"<javac\s+filename=\"([^\"]+)\"", content):
        tool_calls.append({"name": "javac", "arguments": {"filename": fn}})
    
    # <java class_name="..." args="...">
    for cn, args_str in re.findall(r"<java\s+class_name=\"([^\"]+)\"(?:\s+args=\"([^\"]+)\")?", content):
        try:
            args = json.loads(args_str.replace("\\\"", "\"")) if args_str else []
        except Exception:
            args = [args_str] if args_str else []
        tool_calls.append({"name": "java", "arguments": {"class_name": cn, "args": args}})

print(json.dumps(tool_calls))
' <<< "$RESPONSE")

    NUM_CALLS=$(echo "$TOOL_CALLS_ARRAY" | jq 'length')

    # Exit condition if no actions were detected
    if [ "$NUM_CALLS" -eq 0 ]; then
        echo -e "\n=== Agent Finished Naturally ==="
        echo "$RESPONSE" | jq -r '.message.content'
        break
    fi

    COMBINED_OUTPUT=""

    # Process extracted tool actions sequentially
    for (( i=0; i<$NUM_CALLS; i++ )); do
        CALL=$(echo "$TOOL_CALLS_ARRAY" | jq ".[$i]")
        TOOL_NAME=$(echo "$CALL" | jq -r '.name')
        TOOL_ARGS=$(echo "$CALL" | jq '.arguments')

        echo "--> [ACTION DETECTED]: $TOOL_NAME"

        case "$TOOL_NAME" in
            "write_file")
                FILENAME=$(echo "$TOOL_ARGS" | jq -r '.filename')
                CONTENT=$(echo "$TOOL_ARGS" | jq -r '.content')
                echo "   [EXEC]: Writing file '$FILENAME'..."
                printf "%s" "$CONTENT" > "$FILENAME"
                OUT="File $FILENAME written successfully."
                ;;

            "javac")
                FILENAME=$(echo "$TOOL_ARGS" | jq -r '.filename')
                echo "   [EXEC]: javac $FILENAME"
                if COMPILE_ERR=$(javac "$FILENAME" 2>&1); then
                    OUT="Compilation successful."
                    echo "   [SUCCESS]: Compiled cleanly."
                else
                    OUT="Compilation failed:\n$COMPILE_ERR"
                    echo "   [ERROR]: Compilation failed."
                fi
                ;;

            "java")
                CLASS_NAME=$(echo "$TOOL_ARGS" | jq -r '.class_name')
                RAW_ARGS=$(echo "$TOOL_ARGS" | jq -r '.args // [] | join(" ")' 2>/dev/null || true)
                echo "   [EXEC]: java $CLASS_NAME $RAW_ARGS"
                RUN_OUT=$(java $CLASS_NAME $RAW_ARGS 2>&1 || true)
                OUT="Program Output:\n$RUN_OUT"
                echo "   [PROGRAM OUTPUT]: $RUN_OUT"
                ;;

            *)
                OUT="Unknown tool name: $TOOL_NAME"
                ;;
        esac

        COMBINED_OUTPUT=$(printf "%s\n%s" "$COMBINED_OUTPUT" "$OUT")
    done

    # Safe string encoding for message history
    TOOL_RESPONSE_MSG=$(jq -n --arg content "$COMBINED_OUTPUT" '{role: "tool", content: $content}')
    MESSAGES=$(echo "$MESSAGES" | jq --argjson msg "$TOOL_RESPONSE_MSG" '. + [$msg]')

    # Step limit guard
    STEP_COUNT=$((STEP_COUNT + 1))
    echo "   [STEP COUNT]: $STEP_COUNT / $MAX_STEPS"

    if [ "$STEP_COUNT" -ge "$MAX_STEPS" ]; then
        echo -e "\n=== Maximum Steps ($MAX_STEPS) Reached for Model $MODEL. Terminating. ==="
        break
    fi
done

# ==============================================================================
# FINAL EVALUATION SUMMARY REPORT
# ==============================================================================

# Calculate elapsed time in seconds with decimal precision
TOTAL_SECS=$(awk -v ns="$TOTAL_DURATION_NS" 'BEGIN { printf "%.2f", ns / 1000000000 }')
TOTAL_TOKENS=$((TOTAL_PROMPT_TOKENS + TOTAL_EVAL_TOKENS))

# Calculate Tokens Per Second (TPS)
if [ "$(echo "$TOTAL_SECS > 0" | awk '{print ($1 > 0)}')" -eq 1 ]; then
    TPS=$(awk -v tok="$TOTAL_EVAL_TOKENS" -v sec="$TOTAL_SECS" 'BEGIN { printf "%.2f", tok / sec }')
else
    TPS="0.00"
fi

echo -e "\n=========================================="
echo "📊 PERFORMANCE REPORT: $MODEL"
echo "=========================================="
echo " Total Steps Taken:    $STEP_COUNT / $MAX_STEPS"
echo " Total Elapsed Time:   ${TOTAL_SECS}s"
echo " Prompt Tokens:        $TOTAL_PROMPT_TOKENS"
echo " Generated Tokens:     $TOTAL_EVAL_TOKENS"
echo " Total Tokens:         $TOTAL_TOKENS"
echo " Generation Speed:     ${TPS} tokens/sec"
echo "=========================================="
