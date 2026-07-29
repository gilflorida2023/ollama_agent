#!/usr/bin/env python3
import json
import os
import subprocess
import sys


TASKS_FILE = "tasks.json"
PROGRESS_TRACKER = "progress_tracker.json"
CHANGELOG_FILE = "CHANGELOG.md"
PROGRESS_FILE = "progress.txt"


def load_tasks(path=TASKS_FILE):
    with open(path) as f:
        return json.load(f)


def save_tasks(data, path=TASKS_FILE):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def pick_next(tasks):
    for t in tasks["tasks"]:
        if t["status"] == "failing":
            return t
    return None


def _run_regression_tests():
    """Run regression tests for currently-passing tasks. Returns True if all pass."""
    if not os.path.exists(TASKS_FILE):
        return True
    with open(TASKS_FILE) as f:
        data = json.load(f)

    tests = data.get("regression_tests", [])
    if not tests:
        return True

    passing_tasks = {t["id"] for t in data.get("tasks", []) if t["status"] == "passing"}
    if not passing_tasks:
        return True

    all_ok = True
    for t in tests:
        inp = t["input"]
        expected = t["expected"]
        tag = t.get("tag", "")
        if tag not in passing_tasks:
            continue
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
        if actual != expected:
            print(f"  Regression FAIL: N={inp} (task: {tag})")
            print(f"    Expected: {expected}")
            print(f"    Got:      {actual}")
            all_ok = False
    return all_ok


def verify_and_commit(task, turn, ts_human, branch_name):
    """
    Verify task by compiling hashprime.java, running regression tests
    for previously-passing tasks, then running the task-specific
    verification_command. On pass, update tasks.json, progress,
    changelog, and commit. On fail, git reset --hard.
    Returns True if passed, False otherwise.
    """
    task_id = task["id"]
    vcmd = task.get("verification_command", "")
    eout = task.get("expected_output", "")
    passed = False

    if not os.path.exists("hashprime.java"):
        print(f"  hashprime.java not found on disk")
        return _fail_and_rollback(task_id, ts_human, turn, branch_name)

    print(f"  Compiling hashprime.java...")
    result = subprocess.run(
        ["javac", "hashprime.java"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"  Compilation FAILED after complete.sh run")
        return _fail_and_rollback(task_id, ts_human, turn, branch_name)

    print(f"  Compilation OK.")

    if not _run_regression_tests():
        print(f"  Verification: FAIL ({task_id} — regression detected)")
        return _fail_and_rollback(task_id, ts_human, turn, branch_name)

    if vcmd and eout:
        try:
            actual = subprocess.check_output(
                vcmd, shell=True, stderr=subprocess.STDOUT
            ).decode().strip().replace("\r", "")
            if eout in actual:
                passed = True
                print(f"  Verification: PASS ({task_id})")
            else:
                print(f"  Verification: FAIL ({task_id})")
                print(f"  Expected: {eout}")
                print(f"  Got:      {actual}")
        except subprocess.CalledProcessError:
            print(f"  Verification: FAIL ({task_id} — command error)")
        except Exception as e:
            print(f"  Verification: FAIL ({task_id} — {e})")
    elif vcmd and not eout:
        try:
            subprocess.run(vcmd, shell=True, capture_output=True, check=True)
            passed = True
            print(f"  Verification: PASS ({task_id} — run only)")
        except subprocess.CalledProcessError:
            print(f"  Verification: FAIL ({task_id} — run failed)")
    else:
        passed = True
        print(f"  Verification: PASS ({task_id} — existence only)")

    _update_progress_tracker(task_id, passed)

    if passed:
        return _mark_passed(task_id, ts_human, turn, branch_name)
    else:
        return _fail_and_rollback(task_id, ts_human, turn, branch_name)


def _update_progress_tracker(task_id, success):
    data = {"completed_tasks": [], "completed_with_success": []}
    if os.path.exists(PROGRESS_TRACKER):
        with open(PROGRESS_TRACKER) as f:
            data = json.load(f)
    if task_id not in data["completed_tasks"]:
        data["completed_tasks"].append(task_id)
    if success and task_id not in data["completed_with_success"]:
        data["completed_with_success"].append(task_id)
    with open(PROGRESS_TRACKER, "w") as f:
        json.dump(data, f, indent=2)


def _mark_passed(task_id, ts_human, turn, branch_name):
    reasoning = os.environ.get("RALPH_REASONING", "")
    print(f"  -> Task {task_id} PASSED")
    tasks = load_tasks()
    for t in tasks["tasks"]:
        if t["id"] == task_id:
            t["status"] = "passing"
            break
    save_tasks(tasks)

    with open(CHANGELOG_FILE, "a") as f:
        f.write(f"\n## Turn {turn} ({ts_human})\n")
        f.write(f"- **{task_id}**: passed\n")
        if reasoning:
            reasoning_short = reasoning.replace("\n", " ")[:200]
            f.write(f"  - Reasoning: {reasoning_short}\n")

    with open(PROGRESS_FILE, "a") as f:
        f.write(f"Result: PASS\n")

    subprocess.run(["git", "add", "-A"], capture_output=True)
    result = subprocess.run(
        ["git", "diff", "--staged", "--quiet"],
        capture_output=True
    )
    if result.returncode != 0:
        subprocess.run(
            ["git", "commit", "-m", f"ralph: turn {turn} - {task_id} passing", "-q"],
            capture_output=True
        )
        print(f"  Committed to {branch_name}")
    else:
        print(f"  Nothing new to commit.")
    return True


def _fail_and_rollback(task_id, ts_human, turn, branch_name):
    reasoning = os.environ.get("RALPH_REASONING", "")
    print(f"  -> Task {task_id} FAILED — rolling back")
    with open(PROGRESS_FILE, "a") as f:
        f.write(f"Result: FAIL (rolled back)\n")
    subprocess.run(["git", "reset", "--hard", "HEAD"], capture_output=True)
    for pattern in ["*.java", "*.class"]:
        subprocess.run(["rm", "-f", pattern], shell=True, capture_output=True)
    print(f"  Rolled back to last good commit on {branch_name}")
    return False


def check_all_completed(spec_tasks=None):
    """Check if all expected spec tasks are completed. Returns True if all done."""
    if not os.path.exists(PROGRESS_TRACKER):
        return False
    with open(PROGRESS_TRACKER) as f:
        data = json.load(f)
    if spec_tasks is None:
        spec_tasks = [
            "input_validation", "empty_stream", "n_11",
            "n_1000000", "n_10000000", "memory_efficient"
        ]
    completed = set(data.get("completed_tasks", []))
    successful = set(data.get("completed_with_success", []))
    all_done = all(t in completed for t in spec_tasks)
    all_passed = all(t in successful for t in spec_tasks)
    return all_done and all_passed


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else None
    if cmd == "pick_next":
        task = pick_next(load_tasks())
        if task:
            print(json.dumps(task))
        else:
            print("{}")
    elif cmd == "verify":
        turn = int(sys.argv[2]) if len(sys.argv) > 2 else 0
        ts = sys.argv[3] if len(sys.argv) > 3 else ""
        branch = sys.argv[4] if len(sys.argv) > 4 else ""
        task_json = sys.stdin.read()
        task = json.loads(task_json)
        passed = verify_and_commit(task, turn, ts, branch)
        if passed:
            sys.exit(0)
        else:
            sys.exit(1)
    elif cmd == "check_all":
        if check_all_completed():
            print("SUCCESS_ALL_TASKS")
        else:
            print("NOT_COMPLETED")
    elif cmd == "mark_passed":
        task_id = sys.argv[2]
        turn = int(sys.argv[3])
        ts = sys.argv[4]
        branch = sys.argv[5]
        _mark_passed(task_id, ts, turn, branch)
    else:
        print("Commands: pick_next, verify, check_all, mark_passed")
        sys.exit(1)


if __name__ == "__main__":
    main()
