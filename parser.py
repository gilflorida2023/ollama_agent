#!/usr/bin/env python3
import sys
import json
import re
import os
import argparse

BT = '\x60'

REGEX_THINK = re.compile(r'<think>.*?</think>', re.DOTALL)
REGEX_MARKDOWN_JSON = re.compile(
    BT * 3 + r'(?:json)?\s*\n(\{.*?\})\s*\n' + BT * 3, re.DOTALL
)
REGEX_XML_WRITE = re.compile(
    r'<write_file\s+filename="([^"]+)"\s+content="([^"]+)"'
)
REGEX_XML_JAVAC = re.compile(r'<javac\s+filename="([^"]+)"')
REGEX_XML_JAVA = re.compile(
    r'<java\s+class_name="([^"]+)"(?:\s+args="([^"]+)")?'
)
REGEX_MARKDOWN_JAVA = re.compile(
    BT * 3 + r'(?:java(?:\s+([A-Za-z0-9_.\\/]+\.java))?)?\s*\n'
             r'(.*?\bpublic\s+class\s+([A-Za-z0-9_]+).*?)\s*\n' + BT * 3,
    re.DOTALL
)
REGEX_UNFENCED_JAVA = re.compile(
    r'(public\s+class\s+([A-Za-z0-9_]+)\s*\{.*)', re.DOTALL
)
REGEX_SHELL_COMMANDS = re.compile(
    BT * 3 + r'(?:sh|bash)?\s*\n(.*?)\n' + BT * 3, re.DOTALL
)


def _extract_tool_info(obj):
    if not isinstance(obj, dict):
        return None, None
    name = obj.get("name") or obj.get("tool")
    if not name:
        func = obj.get("function")
        if isinstance(func, str):
            name = func
    args = obj.get("arguments") or obj.get("params") or obj.get("args") or {}
    if not name:
        return None, None
    return name, args


def _probe(data):
    """Run full cascade, return first matching stage number or None."""
    msg = data.get("message", {})
    if msg.get("tool_calls"):
        return 1

    raw_content = msg.get("content") or ""
    content = re.sub(REGEX_THINK, '', raw_content)
    if content.strip() == '':
        content = raw_content

    if re.findall(REGEX_MARKDOWN_JSON, content):
        return 3

    decoder = json.JSONDecoder()
    pos = 0
    while pos < len(content):
        idx = content.find('{', pos)
        if idx == -1:
            break
        try:
            obj, end = decoder.raw_decode(content[idx:])
            name, _ = _extract_tool_info(obj)
            if name:
                return 4
            pos = idx + end
        except Exception:
            pos = idx + 1

    if re.findall(REGEX_XML_WRITE, content):
        return 5

    if re.findall(REGEX_MARKDOWN_JAVA, content):
        return 6

    if re.search(REGEX_UNFENCED_JAVA, content):
        return 7

    if re.findall(REGEX_SHELL_COMMANDS, content):
        return 8

    return None


def parse_response(data, skip=None):
    if skip is None:
        skip = set()
    tool_calls = []

    msg = data.get("message", {})

    if 1 not in skip:
        for call in msg.get("tool_calls", []):
            func = call.get("function", {})
            tool_calls.append({
                "name": func.get("name"),
                "arguments": func.get("arguments")
            })
        if tool_calls:
            return tool_calls

    raw_content = msg.get("content") or ""

    if 2 not in skip:
        content = re.sub(REGEX_THINK, '', raw_content)
        if content.strip() == '':
            content = raw_content
    else:
        content = raw_content

    if 3 not in skip:
        for block in re.findall(REGEX_MARKDOWN_JSON, content):
            try:
                parsed = json.loads(block)
                name, args = _extract_tool_info(parsed)
                if name:
                    tool_calls.append({"name": name, "arguments": args})
            except Exception:
                pass
        if tool_calls:
            return tool_calls

    if 4 not in skip:
        decoder = json.JSONDecoder()
        pos = 0
        while pos < len(content):
            match_idx = content.find('{', pos)
            if match_idx == -1:
                break
            try:
                obj, end = decoder.raw_decode(content[match_idx:])
                name, args = _extract_tool_info(obj)
                if name:
                    tool_calls.append({"name": name, "arguments": args})
                pos = match_idx + end
            except Exception:
                pos = match_idx + 1
        if tool_calls:
            return tool_calls

    if 5 not in skip:
        for fn, code_content in re.findall(REGEX_XML_WRITE, content):
            tool_calls.append({
                "name": "write_file",
                "arguments": {"filename": fn, "content": code_content}
            })
        for fn in re.findall(REGEX_XML_JAVAC, content):
            tool_calls.append({
                "name": "javac",
                "arguments": {"filename": fn}
            })
        for cn, args_str in re.findall(REGEX_XML_JAVA, content):
            try:
                args_list = json.loads(args_str) if args_str else []
            except Exception:
                args_list = [args_str] if args_str else []
            tool_calls.append({
                "name": "java",
                "arguments": {"class_name": cn, "args": args_list}
            })
        if tool_calls:
            return tool_calls

    if 6 not in skip:
        java_matches = re.findall(REGEX_MARKDOWN_JAVA, content)
        if java_matches:
            match = java_matches[-1]
            fname, code_body, class_name = match if len(match) == 3 else (None, match[0], match[1])
            filename = fname if fname else class_name + ".java"
            tool_calls.append({
                "name": "write_file",
                "arguments": {
                    "filename": filename,
                    "content": code_body.strip()
                }
            })

    if 7 not in skip and not tool_calls:
        java_match = re.search(REGEX_UNFENCED_JAVA, content)
        if java_match:
            code_body = java_match.group(1)
            class_name = java_match.group(2)
            tool_calls.append({
                "name": "write_file",
                "arguments": {
                    "filename": class_name + ".java",
                    "content": code_body.strip()
                }
            })

    if 8 not in skip:
        if not tool_calls or all(tc["name"] == "write_file" for tc in tool_calls):
            for block in re.findall(REGEX_SHELL_COMMANDS, content):
                for line in block.splitlines():
                    line = line.strip()
                    if line.startswith("javac "):
                        parts = line.split()
                        if len(parts) > 1:
                            tool_calls.append({
                                "name": "javac",
                                "arguments": {"filename": parts[1]}
                            })
                    elif line.startswith("java "):
                        parts = line.split()
                        if len(parts) > 1:
                            class_name = parts[1]
                            cmd_args = parts[2:] if len(parts) > 2 else []
                            tool_calls.append({
                                "name": "java",
                                "arguments": {"class_name": class_name, "args": cmd_args}
                            })

    return tool_calls


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', help='Model name to load config from .configs/')
    ap.add_argument('--probe', action='store_true', help='Detect parser stage and exit')
    args = ap.parse_args()

    if args.probe:
        try:
            raw_input = sys.stdin.read()
            data = json.loads(raw_input)
            stage = _probe(data)
            print(json.dumps({"stage": stage}))
        except Exception:
            print(json.dumps({"stage": None}))
        sys.exit(0)

    skip = set()
    if args.model:
        config_dir = os.path.join(os.path.dirname(__file__), '.configs')
        config_path = os.path.join(config_dir, f'{args.model}.config.json')
        if os.path.exists(config_path):
            with open(config_path) as f:
                config = json.load(f)
                stage = config.get("stage")
                if stage is not None:
                    skip = set(range(1, 9)) - {stage}

    try:
        raw_input = sys.stdin.read()
        data = json.loads(raw_input)
        result = parse_response(data, skip)
        print(json.dumps(result))
    except Exception:
        print("[]")
