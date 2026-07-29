#!/usr/bin/env python3
import json
import sys
import os

TRACKER_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sandbox', 'progress_tracker.json')

def load():
    if not os.path.exists(TRACKER_FILE):
        return {'completed_tasks': [], 'completed_with_success': []}
    with open(TRACKER_FILE) as f:
        return json.load(f)

def save(data):
    os.makedirs(os.path.dirname(TRACKER_FILE), exist_ok=True)
    with open(TRACKER_FILE, 'w') as f:
        json.dump(data, f, indent=2)

def add_completed(task_id, success):
    data = load()
    if task_id not in data['completed_tasks']:
        data['completed_tasks'].append(task_id)
    if success and task_id not in data['completed_with_success']:
        data['completed_with_success'].append(task_id)
    save(data)
    print(f"Progress: {task_id} {'succeeded' if success else 'failed'}")

def check_all():
    data = load()
    all_spec = ["input_validation", "empty_stream", "n_11", "n_1000000", "n_10000000", "memory_efficient"]
    completed = set(data.get('completed_tasks', []))
    successful = set(data.get('completed_with_success', []))
    all_done = all(t in completed for t in all_spec)
    all_passed = all(t in successful for t in all_spec)
    if all_done and all_passed:
        print('SUCCESS_ALL_TASKS')
    elif all_done:
        print('SOME_TASKS_FAILED')
    else:
        print('NONE_COMPLETED_YET')

def main():
    if len(sys.argv) < 2:
        print("Usage: progress_tracker.py <command> [args]")
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == 'add_completed' and len(sys.argv) >= 4:
        task_id = sys.argv[2]
        success = sys.argv[3].lower() == 'true'
        add_completed(task_id, success)
    elif cmd == 'check_all':
        check_all()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == '__main__':
    main()
