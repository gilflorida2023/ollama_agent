#!/usr/bin/env bash

# Disable history expansion so '!' in Java code preview logs won't break Bash
set +H

# Exit immediately if an unhandled command error occurs
set -e

# Target model passed as parameter ($1) or fallback to default
MODEL="${1:-qwen2.5-coder:7b}"
SPEC_FILE="prompt.hashprime.info"
OLLAMA_URL="http://localhost:11434/api/chat"

# Directories and paths
CONFIG_DIR=".configs"
SANITIZED_MODEL=$(echo "$MODEL" | sed 's/[/:]/_/g')
PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.sh"

# Maximum tool-call turns allowed per model
MAX_STEPS=10
STEP_COUNT=0
START_TIME=$(date +%s)

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

# Ensure a dedicated parser exists; auto-profile if missing
if [ ! -f "$PARSER_FILE" ]; then
    echo "⚠️  No parser profile found for $MODEL. Running profile_model.sh..."
    bash ./profile_model.sh "$MODEL"
fi

echo "=========================================="
echo "--> Running evaluation for model: $MODEL"
echo "⚡ Using dedicated parser: $PARSER_FILE"
echo "=========================================="

if [ ! -f "$SPEC_FILE" ]; then
    echo "Error: $SPEC_FILE not found."
    exit 1
fi

# ======================================================
# Clean up build artifacts from previous runs
# User made this change to eliminate contamination before the run.
# Please DO NOT MODIFY unless error exists.
rm -f *.class *.java 2>&1 2>/dev/null

echo "--> Reading specification file..."
SPEC_TEXT=$(cat "$SPEC_FILE")

SYSTEM_PROMPT="You are an automated software engineer. ALWAYS follow this strict action sequence: 1) write_file, 2) javac, 3) java. Never attempt to run 'java' before 'javac' succeeds. Test N=11 and N=1000, then stop."

# Initialize conversation history safely using stdin
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
LAST_RESPONSE=""

while true; do
    # Build payload using stdin to prevent ARG_MAX kernel crashes
    PAYLOAD=$(jq -s --arg model "$MODEL" \
      '{model: $model, messages: .[0], tools: .[1], stream: false}' \
      <(echo "$MESSAGES") <(echo "$TOOLS"))

    # Send request to Ollama
    RESPONSE=$(curl -s "$OLLAMA_URL" -H "Content-Type: application/json" -d "$PAYLOAD")
    LAST_RESPONSE="$RESPONSE"

    # Safely append assistant response to history using stdin
    ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
    MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$ASSISTANT_MSG"))

    # -------------------------------------------------------------
    # DELEGATED TOOL PARSING (Executed by dedicated model parser)
    # -------------------------------------------------------------
    TOOL_CALLS_ARRAY=$(bash "$PARSER_FILE" <<< "$RESPONSE")
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
                FILENAME=$(echo "$TOOL_ARGS" | jq -r '.filename // empty')
                CONTENT=$(echo "$TOOL_ARGS" | jq -r '.content // empty')

                # Guard against invalid or null filenames
                if [ -z "$FILENAME" ] || [ "$FILENAME" = "null" ]; then
                    OUT="Tool Exec Error: Missing or invalid filename. You must provide a valid filename parameter (e.g. 'hashprime.java')."
                    echo "   [ERROR]: Model attempted to write file with null/empty filename. Request rejected."
                else
                    # Un-escape newlines cleanly if passed as a literal string
                    FORMATTED_CONTENT=$(python3 -c '
import sys
code = sys.stdin.read()
if "\\n" in code and "\n" not in code:
    code = code.encode().decode("unicode_escape")
print(code.strip())
' <<< "$CONTENT")

                    echo "   [EXEC]: Writing file '$FILENAME'..."
                    printf "%s\n" "$FORMATTED_CONTENT" > "$FILENAME"

                    echo "   --- [FILE CONTENT PREVIEW] ---"
                    echo "$FORMATTED_CONTENT" | sed 's/^/   | /'
                    echo "   ------------------------------"

                    OUT="File '$FILENAME' written successfully."
                fi
                ;;

            "javac")
                FILENAME=$(echo "$TOOL_ARGS" | jq -r '.filename // empty')
                if [ -z "$FILENAME" ] || [ "$FILENAME" = "null" ]; then
                    OUT="Compilation Error: Missing filename parameter."
                    echo "   [ERROR]: Missing filename for javac."
                else
                    echo "   [EXEC]: javac $FILENAME"
                    if COMPILE_ERR=$(javac "$FILENAME" 2>&1); then
                        OUT="Compilation successful. You can now execute the compiled class using 'java'."
                        echo "   [SUCCESS]: Compiled cleanly."
                    else
                        OUT="Compilation failed with error:\n$COMPILE_ERR\nPlease fix the source code using 'write_file' and re-compile."
                        echo "   [ERROR]: Compilation failed."
                    fi
                fi
                ;;

            "java")
                CLASS_NAME=$(echo "$TOOL_ARGS" | jq -r '.class_name // empty')
                RAW_ARGS=$(echo "$TOOL_ARGS" | jq -r '.args // [] | join(" ")' 2>/dev/null || true)
                
                if [ -z "$CLASS_NAME" ] || [ "$CLASS_NAME" = "null" ]; then
                    OUT="Execution Error: Missing class_name parameter."
                    echo "   [ERROR]: Missing class_name for java tool."
                else
                    echo "   [EXEC]: java $CLASS_NAME $RAW_ARGS"
                    RUN_OUT=$(java $CLASS_NAME $RAW_ARGS 2>&1 || true)

                    if echo "$RUN_OUT" | grep -q "ClassNotFoundException"; then
                        OUT="Program Execution Failed:\n$RUN_OUT\nHINT: Class '$CLASS_NAME.class' was not found. Ensure you call 'write_file' to save the Java source code and 'javac' to compile it before calling 'java'."
                    else
                        OUT="Program Output:\n$RUN_OUT"
                    fi
                    echo "   [PROGRAM OUTPUT]: $RUN_OUT"
                fi
                ;;

            *)
                OUT="Unknown tool name: $TOOL_NAME"
                ;;
        esac

        COMBINED_OUTPUT=$(printf "%s\n%s" "$COMBINED_OUTPUT" "$OUT")
    done

    # Safe string encoding for message history via python stdin
    TOOL_RESPONSE_MSG=$(python3 -c '
import sys, json
content = sys.stdin.read()
print(json.dumps({"role": "tool", "content": content}))
' <<< "$COMBINED_OUTPUT")

    MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$TOOL_RESPONSE_MSG"))

    STEP_COUNT=$((STEP_COUNT + 1))
    echo "   [STEP COUNT]: $STEP_COUNT / $MAX_STEPS"

    if [ "$STEP_COUNT" -ge "$MAX_STEPS" ]; then
        echo -e "\n=== Maximum Steps ($MAX_STEPS) Reached for Model $MODEL. Terminating. ==="
        break
    fi
done

# ==============================================================================
# AUTOMATED HARNESS VALIDATION (Compiles & Runs Test Matrix if File Exists)
# ==============================================================================
echo "=========================================="
echo "          AUTOMATED HARNESS VALIDATION    "
echo "=========================================="

if [ -f "hashprime.java" ]; then
    echo "🔍 Found hashprime.java on disk. Starting automated test harness..."

    # Step A: Compile
    echo "--> [HARNESS]: Compiling hashprime.java..."
    if COMPILE_LOG=$(javac hashprime.java 2>&1); then
        echo "✅ [HARNESS]: Compilation succeeded."

        # Step B: Test N=11
        EXPECTED_11="563d8e0603dcc07d784135d99fd81ff6bf98495e898ec1f52e2e7605320cf6dc"
        ACTUAL_11=$(java hashprime 11 2>&1 | tr -d '\r\n')
        if [ "$ACTUAL_11" = "$EXPECTED_11" ]; then
            echo "✅ [TEST PASS]: N=11 -> $ACTUAL_11"
        else
            echo "❌ [TEST FAIL]: N=11 -> Expected: $EXPECTED_11 | Got: $ACTUAL_11"
        fi

        # Step C: Test N=1000
        EXPECTED_1000="4883963dd4510a29d6df2ffe4dd11e4e1a910e815c7810b200c77b3357f22a28"
        ACTUAL_1000=$(java hashprime 1000 2>&1 | tr -d '\r\n')
        if [ "$ACTUAL_1000" = "$EXPECTED_1000" ]; then
            echo "✅ [TEST PASS]: N=1000 -> $ACTUAL_1000"
        else
            echo "❌ [TEST FAIL]: N=1000 -> Expected: $EXPECTED_1000 | Got: $ACTUAL_1000"
        fi

        # Step D: Invalid Input Handling
        ACTUAL_INVALID=$(java hashprime "" 2>&1 | tr -d '\r\n')
        echo "ℹ️  [HARNESS TEST]: Empty Input -> Returned: '${ACTUAL_INVALID}'"

    else
        echo "❌ [HARNESS]: Compilation failed."
        echo "$COMPILE_LOG" | sed 's/^/   | /'
    fi
else
    echo "❌ [HARNESS]: hashprime.java was not found on disk. Skipping validation."
fi

# ==============================================================================
# VERBOSE TIMING & TOKEN PERFORMANCE STATS
# ==============================================================================
END_TIME=$(date +%s)
TOTAL_WALL_TIME=$((END_TIME - START_TIME))

if [ -n "$LAST_RESPONSE" ]; then
    EVAL_COUNT=$(echo "$LAST_RESPONSE" | jq -r '.eval_count // 0')
    EVAL_DURATION=$(echo "$LAST_RESPONSE" | jq -r '.eval_duration // 0')

    echo "=========================================="
    echo "            MODEL BENCHMARK STATS         "
    echo "=========================================="
    echo "Wall Clock Time:  ${TOTAL_WALL_TIME}s"
    
    if [ "$EVAL_COUNT" -gt 0 ] && [ "$EVAL_DURATION" -gt 0 ]; then
        SPEED=$(python3 -c "print(round($EVAL_COUNT / ($EVAL_DURATION / 1e9), 2))")
        echo "Total Tokens:     $EVAL_COUNT"
        echo "Generation Speed: $SPEED tokens/sec"
    fi
    echo "=========================================="
fi
