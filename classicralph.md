The Ralph Loop Architecture: Characteristics & Persistent State Guide

The Ralph Loop is a long-running, autonomous agent pattern designed for complex software development and benchmarking over an extended horizon. By treating the local filesystem—rather than the LLM's chat window—as the primary source of memory, it avoids context window decay ("context rot") and enables reliable, long-horizon task completion.

1. Key Architectural Characteristics

A. Fresh Context Every Turn (Zero Chat Memory)

Problem Addressed: As conversation logs grow, models slow down, lose track of initial constraints, and suffer reasoning degradation.

Ralph Solution: Every execution loop turn initializes a completely fresh, unpolluted context window. Memory is re-established dynamically by reading physical files on disk at the start of each session.

B. Layered Abstraction (Manager vs. Worker Agent)

ralph.sh (The Manager / Orchestrator): Manages long-term state across turns. It tracks task completion, updates state ledgers, verifies physical files on disk, handles Git commits, and manages loop iterations.

complete.sh (The Worker Agent): Handles single-session interaction with the LLM API. It communicates with Ollama, passes model outputs to parser.py, and executes physical actions (write_file, javac, java).

C. Single-Task Focus

Instead of asking an LLM to build, compile, test, and debug an entire application in one shot, the Ralph Loop forces the worker agent to pick and solve only one discrete task per turn.

D. Self-Healing via Version Control

Every successful turn produces an atomic Git checkpoint. If a model generates non-compiling code or corrupts the workspace, the system can perform a rollback (git reset --hard) to the last known working state before retrying.

2. Persistent Files Breakdown

The table below outlines every persistent file in the Ralph Loop ecosystem, its core purpose, and how it gets created or updated.

File Path

Core Purpose

Created By

How & When It Is Updated

prompt.hashprime.info

Primary task specification (read-only requirements).

User / System Author

Static / Read-Only: Never updated by the agent loop; serves as the fixed ground truth specification.

tasks.json

Machine-readable task ledger tracking sub-goals and pass/fail states.

ralph.sh (Phase 1)

Updated by ralph.sh at the end of each turn. When generated output files (e.g., hashprime.java or hashprime.class) exist and pass checks, their status flips from "failing" to "passing".

progress.txt

Human-readable audit log tracking session history and notes across turns.

ralph.sh (Phase 1)

Appended by ralph.sh after every turn with timestamped session entries, goals attempted, and execution exit statuses.

.git/ (Git Repo)

Atomic rollback save points and version control history.

ralph.sh (git init)

Updated by ralph.sh via git add -A and git commit at the end of every turn where files were modified.

.configs/<model>.sh

Executable parser wrapper for a specific LLM.

profile_model.sh

Created once during model profiling. Configures parser.py to handle a specific model's output format.

.configs/<model>.config.json

Stage-skipping configuration for model parsing.

profile_model.sh

Created once during profiling to tell parser.py which parsing stages to skip for optimal performance.

.configs/<model>.raw.json

Inspection log storing the initial probe response from Ollama.

profile_model.sh

Written once when profiling a new model to capture raw model output for debugging.

hashprime.java

Generated Java source code.

complete.sh via parser.py

Written or overwritten by complete.sh whenever the LLM issues a valid write_file tool action.

hashprime.class

Compiled Java bytecode binary.

javac via complete.sh

Generated or updated by complete.sh when the javac compilation tool action succeeds.

3. How Persistent Files Work Together Across a Turn

                     +---------------------------+
                     |  prompt.hashprime.info    |
                     +-------------+-------------+
                                   |
                                   v
+----------------------------------+----------------------------------+
|                       RALPH.SH (Manager)                            |
|                                                                     |
|  1. Reads `tasks.json` to identify the next "failing" task          |
|  2. Reads `progress.txt` & Git history for orientation              |
|  3. Spawns fresh worker session via `complete.sh`                   |
+----------------------------------+----------------------------------+
                                   |
                                   v
+----------------------------------+----------------------------------+
|                      COMPLETE.SH (Worker)                           |
|                                                                     |
|  1. Queries Ollama API in a fresh context window                    |
|  2. Uses `.configs/<model>.sh` & `parser.py` to decode tool actions  |
|  3. Writes `hashprime.java` to disk                                 |
|  4. Runs `javac` to generate `hashprime.class`                      |
+----------------------------------+----------------------------------+
                                   |
                                   v
+----------------------------------+----------------------------------+
|                       RALPH.SH (Manager)                            |
|                                                                     |
|  1. Verifies physical artifacts (`hashprime.java`, `.class`)        |
|  2. Updates task statuses in `tasks.json`                           |
|  3. Appends entry to `progress.txt`                                 |
|  4. Creates a `git commit` snapshot of the working state            |
+---------------------------------------------------------------------+


4. Summary of Operational Flow

Orientation: The manager (ralph.sh) opens tasks.json to find the first task marked "failing".

Execution: It invokes complete.sh, which queries the model with a fresh context window and executes physical tool calls (write_file, javac, java).

Verification: complete.sh finishes its turn, and ralph.sh checks disk artifacts to verify progress.

Persistence & Commit: ralph.sh updates tasks.json, appends progress notes to progress.txt, and commits all changes to Git.

Next Turn: The context resets completely, and the loop repeats with the updated disk state.
