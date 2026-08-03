#!/usr/bin/env python3
"""
OKF Skill Recorder

Records, searches, and manages skills in the OKF knowledge bundle.
Skills are fine-grained, per-technique concepts that the agent learns
over time and can reference in future situations.

Usage:
    python3 skill_recorder.py record <category> <id> <title> <tags> [body]
    python3 skill_recorder.py search [--tags tag1,tag2] [--type TYPE]
    python3 skill_recorder.py list
    python3 skill_recorder.py seed
    python3 skill_recorder.py ingest <corpus_name> <corpus_dir>

Categories: skills, failure-modes, model-profiles, strategies, reference
"""

import json
import os
import re
import sys
import yaml
from datetime import datetime, timezone
from pathlib import Path


KNOWLEDGE_DIR = os.path.join(os.environ.get("SANDBOX_DIR", "sandbox"), "knowledge")

CATEGORIES = {
    "skills": {"type": "Skill", "description": "Learned techniques and patterns"},
    "failure-modes": {"type": "Failure Mode", "description": "Known failure patterns and fixes"},
    "model-profiles": {"type": "Model Profile", "description": "Per-model characteristics"},
    "strategies": {"type": "Strategy", "description": "High-level approaches"},
    "reference": {"type": "Reference", "description": "External knowledge base content (how do I...)"},
}

INDEX_FILE = "index.json"
INDEX_MD = "index.md"


def _category_dir(category):
    return os.path.join(KNOWLEDGE_DIR, category)


def _index_path(category):
    return os.path.join(_category_dir(category), INDEX_FILE)


def _concept_path(category, skill_id):
    return os.path.join(_category_dir(category), f"{skill_id}.md")


def _load_index(category):
    path = _index_path(category)
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {
        "okf_version": "0.2",
        "generated_by": "skill_recorder/0.1",
        "generated_at": "",
        "skills": [],
    }


def _save_index(category, index_data):
    index_data["generated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    path = _index_path(category)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(index_data, f, indent=2)


def _generate_index_md(category, entries):
    meta = CATEGORIES.get(category, {})
    lines = [f"# {meta.get('description', category)}\n"]
    for entry in entries:
        eid = entry["id"]
        title = entry.get("title", eid)
        tags = ", ".join(entry.get("tags", []))
        link = f"{eid}.md"
        lines.append(f"- [{title}]({link}) — tags: {tags}")
    lines.append("")
    return "\n".join(lines)


def record_skill(category, skill_id, title, tags, body, sources=None, status="stable"):
    """Record a new skill concept to the OKF bundle."""
    if category not in CATEGORIES:
        print(f"Error: unknown category '{category}'. Use: {', '.join(CATEGORIES.keys())}")
        sys.exit(1)

    concept_type = CATEGORIES[category]["type"]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    tags_str = ", ".join(tags) if tags else ""

    sources_block = ""
    if sources:
        sources_lines = []
        for s in sources:
            sid = s.get("id", "unknown")
            sresource = s.get("resource", "")
            stitle = s.get("title", "")
            sources_lines.append(f"  - id: {sid}")
            if sresource:
                sources_lines.append(f"    resource: {sresource}")
            if stitle:
                sources_lines.append(f'    title: "{stitle}"')
        sources_block = "sources:\n" + "\n".join(sources_lines) + "\n"

    concept = f"""---
type: {concept_type}
title: "{title}"
description: "{body[:80].replace(chr(10), ' ').replace('"', '\\"')}..."
status: {status}
tags: [{tags_str}]
generated:
  by: skill_recorder/0.1
  at: {now}
{sources_block}---

{body}
"""

    path = _concept_path(category, skill_id)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(concept)

    _update_index(category, skill_id, title, tags, concept_type, status)
    print(f"Recorded: {category}/{skill_id}.md")
    return path


def record_model_profile_update(model_name, parser_stage, model_id):
    """Update a model profile in the OKF bundle when re-profiling."""
    safe_name = model_name.replace("/", "_").replace(":", "_")
    tags = ["model", "llm", "ollama", f"parser-stage-{parser_stage}"]

    body = f"""## Model: {model_name}

### Parser Profile
- Detected stage: {parser_stage}
- Model ID: `{model_id}`
- Re-profiled at: {datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}

### Characteristics
- Auto-detected by profile_model.sh
- Check parser.py stage documentation for details

### Recommended Skills
- Review parser stages for matching techniques
"""

    return record_skill(
        "model-profiles",
        safe_name,
        f"{model_name} Profile",
        tags,
        body,
        sources=[{"id": "profile-model-sh", "resource": "profile_model.sh", "title": "Model profiler"}],
    )


def _update_index(category, skill_id, title, tags, concept_type, status):
    """Add or update a skill entry in the index."""
    index_data = _load_index(category)
    existing = [s for s in index_data["skills"] if s["id"] == skill_id]
    entry = {
        "id": skill_id,
        "type": concept_type,
        "title": title,
        "tags": tags,
        "status": status,
        "path": f"{category}/{skill_id}.md",
    }
    if existing:
        existing[0].update(entry)
    else:
        index_data["skills"].append(entry)

    _save_index(category, index_data)

    index_md_path = os.path.join(_category_dir(category), INDEX_MD)
    with open(index_md_path, "w") as f:
        f.write(_generate_index_md(category, index_data["skills"]))


def search_skills(query_tags=None, query_type=None):
    """Search all categories by tags or type. Returns matching skill paths."""
    results = []
    for category in CATEGORIES:
        index_data = _load_index(category)
        for skill in index_data.get("skills", []):
            if query_type and skill.get("type", "") != query_type:
                continue
            if query_tags:
                skill_tags = set(skill.get("tags", []))
                if not set(query_tags).intersection(skill_tags):
                    continue
            results.append(skill)
    return results


def list_all():
    """List all recorded skills across all categories."""
    for category in CATEGORIES:
        index_data = _load_index(category)
        skills = index_data.get("skills", [])
        if skills:
            print(f"\n{category}/ ({len(skills)} entries)")
            for s in skills:
                tags = ", ".join(s.get("tags", []))
                print(f"  {s['id']} — {s.get('title', '')} [{tags}]")


def seed_from_codebase():
    """Seed the OKF bundle with existing knowledge from the codebase."""
    print("Seeding skills from existing codebase...")

    # Parser skills
    parser_skills = [
        ("native-tool-call-extraction", "Native Tool Call Extraction",
         ["parser", "stage-1", "gemma4", "qwen3.5"],
         "## Stage 1\n\nReads Ollama's `message.tool_calls[]` array directly.\nUsed by models with native function calling: gemma4, qwen3.5 family.\n\n```python\nif 'tool_calls' in message and message['tool_calls']:\n    for tc in message['tool_calls']:\n        name = tc.get('function', {}).get('name', '')\n        args = tc.get('function', {}).get('arguments', {})\n```"),
        ("think-tag-stripping", "Think-tag Stripping",
         ["parser", "preprocessing", "qwen", "chain-of-thought"],
         "## Preprocessor\n\nStrips `<think>...</think>` reasoning blocks before content parsing.\nPrevents false positives in later stages (thinking blocks contain JSON-like structures).\nAlways runs as Stage 2, regardless of model.\n\n```python\nimport re\ncontent = re.sub(r'<think>.*?</think>', '', content, flags=re.DOTALL)\n```"),
        ("markdown-json-extraction", "Markdown JSON Extraction",
         ["parser", "stage-3", "json", "code-blocks"],
         "## Stage 3\n\nExtracts JSON from `json` fenced code blocks.\nCommon format for models that wrap tool calls in markdown.\n\n````markdown\n```json\n{\"name\": \"write_file\", \"arguments\": {...}}\n```\n````"),
        ("raw-json-stream-parsing", "Raw JSON Stream Parsing",
         ["parser", "stage-4", "json", "stream"],
         "## Stage 4\n\nFinds any `{...}` in content that decodes with a `name` field.\nHandles models that emit JSON without code fences.\n\n```python\nimport re, json\nfor match in re.finditer(r'\\{[^{}]*\"name\"[^{}]*\\}', content):\n    try:\n        obj = json.loads(match.group())\n        if 'name' in obj:\n            yield obj\n    except json.JSONDecodeError:\n        pass\n```"),
        ("xml-tag-extraction", "XML Tag Extraction",
         ["parser", "stage-5", "xml", "tags"],
         "## Stage 5\n\nParses XML-style tool call tags: `<write_file filename=\"...\" content=\"...\"/>`\nUsed by some models that output XML instead of JSON.\n\n```python\nimport re\npattern = r'<(\\w+)\\s+([^/]+)/>'\nfor match in re.finditer(pattern, content):\n    tag_name, attrs = match.groups()\n    # Parse attributes...\n```"),
        ("markdown-java-extraction", "Markdown Java Extraction",
         ["parser", "stage-6", "java", "code-blocks"],
         "## Stage 6\n\nExtracts Java code from `java` fenced code blocks.\nLast match wins (models often emit explanation + code).\n\n````markdown\n```java\npublic class HashPrime { ... }\n```\n````"),
        ("unfenced-java-detection", "Unfenced Java Detection",
         ["parser", "stage-7", "java", "bare-code"],
         "## Stage 7\n\nDetects bare `public class ...` with no backticks.\nFallback for models that emit raw code without markdown formatting.\n\n```python\nif re.search(r'public\\s+class\\s+\\w+', content):\n    # Extract the Java code\n```"),
        ("shell-command-extraction", "Shell Command Extraction",
         ["parser", "stage-8", "shell", "commands"],
         "## Stage 8\n\nExtracts `javac` and `java` lines from `sh`/`bash` blocks.\nUsed when models emit shell commands instead of tool calls.\n\n````markdown\n```sh\njavac HashPrime.java\njava HashPrime 11\n```\n````"),
    ]

    for skill_id, title, tags, body in parser_skills:
        record_skill("skills", skill_id, title, tags, body,
                     sources=[{"id": "parser-py", "resource": "parser.py", "title": "Cascading parser"}])

    # Verification skills
    record_skill("skills", "regression-gate", "Regression Gate Testing",
                 ["verification", "regression", "testing"],
                 "## Regression Gate\n\nBefore verifying a new task, re-run all tests for previously-passing tasks.\nPrevents regressions from being committed.\n\n### Flow\n1. Read `regression_tests` from `tasks.json`\n2. For each test tagged to a passing task, run it\n3. If any regression fails → entire verification fails\n4. Code is never committed with a regression\n\n### Implementation\n```python\ndef _run_regression_tests():\n    passing_tasks = {t['id'] for t in data['tasks'] if t['status'] == 'passing'}\n    for test in tests:\n        if test['tag'] not in passing_tasks:\n            continue\n        actual = subprocess.check_output(['java', 'hashprime', test['input']])\n        if actual.strip() != test['expected']:\n            return False\n    return True\n```",
                 sources=[{"id": "task-runner", "resource": "task_runner.py", "title": "Task verification engine"}])

    record_skill("skills", "auto-inject-params", "Auto-inject Missing Parameters",
                 ["agent", "parameters", "workaround"],
                 "## Auto-inject\n\nWhen a model omits required tool parameters, silently fill them from spec\nrather than wasting a step on rejection.\n\n### Logic\n```bash\nif [ -z \"$FILENAME\" ] || [ \"$FILENAME\" = \"null\" ]; then\n    FILENAME=\"$PROJECT_FILE\"\n    echo \"[AUTO-FIX] Injected filename: $FILENAME\"\nfi\n```\n\n### When to use\n- Model outputs `write_file` with null/empty filename\n- Model outputs `javac` with null/empty filename\n- Model outputs `java` with null class_name\n\n### Benefit\nPreserves step count while preventing wasted turns on parameter errors.",
                 sources=[{"id": "complete-sh", "resource": "complete.sh", "title": "Worker agent loop"}])

    # Failure modes
    failure_modes = [
        ("compile-before-write", "Compile-before-write Loop",
         ["failure", "java", "sequence", "common"],
         "## Symptom\n\nModel runs `javac` before `write_file`, causing compilation failure.\nRepeats the same error pattern across multiple steps.\n\n## Root Cause\n\nModel skips the `write_file` step in the action sequence.\nOften seen with models that haven't learned the tool-use pattern.\n\n## Fix\n\n1. Auto-inject: if javac fails, check if file exists\n2. If not, suggest model run `write_file` first\n3. In extreme cases, terminate evaluation early\n\n## Detection\n\n```bash\nif ! javac HashPrime.java 2>/dev/null; then\n    if [ ! -f HashPrime.java ]; then\n        echo \"File does not exist — compile-before-write failure\"\n    fi\nfi\n```"),
        ("endless-retry-loop", "Endless Retry Loop",
         ["failure", "loop", "stuck", "common"],
         "## Symptom\n\nModel repeats the same failing command without changing behavior.\nStep count increases but no progress is made.\n\n## Root Cause\n\nModel doesn't recognize that its approach isn't working.\nOften after step 5-6, model loses track of what it tried.\n\n## Fix\n\n1. Track consecutive identical tool calls\n2. After 2-3 identical failures, inject hint: 'Try a different approach'\n3. After 5 identical failures, terminate turn\n\n## Detection\n\n```python\nlast_calls = []\nfor call in tool_calls:\n    if call in last_calls[-2:]:\n        consecutive += 1\n        if consecutive >= 3:\n            inject_hint('Try a different approach')\n    else:\n        consecutive = 0\n    last_calls.append(call)\n```"),
    ]

    for failure_id, title, tags, body in failure_modes:
        record_skill("failure-modes", failure_id, title, tags, body,
                     sources=[{"id": "suggestion-txt", "resource": "suggestion.txt", "title": "Developer notes"}])

    # Strategies
    record_skill("strategies", "single-task-focus", "Single Task Focus",
                 ["strategy", "architecture", "multi-turn"],
                 "## Strategy\n\nEach turn selects exactly one discrete task from the machine-readable ledger.\nThe LLM never attempts multiple requirements in one session.\n\n### Benefits\n- Reduces complexity per turn\n- Prevents partial completions\n- Makes verification atomic\n- Easier to diagnose failures\n\n### Implementation\n```python\ndef pick_next(tasks):\n    for t in tasks['tasks']:\n        if t['status'] == 'failing':\n            return t\n    return None\n```")

    record_skill("strategies", "fresh-context-per-turn", "Fresh Context Every Turn",
                 ["strategy", "architecture", "memory"],
                 "## Strategy\n\nEvery loop turn starts with a completely fresh, unpolluted context window.\nMemory is re-established by reading physical files on disk.\n\n### Benefits\n- No context rot over long horizons\n- No stale information carryover\n- Consistent behavior across turns\n- Easy to debug (each turn is independent)\n\n### Implementation\n```\nralph.sh reads tasks.json + progress.txt\n  → generates task prompt\n  → spawns complete.sh (fresh Ollama session)\n  → complete.sh starts with empty message history\n```")

    # Model profiles
    record_skill("model-profiles", "qwen2.5-coder", "Qwen2.5-Coder Profile",
                 ["model", "qwen", "parser-stage-6", "think-tags"],
                 "## Model: qwen2.5-coder\n\n### Parser Profile\n- Detected stage: 6 (markdown Java extraction)\n- Needs think-tag pre-processing: Yes\n- Common output format: think tags + ```java blocks\n\n### Characteristics\n- Good at Java code generation\n- Sometimes emits tool calls as JSON in think tags\n- May skip write_file step (compile-before-write risk)\n\n### Recommended Skills\n- `think-tag-stripping` (always apply)\n- `markdown-java-extraction` (stage 6)\n- `auto-inject-params` (frequently needed)")

    record_skill("model-profiles", "gemma4", "Gemma4 Profile",
                 ["model", "gemma", "parser-stage-1", "native-tools"],
                 "## Model: gemma4\n\n### Parser Profile\n- Detected stage: 1 (native tool calls)\n- Needs think-tag pre-processing: No\n- Common output format: Ollama message.tool_calls[]\n\n### Characteristics\n- Uses native function calling reliably\n- Clean JSON output\n- Rarely needs parameter injection\n\n### Recommended Skills\n- `native-tool-call-extraction` (stage 1)")

    print("Seeding complete.")


def ingest_corpus(corpus_name, corpus_dir, knowledge_dir=None):
    """Ingest a corpus directory into OKF reference category."""
    if knowledge_dir is None:
        knowledge_dir = KNOWLEDGE_DIR
    
    ref_dir = os.path.join(knowledge_dir, "reference")
    os.makedirs(ref_dir, exist_ok=True)
    
    concepts_created = []
    
    for md_file in Path(corpus_dir).rglob("*.md"):
        try:
            content = md_file.read_text(encoding="utf-8", errors="replace")
            if len(content.strip()) < 100:
                continue
            
            # Extract title from first heading or filename
            title_match = re.search(r'^#\s+(.+)$', content, re.MULTILINE)
            if title_match:
                raw_title = title_match.group(1).strip()
            else:
                raw_title = md_file.stem.replace('-', ' ').replace('_', ' ').title()
            
            # Convert to "how do I" format
            if not raw_title.lower().startswith("how do i"):
                title = f"How do I {raw_title}"
            else:
                title = raw_title
            
            # Generate concept ID
            concept_id = re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')
            
            # Extract tags from content
            tags = [corpus_name]
            for word in ['python', 'java', 'bash', 'linux', 'ssh', 'dns', 'dhcp', 'apache']:
                if word in content.lower():
                    tags.append(word)
            
            # Determine difficulty
            difficulty = "beginner"
            if any(w in content.lower() for w in ['advanced', 'complex', 'optimization']):
                difficulty = "advanced"
            elif any(w in content.lower() for w in ['intermediate', 'configuration', 'setup']):
                difficulty = "intermediate"
            
            # Create OKF concept
            concept = f"""---
type: Reference
title: "{title}"
description: "{title} - from {corpus_name}"
status: new
tags: [{', '.join(tags)}]
difficulty: {difficulty}
corpus: {corpus_name}
source: {md_file.relative_to(corpus_dir)}
generated:
  by: okf_ingest/0.1
  at: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
---

{content}
"""
            
            concept_path = os.path.join(ref_dir, f"{concept_id}.md")
            with open(concept_path, "w") as f:
                f.write(concept)
            
            concepts_created.append(concept_id)
            
        except Exception as e:
            print(f"  Warning: {md_file}: {e}")
    
    return concepts_created


def main():
    if len(sys.argv) < 2:
        print("Commands: record, search, list, seed, ingest")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "record":
        if len(sys.argv) < 5:
            print("Usage: record <category> <id> <title> <tags> [body]")
            print("Categories: skills, failure-modes, model-profiles, strategies, reference")
            sys.exit(1)
        category = sys.argv[2]
        skill_id = sys.argv[3]
        title = sys.argv[4]
        tags = sys.argv[5].split(",") if len(sys.argv) > 5 else []
        body = sys.argv[6] if len(sys.argv) > 6 else f"# {title}\n\nNo description provided."
        record_skill(category, skill_id, title, tags, body)

    elif cmd == "search":
        query_tags = None
        query_type = None
        i = 2
        while i < len(sys.argv):
            if sys.argv[i] == "--tags" and i + 1 < len(sys.argv):
                query_tags = sys.argv[i + 1].split(",")
                i += 2
            elif sys.argv[i] == "--type" and i + 1 < len(sys.argv):
                query_type = sys.argv[i + 1]
                i += 2
            else:
                i += 1
        results = search_skills(query_tags=query_tags, query_type=query_type)
        if results:
            print(json.dumps(results, indent=2))
        else:
            print("[]")

    elif cmd == "list":
        list_all()

    elif cmd == "seed":
        seed_from_codebase()

    elif cmd == "update-profile":
        if len(sys.argv) < 5:
            print("Usage: update-profile <model_name> <parser_stage> <model_id>")
            sys.exit(1)
        model_name = sys.argv[2]
        parser_stage = sys.argv[3]
        model_id = sys.argv[4]
        record_model_profile_update(model_name, parser_stage, model_id)

    elif cmd == "ingest":
        if len(sys.argv) < 4:
            print("Usage: ingest <corpus_name> <corpus_dir>")
            print("Example: ingest linux-server corpora/linux-server/en")
            sys.exit(1)
        corpus_name = sys.argv[2]
        corpus_dir = sys.argv[3]
        if not os.path.isdir(corpus_dir):
            print(f"Error: Directory not found: {corpus_dir}")
            sys.exit(1)
        concepts = ingest_corpus(corpus_name, corpus_dir)
        print(f"Ingested {len(concepts)} concepts from {corpus_name}")

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
