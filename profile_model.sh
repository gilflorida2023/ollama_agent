#!/usr/bin/env bash

set +H

MODEL="${1:-qwen3.5:9b-mlx}"
OLLAMA_URL="http://localhost:11434/api/chat"
CONFIG_DIR=".configs"
SCRIPT_DIR="$(dirname "$0")"

mkdir -p "$CONFIG_DIR"

SANITIZED_MODEL=$(echo "$MODEL" | sed 's/[/:]/_/g')
CONFIG_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.config.json"
PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.sh"

echo "=========================================="
echo "Profiling model: $MODEL"
echo "=========================================="

# Get current model ID
MODEL_ID=$(ollama list 2>/dev/null | awk -v m="$MODEL" '$1==m {print $2}' || echo "unknown")
PROFILED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Clean up any pm_* files from previous run
rm -f pm_hello.java pm_hello.class 2>/dev/null || true

# Build tools array for profiling (3 tools: write_file, javac, java)
TOOLS=$(cat << 'TOOLS_EOF'
[
  {
    "type": "function",
    "function": {
      "name": "write_file",
      "description": "Creates or overwrites a Java source file on disk.",
      "parameters": {
        "type": "object",
        "properties": {
          "filename": {
            "type": "string",
            "description": "Target filename for the Java source file. Must end with .java.",
            "pattern": "^.+\\.java$",
            "minLength": 1
          },
          "content": {
            "type": "string",
            "description": "Full Java source code to write. Must include a public class declaration matching the filename."
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
      "description": "Compiles a .java file that already exists on disk.",
      "parameters": {
        "type": "object",
        "properties": {
          "filename": {
            "type": "string",
            "description": "Name of the .java file to compile.",
            "pattern": "^.+\\.java$",
            "minLength": 1
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
      "description": "Runs a compiled Java class.",
      "parameters": {
        "type": "object",
        "properties": {
          "class_name": {
            "type": "string",
            "description": "Name of the compiled class to run (without .class extension).",
            "minLength": 1
          },
          "args": {
            "type": "array",
            "description": "Arguments passed to the Java main method.",
            "items": { "type": "string" }
          }
        },
        "required": ["class_name"]
      }
    }
  }
]
TOOLS_EOF
)

# Helper: send prompt and record response
send_prompt() {
    local step_name="$1"
    local prompt_text="$2"
    local raw_file="$CONFIG_DIR/${SANITIZED_MODEL}_pm_${step_name}.raw.json"

    local messages=$(jq -n \
      --arg user "$prompt_text" \
      '[{role: "user", content: $user}]')

    local payload=$(jq -s --arg model "$MODEL" \
      '{model: $model, messages: .[0], tools: .[1], stream: false, temperature: 0, think: false}' \
      <(echo "$messages") <(echo "$TOOLS"))

    local response=$(timeout 120 curl -s "$OLLAMA_URL" -H "Content-Type: application/json" -d "$payload")
    echo "$response" > "$raw_file"
    echo "$response"
}

# Helper: parse response and extract tool calls
parse_response() {
    local raw_file="$1"
    python3 "$SCRIPT_DIR/parser.py" --fallback < "$raw_file" 2>/dev/null
}

# Helper: validate write_file tool call
validate_write_file() {
    local tool_args="$1"
    local filename=$(echo "$tool_args" | jq -r '.filename // empty')
    local content=$(echo "$tool_args" | jq -r '.content // empty')

    if [ -z "$filename" ] || [ -z "$content" ]; then
        echo "FAIL: missing filename or content"
        return 1
    fi

    if [[ "$filename" != *.java ]]; then
        echo "FAIL: filename does not end with .java"
        return 1
    fi

    # Write content to file (using the new FORMATTED_CONTENT logic)
    local formatted=$(python3 -c "
import sys, re
raw = sys.stdin.read()
decoded = raw
decoded = re.sub(r'\\\\u([0-9a-fA-F]{4})', lambda m: chr(int(m.group(1), 16)), decoded)
decoded = re.sub(r'\}\s*\"?\s*\}?\s*\}?\s*\`{3,}\s*$', '}', decoded, flags=re.DOTALL)
decoded = re.sub(r'\}\s*\"?\s*\}?\s*$', '}', decoded, flags=re.DOTALL)
decoded = decoded.strip()
print(decoded)
" <<< "$content")
    echo "$formatted" > "$filename"

    # Check file exists and has content
    if [ ! -s "$filename" ]; then
        echo "FAIL: file is empty"
        return 1
    fi

    # Check file contains public class
    if ! grep -q "public class" "$filename"; then
        echo "FAIL: no public class declaration"
        return 1
    fi

    echo "PASS"
    return 0
}

# Helper: validate javac tool call
validate_javac() {
    local tool_args="$1"
    local filename=$(echo "$tool_args" | jq -r '.filename // empty')

    if [ -z "$filename" ]; then
        echo "FAIL: missing filename"
        return 1
    fi

    # Compile
    if javac "$filename" 2>/dev/null; then
        local class_file="${filename%.java}.class"
        if [ -f "$class_file" ]; then
            echo "PASS"
            return 0
        else
            echo "FAIL: .class file not created"
            return 1
        fi
    else
        echo "FAIL: compilation failed"
        return 1
    fi
}

# Helper: validate java tool call
validate_java() {
    local tool_args="$1"
    local class_name=$(echo "$tool_args" | jq -r '.class_name // empty')
    local args=$(echo "$tool_args" | jq -r '.args // [] | join(" ")')

    if [ -z "$class_name" ]; then
        echo "FAIL: missing class_name"
        return 1
    fi

    # Run
    local output=$(timeout 10 java $class_name $args 2>&1 || true)
    if echo "$output" | grep -q "Hello World"; then
        echo "PASS"
        return 0
    else
        echo "FAIL: output does not contain 'Hello World'"
        return 1
    fi
}

# Track results
declare -A RESULTS
STAGE_DETECTED=""

echo ""
echo "--- Step 1: CREATE ---"
echo "Prompt: Write a Java file named pm_hello.java with a class pm_hello that prints Hello World."
RESPONSE=$(send_prompt "create" "Write a Java file named pm_hello.java with a class pm_hello that prints Hello World.")
RAW_FILE="$CONFIG_DIR/${SANITIZED_MODEL}_pm_create.raw.json"
TOOL_CALLS=$(parse_response "$RAW_FILE")
NUM_CALLS=$(echo "$TOOL_CALLS" | jq 'length')

if [ "$NUM_CALLS" -gt 0 ]; then
    TOOL_NAME=$(echo "$TOOL_CALLS" | jq -r '.[0].name')
    TOOL_ARGS=$(echo "$TOOL_CALLS" | jq '.[0].arguments')

    # Detect stage from this response
    STAGE_DETECTED=$(python3 "$SCRIPT_DIR/parser.py" --probe < "$RAW_FILE" 2>/dev/null | jq -r '.stage // "None"')

    if [ "$TOOL_NAME" = "write_file" ]; then
        RESULT=$(validate_write_file "$TOOL_ARGS")
        RESULTS[create]="$RESULT"
        echo "Result: $RESULT"
    else
        RESULTS[create]="FAIL: wrong tool name ($TOOL_NAME)"
        echo "Result: FAIL: wrong tool name ($TOOL_NAME)"
    fi
else
    RESULTS[create]="FAIL: no tool calls detected"
    echo "Result: FAIL: no tool calls detected"
fi

echo ""
echo "--- Step 2: COMPILE ---"
echo "Prompt: Compile pm_hello.java."
RESPONSE=$(send_prompt "compile" "Compile pm_hello.java.")
RAW_FILE="$CONFIG_DIR/${SANITIZED_MODEL}_pm_compile.raw.json"
TOOL_CALLS=$(parse_response "$RAW_FILE")
NUM_CALLS=$(echo "$TOOL_CALLS" | jq 'length')

if [ "$NUM_CALLS" -gt 0 ]; then
    TOOL_NAME=$(echo "$TOOL_CALLS" | jq -r '.[0].name')
    TOOL_ARGS=$(echo "$TOOL_CALLS" | jq '.[0].arguments')

    if [ "$TOOL_NAME" = "javac" ]; then
        RESULT=$(validate_javac "$TOOL_ARGS")
        RESULTS[compile]="$RESULT"
        echo "Result: $RESULT"
    else
        RESULTS[compile]="FAIL: wrong tool name ($TOOL_NAME)"
        echo "Result: FAIL: wrong tool name ($TOOL_NAME)"
    fi
else
    RESULTS[compile]="FAIL: no tool calls detected"
    echo "Result: FAIL: no tool calls detected"
fi

echo ""
echo "--- Step 3: RUN ---"
echo "Prompt: Run pm_hello with no arguments."
RESPONSE=$(send_prompt "run" "Run pm_hello with no arguments.")
RAW_FILE="$CONFIG_DIR/${SANITIZED_MODEL}_pm_run.raw.json"
TOOL_CALLS=$(parse_response "$RAW_FILE")
NUM_CALLS=$(echo "$TOOL_CALLS" | jq 'length')

if [ "$NUM_CALLS" -gt 0 ]; then
    TOOL_NAME=$(echo "$TOOL_CALLS" | jq -r '.[0].name')
    TOOL_ARGS=$(echo "$TOOL_CALLS" | jq '.[0].arguments')

    if [ "$TOOL_NAME" = "java" ]; then
        RESULT=$(validate_java "$TOOL_ARGS")
        RESULTS[run]="$RESULT"
        echo "Result: $RESULT"
    else
        RESULTS[run]="FAIL: wrong tool name ($TOOL_NAME)"
        echo "Result: FAIL: wrong tool name ($TOOL_NAME)"
    fi
else
    RESULTS[run]="FAIL: no tool calls detected"
    echo "Result: FAIL: no tool calls detected"
fi

# Cleanup pm_* files
rm -f pm_hello.java pm_hello.class 2>/dev/null || true

# Save config
echo ""
echo "--- Saving Config ---"

# Determine validation status
CREATE_OK=false
COMPILE_OK=false
RUN_OK=false

[[ "${RESULTS[create]}" == "PASS" ]] && CREATE_OK=true
[[ "${RESULTS[compile]}" == "PASS" ]] && COMPILE_OK=true
[[ "${RESULTS[run]}" == "PASS" ]] && RUN_OK=true

if $CREATE_OK && $COMPILE_OK && $RUN_OK; then
    VALIDATION_STATUS="passed"
else
    VALIDATION_STATUS="failed"
fi

# Save config with validation
python3 -c "
import json, sys

# Read results from environment
config = {
    'stage': None,
    'model_id': sys.argv[1],
    'profiled_at': sys.argv[2],
    'validation': {
        'create': sys.argv[3],
        'compile': sys.argv[4],
        'run': sys.argv[5]
    },
    'validation_status': sys.argv[6]
}

# Try to parse stage as integer
try:
    config['stage'] = int(sys.argv[7]) if sys.argv[7] != 'None' else None
except (ValueError, IndexError):
    pass

with open(sys.argv[8], 'w') as f:
    json.dump(config, f, indent=2)
" "$MODEL_ID" "$PROFILED_AT" \
  "${RESULTS[create]}" "${RESULTS[compile]}" "${RESULTS[run]}" \
  "$VALIDATION_STATUS" "${STAGE_DETECTED:-None}" "$CONFIG_FILE"

echo "Config saved to: $CONFIG_FILE"
echo "Validation status: $VALIDATION_STATUS"

# Create parser shim
cat << 'PARSER_EOF' > "$PARSER_FILE"
#!/usr/bin/env bash
exec python3 "$(dirname "$0")/../parser.py" --model "$(basename "$0" .sh)"
PARSER_EOF
chmod +x "$PARSER_FILE"
echo "Parser shim created at: $PARSER_FILE"

# Summary
echo ""
echo "=========================================="
echo "Profile Summary: $MODEL"
echo "=========================================="
echo "  Create:  ${RESULTS[create]}"
echo "  Compile: ${RESULTS[compile]}"
echo "  Run:     ${RESULTS[run]}"
echo "  Status:  $VALIDATION_STATUS"
echo "=========================================="
