# .pi/ — AI Orchestration Artifacts

Everything in this directory is for **building pixel with Claude**, not
part of pixel itself. The pixel renderer lives in the parent directory (`../`).

## Contents

| File | Purpose |
|------|---------|
| `AGENTS.md` | Agent context (lives at project root, auto-loaded by pi) |
| `IMPLEMENTATION_PLAN.md` | Full milestone breakdown with sokol API patterns |
| `TEXEL_SPLATTING_ESSENCE.md` | Algorithm reference (cubemap math, distance encoding, etc.) |
| `milestone-orchestration.md` | How the milestone workflow works |
| `run-milestone.sh` | Launches a pi agent in tmux for a given milestone |

## Usage

```bash
cd /home/mando/dev/gamedev/pixel
.pi/run-milestone.sh 2    # run milestone 2 agent in tmux
```
