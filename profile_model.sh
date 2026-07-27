#!/usr/bin/env bash

set +H
set -e

MODEL="${1:-qwen2.5-coder:7b}"
SPEC_FILE="prompt.hashprime.info"
OLLAMA_URL="http://localhost:11434/api/chat"

CONFIG_DIR=".configs"
mkdir -p "$CONFIG_DIR"

SANITIZED_MODEL=$(echo "$MODEL" | sed 's/[/:]/_/g')
RAW_RESPONSE_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.raw.json"
PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.sh"

echo "=========================================="
echo "🔍 Profiling model: $MODEL"
echo "=========================================="

if [ ! -f "$SPEC_FILE" ]; then
    echo "Error: $SPEC_FILE not found."
    exit 1
fi

SPEC_TEXT=$(cat "$SPEC_FILE")
SYSTEM_PROMPT="You are an automated software engineer. ALWAYS follow this strict action sequence: 1) write_file, 2) javac, 3) java. Never attempt to run 'java' before 'javac' succeeds. Test N=11 and N=1000, then stop."

MESSAGES=$(jq -n \
  --arg sys "$SYSTEM_PROMPT" \
  --arg spec "$SPEC_TEXT" \
  '[
    {role: "system", content: $sys},
    {role: "user", content: $spec}
  ]')

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

PAYLOAD_TEMPLATE='{model: $model, messages: .[0], tools: .[1], stream: false, temperature: 0, think: false}'

PAYLOAD=$(jq -s --arg model "$MODEL" \
  "$PAYLOAD_TEMPLATE" \
  <(echo "$MESSAGES") <(echo "$TOOLS"))

echo "--> Sending probe request to Ollama (up to 3 attempts)..."
CONFIG_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.config.json"

for attempt in 1 2 3; do
    RESPONSE=$(curl -s "$OLLAMA_URL" -H "Content-Type: application/json" -d "$PAYLOAD")
    echo "$RESPONSE" > "$RAW_RESPONSE_FILE"

    python3 "$(dirname "$0")/parser.py" --probe < "$RAW_RESPONSE_FILE" > "$CONFIG_FILE"

    STAGE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('stage'))")
    if [ "$STAGE" != "None" ]; then
        echo "📊 Saved raw response to: $RAW_RESPONSE_FILE"
        echo "✅ Detected format — stage $STAGE (attempt $attempt)"
        break
    fi
    echo "⚠️  Attempt $attempt: no tool calls detected. Retrying..."
done

if [ "$STAGE" = "None" ]; then
    rm -f "$CONFIG_FILE"
    echo "📊 Saved raw response to: $RAW_RESPONSE_FILE"
    echo "⚠️  No format detected after 3 attempts — parser will use full cascade"
fi

cat << 'PARSER_EOF' > "$PARSER_FILE"
#!/usr/bin/env bash
exec python3 "$(dirname "$0")/../parser.py" --model "$(basename "$0" .sh)"
PARSER_EOF

chmod +x "$PARSER_FILE"
echo "✅ Custom parser created at: $PARSER_FILE"
chmod +x profile_model.sh
