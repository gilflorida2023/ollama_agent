#!/usr/bin/env bash

set +H
set -e

START_TIME=$(date +%s)
MODEL="${1:-qwen3.5:9b-mlx}"
SPEC_FILE="prompt.hashprime.info"
OLLAMA_URL="http://localhost:11434/api/chat"

CONFIG_DIR=".configs"
SANITIZED_MODEL=$(echo "$MODEL" | sed 's/[/:]/_/g')
PARSER_FILE="parser.py"
if [ -f "$CONFIG_DIR/${SANITIZED_MODEL}.sh" ]; then
    # Check if validation failed and re-profile
    VALIDATION_STATUS=$(python3 -c "import json; print(json.load(open('$CONFIG_DIR/${SANITIZED_MODEL}.config.json')).get('validation_status', 'unknown'))" 2>/dev/null || echo "unknown")
    if [ "$VALIDATION_STATUS" = "failed" ]; then
        echo "⚠️  Re-profiling: previous validation failed"
        rm -f "$CONFIG_DIR/${SANITIZED_MODEL}.sh" "$CONFIG_DIR/${SANITIZED_MODEL}.config.json" "$CONFIG_DIR/${SANITIZED_MODEL}_pm_"*.raw.json
        bash ./profile_model.sh "$MODEL"
    else
        # Check if model ID is present and matches current
        CURRENT_ID=$(ollama list 2>/dev/null | awk -v m="$MODEL" '$1==m {print $2}' || echo "")
        STORED_ID=$(python3 -c "import json; print(json.load(open('$CONFIG_DIR/${SANITIZED_MODEL}.config.json')).get('model_id', ''))" 2>/dev/null || echo "")
        if [ -z "$STORED_ID" ] || [ "$CURRENT_ID" != "$STORED_ID" ]; then
            REASON=$( [ -z "$STORED_ID" ] && echo "no model_id in config" || echo "ID changed ($STORED_ID → $CURRENT_ID)" )
            echo "⚠️  Re-profiling: $REASON"
            rm -f "$CONFIG_DIR/${SANITIZED_MODEL}.sh" "$CONFIG_DIR/${SANITIZED_MODEL}.config.json" "$CONFIG_DIR/${SANITIZED_MODEL}_pm_"*.raw.json
            bash ./profile_model.sh "$MODEL"
        fi
    fi
    PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.sh"
elif [ -f "$CONFIG_DIR/${SANITIZED_MODEL}.py" ]; then
    PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.py"
else
    echo "⚠️  No parser profile found for $MODEL. Running profile_model.sh..."
    bash ./profile_model.sh "$MODEL"
    PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.sh"
fi

MAX_STEPS=10
STEP_TIMEOUT=120
STEP_COUNT=0

PROGRESS_FILE="sandbox/progress_tracker.py"

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

# Extract filename from spec: handles both plain "File: foo.java" and markdown "**File**: `foo.java`"
shopt -s nocasematch
if [[ "$SPEC_TEXT" =~ \*\*File\*\*:[[:space:]]*\`([^[:space:]]+\.java)\` ]]; then
    EXPECTED_FILENAME="${BASH_REMATCH[1]}"
elif [[ "$SPEC_TEXT" =~ File:[[:space:]]*([^[:space:]]+\.java) ]]; then
    EXPECTED_FILENAME="${BASH_REMATCH[1]}"
else
    # Fallback: look for any .java filename in the spec
    EXPECTED_FILENAME=$(echo "$SPEC_TEXT" | grep -oE '[a-zA-Z0-9_-]+\.java' | head -1)
    [ -z "$EXPECTED_FILENAME" ] && EXPECTED_FILENAME="Main.java"
fi
shopt -u nocasematch

CLASS_TOKEN="${EXPECTED_FILENAME%.java}"

echo "--> Spec requests file: $EXPECTED_FILENAME"

SYSTEM_PROMPT=$(sed "s/{{FILENAME}}/$EXPECTED_FILENAME/g; s/{{CLASS_TOKEN}}/$CLASS_TOKEN/g" prompts/system.txt)

# Auto-context injection: search OKF for relevant knowledge
if [ -d "knowledge" ]; then
    # Extract meaningful keywords from spec (exclude common words)
    KEYWORDS=$(echo "$SPEC_TEXT" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | \
        grep -E '^.{4,}$' | \
        grep -v -E '^(this|that|with|from|have|been|will|your|file|class|code|test|run|make|use|the|and|for|not|are|but|can|may|its|our|has|how|all|any|one|do|no|so|if|to|in|it|of|or|we|by)$' | \
        head -5 | tr '\n' ' ')
    
    if [ -n "$KEYWORDS" ]; then
        OKF_CONTEXT=""
        for keyword in $KEYWORDS; do
            FOUND=$(grep -r -i --include="*.md" -l "$keyword" knowledge/trusted_bundles knowledge/new_bundles 2>/dev/null | head -3)
            if [ -n "$FOUND" ]; then
                for file in $FOUND; do
                    # Extract relevant lines (not frontmatter)
                    CONTENT=$(sed -n '/^##/,$p' "$file" 2>/dev/null | head -20)
                    if [ -n "$CONTENT" ]; then
                        OKF_CONTEXT="${OKF_CONTEXT}\n--- From: $(basename "$file") ---\n${CONTENT}\n"
                    fi
                done
            fi
        done
        
        if [ -n "$OKF_CONTEXT" ]; then
            SYSTEM_PROMPT="${SYSTEM_PROMPT}

=== RELEVANT OKF KNOWLEDGE ===
The following knowledge may be relevant to your task:
${OKF_CONTEXT}
Apply these patterns to your implementation."
        fi
    fi
fi

MESSAGES=$(jq -n \
  --arg sys "$SYSTEM_PROMPT" \
  --arg spec "$SPEC_TEXT" \
  '[
    {role: "system", content: $sys},
    {role: "user", content: $spec}
  ]')

# Load tools from external JSON file, injecting spec filename into descriptions
TOOLS=$(jq -c --arg fn "$EXPECTED_FILENAME" --arg cn "$CLASS_TOKEN" '.tools |
  map(
    if .function.name == "write_file" then
      .function.description = ("Creates or overwrites a Java source file on disk. Use this FIRST — before javac or java. ALWAYS write to file: " + $fn + ". Do not use any other filename.")
      | .function.parameters.properties.filename.description = ("Must be exactly: " + $fn + ". Do not use any other filename.")
    elif .function.name == "javac" then
      .function.description = ("Compiles " + $fn + " that already exists on disk. Only proceed to java after this succeeds.")
      | .function.parameters.properties.filename.description = ("Must be exactly: " + $fn)
    elif .function.name == "java" then
      .function.description = ("Runs " + $cn + " (must have called javac successfully first). Do not call this before javac completes without errors.")
      | .function.parameters.properties.class_name.description = ("Must be exactly: " + $cn + ". Do not add .class extension.")
    else . end
  )' tools.json 2>/dev/null || echo "[]")

echo "--> Starting Ollama Agent Loop (Max Steps: $MAX_STEPS, Max Time per Step: ${STEP_TIMEOUT}s)..."
LAST_RESPONSE=""
MISSING_COUNT=0
DEBUG_LOG="$PWD/logs/complete_debug.log"
STEP_TIMEOUT_COUNT=0
LAST_TOOL=""  # Track last tool executed for context detection

_log_debug() {
    local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[$ts] $*" >> "$DEBUG_LOG"
}

_probe_parser_stage() {
    local stage
    stage=$(echo "$RESPONSE" | python3 parser.py --probe 2>/dev/null | jq -r '.stage // "None"' 2>/dev/null)
    echo "$stage"
}

# Determine context from last tool executed
_get_context() {
    case "$LAST_TOOL" in
        write_file) echo "compile" ;;
        javac) echo "run" ;;
        *) echo "create" ;;
    esac
}

while true; do
    PAYLOAD=$(jq -s --arg model "$MODEL" \
      '{model: $model, messages: .[0], tools: .[1], stream: false, temperature: 0, think: false}' \
      <(echo "$MESSAGES") <(echo "$TOOLS"))

    if ! RESPONSE=$(timeout "$STEP_TIMEOUT" curl -s "$OLLAMA_URL" -H "Content-Type: application/json" -d "$PAYLOAD"); then
        echo -e "\n=== Step timed out after ${STEP_TIMEOUT}s (curl). Terminating. ==="
        _log_debug "step_timeout after ${STEP_TIMEOUT}s"
        break
    fi
    LAST_RESPONSE="$RESPONSE"

    # Periodic re-probing every 3 steps to detect format shifts (log only, no config update)
    if [ "$STEP_COUNT" -gt 0 ] && [ $((STEP_COUNT % 3)) -eq 0 ]; then
        DETECTED_STAGE=$(_probe_parser_stage)
        CONFIGURED_STAGE=$(python3 -c "import json; print(json.load(open('.configs/${SANITIZED_MODEL}.config.json')).get('stage'))" 2>/dev/null || echo "None")
        if [ "$DETECTED_STAGE" != "None" ] && [ -n "$DETECTED_STAGE" ] && [ "$DETECTED_STAGE" != "$CONFIGURED_STAGE" ]; then
            _log_debug "format_shift old_stage=$CONFIGURED_STAGE new_stage=$DETECTED_STAGE"
        fi
    fi

    # Get context for Format C models (determines how to interpret markdown code blocks)
    CONTEXT=$(_get_context)

    TOOL_CALLS_ARRAY=$(
        case "$PARSER_FILE" in
            *.sh) RESULT=$(bash "$PARSER_FILE" <<< "$RESPONSE")
                  if [ "$(echo "$RESULT" | python3 -c "import sys,json; calls=json.load(sys.stdin); print(len(calls))" 2>/dev/null || echo 0)" -eq 0 ]; then
                      python3 parser.py --model "$(basename "$PARSER_FILE" .sh)" --fallback --context "$CONTEXT" <<< "$RESPONSE"
                  else
                      echo "$RESULT"
                  fi ;;
            *)    python3 parser.py --model "$(basename "$PARSER_FILE" .sh)" --fallback --context "$CONTEXT" <<< "$RESPONSE" ;;
        esac
    )
    NUM_CALLS=$(echo "$TOOL_CALLS_ARRAY" | jq 'length')
    _log_debug "step=$STEP_COUNT calls=$NUM_CALLS"

    if [ "${NUM_CALLS:-0}" -eq 0 ]; then
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
                    echo "$COMPILE_ERR" | sed 's/^/   | /'
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

        # Fallback: Save raw stream for user inspection
        RAW_STREAM_FILE="logs/raw_stream_${SANITIZED_MODEL}_step${STEP_COUNT}.log"
        echo "$RESPONSE" > "$RAW_STREAM_FILE"
        _log_debug "fallback_triggered step=$STEP_COUNT raw_file=$RAW_STREAM_FILE"

        echo "⚠️  PARSER FALLBACK: All stages failed to extract tool calls."
        echo "    Raw stream saved to: $RAW_STREAM_FILE"
        echo ""
        echo "=== RAW MODEL OUTPUT (first 2000 chars) ==="
        echo "$CONTENT_PREVIEW"
        echo "========================================"
        echo ""
        echo "⏭️  Skipping this turn..."

        TOOL_RESPONSE_MSG=$(python3 -c '
import sys, json
print(json.dumps({"role": "tool", "content": "Skipped: no tool calls detected."}))
')

        ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
        MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$ASSISTANT_MSG"))
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
    MISSING_COUNT=0

    ASSISTANT_MSG=$(echo "$RESPONSE" | jq '.message')
    MESSAGES=$(jq -s '.[0] + [.[1]]' <(echo "$MESSAGES") <(echo "$ASSISTANT_MSG"))

     COMBINED_OUTPUT=""

    for (( i=0; i<$NUM_CALLS; i++ )); do
        CALL=$(echo "$TOOL_CALLS_ARRAY" | jq ".[$i]")
        TOOL_NAME=$(echo "$CALL" | jq -r '.name')
        TOOL_ARGS=$(echo "$CALL" | jq '.arguments')

        _log_debug "exec step=$STEP_COUNT call=$i tool=$TOOL_NAME"
        echo "--> [ACTION DETECTED]: $TOOL_NAME"

        case "$TOOL_NAME" in
            "write_file")
                FILENAME=$(echo "$TOOL_ARGS" | jq -r '.filename // empty')
                CONTENT=$(echo "$TOOL_ARGS" | jq -r '.content // empty')

                if [ -z "$FILENAME" ] || [ "$FILENAME" = "null" ]; then
                    FILENAME="$EXPECTED_FILENAME"
                    echo "   [AUTO-FIX]: Filename was null/empty. Auto-injecting '$EXPECTED_FILENAME' from spec."
                fi

                # Enforce spec filename: if model wrote a .java file with wrong name, rename it
                if [[ "$FILENAME" == *.java && "$FILENAME" != "$EXPECTED_FILENAME" ]]; then
                    echo "   [AUTO-FIX]: Model wrote '$FILENAME' but spec requires '$EXPECTED_FILENAME'. Renaming."
                    # Fix class name inside content to match expected filename exactly
                    CLASS_FROM_FILE="${FILENAME%.java}"
                    CLASS_EXPECTED="${EXPECTED_FILENAME%.java}"
                    CONTENT=$(echo "$CONTENT" | sed "s/class ${CLASS_FROM_FILE}/class ${CLASS_EXPECTED}/g")
                    FILENAME="$EXPECTED_FILENAME"
                fi

                FORMATTED_CONTENT=$(python3 -c '
import sys, re

raw = sys.stdin.read()
decoded = raw

# Handle unicode escapes (e.g., \u0022 -> ")
decoded = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), decoded)

# Only strip trailing artifacts that contain quotes or backticks (parser junk)
# Do NOT strip bare closing braces - those are legitimate Java code
decoded = re.sub(r"\}\s*\"\s*\}\s*\}\s*`{3,}\s*$", "}", decoded, flags=re.DOTALL)
decoded = re.sub(r"\}\s*\"\s*\}\s*`{3,}\s*$", "}", decoded, flags=re.DOTALL)
decoded = re.sub(r"`{3,}\s*$", "", decoded, flags=re.DOTALL)

decoded = decoded.strip()

print(decoded)
' <<< "$CONTENT")

                echo "   [EXEC]: Writing file '$FILENAME'..."
                printf "%s\n" "$FORMATTED_CONTENT" > "$FILENAME"

                echo "   --- [FILE CONTENT PREVIEW] ---"
                echo "$FORMATTED_CONTENT" | sed 's/^/   | /'
                echo "   ------------------------------"

                OUT="File '$FILENAME' written successfully."
                ;;

            "javac")
                FILENAME=$(echo "$TOOL_ARGS" | jq -r '.filename // empty')
                if [ -z "$FILENAME" ] || [ "$FILENAME" = "null" ]; then
                    FILENAME="$EXPECTED_FILENAME"
                    echo "   [AUTO-FIX]: Filename was null/empty. Auto-injecting '$EXPECTED_FILENAME' from spec."
                fi

                # Enforce spec filename
                if [[ "$FILENAME" == *.java && "$FILENAME" != "$EXPECTED_FILENAME" ]]; then
                    echo "   [AUTO-FIX]: Model tried to compile '$FILENAME' but spec requires '$EXPECTED_FILENAME'."
                    FILENAME="$EXPECTED_FILENAME"
                fi

                echo "   [EXEC]: javac $FILENAME"
                if COMPILE_ERR=$(timeout "$STEP_TIMEOUT" javac "$FILENAME" 2>&1); then
                    OUT="Compilation successful. You can now execute the compiled class using 'java'."
                    echo "   [SUCCESS]: Compiled cleanly."
                else
                    OUT="Compilation failed with error:\n$COMPILE_ERR\nPlease fix the source code using 'write_file' and re-compile."
                    echo "   [ERROR]: Compilation failed."
                    echo "$COMPILE_ERR" | sed 's/^/   | /'
                fi
                ;;

            "java")
                CLASS_NAME=$(echo "$TOOL_ARGS" | jq -r '.class_name // empty')
                RAW_ARGS=$(echo "$TOOL_ARGS" | jq -r '.args // [] | join(" ")' 2>/dev/null || true)
                
                if [ -z "$CLASS_NAME" ] || [ "$CLASS_NAME" = "null" ]; then
                    CLASS_NAME="$CLASS_TOKEN"
                    echo "   [AUTO-FIX]: class_name was null/empty. Auto-injecting '$CLASS_TOKEN' from spec."
                fi

                # Enforce spec class name
                if [ "$CLASS_NAME" != "$CLASS_TOKEN" ]; then
                    echo "   [AUTO-FIX]: Model tried to run '$CLASS_NAME' but spec requires '$CLASS_TOKEN'."
                    CLASS_NAME="$CLASS_TOKEN"
                fi

                echo "   [EXEC]: java $CLASS_NAME $RAW_ARGS"
                RUN_OUT=$(timeout "$STEP_TIMEOUT" java $CLASS_NAME $RAW_ARGS 2>&1 || true)

                if echo "$RUN_OUT" | grep -q "ClassNotFoundException"; then
                    OUT="Program Execution Failed:\n$RUN_OUT\nHINT: Class '$CLASS_NAME.class' was not found. Ensure you call 'write_file' to save the Java source code and 'javac' to compile it before calling 'java'."
                else
                    OUT="Program Output:\n$RUN_OUT"
                fi
                echo "   [PROGRAM OUTPUT]: $RUN_OUT"
                ;;

            "search_okf")
                QUERY=$(echo "$TOOL_ARGS" | jq -r '.query // empty')
                echo "   [OKF SEARCH]: $QUERY"
                RESULT=""

                # Build regex matching any word in the query (split on spaces)
                WORDS_REGEX=$(echo "$QUERY" | tr ' ' '|' | sed 's/|/\\|/g')

                for dir in "knowledge/trusted_bundles" "knowledge/new_bundles"; do
                    if [ -d "$dir" ]; then
                        # Search for each word individually, return matching lines
                        FOUND=$(grep -r -i -E --include="*.md" "$WORDS_REGEX" "$dir/" 2>/dev/null | head -20 || true)
                        if [ -n "$FOUND" ]; then
                            RESULT="${RESULT}\n=== Results from ${dir} ===\n${FOUND}\n"
                        fi
                    fi
                done
                OUT="OKF Search Results for '${QUERY}':\n${RESULT:-No results found.}"
                ;;

            "create_skill")
                SKILL_NAME=$(echo "$TOOL_ARGS" | jq -r '.skill_name // empty')
                DESC=$(echo "$TOOL_ARGS" | jq -r '.description // empty')
                INPUT_EX=$(echo "$TOOL_ARGS" | jq -r '.example_input // "None provided"')
                OUTPUT_EX=$(echo "$TOOL_ARGS" | jq -r '.example_output // "None provided"')

                echo "   [CREATE SKILL]: $SKILL_NAME"
                mkdir -p knowledge/new_bundles/skills

                cat > "knowledge/new_bundles/skills/${SKILL_NAME}.md" << EOF
---
type: skill
name: ${SKILL_NAME}
status: new
description: ${DESC}
created_by: agent
created_at: $(date +%Y-%m-%d)
---

## Description
${DESC}

## Examples
- Input: ${INPUT_EX}
- Output: ${OUTPUT_EX}
EOF
                OUT="Skill '${SKILL_NAME}' created in knowledge/new_bundles/skills/ (ready for review)"
                ;;

            "promote_skill")
                SKILL_NAME=$(echo "$TOOL_ARGS" | jq -r '.skill_name // empty')
                echo "   [PROMOTE SKILL]: $SKILL_NAME"

                SRC="knowledge/new_bundles/skills/${SKILL_NAME}.md"
                DST="knowledge/trusted_bundles/skills/${SKILL_NAME}.md"

                if [ -f "$SRC" ]; then
                    mkdir -p knowledge/trusted_bundles/skills
                    mv "$SRC" "$DST"
                    sed -i 's/status: new/status: trusted/' "$DST"
                    OUT="Skill '${SKILL_NAME}' promoted to trusted_bundles/ ✓"
                elif [ -f "$DST" ]; then
                    OUT="Skill '${SKILL_NAME}' is already in trusted_bundles/"
                else
                    OUT="Skill '${SKILL_NAME}' not found in new_bundles/"
                fi
                ;;

            "view_concept")
                CONCEPT_ID=$(echo "$TOOL_ARGS" | jq -r '.concept_id // empty')
                echo "   [VIEW CONCEPT]: $CONCEPT_ID"
                OUT=""
                
                # Search trusted_bundles first, then new_bundles
                for dir in "knowledge/trusted_bundles/reference" "knowledge/new_bundles/reference"; do
                    FILE="$dir/${CONCEPT_ID}.md"
                    if [ -f "$FILE" ]; then
                        OUT=$(cat "$FILE")
                        break
                    fi
                done
                
                # Also check skills directory
                if [ -z "$OUT" ]; then
                    for dir in "knowledge/trusted_bundles/skills" "knowledge/new_bundles/skills"; do
                        FILE="$dir/${CONCEPT_ID}.md"
                        if [ -f "$FILE" ]; then
                            OUT=$(cat "$FILE")
                            break
                        fi
                    done
                fi
                
                OUT="${OUT:-Concept not found: $CONCEPT_ID}"
                ;;

            *)
                OUT="Unknown tool name: $TOOL_NAME"
                ;;
        esac

        # Track last tool for context detection
        LAST_TOOL="$TOOL_NAME"

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

# Capture model reasoning from last response
REASONING=$(echo "$LAST_RESPONSE" | jq -r '.message.content // ""' 2>/dev/null | head -c 500)
echo "$REASONING" > .last_reasoning.txt

echo "=========================================="
echo "    AUTOMATED HARNESS VALIDATION — $MODEL"
echo "=========================================="

HARNESS_EXIT=0

if [ -f "hashprime.java" ]; then
    echo "🔍 Found hashprime.java on disk. Starting automated test harness..."

    # Ensure tasks.json exists for regression tests
    if [ ! -f "tasks.json" ]; then
        if [ -f "sandbox/tasks.json" ]; then
            cp sandbox/tasks.json tasks.json
        elif [ -f "spec.yaml" ]; then
            python3 spec_parser.py spec.yaml 2>/dev/null || true
        fi
    fi

    if COMPILE_LOG=$(javac hashprime.java 2>&1); then
        echo "✅ [HARNESS]: Compilation succeeded."

        python3 << 'PYEOF' 2>&1 || HARNESS_EXIT=$?
import json, subprocess, sys
with open("tasks.json") as f:
    data = json.load(f)
tests = data.get("regression_tests", [])
if not tests:
    print("⚠️  No regression tests defined in tasks.json (regression_tests empty).")
    sys.exit(0)
passed = 0
failed = 0
for t in tests:
    inp = t["input"]
    expected = t["expected"]
    try:
        actual = subprocess.check_output(
            ["java", "hashprime", inp],
            stderr=subprocess.STDOUT,
            timeout=60
        ).decode().replace("\r", "").replace("\n", "").strip()
    except subprocess.TimeoutExpired:
        actual = "TIMEOUT"
    except subprocess.CalledProcessError as e:
        actual = f"EXIT_CODE_{e.returncode}"
    except Exception as e:
        actual = f"ERROR: {e}"
    if actual.lower() == expected.lower():
        print(f"✅ [TEST PASS]: N={inp} -> {actual}")
        passed += 1
    else:
        print(f"❌ [TEST FAIL]: N={inp} -> Expected: {expected} | Got: {actual}")
        failed += 1
print(f"  Harness: {passed} passed, {failed} failed")
sys.exit(1 if failed > 0 else 0)
PYEOF
    else
        echo "❌ [HARNESS]: Compilation failed."
        echo "$COMPILE_LOG" | sed 's/^/   | /'
        HARNESS_EXIT=1
    fi
else
    echo "❌ [HARNESS]: hashprime.java was not found on disk. Skipping validation."
    HARNESS_EXIT=1
fi

echo ""
    echo "    AUTOMATED HARNESS VERDICT — $MODEL $( [ $HARNESS_EXIT -eq 0 ] && echo 'PASS' || echo 'FAIL' )"
    echo "MODEL_RESULT: $( [ $HARNESS_EXIT -eq 0 ] && echo 'PASS' || echo 'FAIL' )"

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
