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

# ---------------------------------------------------------------------------
# Phase 0: Sandbox directory setup
# ---------------------------------------------------------------------------

mkdir -p "$SANDBOX_DIR"

for f in complete.sh parser.py profile_model.sh; do
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

# ---------------------------------------------------------------------------
# Phase 0.5: Model profiling
# ---------------------------------------------------------------------------
PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.sh"
if [ ! -f "$PARSER_FILE" ]; then
    echo "Model parser config not found. Running profile_model.sh..."
    ../profile_model.sh "$MODEL"
fi

# ---------------------------------------------------------------------------
# Phase 1: Git + task ledger initialization (one-time)
# ---------------------------------------------------------------------------
if [ ! -d ".git" ]; then
    echo "Initializing sandbox git repository..."
    git init -q
    git config user.name "Ralph Agent"
    git config user.email "ralph@agent.local"
    CUR_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
    if [ "$CUR_BRANCH" != "main" ]; then
        git branch -m "$CUR_BRANCH" main 2>/dev/null || true
    fi

    # Copy the spec into the sandbox (not symlinked — we modify it per-turn)
    cp "../$SPEC_FILE" "$SPEC_FILE"

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

    # ------------------------------------------------------------------
    # Generate tasks.json by parsing the spec
    # ------------------------------------------------------------------
    echo "Generating tasks.json from $SPEC_FILE..."
    python3 << 'PYEOF' || { echo "FAILED to generate tasks.json"; exit 1; }
import sys, json, re

spec_file = "prompt.hashprime.info"
with open(spec_file) as f:
    spec = f.read()

tasks = []

# ------ 1. Error handling / help text task ------
has_help = re.search(r'(?i)Usage\s*:', spec)
has_error_handling = re.search(r'(?i)no argument|invalid|error.*handling|help message', spec)
if has_help or has_error_handling:
    # Extract the usage line if present
    help_text = "Usage: java hashprime <N>"
    for line in spec.split('\n'):
        if 'Usage:' in line:
            candidate = line.strip().strip('`').strip()
            if candidate:
                help_text = candidate
            break
    tasks.append({
        "id": "input_validation",
        "description": "Handle no argument or invalid integer — print help message to stdout and exit 0",
        "status": "failing",
        "priority": 1,
        "verification_command": "java hashprime 2>&1",
        "expected_output": "Usage:"
    })

# ------ 2. Parse the validation table ------
EMPTY_HASH = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
seen_hashes = set()
priority = 2

table_pattern = re.compile(r'\|\s*`\s*(-?\d+)\s*`\s*\|\s*`\s*([a-f0-9]+)\s*`\s*\|')
for match in table_pattern.finditer(spec):
    n_str, h = match.groups()
    # Deduplicate by hash (multiple N map to same hash)
    if h in seen_hashes:
        continue
    seen_hashes.add(h)

    # Single task for all empty-stream cases (N < 2)
    if h == EMPTY_HASH:
        tid = "empty_stream"
        desc = f"N<2 (negative, 0, 1) produces empty-stream hash {EMPTY_HASH[:16]}..."
        vcmd = "java hashprime -5 2>&1"
        eout = EMPTY_HASH
    else:
        tid = f"n_{n_str}"
        desc = f"N={n_str} produces {h[:16]}..."
        vcmd = f"java hashprime {n_str} 2>&1"
        eout = h

    tasks.append({
        "id": tid,
        "description": desc,
        "status": "failing",
        "priority": priority,
        "verification_command": vcmd,
        "expected_output": eout
    })
    priority += 1

# ------ 3. Memory / performance constraint ------
if re.search(r'(?i)(?:100[,_]?000[,_]?000|1\s*0{8}|performance|constraint|512m)', spec):
    tasks.append({
        "id": "memory_efficient",
        "description": "Handle N=100M within -Xmx512m: incremental MessageDigest, BitSet sieve, no string concatenation",
        "status": "failing",
        "priority": 99,
        "verification_command": "java -Xmx512m hashprime 100000000 2>&1 >/dev/null",
        "expected_output": ""
    })

with open("tasks.json", "w") as f:
    json.dump({"tasks": tasks}, f, indent=2)

print(f"Generated {len(tasks)} tasks from spec.")
PYEOF

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

# ---------------------------------------------------------------------------
# Phase 2: Switch to model branch
# ---------------------------------------------------------------------------

source "$INIT_FILE" 2>/dev/null || true

if git rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
    git checkout "$BRANCH_NAME"
    echo "Resumed existing branch: $BRANCH_NAME"
else
    git checkout -b "$BRANCH_NAME" main
    echo "Created new branch: $BRANCH_NAME (from main)"
fi

# ---------------------------------------------------------------------------
# Helper: generate task-focused prompt for the LLM
# ---------------------------------------------------------------------------
generate_task_prompt() {
    local task_id="$1" task_desc="$2" verify_cmd="$3" expected_out="$4" passing_tasks="$5"
    local tmpl="prompts/task_context.txt"

    # Substitute template placeholders safely via python3
    local header
    header=$(TASK_ID="$task_id" TASK_DESC="$task_desc" \
             PASSING_TASKS="$passing_tasks" VERIFY_CMD="$verify_cmd" \
             EXPECTED_OUT="$expected_out" TMPL_FILE="$tmpl" \
             python3 << 'PYEOF'
import os
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
sys.stdout.write(t)
PYEOF
)

    local real_spec
    real_spec=$(cat "../$SPEC_FILE" 2>/dev/null || cat "$SPEC_FILE" 2>/dev/null || echo "Spec file not found.")

    {
        echo "$header"
        echo ""
        echo "--- ORIGINAL SPECIFICATION FOLLOWS ---"
        echo "$real_spec"
    } > "$SPEC_FILE"
}

# ---------------------------------------------------------------------------
# Phase 3: Iterative worker loop
# ---------------------------------------------------------------------------
TURN=1

while [ $TURN -le $MAX_TURNS ]; do
    echo ""
    echo "--------------------------------------------------"
    echo "Turn $TURN of $MAX_TURNS (branch: $BRANCH_NAME)"
    echo "--------------------------------------------------"

    REMAINING=$(jq '[.tasks[] | select(.status == "failing")] | length' "$TASKS_FILE")
    if [ "$REMAINING" -eq 0 ]; then
        echo "=========================================="
        echo "All tasks passing! Ralph loop finished successfully."
        echo "=========================================="
        git checkout main 2>/dev/null || true
        exit 0
    fi

    NEXT_TASK=$(jq -r '[.tasks[] | select(.status == "failing")] | sort_by(.priority) | .[0]' "$TASKS_FILE")
    TASK_ID=$(echo "$NEXT_TASK" | jq -r '.id')
    TASK_DESC=$(echo "$NEXT_TASK" | jq -r '.description')
    VERIFY_CMD=$(echo "$NEXT_TASK" | jq -r '.verification_command // ""')
    EXPECTED_OUT=$(echo "$NEXT_TASK" | jq -r '.expected_output // ""')

    PASSING_TASKS=$(jq -r '[.tasks[] | select(.status == "passing") | .id] | join(", ")' "$TASKS_FILE")
    [ -z "$PASSING_TASKS" ] && PASSING_TASKS="(none)"

    echo "Task: $TASK_ID"
    echo "  $TASK_DESC"

    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    {
        echo "## Turn $TURN ($TIMESTAMP)"
        echo "Model: $MODEL"
        echo "Branch: $BRANCH_NAME"
        echo "Task: $TASK_ID - $TASK_DESC"
        echo "Passing: $PASSING_TASKS"
    } >> "$PROGRESS_FILE"

    # ---------------------------------------------------------------
    # Inject task context into the prompt for the LLM
    # ---------------------------------------------------------------
    generate_task_prompt "$TASK_ID" "$TASK_DESC" "$VERIFY_CMD" "$EXPECTED_OUT" "$PASSING_TASKS"

    echo ""
    echo "Invoking complete.sh with task-focused prompt..."

    set +eo pipefail
    ../complete.sh "$MODEL"
    RUN_EXIT=$?
    set -e

    echo "Exit Status: $RUN_EXIT" >> "$PROGRESS_FILE"

    # -----------------------------------------------------------------------
    # Verify: compile + run verification_command
    # -----------------------------------------------------------------------
    PASS=false
    if [ -f "hashprime.java" ]; then
        echo "  Compiling hashprime.java..."
        if javac hashprime.java 2>/dev/null; then
            echo "  Compilation OK."
            if [ -n "$VERIFY_CMD" ] && [ -n "$EXPECTED_OUT" ]; then
                ACTUAL_OUT=$(eval "$VERIFY_CMD" | tr -d '\r\n')
                if [ "$ACTUAL_OUT" = "$EXPECTED_OUT" ]; then
                    PASS=true
                    echo "  Verification: PASS ($TASK_ID)"
                else
                    echo "  Verification: FAIL ($TASK_ID)"
                    echo "  Expected: $EXPECTED_OUT"
                    echo "  Got:      $ACTUAL_OUT"
                fi
            elif [ -n "$VERIFY_CMD" ] && [ -z "$EXPECTED_OUT" ]; then
                if eval "$VERIFY_CMD" 2>/dev/null; then
                    PASS=true
                    echo "  Verification: PASS ($TASK_ID — run only)"
                else
                    echo "  Verification: FAIL ($TASK_ID — run failed)"
                fi
            else
                PASS=true
                echo "  Verification: PASS ($TASK_ID — existence only)"
            fi
        else
            echo "  Compilation FAILED after complete.sh run"
        fi
    else
        echo "  hashprime.java not found on disk"
    fi

    # -----------------------------------------------------------------------
    # Commit or rollback
    # -----------------------------------------------------------------------
    if [ "$PASS" = true ]; then
        echo "  -> Task $TASK_ID PASSED"

        jq "(.tasks[] | select(.id == \"$TASK_ID\")).status = \"passing\"" "$TASKS_FILE" > "$TASKS_FILE.tmp" && mv "$TASKS_FILE.tmp" "$TASKS_FILE"

        {
            echo ""
            echo "## Turn $TURN ($TIMESTAMP)"
            echo "- **$TASK_ID**: passed"
        } >> "$CHANGELOG_FILE"

        echo "Result: PASS" >> "$PROGRESS_FILE"

        git add -A
        if ! git diff --staged --quiet; then
            git commit -m "ralph: turn $TURN - $TASK_ID passing" -q
            echo "  Committed to $BRANCH_NAME"
        else
            echo "  Nothing new to commit."
        fi
    else
        echo "  -> Task $TASK_ID FAILED — rolling back"
        echo "Result: FAIL (rolled back)" >> "$PROGRESS_FILE"
        git reset --hard HEAD
        echo "  Rolled back to last good commit on $BRANCH_NAME"
    fi

    TURN=$((TURN + 1))
done

echo ""
echo "=========================================="
echo "Reached MAX_TURNS ($MAX_TURNS) without completing all tasks."
echo "Unfinished tasks remain on branch $BRANCH_NAME."
echo "=========================================="

git checkout main 2>/dev/null || true
