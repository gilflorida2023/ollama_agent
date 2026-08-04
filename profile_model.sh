#!/usr/bin/env bash

# The key insight: we don't need to change the model, we need to adapt to it.
# Models use 3 different response formats:
#   Format A: Native tool_calls (gemma4, qwen3.5 mlx)
#   Format B: JSON in content (qwen2.5-coder)
#   Format C: Markdown code blocks (qwen3.5:9b-mlx)
# We detect the format during profiling and adapt parsing accordingly.
# Format C models write javac/java in bash blocks — we detect these with --context.

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

# Helper: send messages and record response
send_messages() {
    local step_name="$1"
    local messages="$2"
    local raw_file="$CONFIG_DIR/${SANITIZED_MODEL}_pm_${step_name}.raw.json"

    # Write to temp files for jq slurpfile (more reliable than process substitution)
    local tmp_messages="/tmp/profile_messages.json"
    local tmp_tools="/tmp/profile_tools.json"
    echo "$messages" > "$tmp_messages"
    echo "$TOOLS" > "$tmp_tools"

    local payload=$(jq -s -n --arg model "$MODEL" \
      --slurpfile m "$tmp_messages" \
      --slurpfile t "$tmp_tools" \
      '{model: $model, messages: $m[0], tools: $t[0], stream: false, temperature: 0, think: false}')

    local response=$(timeout 120 curl -s "$OLLAMA_URL" -H "Content-Type: application/json" -d "$payload")
    echo "$response" > "$raw_file"
    echo "$response"
}

# Helper: parse response and extract tool calls
parse_response() {
    local raw_file="$1"
    local context="${2:-}"
    if [ -n "$context" ]; then
        python3 "$SCRIPT_DIR/parser.py" --fallback --context "$context" < "$raw_file" 2>/dev/null
    else
        python3 "$SCRIPT_DIR/parser.py" --fallback < "$raw_file" 2>/dev/null
    fi
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
# Only strip trailing artifacts that contain quotes or backticks (parser junk)
# Do NOT strip bare closing braces - those are legitimate Java code
decoded = re.sub(r'\}\s*\"\s*\}\s*\}\s*\`{3,}\s*$', '}', decoded, flags=re.DOTALL)
decoded = re.sub(r'\}\s*\"\s*\}\s*\`{3,}\s*$', '}', decoded, flags=re.DOTALL)
decoded = re.sub(r'\`{3,}\s*$', '', decoded, flags=re.DOTALL)
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
FORMAT_DETECTED=""

# Initialize MESSAGES with system prompt and first user prompt
MESSAGES=$(jq -n \
  --arg user "Write a Java file named pm_hello.java with a class pm_hello that prints Hello World." \
  '[{role: "user", content: $user}]')

echo ""
echo "--- Step 1: CREATE ---"
echo "Prompt: Write a Java file named pm_hello.java with a class pm_hello that prints Hello World."
RESPONSE=$(send_messages "create" "$MESSAGES")
RAW_FILE="$CONFIG_DIR/${SANITIZED_MODEL}_pm_create.raw.json"
TOOL_CALLS=$(parse_response "$RAW_FILE" "create")
NUM_CALLS=$(echo "$TOOL_CALLS" | jq 'length')

if [ "$NUM_CALLS" -gt 0 ]; then
    TOOL_NAME=$(echo "$TOOL_CALLS" | jq -r '.[0].name')
    TOOL_ARGS=$(echo "$TOOL_CALLS" | jq '.[0].arguments')

    # Detect stage from this response
    STAGE_DETECTED=$(python3 "$SCRIPT_DIR/parser.py" --probe < "$RAW_FILE" 2>/dev/null | jq -r '.stage // "None"')

    # Map stage to format: A=native tool_calls, B=JSON in content, C=markdown code blocks
    case "$STAGE_DETECTED" in
        1) FORMAT_DETECTED="A" ;;      # Native tool_calls
        3|4) FORMAT_DETECTED="B" ;;    # JSON in content
        6|7|8) FORMAT_DETECTED="C" ;;  # Markdown code blocks
        *) FORMAT_DETECTED="C" ;;      # Default to C for unknown
    esac

    if [ "$TOOL_NAME" = "write_file" ]; then
        RESULT=$(validate_write_file "$TOOL_ARGS")
        RESULTS[create]="$RESULT"
        echo "Result: $RESULT"

        # Append assistant response to MESSAGES
        ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
        MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$ASSISTANT_MSG"))

        # Append tool result as user message
        MESSAGES=$(jq -s '.[0] + [{"role": "user", "content": "File written successfully."}]' <(echo "$MESSAGES"))
    else
        RESULTS[create]="FAIL: wrong tool name ($TOOL_NAME)"
        echo "Result: FAIL: wrong tool name ($TOOL_NAME)"

        # Still append the response to maintain history
        ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
        MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$ASSISTANT_MSG"))
        MESSAGES=$(jq -s '.[0] + [{"role": "user", "content": "Error: expected write_file tool call."}]' <(echo "$MESSAGES"))
    fi
else
    RESULTS[create]="FAIL: no tool calls detected"
    echo "Result: FAIL: no tool calls detected"

    # Append empty response to maintain history
    MESSAGES=$(jq -s '.[0] + [{"role": "assistant", "content": ""}, {"role": "user", "content": "No tool call detected. Please try again."}]' <(echo "$MESSAGES"))
fi

echo ""
echo "--- Step 2: COMPILE ---"
echo "Prompt: Compile pm_hello.java."
RESPONSE=$(send_messages "compile" "$MESSAGES")
RAW_FILE="$CONFIG_DIR/${SANITIZED_MODEL}_pm_compile.raw.json"
TOOL_CALLS=$(parse_response "$RAW_FILE" "compile")
NUM_CALLS=$(echo "$TOOL_CALLS" | jq 'length')

if [ "$NUM_CALLS" -gt 0 ]; then
    TOOL_NAME=$(echo "$TOOL_CALLS" | jq -r '.[0].name')
    TOOL_ARGS=$(echo "$TOOL_CALLS" | jq '.[0].arguments')

    if [ "$TOOL_NAME" = "javac" ]; then
        RESULT=$(validate_javac "$TOOL_ARGS")
        RESULTS[compile]="$RESULT"
        echo "Result: $RESULT"

        # Append assistant response to MESSAGES
        ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
        MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$ASSISTANT_MSG"))

        # Append tool result
        if [ "$RESULT" = "PASS" ]; then
            MESSAGES=$(jq -s '.[0] + [{"role": "user", "content": "Compilation successful."}]' <(echo "$MESSAGES"))
        else
            MESSAGES=$(jq -s '.[0] + [{"role": "user", "content": "Compilation failed: '"$RESULT"'"}]' <(echo "$MESSAGES"))
        fi
    else
        RESULTS[compile]="FAIL: wrong tool name ($TOOL_NAME)"
        echo "Result: FAIL: wrong tool name ($TOOL_NAME)"

        ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
        MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$ASSISTANT_MSG"))
        MESSAGES=$(jq -s '.[0] + [{"role": "user", "content": "Error: expected javac tool call."}]' <(echo "$MESSAGES"))
    fi
else
    RESULTS[compile]="FAIL: no tool calls detected"
    echo "Result: FAIL: no tool calls detected"

    MESSAGES=$(jq -s '.[0] + [{"role": "assistant", "content": ""}, {"role": "user", "content": "No tool call detected. Please try again."}]' <(echo "$MESSAGES"))
fi

echo ""
echo "--- Step 3: RUN ---"
echo "Prompt: Run pm_hello with no arguments."
RESPONSE=$(send_messages "run" "$MESSAGES")
RAW_FILE="$CONFIG_DIR/${SANITIZED_MODEL}_pm_run.raw.json"
TOOL_CALLS=$(parse_response "$RAW_FILE" "run")
NUM_CALLS=$(echo "$TOOL_CALLS" | jq 'length')

if [ "$NUM_CALLS" -gt 0 ]; then
    TOOL_NAME=$(echo "$TOOL_CALLS" | jq -r '.[0].name')
    TOOL_ARGS=$(echo "$TOOL_CALLS" | jq '.[0].arguments')

    if [ "$TOOL_NAME" = "java" ]; then
        RESULT=$(validate_java "$TOOL_ARGS")
        RESULTS[run]="$RESULT"
        echo "Result: $RESULT"

        # Append assistant response to MESSAGES
        ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
        MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$ASSISTANT_MSG"))

        # Append tool result
        if [ "$RESULT" = "PASS" ]; then
            MESSAGES=$(jq -s '.[0] + [{"role": "user", "content": "Hello World"}]' <(echo "$MESSAGES"))
        else
            MESSAGES=$(jq -s '.[0] + [{"role": "user", "content": "Error: '"$RESULT"'"}]' <(echo "$MESSAGES"))
        fi
    else
        RESULTS[run]="FAIL: wrong tool name ($TOOL_NAME)"
        echo "Result: FAIL: wrong tool name ($TOOL_NAME)"

        ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
        MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$ASSISTANT_MSG"))
        MESSAGES=$(jq -s '.[0] + [{"role": "user", "content": "Error: expected java tool call."}]' <(echo "$MESSAGES"))
    fi
else
    RESULTS[run]="FAIL: no tool calls detected"
    echo "Result: FAIL: no tool calls detected"

    MESSAGES=$(jq -s '.[0] + [{"role": "assistant", "content": ""}, {"role": "user", "content": "No tool call detected. Please try again."}]' <(echo "$MESSAGES"))
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
    'format': sys.argv[9] if len(sys.argv) > 9 else 'C',  # A=native, B=JSON, C=markdown
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
  "$VALIDATION_STATUS" "${STAGE_DETECTED:-None}" "$CONFIG_FILE" "${FORMAT_DETECTED:-C}"

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
