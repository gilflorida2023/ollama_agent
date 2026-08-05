#!/usr/bin/env python3
import sys
import json
import re
import os
import argparse
from datetime import datetime, timezone

BT = '\x60'

DEBUG_LOG_PATH = os.path.join(os.path.dirname(__file__), 'logs', 'parser_debug.log')

def _debug_log(message, model=None):
    try:
        os.makedirs(os.path.join(os.path.dirname(__file__), 'logs'), exist_ok=True)
        ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        model_prefix = f'[{model}] ' if model else ''
        with open(DEBUG_LOG_PATH, 'a') as f:
            f.write(f'[{ts}] {model_prefix}{message}\n')
    except Exception:
        pass

REGEX_THINK = re.compile(r'<think>.*?</think>', re.DOTALL)
REGEX_MARKDOWN_JSON = re.compile(
    BT * 3 + r'(?:json)?\s*\n(\{.*?\})\s*\n' + BT * 3, re.DOTALL
)
REGEX_XML_WRITE_TAG = re.compile(
    r'<write_file>\s*\n\s*\{.*?\}\s*\n</write_file>',
    re.DOTALL
)
REGEX_XML_WRITE_INLINE = re.compile(
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

def _unescape_content(s):
    """Unescape common escape sequences in JSON strings"""
    s = s.replace('\\\\\\\\', '\\\\')
    s = s.replace('\\\\n', '\n')
    s = s.replace('\\\\t', '\t')
    s = s.replace('\\\\\\"', '\\"')
    return s


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

    # Check both tag-style and inline-style formats
    if re.findall(REGEX_XML_WRITE_TAG, content) or re.findall(REGEX_XML_WRITE_INLINE, content):
        return 5

    if re.findall(REGEX_MARKDOWN_JAVA, content):
        return 6

    if re.search(REGEX_UNFENCED_JAVA, content):
        return 7

    if re.findall(REGEX_SHELL_COMMANDS, content):
        return 8

    return None


def parse_response(data, skip=None, context=None):
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
            stage = 1
            for tc in tool_calls:
                args_str = json.dumps(tc["arguments"])[:200]
                _debug_log(f'stage={stage} calls=1 tool={tc["name"]} args={args_str}')
            return tool_calls

    raw_content = msg.get("content") or ""
    if not raw_content or not raw_content.strip():
        _debug_log('stage=NONE calls=0 content_preview=[EMPTY]')
        return tool_calls

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
            stage = 3
            for tc in tool_calls:
                args_str = json.dumps(tc["arguments"])[:200]
                _debug_log(f'stage={stage} calls=1 tool={tc["name"]} args={args_str}')
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
            stage = 4
            for tc in tool_calls:
                args_str = json.dumps(tc["arguments"])[:200]
                _debug_log(f'stage={stage} calls=1 tool={tc["name"]} args={args_str}')
            return tool_calls

    if 5 not in skip:
        # First try tag-style format
        for tag_match in re.findall(REGEX_XML_WRITE_TAG, content):
            # Extract JSON from inside the tag
            json_match = re.search(r'\{[\s\S]*?\}', tag_match)
            if json_match:
                json_str = json_match.group(0)
                
                # Try to parse JSON directly
                try:
                    parsed = json.loads(json_str)
                    name, args = _extract_tool_info(parsed)
                    if name:
                        tool_calls.append({"name": name, "arguments": args})
                except Exception:
                    # Fallback: extract filename and content manually
                    filename_match = re.search(r'"filename"\s*:\s*"([^"]*)"', json_str)
                    content_match = re.search(r'"content"\s*:\s*"([^"]*(?:\\\"[^\"]*)*)\"', json_str, re.DOTALL)
                    
                    if filename_match and content_match:
                        filename = filename_match.group(1)
                        content_field = content_match.group(1)
                        
                        # Unescape the content field
                        unescaped_content = _unescape_content(content_field)
                        
                        tool_calls.append({
                            "name": "write_file",
                            "arguments": {"filename": filename, "content": unescaped_content}
                        })
        
        # Then try inline format
        for fn, code_content in re.findall(REGEX_XML_WRITE_INLINE, content):
            # Unescape the content
            unescaped_content = _unescape_content(code_content)
            
            tool_calls.append({
                "name": "write_file",
                "arguments": {"filename": fn, "content": unescaped_content}
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
            stage = 5
            for tc in tool_calls:
                args_str = json.dumps(tc["arguments"])[:200]
                _debug_log(f'stage={stage} calls={len(tool_calls)} tool={tc["name"]} args={args_str}')
            return tool_calls

    if 6 not in skip:
        # If context is compile or run, don't wrap Java code as write_file
        # The model is ignoring tools and writing code instead - skip it
        if context not in ('compile', 'run'):
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
        # If context is compile or run, don't wrap Java code as write_file
        if context not in ('compile', 'run'):
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
        # If context is compile or run, always try to extract shell commands
        # This handles Format C models that write javac/java in bash blocks
        if context in ('compile', 'run') or not tool_calls or all(tc["name"] == "write_file" for tc in tool_calls):
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

    if tool_calls:
        for tc in tool_calls:
            args_str = json.dumps(tc["arguments"])[:200]
            _debug_log(f'stage=detected calls={len(tool_calls)} tool={tc["name"]} args={args_str}')
    else:
        content_preview = raw_content[:500] if isinstance(raw_content, str) else str(raw_content)[:500]
        _debug_log(f'stage=NONE calls=0 content_preview={content_preview}')

    return tool_calls


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', help='Model name to load config from .configs/')
    ap.add_argument('--probe', action='store_true', help='Detect parser stage and exit')
    ap.add_argument('--fallback', action='store_true', help='Fallback to all stages if configured stage fails')
    ap.add_argument('--context', help='Current step context (create/compile/run) for Format C models')
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
    configured_stage = None
    if args.model:
        config_dir = os.path.join(os.path.dirname(__file__), '.configs')
        config_path = os.path.join(config_dir, f'{args.model}.config.json')
        if os.path.exists(config_path):
            with open(config_path) as f:
                config = json.load(f)
                configured_stage = config.get("stage")
                if configured_stage is not None:
                    skip = set(range(1, 9)) - {configured_stage}

    try:
        raw_input = sys.stdin.read()
        data = json.loads(raw_input)

        if args.fallback:
            if configured_stage is not None:
                # First try configured stage
                result = parse_response(data, skip, context=args.context)
                if result:
                    print(json.dumps(result))
                    sys.exit(0)
                _debug_log(f'CONFIGURED STAGE {configured_stage} FAILED, trying all stages', model=args.model)
            # Fallback: try all stages, prioritizing common ones
            # Skip stages 6 and 7 when context is compile/run (model ignoring tools)
            stages_to_try = [1, 3, 4, 5, 8] if args.context in ('compile', 'run') else [1, 3, 4, 5, 6, 7, 8]
            for stage in stages_to_try:
                result = parse_response(data, skip=set(range(1, 9)) - {stage}, context=args.context)
                if result:
                    print(json.dumps(result))
                    sys.exit(0)
            _debug_log('ALL STAGES FAILED', model=args.model)
            print("[]")
        else:
            result = parse_response(data, skip, context=args.context)
            print(json.dumps(result))
    except Exception:
        _debug_log('EXCEPTION in main: parse failure', model=args.model)
        print("[]")
