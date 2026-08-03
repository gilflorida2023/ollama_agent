# Plan: Add skill_recorder.py Usage to README

## Goal

Educate users on how to use `skill_recorder.py` from the command line to manage the OKF knowledge bundle.

## Where to Insert

README.md — after the OKF Tools section, before "Creating a New Skill — Step by Step".

## Content to Add

### Using skill_recorder.py (CLI)

The `skill_recorder.py` script provides a command-line interface to manage the OKF knowledge bundle directly (outside of the agent loop).

#### Commands

| Command | Description |
|---------|-------------|
| `seed` | Seed the bundle with existing skills from the codebase (run once) |
| `record` | Record a new skill, failure mode, model profile, or strategy |
| `search` | Search by tags or type |
| `list` | List all recorded skills |

#### seed — Populate from Codebase

```bash
python3 skill_recorder.py seed
```

Seeds 16 concepts: 10 parser skills, 2 failure modes, 2 strategies, 2 model profiles.

#### record — Add a New Skill

```bash
# Basic syntax
python3 skill_recorder.py record <category> <id> <title> <tags> [body]

# Categories: skills, failure-modes, model-profiles, strategies

# Example: Record a new skill
python3 skill_recorder.py record skills "prime-factors" "Prime Factorization" "math,number-theory" "## Description\n\nAccepts integer N, returns prime factors."

# Example: Record a failure mode
python3 skill_recorder.py record failure-modes "infinite-loop" "Infinite Loop" "failure,loop" "## Symptom\n\nAgent repeats same failing command..."

# Example: Record a model profile
python3 skill_recorder.py record model-profiles "llama3" "Llama3 Profile" "model,llama" "## Model: llama3\n\n### Characteristics\n- ..."
```

#### search — Find Skills

```bash
# Search by tags (comma-separated)
python3 skill_recorder.py search --tags "parser,java"

# Search by type
python3 skill_recorder.py search --type "Failure Mode"

# Combine both
python3 skill_recorder.py search --tags "model" --type "Model Profile"
```

#### list — Show All Skills

```bash
python3 skill_recorder.py list
```

Output:
```
skills/ (12 entries)
  native-tool-call-extraction — Native Tool Call Extraction [parser, stage-1, gemma4]
  think-tag-stripping — Think-tag Stripping [parser, preprocessing, qwen]
  ...

failure-modes/ (2 entries)
  compile-before-write — Compile-before-write Loop [failure, java, sequence]
  ...
```

### File Structure Created

```
knowledge/
├── trusted_bundles/          # Human-vetted / approved content
│   ├── skills/
│   │   ├── index.json        # Machine-readable index
│   │   ├── index.md          # Human-readable index
│   │   ├── think-tag-stripping.md
│   │   └── ...
│   ├── failure-modes/
│   │   ├── index.json
│   │   ├── index.md
│   │   ├── compile-before-write.md
│   │   └── ...
│   ├── model-profiles/
│   │   ├── index.json
│   │   ├── index.md
│   │   ├── qwen2.5-coder.md
│   │   └── ...
│   └── strategies/
│       ├── index.json
│       ├── index.md
│       ├── single-task-focus.md
│       └── ...
└── new_bundles/              # Agent-created / unvetted content
    └── skills/
        └── ...
```

## Files Modified

| File | Change |
|------|--------|
| `README.md` | Insert ~70 lines after OKF Tools section |

## Notes

- `skill_recorder.py` writes to `knowledge/trusted_bundles/` (human-managed)
- `create_skill` in `complete.sh` writes to `knowledge/new_bundles/` (agent-created)
- Promote with `promote_skill` tool or `mv` manually
