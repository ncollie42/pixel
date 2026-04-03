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

**What milestone are we on?** → Check § Milestone Status at the bottom of this file.

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

## 5. Comment Philosophy — Notes to Future Self

> Write comments as if the reader has **zero context** and is **reading this file for the first time
> in 6 months**. Because that's exactly what will happen — either for a human returning to the
> project, or for an AI agent starting a fresh session.

### What to comment

| Situation | Comment style | Example |
|-----------|--------------|---------|
| **Why, not what** | Explain the reason, not the mechanics | `// Bias depth slightly to avoid shadow acne on surfaces facing the light` |
| **Tricky math** | Cite the source formula | `// Chebyshev distance — see TEXEL_SPLATTING_ESSENCE.md § "Distance Encoding"` |
| **Non-obvious sokol calls** | Explain what the API is doing | `// make_view wraps an image slice for use as a render target attachment` |
| **Format coupling** | Note what must match | `// RGBA8 here must match the pixel_format in the pipeline color attachment` |
| **Magic numbers** | Name the constant or explain derivation | `// 0.999 threshold: radial >= this means sky (no geometry hit)` |
| **Intentional deviation** | Explain why we're not doing the "obvious" thing | `// Using R32F for entity ID instead of R32UI — R32UI not guaranteed as render target` |
| **Workarounds** | Mark with WORKAROUND so they can be found and removed later | `// WORKAROUND: sokol-shdc doesn't generate correct binding index — hardcode for now` |

### What NOT to comment

- Obvious Odin syntax (`i += 1  // increment i`)
- Struct field types that are self-documenting
- Anything the function/variable name already says clearly

### File-level header

Every `.odin` file starts with a one-line comment saying what it owns and its role:

```odin
// shadow.odin — Shadow map rendering. Owns the depth texture, light matrices, and shadow draw pass.
```

Every `.glsl` file starts with the sokol-shdc header block plus a brief description:

```glsl
// Shadow caster — depth-only pass from the sun's point of view.
// Writes to: shadow depth texture (sampled by lighting.glsl)
@header package game
@header import sg "sokol/gfx"
...
```

---

## 6. Structural Rules

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
7. Update § File Map and § Milestone Status in this file

---

## 7. Traps & Pitfalls

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

## 8. Reference Documents

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

---

## 9. Milestone Status

- [x] **M0**: Scaffold — window, camera, input, hot reload. All working.
- [x] **M1**: Scene + shadow map — test geometry, shadow depth pass, forward-lit verify.
- [x] **M2**: Single probe G-buffer — cubemap MRT capture, debug vis.
- [x] **M3**: Lighting pass — fullscreen fragment shading per face.
- [x] **M4**: Splat render — instanced quads from cubemap texels. **← the magic moment**
- [x] **M5**: Grid probe + crossfade — second probe, Bayer dithering.
- [x] **M6**: Prev probe + full transition — third probe, smooth crossfade.
- [x] **M7**: Edge masks + outlines — silhouette cleanup, entity boundaries.
- [x] **M8**: Posterization + polish — OKLab quantization, haze, upscale.

### M0 Deliverables (complete)

- `game.odin`: Game_Memory, init/frame/cleanup, hot-reload lifecycle
- `camera.odin`: First-person camera with yaw/pitch, view/proj matrices
- `input.odin`: WASD + mouse look, key_held/key_pressed/mouse_move
- `math_utils.odin`: Mat4/Vec3/Vec4 aliases, perspective, look_at, model_matrix
- Window opens, clears to sky blue, camera moves with WASD + mouse

### M1 Deliverables (complete)

- `scene.odin`: ground plane + boxes (vertex buffer: position + normal)
- `shadow.odin`: shadow depth texture (2048²), depth-only pass from sun
- `shadow.glsl`: depth-only vertex shader (RGBA8 encoded depth)
- `forward.glsl`: forward-lit fragment shader sampling shadow map
- Verify: scene renders with diffuse lighting + shadows on screen

### M2 Deliverables (complete)

- `probe.odin`: 90° FOV cube perspective, per-face view matrices, face_uv_to_dir
- `gbuffer.odin`: G-buffer textures (albedo/normal/radial/depth, 384×384×6 array)
- `gbuffer.glsl`: MRT capture shader (albedo + octahedral normal + Chebyshev radial)
- `debug_vis.glsl`: debug visualization (fullscreen quad sampling G-buffer faces)
- Verify: cubemap faces show scene, radial encodes distance

### M3 Deliverables (complete)

- `lighting.odin`: lit texture (RGBA8, 384×384×6), fullscreen lighting pipeline
- `lighting.glsl`: fullscreen fragment — reads G-buffer + shadow map, writes lit color
- Verify: cubemap shows lit scene with shadows (debug vis Lit mode)

### M4 Deliverables (complete)

- `splat.odin`: splat + background pipelines, instanced draw per face
- `splat.glsl`: vertex shader (texelFetch radial, reconstruct world pos, expand quad)
                fragment shader (texelFetch lit color)
- `background.glsl`: fullscreen sky from probe cubemap (direction → face+UV → texelFetch)
- Draw order: background (depth 1.0) → 6× instanced splat draws (PROBE_SIZE² instances each)
- Tab cycles: Splat → Forward → Albedo → Normal → Radial → Lit
- Verify: pixelated 3D scene, stable under camera rotation

### M5 Deliverables (complete)

- `probe.odin`: Transition_State (grid snap, crossfade timer, speed-adaptive blend rate)
  - Constants: NUM_PROBES=2, TOTAL_LAYERS=12, GRID_STEP=1.0, BLEND_DURATION=0.5
  - Face mask culling: EYE_CULL_COS=cos(98°), GRID_CULL_COS=cos(103°)
- `gbuffer.odin`: Expanded from 6→12 layers (2 probes × 6 faces)
- `lighting.odin`: Expanded to 12 layers, face+layer parameter separation
- `lighting.glsl`: Uses layer (not face) for texelFetch into correct probe's G-buffer
- `splat.odin`: Multi-probe draw loop with face mask culling per probe
- `splat.glsl`: splat_params uniform (probe_idx, fade_t), Bayer 4×4 discard for grid crossfade,
                eye probe depth bias (+0.001*w), layer-aware texelFetch
- `background.glsl`: Unchanged (always samples eye probe layers 0-5)
- Draw order: background → eye splat (depth-biased) → grid splat (Bayer-dithered)
- Key 7 toggles debug probe (eye/grid) in debug vis modes
- Verify: grid texels stable under camera rotation, smooth Bayer crossfade at grid boundaries

### M6 Deliverables (complete)

- `probe.odin`: NUM_PROBES=3, TOTAL_LAYERS=18, PROBE_PREV=2
  - Transition advance restructured: fade starts on same frame (no 1-frame double-vision)
- `gbuffer.odin`: Expanded from 12→18 layers (3 probes × 6 faces)
- `lighting.odin`: Expanded to 18 layers
- `splat.odin`: 3-probe draw loop; prev mask=0 when not blending (zero cost when idle)
- `splat.glsl`: Grid (idx=1) fades IN via Bayer discard (threshold >= fade_t)
                Prev (idx=2) fades OUT via inverse Bayer (threshold < fade_t)
                Complementary patterns tile screen without overlap
- `background.glsl`: Unchanged (always samples eye probe layers 0-5)
- `game.odin`: ProbeToggle cycles 0→1→2→0; prev_mask computed conditionally on blending
- Draw order: background → eye splat → grid splat (Bayer IN) → prev splat (Bayer OUT)
- Verify: smooth transitions in all directions, no popping

### M7 Deliverables (complete)

- `scene.odin`: Added entity_id to Box_Instance (unique per object, 1-7)
- `gbuffer.glsl`: Entity ID stored in albedo.a (normalized to [0,1] for RGBA8)
- `edge_mask.odin`: Edge mask texture (RGBA8, 384×384×18), per-layer attachment views
- `edge_mask.glsl`: Fullscreen fragment — compares radial with 4 neighbors,
                    outputs per-side continuity (R=left, G=right, B=bottom, A=top)
                    Threshold: 0.2% relative radial difference or sky neighbor
- `lighting.glsl`: OKLab conversion (toOKLab/fromOKLab) + detectEdge() function
                   Entity ID boundary → darken closer texel
                   Normal discontinuity (dot < 0.7) → darken/highlight based on view angle
                   Applied only for grid/prev probes (layers 6+), 1 band step in OKLab lightness
- `splat.glsl`: Per-side quad expansion from edge mask (tight vs expanded half-size)
               Angle-compensated tight size: halfTexel * 1.15 + 0.0005 * tan(θ)
               New camera_pos uniform for viewing angle computation
               New sp_edge_mask texture binding
- `splat.odin`: Binds edge mask texture + sampler, passes camera_pos to shader
- `game.odin`: Edge_Mask added to Game_Memory; init/cleanup/refresh/draw integrated
               Pass order: shadow → G-buffer → edge mask → lighting → splat
- Verify: clean silhouettes, no gaps between splats, visible outlines at entity boundaries

### M8 Deliverables (complete)

- `lighting.glsl`: Posterization via OKLab lightness quantization (32 bands, subtle chroma shift)
                   Procedural sky gradient (zenith/horizon blend based on cubemap direction)
                   Horizon haze blending for sky texels near the horizon
                   Gamma correction removed (moved to post.glsl for correct linear pipeline)
- `splat.glsl`: Distance haze in fragment shader (exponential fog, camera-to-texel distance)
               New v_haze_dist flat varying from vertex shader
               Haze constants: density=0.005, color=(0.5, 0.56, 0.66)
- `background.glsl`: Radial texture binding for distance-based haze on non-sky texels
                     New haze_params/haze_color uniforms in bg_params
- `debug_vis.glsl`: Gamma correction for Lit mode (lit texture now stores linear RGB)
- `post.odin`: Post_Pass struct with offscreen RGBA8+DEPTH render targets
               Internal resolution from reference formula: height=ceil(2.5*384*tan(fov/2))≈55
               Width computed from window aspect ratio
               Nearest-neighbor sampler for pixel-art upscale
               post_init, post_begin_pass, post_draw, post_cleanup, post_refresh_pipeline
- `post.glsl`: Fullscreen triangle blit with gamma correction (linear → sRGB)
- `splat.odin`: Background shader now binds radial texture + haze uniforms
                render_w/render_h parameters for correct background viewport
- `game.odin`: Post_Pass added to Game_Memory; init/cleanup/refresh integrated
               Splat mode: post_begin_pass → splat_draw → end_pass → swapchain → post_draw
               Debug/Forward modes: render directly to swapchain (unchanged)
               Pass order: shadow → G-buffer → edge mask → lighting → splat(offscreen) → post(blit)
- Verify: posterized color banding, procedural sky gradient, distance haze, pixel-art upscale
