#!/usr/bin/env python3
"""
OKF (Open Knowledge Format) v0.2 Bundle Generator

Generates an OKF knowledge bundle from the agent's runtime state:
  - spec.yaml        → project concept
  - tasks.json       → attested computation concepts
  - progress_tracker.json → trust/verification state
  - CHANGELOG.md     → log.md

Usage:
    python3 okf_generator.py [sandbox_dir]

If sandbox_dir is not given, defaults to 'sandbox'.
"""

import json
import os
import re
import sys
import yaml
from datetime import datetime, timezone


OKF_VERSION = "0.2"


def load_json(path):
    with open(path) as f:
        return json.load(f)


def load_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f)


def load_text(path):
    with open(path) as f:
        return f.read()


def save(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)


def status_to_okf(task_status):
    """Map task status to OKF lifecycle status."""
    return "stable" if task_status == "passing" else "draft"


def derive_trust_tier(task_id, progress):
    """Derive OKF trust tier from progress state."""
    if task_id in progress.get("completed_with_success", []):
        return "machine-confirmed"
    if task_id in progress.get("completed_tasks", []):
        return "machine-confirmed"
    return "unverified"


def get_model_from_changelog(changelog_text, task_id):
    """Extract the model name from changelog entries for a given task."""
    for line in changelog_text.splitlines():
        if f"**{task_id}**" in line:
            return None
    lines = changelog_text.splitlines()
    current_model = None
    for line in lines:
        if line.startswith("Model: "):
            current_model = line.split("Model: ", 1)[1].strip()
    return current_model


def get_last_turn_info(changelog_text, progress_txt, task_id):
    """Get turn number, timestamp, and model for a task's pass from changelog/progress."""
    lines = changelog_text.splitlines()
    current_turn = None
    current_ts = None
    current_model = None
    for line in lines:
        m = re.match(r"^## Turn (\d+) \((.+?)\)", line)
        if m:
            current_turn = m.group(1)
            current_ts = m.group(2)
        if f"**{task_id}**" in line and "passed" in line:
            break

    # Also search progress.txt for model info
    for line in progress_txt.splitlines():
        m = re.match(r"^## Turn (\d+)", line)
        if m:
            current_turn = m.group(1)
        if line.startswith("Model: "):
            current_model = line.split("Model: ", 1)[1].strip()
        if line.startswith("Task: ") and task_id in line:
            break

    return current_turn, current_ts, current_model


def generate_project_concept(spec, changelog_text):
    """Generate project.md from spec.yaml."""
    project = spec.get("project", {})
    name = project.get("name", "unknown")
    lang = project.get("language", "unknown")
    filename = project.get("file", "unknown")
    desc = spec.get("input", {}).get("description", "")

    constraints = spec.get("constraints", {})
    max_mem = constraints.get("max_memory", "")
    target_n = constraints.get("target_n", "")

    validation_count = len(spec.get("validation", []))

    body_parts = []
    body_parts.append(f"# Specification\n")
    body_parts.append(f"Project: `{filename}` ({lang})")
    body_parts.append(f"Input: {desc}")
    if max_mem:
        body_parts.append(f"Memory constraint: `{max_mem}`")
    if target_n:
        body_parts.append(f"Target N: `{target_n:,}`")
    body_parts.append(f"Validation cases: {validation_count}")
    body_parts.append("")

    body_parts.append("# Validation Table\n")
    body_parts.append("| Input | Expected Hash |")
    body_parts.append("|-------|---------------|")
    for v in spec.get("validation", []):
        inp = v.get("input", "")
        exp = v.get("expected", "")
        body_parts.append(f"| `{inp}` | `{exp}` |")
    body_parts.append("")

    body_parts.append("# References\n")
    algo_ref = spec.get("algorithm_reference", "")
    if algo_ref:
        body_parts.append(f"- Algorithm spec: `{algo_ref}`")

    generated_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    return f"""---
type: Project
title: "{name}"
description: "LLM evaluation benchmark — {lang} program that computes SHA-256 hash of all primes ≤ N."
status: stable
tags: [benchmark, java, sha256, prime, hashprime]
generated: {{ by: okf_generator/0.1, at: {generated_ts} }}
---

{chr(10).join(body_parts)}
"""


def generate_task_concept(task, spec, progress, changelog_text, progress_txt):
    """Generate an attested computation concept for a single task."""
    task_id = task["id"]
    status = status_to_okf(task["status"])
    trust_tier = derive_trust_tier(task_id, progress)
    turn, ts_human, model = get_last_turn_info(changelog_text, progress_txt, task_id)

    generated_by = f"ralph_agent/{model}" if model else "ralph_agent/unknown"
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if ts_human:
        generated_at = ts_human

    verified_lines = []
    if trust_tier == "machine-confirmed" and ts_human:
        verified_lines.append(f"  - by: process:regression-gate")
        verified_lines.append(f"    at: {generated_at}")
    verified_block = ""
    if verified_lines:
        verified_block = "verified:\n" + "\n".join(verified_lines) + "\n"

    vcmd = task.get("verification_command", "")
    eout = task.get("expected_output", "")
    desc = task.get("description", "")
    priority = task.get("priority", 0)

    tags = ["hashprime", "attested-computation"]
    if "memory" in task_id:
        tags.append("memory-constraint")
    if "validation" in task_id or "empty" in task_id:
        tags.append("edge-case")
    else:
        tags.append("hash-test")

    body_parts = []
    body_parts.append(f"# Computation\n")
    if vcmd:
        body_parts.append(f"    {vcmd}")
    body_parts.append("")

    if eout:
        body_parts.append(f"Expected output: `{eout}`")
        body_parts.append("")

    body_parts.append(f"# Verification\n")
    body_parts.append(f"Verification command: `{vcmd}`" if vcmd else "No verification command.")
    body_parts.append(f"Priority: {priority}")
    if turn:
        body_parts.append(f"First passing turn: {turn}")

    tags_str = ", ".join(tags)

    return f"""---
type: Attested Computation
title: "{desc}"
description: "Task {task_id}: {desc}"
status: {status}
runtime: java
tags: [{tags_str}]
parameters:
  - {{ name: N, type: integer, required: true }}
executor:
  resource: /references/skills/run-java.md
  receipt: [exit_code, stdout, stderr]
attester:
  resource: /references/attesters/output_match.md
generated:
  by: {generated_by}
  at: {generated_at}
{verified_block}sources:
  - id: spec-validation
    resource: /project.md
    title: "spec.yaml validation table"
---

{chr(10).join(body_parts)}
"""


def generate_model_concept(model_name, tasks, progress, changelog_text, progress_txt):
    """Generate a model concept showing what a model passed/failed."""
    safe_name = model_name.replace("/", "_").replace(":", "_")
    passing = [t["id"] for t in tasks if t["status"] == "passing"]
    failing = [t["id"] for t in tasks if t["status"] == "failing"]

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    body_parts = []
    body_parts.append("# Task Results\n")
    if passing:
        body_parts.append("## Passing\n")
        for tid in passing:
            body_parts.append(f"- [ ] [{tid}](/computations/{tid}.md)")
        body_parts.append("")
    if failing:
        body_parts.append("## Failing\n")
        for tid in failing:
            body_parts.append(f"- [ ] [{tid}](/computations/{tid}.md)")
        body_parts.append("")

    total = len(tasks)
    passed = len(passing)
    body_parts.append(f"# Summary\n")
    body_parts.append(f"Tasks passed: {passed}/{total}")
    body_parts.append(f"Completion: {passed * 100 // total if total else 0}%")

    return f"""---
type: Model
title: "{model_name}"
description: "Evaluation results for {model_name} on hashprime benchmark."
status: stable
tags: [model, llm, ollama]
generated:
  by: okf_generator/0.1
  at: {generated_at}
---

{chr(10).join(body_parts)}
"""


def generate_index_md(title, entries):
    """Generate an index.md listing for a directory."""
    lines = [f"# {title}\n"]
    for entry in entries:
        name = entry["name"]
        link = entry["link"]
        desc = entry.get("description", "")
        if desc:
            lines.append(f"- [{name}]({link}) — {desc}")
        else:
            lines.append(f"- [{name}]({link})")
    lines.append("")
    return "\n".join(lines)


def generate_log_md(changelog_text):
    """Convert CHANGELOG.md to OKF log.md format."""
    lines = ["# Update Log\n"]
    for line in changelog_text.splitlines():
        if line.startswith("# "):
            continue
        lines.append(line)
    lines.append("")
    return "\n".join(lines)


def generate_bundle(sandbox_dir):
    """Generate the full OKF bundle from runtime state."""
    knowledge_dir = os.path.join(sandbox_dir, "knowledge")

    spec_path = os.path.join(sandbox_dir, "spec.yaml")
    tasks_path = os.path.join(sandbox_dir, "tasks.json")
    progress_path = os.path.join(sandbox_dir, "progress_tracker.json")
    changelog_path = os.path.join(sandbox_dir, "CHANGELOG.md")
    progress_txt_path = os.path.join(sandbox_dir, "progress.txt")

    if not os.path.exists(tasks_path):
        print(f"OKF: No tasks.json found at {tasks_path}, skipping.")
        return

    spec = {}
    if os.path.exists(spec_path):
        spec = load_yaml(spec_path)

    tasks_data = load_json(tasks_path)
    progress = {}
    if os.path.exists(progress_path):
        progress = load_json(progress_path)

    changelog_text = ""
    if os.path.exists(changelog_path):
        changelog_text = load_text(changelog_path)

    progress_txt = ""
    if os.path.exists(progress_txt_path):
        progress_txt = load_text(progress_txt_path)

    tasks = tasks_data.get("tasks", [])
    project_name = spec.get("project", {}).get("name", "unknown")

    # project.md
    project_md = generate_project_concept(spec, changelog_text)
    save(os.path.join(knowledge_dir, "project.md"), project_md)

    # computations/
    comp_dir = os.path.join(knowledge_dir, "computations")
    comp_entries = []
    for task in tasks:
        tid = task["id"]
        concept_md = generate_task_concept(task, spec, progress, changelog_text, progress_txt)
        save(os.path.join(comp_dir, f"{tid}.md"), concept_md)
        comp_entries.append({
            "name": tid,
            "link": f"{tid}.md",
            "description": task.get("description", ""),
        })
    comp_index = generate_index_md("Attested Computations", comp_entries)
    save(os.path.join(comp_dir, "index.md"), comp_index)

    # models/ — collect unique models from changelog and progress.txt
    models_dir = os.path.join(knowledge_dir, "models")
    model_names = set()
    for line in changelog_text.splitlines():
        if line.startswith("Model: "):
            model = line.split("Model: ", 1)[1].strip()
            if model:
                model_names.add(model)
    for line in progress_txt.splitlines():
        if line.startswith("Model: "):
            model = line.split("Model: ", 1)[1].strip()
            if model:
                model_names.add(model)

    model_entries = []
    for model_name in sorted(model_names):
        concept_md = generate_model_concept(model_name, tasks, progress, changelog_text, progress_txt)
        safe = model_name.replace("/", "_").replace(":", "_")
        save(os.path.join(models_dir, f"{safe}.md"), concept_md)
        model_entries.append({
            "name": model_name,
            "link": f"{safe}.md",
            "description": f"Evaluation results for {model_name}",
        })
    model_index = generate_index_md("Models", model_entries)
    save(os.path.join(models_dir, "index.md"), model_index)

    # skills/, failure-modes/, model-profiles/, strategies/ — preserved from skill_recorder
    skill_dirs = ["skills", "failure-modes", "model-profiles", "strategies"]
    skill_dir_counts = {}
    for dir_name in skill_dirs:
        src_dir = os.path.join(knowledge_dir, dir_name)
        if os.path.exists(src_dir):
            md_count = len([f for f in os.listdir(src_dir) if f.endswith(".md") and f != "index.md"])
            skill_dir_counts[dir_name] = md_count

    # references/
    refs_dir = os.path.join(knowledge_dir, "references")
    skills_dir = os.path.join(refs_dir, "skills")
    attesters_dir = os.path.join(refs_dir, "attesters")

    save(os.path.join(skills_dir, "run-java.md"), """---
type: Skill
title: "Run Java"
description: "Executor skill for running compiled Java classes with arguments."
status: stable
tags: [executor, java]
---

# Run Java

Executor that compiles and runs a Java class.

## Usage

    javac <filename>.java
    java <class_name> <args...>

## Receipt

Returns: exit_code, stdout, stderr
""")

    save(os.path.join(attesters_dir, "output_match.md"), """---
type: Attester
title: "SHA-256 Output Match"
description: "Attester that compares program output against expected SHA-256 hash."
status: stable
tags: [attester, sha256, verification]
---

# SHA-256 Output Match

Deterministic attester that inspects a run receipt and compares stdout
against the expected SHA-256 hash value.

## Verdict

- PASS: stdout contains the expected hash string
- FAIL: stdout does not contain the expected hash, or exit_code != 0
""")

    # root index.md
    root_entries = [
        {"name": "Project", "link": "project.md", "description": f"The {project_name} specification"},
        {"name": "Computations", "link": "computations/", "description": f"{len(tasks)} attested computations"},
    ]
    if model_entries:
        root_entries.append({"name": "Models", "link": "models/", "description": f"{len(model_entries)} models evaluated"})
    for dir_name in skill_dirs:
        count = skill_dir_counts.get(dir_name, 0)
        if count > 0:
            label = dir_name.replace("-", " ").title()
            root_entries.append({"name": label, "link": f"{dir_name}/", "description": f"{count} {dir_name}"})
    root_entries.append({"name": "References", "link": "references/", "description": "Executor and attester skills"})

    root_index = generate_index_md(f"Knowledge Bundle — {project_name}", root_entries)
    # Add OKF version to root index frontmatter
    root_index = root_index.replace("# ", "---\nokf_version: \"0.2\"\n---\n\n# ", 1)
    save(os.path.join(knowledge_dir, "index.md"), root_index)

    # log.md
    if changelog_text:
        log_md = generate_log_md(changelog_text)
        save(os.path.join(knowledge_dir, "log.md"), log_md)

    print(f"OKF: Bundle generated at {knowledge_dir}/")
    print(f"  - project.md")
    print(f"  - {len(tasks)} computation concepts")
    print(f"  - {len(model_entries)} model concepts")
    for dir_name in skill_dirs:
        count = skill_dir_counts.get(dir_name, 0)
        if count > 0:
            print(f"  - {dir_name}/ ({count} entries)")
    print(f"  - references/")
    print(f"  - index.md, log.md")


def main():
    sandbox_dir = sys.argv[1] if len(sys.argv) > 1 else "sandbox"
    generate_bundle(sandbox_dir)


if __name__ == "__main__":
    main()
