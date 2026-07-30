#!/usr/bin/env bash

set +H
set -e

MODEL="${1:-qwen2.5-coder:7b}"
MAX_TURNS="${2:-10}"
SANDBOX_DIR="sandbox"
SPEC_FILE="prompt.hashprime.info"
TASKS_FILE="tasks.json"
PROGRESS_FILE="progress.txt"
CHANGELOG_FILE="CHANGELOG.md"
INIT_FILE="init.sh"
GITIGNORE_FILE=".gitignore"
CONFIG_DIR=".configs"

SANITIZED_MODEL=$(echo "$MODEL" | sed 's/[/:]/_/g')
BRANCH_NAME="ralph_${SANITIZED_MODEL}"

echo "=========================================="
echo "Starting Ralph Loop for: $MODEL"
echo "Branch: $BRANCH_NAME"
echo "=========================================="

mkdir -p "$SANDBOX_DIR"

for f in complete.sh parser.py profile_model.sh progress_tracker.py spec_parser.py task_runner.py okf_generator.py skill_recorder.py; do
    if [ ! -L "$SANDBOX_DIR/$f" ] && [ ! -f "$SANDBOX_DIR/$f" ]; then
        ln -s "../$f" "$SANDBOX_DIR/$f"
    fi
done

if [ ! -L "$SANDBOX_DIR/prompts" ] && [ ! -d "$SANDBOX_DIR/prompts" ]; then
    ln -s "../prompts" "$SANDBOX_DIR/prompts"
fi

if [ ! -L "$SANDBOX_DIR/$CONFIG_DIR" ] && [ ! -d "$SANDBOX_DIR/$CONFIG_DIR" ]; then
    ln -s "../$CONFIG_DIR" "$SANDBOX_DIR/$CONFIG_DIR"
fi

cd "$SANDBOX_DIR"

if [ ! -d ".git" ]; then
    echo "Initializing sandbox git repository..."
    git init -q
    git config user.name "Ralph Agent"
    git config user.email "ralph@agent.local"
    CUR_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
    if [ "$CUR_BRANCH" != "main" ]; then
        git branch -m "$CUR_BRANCH" main 2>/dev/null || true
    fi

    cp "../$SPEC_FILE" "$SPEC_FILE"
    cp "../spec.yaml" "spec.yaml"

    cat > "$GITIGNORE_FILE" << 'GITEOF'
*.tmp
logs/
*.log
GITEOF

    cat > "$INIT_FILE" << 'INITEOF'
#!/usr/bin/env bash
JAVAC_CMD="javac hashprime.java"
RUN_CMD="java hashprime <N>"
EXPECTED_EMPTY="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
EXPECTED_11="563d8e0603dcc07d784135d99fd81ff6bf98495e898ec1f52e2e7605320cf6dc"
EXPECTED_1000="55542ac8f84d3c795ac05ea7dc3e382353c4bdd519d97e178d3f17a7f97fb25f"
EXPECTED_1M="4883963dd4510a29d6df2ffe4dd11e4e1a910e815c7810b200c77b3357f22a28"
INITEOF
    chmod +x "$INIT_FILE"

    echo "Generating tasks.json from spec.yaml..."
    python3 ../spec_parser.py "spec.yaml"

    echo "Generating OKF knowledge bundle..."
    python3 ../okf_generator.py .

    cat > "$CHANGELOG_FILE" << 'CHANGEOF'
# Changelog

## Initial

- Sandbox initialized with dynamically generated tasks.
CHANGEOF

    echo "# Progress Log" > "$PROGRESS_FILE"
    echo "" >> "$PROGRESS_FILE"

    git add -A
    git commit -m "ralph: initialize sandbox" -q
    echo "Sandbox initialized on branch 'main'."
fi

source "$INIT_FILE" 2>/dev/null || true

PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.sh"
if [ ! -f "$PARSER_FILE" ]; then
    echo "Model parser config not found. Running profile_model.sh..."
    ../profile_model.sh "$MODEL"
fi

if git rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
    git checkout "$BRANCH_NAME"
    echo "Resumed existing branch: $BRANCH_NAME"
else
    git checkout -b "$BRANCH_NAME" main
    echo "Created new branch: $BRANCH_NAME (from main)"
fi

generate_task_prompt() {
    local task_id="$1" task_desc="$2" verify_cmd="$3" expected_out="$4" passing_tasks="$5" regression_inputs="$6" filename="$7" skill_ctx="$8" failure_ctx="$9"
    local tmpl="prompts/task_context.txt"

    local header
    header=$(TASK_ID="$task_id" TASK_DESC="$task_desc" \
             PASSING_TASKS="$passing_tasks" VERIFY_CMD="$verify_cmd" \
             EXPECTED_OUT="$expected_out" REGRESSION_INPUTS="$regression_inputs" \
             FILENAME="$filename" TMPL_FILE="$tmpl" \
             python3 << 'PYEOF'
import os, sys
with open(os.environ['TMPL_FILE']) as f:
    t = f.read()
t = t.replace('{{TASK_ID}}', os.environ['TASK_ID'])
t = t.replace('{{TASK_DESC}}', os.environ['TASK_DESC'])
t = t.replace('{{PASSING_TASKS}}', os.environ['PASSING_TASKS'])
t = t.replace('{{VERIFY_CMD}}', os.environ['VERIFY_CMD'])
exp = os.environ.get('EXPECTED_OUT', '')
if exp:
    t = t.replace('{{EXPECTED_OUTPUT_BLOCK}}', 'Expected output:\n  ' + exp)
else:
    t = t.replace('{{EXPECTED_OUTPUT_BLOCK}}\n', '')
ri = os.environ.get('REGRESSION_INPUTS', '')
if ri:
    items = [f'  - N={x}' for x in ri.split(', ')]
    t = t.replace('{{REGRESSION_INPUTS}}', '\n'.join(items))
else:
    t = t.replace('{{REGRESSION_INPUTS}}\n', '')
fn = os.environ.get('FILENAME', '')
if fn:
    t = t.replace('{{FILENAME}}', fn)
else:
    t = t.replace('{{FILENAME}}\n', '')
sys.stdout.write(t)
PYEOF
)

    local real_spec
    real_spec=$(cat "../$SPEC_FILE" 2>/dev/null || cat "$SPEC_FILE" 2>/dev/null || echo "Spec file not found.")

    local skill_block=""
    if [ -n "$skill_ctx" ] || [ -n "$failure_ctx" ]; then
        skill_block="=== KNOWN KNOWLEDGE ===
${skill_ctx}
${failure_ctx}
"
    fi

    {
        echo "$header"
        echo ""
        if [ -n "$skill_block" ]; then
            echo "$skill_block"
            echo ""
        fi
        echo "--- ORIGINAL SPECIFICATION FOLLOWS ---"
        echo "$real_spec"
    } > "$SPEC_FILE"
}

TURN=1

while [ $TURN -le $MAX_TURNS ]; do
    TURN_START=$(date +%s)
    TS_HUMAN=$(date +"%Y-%m-%d %H:%M:%S")
    echo ""
    echo "--------------------------------------------------"
    echo "Turn $TURN of $MAX_TURNS (branch: $BRANCH_NAME) @ $TS_HUMAN"
    echo "--------------------------------------------------"

    if python3 -c "import task_runner; exit(0) if task_runner.check_all_completed() else exit(1)" 2>/dev/null; then
        echo ""
        echo "  --- All expected tasks completed successfully ---"
        echo "  RALPH will exit early as all tasks are done."
        echo "=========================================="
        echo "RALPH loop finished successfully — all tasks complete."
        echo "=========================================="
        git checkout main 2>/dev/null || true
        exit 0
    fi

    REMAINING=$(jq '[.tasks[] | select(.status == "failing")] | length' "$TASKS_FILE")
    if [ "$REMAINING" -eq 0 ]; then
        echo ""
        echo "  --- Regression check: re-verifying all passing tasks ---"
        REGRESSIONS=0
        while IFS= read -r task; do
            tid=$(echo "$task" | jq -r '.id')
            vcmd=$(echo "$task" | jq -r '.verification_command // ""')
            eout=$(echo "$task" | jq -r '.expected_output // ""')
            if [ -n "$vcmd" ] && [ -n "$eout" ]; then
                actual=$(eval "$vcmd" | tr -d '\r\n')
                if case "$actual" in *"$eout"*) true;; *) false;; esac; then
                    echo "    $tid - OK"
                else
                    echo "    $tid - FAIL (regression)"
                    jq "(.tasks[] | select(.id == \"$tid\")).status = \"failing\"" "$TASKS_FILE" > "$TASKS_FILE.tmp" && mv "$TASKS_FILE.tmp" "$TASKS_FILE"
                    REGRESSIONS=$((REGRESSIONS + 1))
                fi
            elif [ -n "$vcmd" ] && [ -z "$eout" ]; then
                if eval "$vcmd" 2>/dev/null; then
                    echo "    $tid - OK"
                else
                    echo "    $tid - FAIL (regression)"
                    jq "(.tasks[] | select(.id == \"$tid\")).status = \"failing\"" "$TASKS_FILE" > "$TASKS_FILE.tmp" && mv "$TASKS_FILE.tmp" "$TASKS_FILE"
                    REGRESSIONS=$((REGRESSIONS + 1))
                fi
            else
                echo "    $tid - OK (no verification)"
            fi
        done < <(jq -c '.tasks[] | select(.status == "passing")' "$TASKS_FILE")

        REMAINING=$(jq '[.tasks[] | select(.status == "failing")] | length' "$TASKS_FILE")
        if [ "$REMAINING" -gt 0 ]; then
            echo "  $REGRESSIONS regression(s) detected. Continuing loop..."
            echo ""
        else
            echo "  All passing tasks still pass."
            echo "=========================================="
            echo "All tasks passing! Ralph loop finished successfully."
            echo "=========================================="
            git checkout main 2>/dev/null || true
            exit 0
        fi
    fi

    NEXT_TASK=$(jq -r '[.tasks[] | select(.status == "failing")] | sort_by(.priority) | .[0]' "$TASKS_FILE")
    TASK_ID=$(echo "$NEXT_TASK" | jq -r '.id')
    TASK_DESC=$(echo "$NEXT_TASK" | jq -r '.description')
    VERIFY_CMD=$(echo "$NEXT_TASK" | jq -r '.verification_command // ""')
    EXPECTED_OUT=$(echo "$NEXT_TASK" | jq -r '.expected_output // ""')

    PASSING_TASKS=$(jq -r '[.tasks[] | select(.status == "passing") | .id] | join(", ")' "$TASKS_FILE")
    [ -z "$PASSING_TASKS" ] && PASSING_TASKS="(none)"

    REGRESSION_INPUTS=$(python3 -c "
import json
with open('$TASKS_FILE') as f:
    data = json.load(f)
rt = data.get('regression_tests', [])
print(', '.join(t['input'] for t in rt))
" 2>/dev/null || echo "")

    PROJECT_FILE=$(jq -r '.filename // "hashprime.java"' "$TASKS_FILE" 2>/dev/null || echo "hashprime.java")

    # Search for relevant skills and failure modes
    SKILL_CONTEXT=$(python3 ../skill_recorder.py search --tags "parser" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    skills = [s['title'] for s in data[:3]]
    if skills:
        print('Known skills: ' + ', '.join(skills))
except:
    pass
" 2>/dev/null || echo "")

    FAILURE_CONTEXT=$(python3 ../skill_recorder.py search --type "Failure Mode" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    modes = [s['title'] for s in data[:3]]
    if modes:
        print('Known failure modes: ' + ', '.join(modes))
except:
    pass
" 2>/dev/null || echo "")

    echo "Task: $TASK_ID"
    echo "  $TASK_DESC"

    {
        echo "## Turn $TURN ($TS_HUMAN)"
        echo "Model: $MODEL"
        echo "Branch: $BRANCH_NAME"
        echo "Task: $TASK_ID - $TASK_DESC"
        echo "Passing: $PASSING_TASKS"
    } >> "$PROGRESS_FILE"

    generate_task_prompt "$TASK_ID" "$TASK_DESC" "$VERIFY_CMD" "$EXPECTED_OUT" "$PASSING_TASKS" "$REGRESSION_INPUTS" "$PROJECT_FILE" "$SKILL_CONTEXT" "$FAILURE_CONTEXT"

    echo ""
    echo "--- Starting fresh worker session (up to 10 tool steps per session) ---"
    echo "  Spawning: ../complete.sh $MODEL"

    set +eo pipefail
    ../complete.sh "$MODEL"
    RUN_EXIT=$?
    set -e

    echo "Exit Status: $RUN_EXIT" >> "$PROGRESS_FILE"

    # Capture model reasoning before task_runner (which may git reset --hard)
    RALPH_REASONING=""
    if [ -f ".last_reasoning.txt" ]; then
        RALPH_REASONING=$(head -c 500 < .last_reasoning.txt || true)
        rm -f .last_reasoning.txt
    fi
    export RALPH_REASONING

    echo "$NEXT_TASK" | python3 ../task_runner.py verify "$TURN" "$TS_HUMAN" "$BRANCH_NAME"
    PASS_RESULT=$?

    TURN_END=$(date +%s)
    TURN_DURATION=$((TURN_END - TURN_START))
    if [ "$PASS_RESULT" -eq 0 ]; then
        echo "  Turn $TURN duration: ${TURN_DURATION}s | Result: PASS | Task: $TASK_ID"
    else
        echo "  Turn $TURN duration: ${TURN_DURATION}s | Result: FAIL (rolled back) | Task: $TASK_ID"
    fi

    TURN=$((TURN + 1))
done

echo ""
echo "=========================================="
echo "Reached MAX_TURNS ($MAX_TURNS) without completing all tasks."
echo "Unfinished tasks remain on branch $BRANCH_NAME."
echo "=========================================="

git checkout main 2>/dev/null || true
