#!/usr/bin/env bash

# Paste this in your ~/.bashrc or ~/.bash_aliases, or in your script
kill_ollama_models() {
    echo "🛑 Stopping all running Ollama models..."

    local max_attempts=30
    local attempt=0

    while true; do
        # Get running models (skip header line)
        local running
        running=$(ollama ps 2>/dev/null | tail -n +2 | awk '{print $1}')

        if [ -z "$running" ]; then
            echo "✅ All Ollama models are stopped."
            return 0
        fi

        echo "Found running model(s):"
        echo "$running"

        # Stop each model
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


# Exit immediately if an unhandled command error occurs
set -e

# 1. Target model passed as parameter ($1) or fallback to default
MODEL="${1:-qwen2.5-coder:7b}"
SPEC_FILE="prompt.hashprime.info"
OLLAMA_URL="http://localhost:11434/api/chat"

# Maximum tool-call turns allowed per model
MAX_STEPS=20
STEP_COUNT=0


kill_ollama_models

echo "--> Preloading/Warming model into memory: $MODEL..."
curl -s "$OLLAMA_URL" -H "Content-Type: application/json" -d $(jq -n --arg model "$MODEL" '{
  model: $model,
  messages: [{role: "user", content: "hi"}],
  keep_alive: "5m"
}') > /dev/null


echo "=========================================="
echo "--> Running evaluation for model: $MODEL"
echo "=========================================="

if [ ! -f "$SPEC_FILE" ]; then
    echo "Error: $SPEC_FILE not found."
    exit 1
fi

# Clean up build artifacts from previous runs
rm -f *.class hashprime.java

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

    # Record assistant message into history
    ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
    MESSAGES=$(echo "$MESSAGES" | jq --argjson msg "$ASSISTANT_MSG" '. + [$msg]')

    TOOL_CALLS_ARRAY="[]"

    # 1. First check native tool calls
    NATIVE_CALLS=$(echo "$RESPONSE" | jq -c '.message.tool_calls // []')
    if [ "$NATIVE_CALLS" != "[]" ]; then
        TOOL_CALLS_ARRAY=$(echo "$NATIVE_CALLS" | jq '[.[] | {name: .function.name, arguments: .function.arguments}]')
    else
        # 2. Fallback: Parse raw JSON objects out of text content
        RAW_CONTENT=$(echo "$RESPONSE" | jq -r '.message.content // empty')
        
        # Remove markdown codeblocks (```json ... ```)
        CLEAN_TEXT=$(echo "$RAW_CONTENT" | sed 's/```json//g; s/```//g')

        # Use jq slurp (-s) to capture multiple JSON blocks safely
        PARSED_JSON=$(echo "$CLEAN_TEXT" | jq -s '.' 2>/dev/null || echo "[]")
        
        if [ "$PARSED_JSON" != "[]" ] && echo "$PARSED_JSON" | jq -e '.[0].name' >/dev/null 2>&1; then
            TOOL_CALLS_ARRAY="$PARSED_JSON"
        fi
    fi

    NUM_CALLS=$(echo "$TOOL_CALLS_ARRAY" | jq 'length')

    # Exit condition if no tools were emitted
    if [ "$NUM_CALLS" -eq 0 ]; then
        echo -e "\n=== Agent Finished Naturally ==="
        echo "$RESPONSE" | jq -r '.message.content'
        break
    fi

    COMBINED_OUTPUT=""

    # Process all detected actions sequentially
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

    # -------------------------------------------------------------
    # MAX STEPS SAFETY CHECK
    # -------------------------------------------------------------
    STEP_COUNT=$((STEP_COUNT + 1))
    echo "   [STEP COUNT]: $STEP_COUNT / $MAX_STEPS"

    if [ "$STEP_COUNT" -ge "$MAX_STEPS" ]; then
        echo -e "\n=== Maximum Steps ($MAX_STEPS) Reached for Model $MODEL. Terminating. ==="
        break
    fi
done
