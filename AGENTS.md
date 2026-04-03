# AGENTS.md — Read This First

> This is the orientation document for any agent (AI or human) starting a session on this project.
> If you have no context, this file gives you enough to navigate, modify, and extend the codebase
> without breaking established structure. When in doubt, read this file again.

---

## 1. Environment & Build (Copy-Paste Ready)

```bash
export PATH="$HOME/Odin:$PATH"
cd /home/mando/dev/gamedev/pixel

# Type-check only (fast — run after every edit)
odin check source -vet -no-entry-point

# Build (compiles shaders, builds DLL + exe, runs hot-reload)
python3 build.py -hot-reload

# If the exe is already running, just rebuild the DLL:
python3 build.py -hot-reload
# → the running exe detects the new DLL and hot-reloads

# Release build
python3 build.py -release
```

- **OS**: Fedora 43
- **Odin**: `~/Odin/odin` (dev-2026-04). APIs differ from older examples — see § Traps.
- **Project root**: `/home/mando/dev/gamedev/pixel/`

---

## 2. How to Navigate (Agent Quickstart)

**Where is the state?** → `game.odin`: `Game_Memory` struct. Everything persistent lives here.

**Where is the frame loop?** → `game.odin`: `game_frame()`. Passes execute in order. Follow the calls.

**Where does pass X live?** → Each rendering stage has its own `.odin` + `.glsl` file pair.
The file name matches the stage name. `game.odin` calls them in pipeline order.

**Where are the types?** → `math_utils.odin` for `Mat4`, `Vec3`, etc. These are mapped to GLSL
via `@ctype` in every shader file. Rename a type here → update every `.glsl` `@ctype` line.

**Where are the sokol bindings?** → `source/sokol/gfx/gfx.odin` is the source of truth for types
and proc signatures. When the implementation plan and actual bindings disagree, trust the bindings.

### File Map

```
source/
├── game.odin              # Frame loop, Game_Memory, pass orchestration
├── camera.odin            # First-person camera (pos/yaw/pitch → view/proj matrices)
├── input.odin             # Key/mouse state from sokol events → key_held[], mouse_move
├── math_utils.odin        # Type aliases (Mat4, Vec3...) + matrix builders
├── scene.odin             # Test geometry (ground, boxes). Owns vertex/index buffers.
├── shadow.odin            # Shadow map texture + depth-only render pass from sun.
├── shadow.glsl            # Depth-only shadow caster shader.
├── forward.glsl           # Forward-lit shader (debug/fallback, Tab key).
├── probe.odin             # Probe origins, face matrices, transition state, face masks.
├── gbuffer.odin           # G-buffer textures/views (18 layers), MRT capture passes.
├── gbuffer.glsl           # G-buffer vertex/fragment (MRT output).
├── debug_vis.glsl         # Debug visualization (Tab key: albedo/normal/radial/lit).
├── edge_mask.odin         # Edge mask texture, per-texel continuity pass.
├── edge_mask.glsl         # Fullscreen fragment — radial neighbor comparison, RGBA8 mask.
├── lighting.odin          # Lighting pass (18 layers), fullscreen shading.
├── lighting.glsl          # G-buf + shadow + outlines + posterization + sky.
├── splat.odin             # Multi-probe splat + background + edge mask + haze.
├── splat.glsl             # Splat with Bayer crossfade, edge mask, haze.
├── background.glsl        # Fullscreen sky from eye probe cubemap + distance haze.
├── post.odin              # Offscreen render target + nearest-neighbor upscale.
├── post.glsl              # Fullscreen blit with gamma correction.
├── gen__*.odin            # Sokol-shdc generated shader bindings (build artifact).
├── main_hot_reload/       # Dev exe entry point (DLL loader + file watcher)
├── main_release/          # Release exe entry point (static link)
└── sokol/                 # Vendored bindings (gitignored, downloaded by build.py)
```

---

## 3. Ownership Rules (Who Touches What)

Each file owns one concern. Cross-file dependencies flow in one direction.
**If you need to add behavior, put it in the file that OWNS that concern.**

| File | Owns | Depends On | Depended On By |
|------|------|------------|----------------|
| `game.odin` | `Game_Memory`, frame orchestration, pass ordering | everything | `main_hot_reload/`, `main_release/` |
| `camera.odin` | Camera struct, yaw/pitch, view/proj matrices | `math_utils`, `input` (reads `key_held[]`) | `game.odin` |
| `input.odin` | Event processing, `key_held[]`, `mouse_move` | sokol/app events | `camera.odin`, `game.odin` |
| `math_utils.odin` | `Mat4`, `Vec3`, matrix utilities | nothing | everything |
| `scene.odin` | Geometry data, vertex/index buffers | `math_utils` | `shadow.odin`, `game.odin` |
| `shadow.odin` | Shadow map texture, shadow render pass | `scene.odin` (draws geometry) | `game.odin`, `lighting.glsl` |
| `probe.odin` | Probe constants, cubemap face matrices | `math_utils` | `gbuffer.odin`, `splat.odin` |
| `gbuffer.odin` | G-buffer textures, MRT views, capture pass | `scene.odin`, `probe.odin` | `edge_mask.odin`, `lighting.odin`, `splat.odin` |
| `edge_mask.odin` | Edge mask texture, per-texel continuity pass | `gbuffer.odin` (reads radial) | `splat.odin` |
| `lighting.odin` | Lit texture, fullscreen lighting pass + outlines | `gbuffer.odin`, `shadow.odin` | `splat.odin` |
| `splat.odin` | Splat + background pipelines, draw calls | `gbuffer.odin`, `lighting.odin`, `edge_mask.odin`, `camera.odin` | `post.odin`, `game.odin` |
| `post.odin` | Offscreen render target, nearest-neighbor upscale + gamma | `splat.odin` (renders to offscreen) | `game.odin` |

**Rule: data flows downward in the pass order.** Shadow map → G-buffer → edge mask → lighting → splat → post → screen.
A later pass may read a texture produced by an earlier pass, but never the reverse.

---

## 4. Data Flow Conventions

### Why this matters

When an agent modifies a shader or a texture format, it needs to know: who writes this data?
who reads it? what format are they expecting? A change to one end of a data flow without updating
the other end creates silent corruption (wrong colors, black screen, no errors).

### Annotation pattern

Every GPU resource that crosses pass boundaries gets a data flow comment:

```odin
// ── Data flow ──
// Written by: shadow pass (depth-only draw of scene from sun POV)
// Read by:    lighting.glsl (shadow comparison via texture2D + sampler)
// Format:     DEPTH_STENCIL, 2048×2048
// Lifetime:   created in shadow_init(), destroyed in shadow_cleanup()
shadow_depth_img := sg.make_image({ ... })
```

### Annotation pattern (shader side)

```glsl
// ── Data flow ──
// Bound as: views[VIEW_shadow_tex] in lighting pass (game.odin)
// Produced by: shadow.odin depth-only pass
// Coordinate space: light clip space → [0,1] UV after perspective divide
layout(binding=0) uniform texture2D shadow_tex;
```

### Cross-file references

When a value's meaning is defined in another file or doc, say where:

```odin
// Face index 0..5 — ordering matches TEXEL_SPLATTING_ESSENCE.md § "Cubemap Face ↔ Direction Mapping"
// and must agree with gbuffer.glsl face_dir() and probe.odin cube_face_view()
face: int,
```

---

## 5. Structural Rules

These exist to prevent drift. Follow them even when it feels like overkill for a small change.

### One concern per file

If `shadow.odin` starts growing lighting logic, that logic belongs in `lighting.odin`.
`game.odin` is the orchestrator — it calls into stage files, it doesn't implement stages.

### State lives in Game_Memory

All frame-to-frame state goes in `Game_Memory`. No file-level mutable globals except
the input state (`key_held`, `mouse_move`) which is inherently per-frame and reset each frame.

### Hot reload safety

- Pipelines embed shader bytecode pointers → **must** be recreated in `game_hot_reloaded()`.
- GPU images/views/samplers survive hot reload (handles, not pointers).
- If you add a new pipeline, add its recreation to `game_hot_reloaded()`.

### Shader ↔ Odin coupling

- Every `.glsl` needs `@header package game` and `@ctype` lines matching `math_utils.odin` types.
- sokol-shdc generates `gen__foo.odin` with binding slot constants (`VIEW_foo`, `SMP_bar`, `SLOT_params`).
- **Never hardcode binding indices** — use the generated constants.
- If a shader uniform struct changes, the Odin side calling `sg.apply_uniforms()` must match exactly.

### New rendering stage checklist

When adding a new stage (e.g., M1 adds `shadow.odin`):

1. Create `stage.odin` with `stage_init()`, `stage_cleanup()`, and `stage_draw()` (or `stage_pass()`)
2. Add stage state as fields on `Game_Memory`
3. Call `stage_init()` from `game_init()`
4. Call `stage_draw()` from `game_frame()` in the correct pass order
5. Call `stage_cleanup()` from `game_cleanup()`
6. If it has a pipeline → recreate in `game_hot_reloaded()`
7. Update § File Map in this file

---

## 6. Traps & Pitfalls

### Don't copy Karl's sokol patterns

`odin-sokol-first-person-shadow-mapping/` uses the **old** sokol API:
- ~~`sg.make_attachments({colors = {0 = {image = img}}})`~~ → **use `sg.make_view()`**
- ~~`bindings.images[IMG_foo]`~~ → **use `bindings.views[VIEW_foo]`**
- ~~`{render_target = true}`~~ → **use `{usage = {color_attachment = true}}`**

Correct patterns: `IMPLEMENTATION_PLAN.md` § "Sokol API Patterns".

### Don't copy Karl's Odin patterns for os/time

Odin `dev-2026-04` has modernized `core:os`:
- No `core:os/os2` — merged into `core:os`
- `os.last_write_time_by_name()` → `os.modification_time_by_path()`
- `os.open()` takes flag bit_set `{.Create, .Trunc, .Read, .Write}`, not int bitmasks

### Sokol default face winding is CW — set `.CCW` on every culled pipeline

Sokol defaults to `face_winding = .CW` (clockwise front faces). Our vertex data
uses **CCW winding** (standard OpenGL). Any pipeline with `cull_mode = .BACK`
**must** also set `face_winding = .CCW`, otherwise front faces are culled and
geometry renders inside-out with flipped normals.

```odin
sg.make_pipeline({
    cull_mode    = .BACK,
    face_winding = .CCW,  // REQUIRED — sokol defaults to .CW!
})
```

Symptoms: normals inverted (lit surfaces dark, unlit bright), shadows on wrong
side, ground visible from below but not above.

### Sokol binding is the source of truth

When any doc (including this one) disagrees with what `source/sokol/gfx/gfx.odin` says,
trust the binding file. It's the actual code that compiles.

### R32UI may not work as a render target

Entity ID texture: prefer `R32F` with `intBitsToFloat` / `floatBitsToInt`, or pack into
alpha of another RGBA8 target. Check `sg.query_pixelformat(.R32UI).render` at init time.

---

## 7. Reference Documents

| Doc | Location | When to read |
|-----|----------|--------------|
| `AGENTS.md` | `AGENTS.md` (this file) | Every new session — orientation and conventions |
| `IMPLEMENTATION_PLAN.md` | `.pi/IMPLEMENTATION_PLAN.md` | Starting a milestone, sokol API patterns, pass structure |
| `TEXEL_SPLATTING_ESSENCE.md` | `.pi/TEXEL_SPLATTING_ESSENCE.md` | Algorithm math — cubemap directions, distance encoding, quad expansion |
| Reference WGSL shaders | [texel-splatting](https://github.com/dylanebert/texel-splatting) `src/splat.ts` | Reference WGSL shaders for splat/lighting (search for `fn vs(`, `fn main(`) |
| `source/sokol/gfx/gfx.odin` | Vendored binding | When any sokol type/proc signature is unclear |

All `.pi/` paths are relative to the project root (`/home/mando/dev/gamedev/pixel/`).

The implementation plan has a "What to Read When Implementing" table — use it to find
the right section of the essence doc for each stage.
