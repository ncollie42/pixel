#!/bin/bash
# Usage: .pi/run-milestone.sh <N>
# Spawns a pi agent in a new tmux window to execute milestone N.
# Run from the pixel/ project root.

set -e

N=${1:?Usage: .pi/run-milestone.sh <milestone-number>}
AI_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$AI_DIR/.."
PROMPT_FILE="$AI_DIR/prompts/milestone-${N}.md"

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: $PROMPT_FILE not found"
    exit 1
fi

SESSION_NAME="milestone-${N}"

echo "Launching Milestone ${N} agent in tmux window '${SESSION_NAME}'..."
echo "  Working dir: $PROJECT_DIR"
echo "  Context:     AGENTS.md, IMPLEMENTATION_PLAN.md, TEXEL_SPLATTING_ESSENCE.md"

tmux new-window -n "$SESSION_NAME" \
    "export PATH='/home/mando/Odin:/usr/local/bin:/usr/bin:\$PATH'; \
     cd $PROJECT_DIR; \
     pi --no-session \
        @$PROJECT_DIR/AGENTS.md \
        @$AI_DIR/IMPLEMENTATION_PLAN.md \
        @$AI_DIR/TEXEL_SPLATTING_ESSENCE.md \
        @${PROMPT_FILE}; \
     echo '--- MILESTONE ${N} DONE --- press Enter to close'; read"
