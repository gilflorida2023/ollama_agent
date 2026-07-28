#!/usr/bin/env bash

set +H
set -e

MODEL="${1:-qwen2.5-coder:7b}"
SPEC_FILE="prompt.hashprime.info"
OLLAMA_URL="http://localhost:11434/api/chat"

CONFIG_DIR=".configs"
SANITIZED_MODEL=$(echo "$MODEL" | sed 's/[/:]/_/g')
PARSER_FILE="parser.py"
if [ -f "$CONFIG_DIR/${SANITIZED_MODEL}.sh" ]; then
    PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.sh"
elif [ -f "$CONFIG_DIR/${SANITIZED_MODEL}.py" ]; then
    PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.py"
else
    echo "⚠️  No parser profile found for $MODEL. Running profile_model.sh..."
    bash ./profile_model.sh "$MODEL"
    PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.sh"
fi

MAX_STEPS=10
MAX_SESSION_SECONDS=120

echo "=========================================="
echo "--> Preloading/Warming model into memory: $MODEL..."
echo "=========================================="

JSON_PAYLOAD=$(jq -c -n --arg model "$MODEL" '{
  model: $model,
  messages: [{role: "user", content: "hi"}],
  keep_alive: "5m",
  think: false
}')

curl -s "$OLLAMA_URL" \
     -H "Content-Type: application/json" \
     -d "$JSON_PAYLOAD" \
     > /dev/null

echo "✅ Model preloaded successfully."

echo "=========================================="
echo "--> Running evaluation for model: $MODEL"
echo "⚡ Using dedicated parser: $PARSER_FILE"
echo "=========================================="

if [ ! -f "$SPEC_FILE" ]; then
    echo "Error: $SPEC_FILE not found."
    exit 1
fi

rm -f *.class *.java 2>&1 >/dev/null || true

echo "--> Reading specification file..."
SPEC_TEXT=$(cat "$SPEC_FILE")

shopt -s nocasematch
if [[ "$SPEC_TEXT" =~ File:[[:space:]]*([^[:space:]]+\.java) ]]; then
    EXPECTED_FILENAME="${BASH_REMATCH[1]}"
else
    EXPECTED_FILENAME="hashprime.java"
fi
shopt -u nocasematch

CLASS_TOKEN="${EXPECTED_FILENAME%.java}"

echo "--> Spec requests file: $EXPECTED_FILENAME"

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

echo "--> Starting Ollama Agent Loop (Max Steps: $MAX_STEPS, Max Time: ${MAX_SESSION_SECONDS}s)..."
LAST_RESPONSE=""
MISSING_COUNT=0
SUBMIT_CALLED=false
TIMED_OUT=false
SESSION_START=$(date +%s)

while true; do
    PAYLOAD=$(jq -s --arg model "$MODEL" \
      '{model: $model, messages: .[0], tools: .[1], stream: false, temperature: 0, think: false}' \
      <(echo "$MESSAGES") <(echo "$TOOLS"))

    RESPONSE=$(curl -s "$OLLAMA_URL" -H "Content-Type: application/json" -d "$PAYLOAD")
    LAST_RESPONSE="$RESPONSE"

    TOOL_CALLS_ARRAY=$(
        case "$PARSER_FILE" in
            *.sh) RESULT=$(bash "$PARSER_FILE" <<< "$RESPONSE")
                  if [ "$(echo "$RESULT" | python3 -c "import sys,json; calls=json.load(sys.stdin); print(len(calls))" 2>/dev/null || echo 0)" -eq 0 ]; then
                      python3 parser.py <<< "$RESPONSE"
                  else
                      echo "$RESULT"
                  fi ;;
            *)    python3 "$PARSER_FILE" <<< "$RESPONSE" ;;
        esac
    )
    NUM_CALLS=$(echo "$TOOL_CALLS_ARRAY" | jq 'length')

    if [ "$NUM_CALLS" -eq 0 ]; then
        if [ "$MISSING_COUNT" -eq 0 ] && [ "$STEP_COUNT" -eq 0 ]; then
            MISSING_COUNT=1
            echo "⚠️  No tool calls detected on first turn — retrying once..."
            continue
        fi

        CONTENT=$(echo "$RESPONSE" | jq -r '.message.content // ""')
        if echo "$CONTENT" | grep -q '\`\`\`sh'; then
            echo "📦 Parsing \`\`\`sh code block..."
            COMMANDS=$(echo "$CONTENT" | sed -n '/```sh/,/```/{//!p}' | sed '/^$/d')

            ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
            MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$ASSISTANT_MSG"))

            COMBINED_OUTPUT=""
            while IFS= read -r CMD; do
                [ -z "$CMD" ] && continue
                read -r CMD_NAME REST <<< "$CMD"
                case "$CMD_NAME" in
                    javac)
                        echo "   [PARSED]: javac $REST"
                        if COMPILE_ERR=$(javac $REST 2>&1); then
                            OUT="Compilation successful."
                            echo "   [SUCCESS]: Compiled cleanly."
                        else
                            OUT="Compilation failed with error:\n$COMPILE_ERR"
                            echo "   [ERROR]: Compilation failed."
                        fi
                        ;;
                    java)
                        echo "   [PARSED]: java $REST"
                        RUN_OUT=$(java $REST 2>&1 || true)
                        OUT="Program Output:\n$RUN_OUT"
                        echo "   [PROGRAM OUTPUT]: $RUN_OUT"
                        ;;
                    *)
                        echo "   [SKIP]: unknown command '$CMD_NAME'"
                        continue
                        ;;
                esac
                COMBINED_OUTPUT=$(printf "%s\n%s" "$COMBINED_OUTPUT" "$OUT")
            done <<< "$COMMANDS"

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
            MISSING_COUNT=0
            continue
        fi

        echo -e "\n=== Agent Finished Naturally ==="
        echo "$RESPONSE" | jq -r '.message.content'
        break
    fi
    MISSING_COUNT=0

    ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
    MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$ASSISTANT_MSG"))

    COMBINED_OUTPUT=""

    for (( i=0; i<$NUM_CALLS; i++ )); do
        CALL=$(echo "$TOOL_CALLS_ARRAY" | jq ".[$i]")
        TOOL_NAME=$(echo "$CALL" | jq -r '.name')
        TOOL_ARGS=$(echo "$CALL" | jq '.arguments')

        echo "--> [ACTION DETECTED]: $TOOL_NAME"

        case "$TOOL_NAME" in
            "write_file")
                FILENAME=$(echo "$TOOL_ARGS" | jq -r '.filename // empty')
                CONTENT=$(echo "$TOOL_ARGS" | jq -r '.content // empty')

                if [ -z "$FILENAME" ] || [ "$FILENAME" = "null" ]; then
                    OUT="Tool Exec Error: Missing or invalid filename. You must provide a valid filename parameter (e.g. 'hashprime.java')."
                    echo "   [ERROR]: Model attempted to write file with null/empty filename. Request rejected."
                else
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

echo "=========================================="
echo "          AUTOMATED HARNESS VALIDATION    "
echo "=========================================="

if [ -f "hashprime.java" ]; then
    echo "🔍 Found hashprime.java on disk. Starting automated test harness..."

    if COMPILE_LOG=$(javac hashprime.java 2>&1); then
        echo "✅ [HARNESS]: Compilation succeeded."

        EXPECTED_11="563d8e0603dcc07d784135d99fd81ff6bf98495e898ec1f52e2e7605320cf6dc"
        ACTUAL_11=$(java hashprime 11 2>&1 | tr -d '\r\n')
        if [ "$ACTUAL_11" = "$EXPECTED_11" ]; then
            echo "✅ [TEST PASS]: N=11 -> $ACTUAL_11"
        else
            echo "❌ [TEST FAIL]: N=11 -> Expected: $EXPECTED_11 | Got: $ACTUAL_11"
        fi

        EXPECTED_1000="55542ac8f84d3c795ac05ea7dc3e382353c4bdd519d97e178d3f17a7f97fb25f"
        ACTUAL_1000=$(java hashprime 1000 2>&1 | tr -d '\r\n')
        if [ "$ACTUAL_1000" = "$EXPECTED_1000" ]; then
            echo "✅ [TEST PASS]: N=1000 -> $ACTUAL_1000"
        else
            echo "❌ [TEST FAIL]: N=1000 -> Expected: $EXPECTED_1000 | Got: $ACTUAL_1000"
        fi

        EXPECTED_EMPTY="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        ACTUAL_EMPTY=$(java hashprime -1 2>&1 | tr -d '\r\n')
        if [ "$ACTUAL_EMPTY" = "$EXPECTED_EMPTY" ]; then
            echo "✅ [TEST PASS]: N=-1 -> $ACTUAL_EMPTY"
        else
            echo "❌ [TEST FAIL]: N=-1 -> Expected: $EXPECTED_EMPTY | Got: $ACTUAL_EMPTY"
        fi
    else
        echo "❌ [HARNESS]: Compilation failed."
        echo "$COMPILE_LOG" | sed 's/^/   | /'
    fi
else
    echo "❌ [HARNESS]: hashprime.java was not found on disk. Skipping validation."
fi

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
