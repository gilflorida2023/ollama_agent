#!/usr/bin/env bash

# Disable history expansion so '!' characters won't break Bash
set +H
set -e

MODEL="${1:-qwen2.5-coder:7b}"
SPEC_FILE="prompt.hashprime.info"
OLLAMA_URL="http://localhost:11434/api/chat"

CONFIG_DIR=".configs"
mkdir -p "$CONFIG_DIR"

# Sanitize model name for filesystem safety
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

# Build initialization payload
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

PAYLOAD=$(jq -s --arg model "$MODEL" \
  '{model: $model, messages: .[0], tools: .[1], stream: false}' \
  <(echo "$MESSAGES") <(echo "$TOOLS"))

echo "--> Sending probe request to Ollama..."
RESPONSE=$(curl -s "$OLLAMA_URL" -H "Content-Type: application/json" -d "$PAYLOAD")

# Save raw response for inspection
echo "$RESPONSE" > "$RAW_RESPONSE_FILE"
echo "📊 Saved raw response to: $RAW_RESPONSE_FILE"

# Detect response structure style
NATIVE_CALLS=$(echo "$RESPONSE" | jq -c '.message.tool_calls // []')
CONTENT=$(echo "$RESPONSE" | jq -r '.message.content // empty')

DETECTED_STYLE="unknown"

if [ "$NATIVE_CALLS" != "[]" ]; then
    DETECTED_STYLE="native"
elif echo "$CONTENT" | grep -q '"name":'; then
    DETECTED_STYLE="json_embedded"
elif echo "$CONTENT" | grep -q -E '<write_file|<javac|<java'; then
    DETECTED_STYLE="xml"
elif echo "$CONTENT" | grep -q '```java'; then
    DETECTED_STYLE="markdown_code_block"
elif echo "$CONTENT" | grep -q -E '```sh|```bash'; then
    DETECTED_STYLE="shell_command_block"
fi

echo "🎯 Detected tool calling style: [$DETECTED_STYLE]"

# Generate standalone pure Bash parser file for this model
cat << 'EOF' > "$PARSER_FILE"
#!/usr/bin/env bash

# Reads JSON response from stdin and outputs JSON array of tool calls
RESPONSE_INPUT=$(cat)

# 1. Native Tool Calls
NATIVE=$(echo "$RESPONSE_INPUT" | jq -c '.message.tool_calls // []' 2>/dev/null || echo "[]")
if [ "$NATIVE" != "[]" ]; then
    echo "$NATIVE" | jq '[.[] | {name: .function.name, arguments: .function.arguments}]'
    exit 0
fi

CONTENT=$(echo "$RESPONSE_INPUT" | jq -r '.message.content // empty')

# 2. Extract Embedded JSON
JSON_EXTRACTED=$(echo "$CONTENT" | sed 's/```json//g; s/```//g' | grep -o '{"name"[^}]*}}' | jq -s '.' 2>/dev/null || echo "[]")
if [ "$JSON_EXTRACTED" != "[]" ] && [ "$(echo "$JSON_EXTRACTED" | jq 'length')" -gt 0 ]; then
    echo "$JSON_EXTRACTED"
    exit 0
fi

# 3. Extract XML Tags
XML_CALLS="[]"
if echo "$CONTENT" | grep -q "<write_file"; then
    FN=$(echo "$CONTENT" | sed -n 's/.*<write_file[^>]*filename="\([^"]*\)".*/\1/p')
    CNT=$(echo "$CONTENT" | sed -n 's/.*content="\([^"]*\)".*/\1/p')
    if [ -n "$FN" ]; then
        XML_CALLS=$(echo "$XML_CALLS" | jq --arg fn "$FN" --arg cnt "$CNT" '. + [{name: "write_file", arguments: {filename: $fn, content: $cnt}}]')
    fi
fi

if echo "$CONTENT" | grep -q "<javac"; then
    FN=$(echo "$CONTENT" | sed -n 's/.*<javac[^>]*filename="\([^"]*\)".*/\1/p')
    if [ -n "$FN" ]; then
        XML_CALLS=$(echo "$XML_CALLS" | jq --arg fn "$FN" '. + [{name: "javac", arguments: {filename: $fn}}]')
    fi
fi

if echo "$CONTENT" | grep -q "<java"; then
    CN=$(echo "$CONTENT" | sed -n 's/.*class_name="\([^"]*\)".*/\1/p')
    RAW_A=$(echo "$CONTENT" | sed -n 's/.*args="\([^"]*\)".*/\1/p')
    if [ -n "$CN" ]; then
        XML_CALLS=$(echo "$XML_CALLS" | jq --arg cn "$CN" --argjson args "${RAW_A:-[]}" '. + [{name: "java", arguments: {class_name: $cn, args: $args}}]' 2>/dev/null || \
                    echo "$XML_CALLS" | jq --arg cn "$CN" '. + [{name: "java", arguments: {class_name: $cn, args: []}}]')
    fi
fi

if [ "$XML_CALLS" != "[]" ]; then
    echo "$XML_CALLS"
    exit 0
fi

# 4. Extract Raw Markdown Java Code Block
if echo "$CONTENT" | grep -q "public class"; then
    CLASS_NAME=$(echo "$CONTENT" | sed -n 's/.*public[[:space:]]\+class[[:space:]]\+\([A-Za-z0-9_]\+\).*/\1/p' | head -n 1)
    if [ -n "$CLASS_NAME" ]; then
        CODE_BODY=$(echo "$CONTENT" | sed -n '/```java/,/```/p' | sed '1d;$d')
        if [ -z "$CODE_BODY" ]; then
            CODE_BODY=$(echo "$CONTENT" | sed -n '/```/,/```/p' | sed '1d;$d')
        fi
        if [ -n "$CODE_BODY" ]; then
            jq -n --arg fn "${CLASS_NAME}.java" --arg cnt "$CODE_BODY" \
               '[{name: "write_file", arguments: {filename: $fn, content: $cnt}}]'
            exit 0
        fi
    fi
fi

# 5. Fallback empty array
echo "[]"
EOF

chmod +x "$PARSER_FILE"
echo "✅ Custom Bash parser created at: $PARSER_FILE"