#!/usr/bin/env python3
import json
import sys
import yaml


def load_spec(path="spec.yaml"):
    with open(path) as f:
        return yaml.safe_load(f)


def generate_tasks(spec):
    tasks = []
    pname = spec["project"]["name"]
    empty_hash = spec["byte_stream"]["empty_stream"]["hash"]

    help_msg = spec.get("help_message", "")
    help_first_line = help_msg.split("\n")[0] if help_msg else "Usage:"

    tasks.append({
        "id": "input_validation",
        "description": f"Handle no argument \u2014 print help message to stdout and exit 0",
        "status": "failing",
        "priority": 1,
        "verification_command": f"java {pname} 2>&1",
        "expected_output": help_first_line
    })

    # Build hash-to-task-id mapping (first occurrence's task ID wins)
    hash_to_task_id = {}
    for v in spec.get("validation", []):
        h = v["expected"]
        if h in hash_to_task_id:
            continue
        if h == empty_hash:
            hash_to_task_id[h] = "empty_stream"
        else:
            hash_to_task_id[h] = f"n_{v['input']}"

    # Build regression tests (fast tests only)
    regression_tests = []
    for v in spec.get("validation", []):
        inp = v["input"]
        h = v["expected"]
        if inp.lstrip('-').isdigit() and abs(int(inp)) < 1000000:
            regression_tests.append({
                "input": inp,
                "expected": h,
                "tag": hash_to_task_id.get(h, "")
            })

    # Build tasks (dedup by hash — first occurrence wins)
    seen_hashes = set()
    priority = 2
    for v in spec.get("validation", []):
        h = v["expected"]
        if h in seen_hashes:
            continue
        seen_hashes.add(h)

        if h == empty_hash:
            tid = "empty_stream"
            desc = f"N<2 (negative, 0, 1) produces empty-stream hash {empty_hash[:16]}..."
            vcmd = f"java {pname} -5 2>&1"
            eout = empty_hash
        else:
            tid = f"n_{v['input']}"
            desc = f"N={v['input']} produces {h[:16]}..."
            vcmd = f"java {pname} {v['input']} 2>&1"
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

    constraints = spec.get("constraints", {})
    if constraints.get("max_memory") and constraints.get("target_n"):
        target = constraints["target_n"]
        mem = constraints["max_memory"]
        tasks.append({
            "id": "memory_efficient",
            "description": f"Handle N={target:,} within {mem}: incremental MessageDigest, BitSet sieve, no string concatenation",
            "status": "failing",
            "priority": 99,
            "verification_command": f"java {mem} {pname} {target} 2>&1 >/dev/null",
            "expected_output": ""
        })

    return {
        "filename": spec["project"]["file"],
        "tasks": tasks,
        "regression_tests": regression_tests
    }


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "spec.yaml"
    spec = load_spec(path)
    tasks = generate_tasks(spec)
    with open("tasks.json", "w") as f:
        json.dump(tasks, f, indent=2)
    plural = "s" if len(tasks["tasks"]) != 1 else ""
    print(f"Generated {len(tasks['tasks'])} task{plural} from spec.")


if __name__ == "__main__":
    main()
