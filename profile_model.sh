#!/usr/bin/env bash

set +H
set -e

MODEL="${1:-qwen2.5-coder:7b}"
OLLAMA_URL="http://localhost:11434/api/chat"

SPEC_META=$(python3 "$(dirname "$0")/spec_parser.py" metadata)
SPEC_FILE=$(echo "$SPEC_META" | jq -r '.spec_file')
EXPECTED_FILENAME=$(echo "$SPEC_META" | jq -r '.filename')
CLASS_TOKEN=$(echo "$SPEC_META" | jq -r '.class_name')

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

SYSTEM_PROMPT=$(sed "s/{{FILENAME}}/$EXPECTED_FILENAME/g; s/{{CLASS_TOKEN}}/$CLASS_TOKEN/g" prompts/system.txt)

MESSAGES=$(jq -n \
  --arg sys "$SYSTEM_PROMPT" \
  --arg spec "$SPEC_TEXT" \
  '[
    {role: "system", content: $sys},
    {role: "user", content: $spec}
  ]')

TOOLS=$(jq -n \
  --arg fn "$EXPECTED_FILENAME" \
  --arg cn "$CLASS_TOKEN" \
  '[
    {
      "type": "function",
      "function": {
        "name": "write_file",
        "description": "Creates or overwrites a Java source file on disk. Use this first - before javac or java. Always provide both filename (ending in .java) and content (valid Java source code matching the filename).",
        "parameters": {
          "type": "object",
          "properties": {
            "filename": {
              "type": "string",
              "description": ("Target filename for the Java source file. Must end with .java. The spec requires " + $fn + " - use that exact value. Do not use paths like ./src/ - write to the current directory."),
              "pattern": "^.+\\.java$",
              "minLength": 1,
              "examples": [$fn]
            },
            "content": {
              "type": "string",
              "description": ("Full Java source code to write. Must include a public class <ClassName> declaration where ClassName matches the filename (e.g. public class " + $cn + " for " + $fn + "). Use Java 17+ syntax. No external dependencies - standard library only.")
            }
          },
          "required": ["filename", "content"]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "javac",
        "description": "Compiles a .java file that already exists on disk (created by a prior write_file call). The class file output will be in the same directory. Only proceed to java after this succeeds. If compilation fails, use write_file again to fix errors.",
        "parameters": {
          "type": "object",
          "properties": {
            "filename": {
              "type": "string",
              "description": ("Name of the .java file to compile. Must match a file you already created with write_file. The spec expects " + $fn + "."),
              "pattern": "^.+\\.java$",
              "minLength": 1,
              "examples": [$fn]
            }
          },
          "required": ["filename"]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "java",
        "description": "Runs a compiled Java class (must have called javac successfully first). Do not call this before javac completes without errors. The args array holds command-line arguments for the program main(String[]) method.",
        "parameters": {
          "type": "object",
          "properties": {
            "class_name": {
              "type": "string",
              "description": ("Name of the compiled class to run. Do not add .class extension. Must match the public class declaration in your .java file and equal the filename without extension. For " + $fn + ", use " + $cn + ". Do not include packages - the file has no package declaration."),
              "minLength": 1,
              "examples": [$cn]
            },
            "args": {
              "type": "array",
              "description": "Arguments passed to the Java main method. The spec expects an integer N as the first argument. Example: [\"11\"] for N=11, [\"1000\"] for N=1000, [\"-1\"] for the empty-stream test. Pass exactly one string per argument.",
              "items": { "type": "string" },
              "examples": [["11"], ["1000"], ["-1"]]
            }
          },
          "required": ["class_name"]
        }
      }
    }
  ]')

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
