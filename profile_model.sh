#!/usr/bin/env bash

set +H
set -e

MODEL="${1:-qwen2.5-coder:7b}"
SPEC_FILE="prompt.hashprime.info"
OLLAMA_URL="http://localhost:11434/api/chat"

CONFIG_DIR=".configs"
mkdir -p "$CONFIG_DIR"

SANITIZED_MODEL=$(echo "$MODEL" | sed 's/[/:]/_/g')
RAW_RESPONSE_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.raw.json"
PARSER_FILE="$CONFIG_DIR/${SANITIZED_MODEL}.sh"

echo "=========================================="
echo "🔍 Profiling model: $MODEL"
echo "=========================================="

if [ ! -f "$SPEC_FILE" ]; then
    echo "Error: $SPEC_FILE not found."
    exit 1
fi

SPEC_TEXT=$(cat "$SPEC_FILE")
SYSTEM_PROMPT="You are an automated software engineer. ALWAYS follow this strict action sequence: 1) write_file, 2) javac, 3) java. Never attempt to run 'java' before 'javac' succeeds. Test N=11 and N=1000, then stop."

MESSAGES=$(jq -n \
  --arg sys "$SYSTEM_PROMPT" \
  --arg spec "$SPEC_TEXT" \
  '[
    {role: "system", content: $sys},
    {role: "user", content: $spec}
  ]')

TOOLS='[
  {
    "type": "function",
    "function": {
      "name": "write_file",
      "description": "Writes Java source code to disk.",
      "parameters": {
        "type": "object",
        "properties": {
          "filename": { "type": "string" },
          "content": { "type": "string" }
        },
        "required": ["filename", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "javac",
      "description": "Compiles a Java source file.",
      "parameters": {
        "type": "object",
        "properties": {
          "filename": { "type": "string" }
        },
        "required": ["filename"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "java",
      "description": "Runs a compiled Java class.",
      "parameters": {
        "type": "object",
        "properties": {
          "class_name": { "type": "string" },
          "args": { 
            "type": "array", 
            "items": { "type": "string" }
          }
        },
        "required": ["class_name"]
      }
    }
  }
]'

PAYLOAD=$(jq -s --arg model "$MODEL" \
  '{model: $model, messages: .[0], tools: .[1], stream: false}' \
  <(echo "$MESSAGES") <(echo "$TOOLS"))

echo "--> Sending probe request to Ollama..."
RESPONSE=$(curl -s "$OLLAMA_URL" -H "Content-Type: application/json" -d "$PAYLOAD")

echo "$RESPONSE" > "$RAW_RESPONSE_FILE"
echo "📊 Saved raw response to: $RAW_RESPONSE_FILE"

cat << 'PARSER_EOF' > "$PARSER_FILE"
#!/usr/bin/env bash

python3 - << 'PYEOF'
import sys
import json
import re

REGEX_XML_WRITE = bytes.fromhex('3c77726974655f66696c655c732b66696c656e616d653d22285b5e225d2b29225c732b636f6e74656e743d22285b5e225d2b2922').decode('utf-8')
REGEX_XML_JAVAC = bytes.fromhex('3c6a617661635c732b66696c656e616d653d22285b5e225d2b2922').decode('utf-8')
REGEX_XML_JAVA = bytes.fromhex('3c6a6176615c732b636c6173735f6e616d653d22285b5e225d2b2922283a3f5c732b617267733d22285b5e225d2b2922293f').decode('utf-8')
REGEX_JAVA_BLOCKS = bytes.fromhex('606060283a3f6a617661293f5c732a5c6e282e2a3f7075626c69635c732b636c6173735c732b285b412d5a612d7a302d395f5d2b292e2a3f29606060').decode('utf-8')
REGEX_SH_CMDS = bytes.fromhex('606060283a3f73687c62617368293f5c732a5c6e282e2a3f295c6e606060').decode('utf-8')

try:
    data = json.load(sys.stdin)
except Exception:
    print("[]")
    sys.exit(0)

tool_calls = []

native = data.get("message", {}).get("tool_calls", [])
if native:
    for tc in native:
        func = tc.get("function", {})
        tool_calls.append({"name": func.get("name"), "arguments": func.get("arguments")})

if not tool_calls:
    content = data.get("message", {}).get("content", "") or ""
    decoder = json.JSONDecoder()
    pos = 0
    while pos < len(content):
        match = content.find("{", pos)
        if match == -1:
            break
        try:
            obj, end = decoder.raw_decode(content[match:])
            if isinstance(obj, dict) and "name" in obj:
                tool_calls.append({"name": obj["name"], "arguments": obj.get("arguments", {})})
            pos = match + end
        except Exception:
            pos = match + 1

if not tool_calls:
    content = data.get("message", {}).get("content", "") or ""
    xml_write = re.findall(REGEX_XML_WRITE, content, re.DOTALL)
    for fn, cnt in xml_write:
        tool_calls.append({"name": "write_file", "arguments": {"filename": fn, "content": cnt}})

    xml_javac = re.findall(REGEX_XML_JAVAC, content)
    for fn in xml_javac:
        tool_calls.append({"name": "javac", "arguments": {"filename": fn}})

    xml_java = re.findall(REGEX_XML_JAVA, content)
    for cn, args_str in xml_java:
        try:
            args = json.loads(args_str.replace('\\"', '"')) if args_str else []
        except Exception:
            args = [args_str] if args_str else []
        tool_calls.append({"name": "java", "arguments": {"class_name": cn, "args": args}})

if not tool_calls:
    content = data.get("message", {}).get("content", "") or ""
    java_blocks = re.findall(REGEX_JAVA_BLOCKS, content, re.DOTALL)
    for code_body, class_name in java_blocks:
        tool_calls.append({
            "name": "write_file",
            "arguments": {"filename": f"{class_name}.java", "content": code_body.strip()}
        })

if not tool_calls or all(tc["name"] == "write_file" for tc in tool_calls):
    content = data.get("message", {}).get("content", "") or ""
    sh_cmds = re.findall(REGEX_SH_CMDS, content, re.DOTALL)
    for block in sh_cmds:
        for line in block.splitlines():
            line = line.strip()
            if line.startswith("javac "):
                parts = line.split()
                if len(parts) > 1:
                    tool_calls.append({"name": "javac", "arguments": {"filename": parts[1]}})
            elif line.startswith("java "):
                parts = line.split()
                if len(parts) > 1:
                    cn = parts[1]
                    args = parts[2:] if len(parts) > 2 else []
                    tool_calls.append({"name": "java", "arguments": {"class_name": cn, "args": args}})

print(json.dumps(tool_calls))
PYEOF
PARSER_EOF

chmod +x "$PARSER_FILE"
echo "✅ Custom parser created at: $PARSER_FILE"
chmod +x profile_model.sh
