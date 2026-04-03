# Milestone Orchestration Workflow

How to break a project into milestones and execute them via sub-agents in tmux.

## Overview

1. Write an **implementation plan** with numbered milestones
2. Write a **prompt file** per milestone (`prompts/milestone-N.md`)
3. An **orchestrator agent** (or human) runs each milestone via `run-milestone.sh`
4. After each milestone: verify build, test, fix issues, then proceed

## Setup

### Required files

```
project/
├── .pi/
│   ├── AGENTS.md                # project context for all agents
│   ├── IMPLEMENTATION_PLAN.md   # full milestone breakdown
│   ├── TEXEL_SPLATTING_ESSENCE.md # domain-specific reference (optional)
│   ├── prompts/
│   │   ├── milestone-2.md       # prompt for each milestone
│   │   ├── milestone-3.md
│   │   └── ...
│   └── run-milestone.sh         # launches a pi agent in a tmux window
├── source/                      # actual pixel code
└── build.py
```

### run-milestone.sh

```bash
#!/bin/bash
set -e
N=${1:?Usage: ./run-milestone.sh <milestone-number>}
PROMPT_FILE="prompts/milestone-${N}.md"
[ ! -f "$PROMPT_FILE" ] && echo "Error: $PROMPT_FILE not found" && exit 1

SESSION_NAME="milestone-${N}"
echo "Launching Milestone ${N} agent in tmux window '${SESSION_NAME}'..."

tmux new-window -n "$SESSION_NAME" \
    "export PATH='/home/mando/Odin:/usr/local/bin:/usr/bin:\$PATH'; \
     cd $(pwd); \
     pi --no-session @AGENTS.md @.pi/IMPLEMENTATION_PLAN.md @${PROMPT_FILE}; \
     echo '--- MILESTONE ${N} DONE --- press Enter to close'; read"
```

Key points:
- `@file` syntax passes file contents as context to pi
- `--no-session` prevents session state leaking between milestones
- The tmux window name makes it easy to monitor progress
- PATH must include the Odin compiler, node, and pi binary

### Milestone prompt format

Each `prompts/milestone-N.md` should:

```markdown
Read @.pi/IMPLEMENTATION_PLAN.md and @AGENTS.md fully.
Then read ALL source/*.odin and source/*.glsl files.

Milestones 1-(N-1) are complete.

Implement Milestone N: <Title>.

Goal: <one sentence>

Tasks:
1. <specific task with file names>
2. <specific task>
...

Build and test: `export PATH="..." && python3 build.py -hot-reload`

Important: <any critical gotchas for this milestone>
```

## Orchestrator workflow

The orchestrator (parent agent or human) runs this loop:

```
for N in 2..8:
    ./run-milestone.sh N
    wait for completion (monitor tmux pane)
    verify:
        - build passes: python3 build.py -hot-reload
        - runtime test: timeout 3 ./game_hot_reload.bin
        - read changed source files for obvious issues
    if errors:
        fix them before proceeding
    proceed to N+1
```

### Monitoring a milestone agent

```bash
# Check if still running
tmux capture-pane -t main:milestone-N -p | tail -20

# Check for build results
tmux capture-pane -t main:milestone-N -p -S -100 | grep -i "build\|error\|Took"

# Kill a stuck agent
tmux send-keys -t main:milestone-N C-c
```

### Post-milestone verification

```bash
export PATH="/home/mando/Odin:$PATH"

# 1. Build
python3 build.py -hot-reload

# 2. Quick runtime test (should not crash)
timeout 3 ./game_hot_reload.bin

# 3. Type check
odin check source -vet -no-entry-point
```

## Lessons learned

### Agent context matters
- Sub-agents need ALL relevant context files (`@AGENTS.md`, `@.pi/IMPLEMENTATION_PLAN.md`)
- Missing reference docs → agents hallucinate APIs or skip steps
- Symlink shared docs if they live in a parent directory

### PATH in tmux
- tmux windows inherit a minimal PATH — explicitly include tool directories
- Node, pi, odin, and system binaries all need to be reachable

### Fix bugs between milestones
- Don't let errors accumulate — each milestone builds on the previous
- The orchestrator is responsible for verifying and fixing before proceeding
- Common issues: missing imports, name collisions in sokol-shdc constants,
  API misuse (like the sokol face_winding default)

### Visual verification catches what builds don't
- A clean build does NOT mean correct rendering
- Run the app and visually inspect after non-trivial rendering changes
- Add debug visualization modes (normal view, shadow view, NdotL view)
  early — they're invaluable for diagnosing issues
