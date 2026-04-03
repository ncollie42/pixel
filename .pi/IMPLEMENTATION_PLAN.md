# Texel Splatting — Implementation Plan (Odin + Sokol)

## CRITICAL: Sokol API Has Changed

**Sokol now supports compute shaders, storage buffers, storage images, and a new View-based API.**
Karl Zylinski's project uses the OLD sokol API (`sg.make_attachments` with inline image references,
`bindings.images[]`). The LATEST sokol-odin uses:

- **`sg.make_view()`** — creates typed view objects for attachment or texture sampling
- **`Bindings.views[]`** — textures bound through View objects, not directly
- **`Image_Usage`** — `.color_attachment`, `.depth_stencil_attachment`, `.storage_image` etc.
- **Compute passes** — `sg.begin_pass({compute = true})`, `sg.dispatch(x, y, z)`
- **`@cs` blocks** in sokol-shdc — first-class compute shader support
- **Storage buffers** — `layout(binding=N) buffer name { ... }` in shaders
- **Storage images** — writable images from compute shaders

This means we CAN do the GPU cull and compute lighting natively in sokol if we want,
but the fragment-shader approach remains simpler to start with. The plan below starts
with fragment passes and notes where compute can be swapped in later.

**When coding**: use the new View-based API. Do NOT copy sokol patterns from Karl's game.odin
directly — his `sg.make_attachments({colors = {0 = {image = ..., slice = ...}}})` syntax is
outdated. Instead use `sg.make_view` + `sg.View` objects. See the "Sokol API Patterns" section below.

---

## Starting Point

**New project, modeled after Karl Zylinski's odin-sokol project structure.**

Don't fork either repo. Karl's project gives us scaffolding patterns. Dylan's repo is algorithm reference.

What to take from Karl's project:
- `build.py` — copy and adapt (shader compilation, hot reload, release builds)
- `source/main_hot_reload/` — hot reload entry point (copy nearly verbatim)
- `source/main_release/` — release entry point (copy nearly verbatim)
- `.gitignore` — same patterns (`build/`, `gen__*`, `sokol-shdc/`, `source/sokol/`)
- Project structure conventions (`source/`, `assets/`, sokol as vendored dep)

What NOT to take:
- Any game logic (player, bounding_box, etc.)
- His specific shaders
- His scene/object system

Algorithm reference: `TEXEL_SPLATTING_ESSENCE.md` in this same directory.
Source reference: [texel-splatting](https://github.com/dylanebert/texel-splatting) (read `src/splat.ts` for details).
Sokol scaffold reference: Karl Zylinski's [odin-sokol hot-reload template](https://github.com/nicebyte/odin-sokol-first-person-shadow-mapping) (structure only, not API calls).

---

## Project Structure

```
pixel/
├── build.py                          # adapted from Karl's project
├── .gitignore
├── assets/
├── source/
│   ├── main_hot_reload/
│   │   └── main_hot_reload.odin      # from Karl's pattern
│   ├── main_release/
│   │   └── main_release.odin         # from Karl's pattern
│   ├── game.odin                     # init, frame, cleanup, event — top-level orchestration
│   ├── camera.odin                   # first-person camera (yaw/pitch/move)
│   ├── input.odin                    # key/mouse state
│   ├── math_utils.odin               # Mat4, Vec3, lookAt, perspective, cubePerspective
│   ├── probe.odin                    # probe origins, transition state, face masks
│   ├── gbuffer.odin                  # G-buffer textures, MRT views, capture pass
│   ├── shadow.odin                   # shadow map: texture, views, render pass
│   ├── lighting.odin                 # lighting pass: pipeline, fullscreen frag, edge masks
│   ├── splat.odin                    # splat pass: pipeline, instanced draw, background
│   ├── sky.odin                      # sky rendering (procedural gradient)
│   ├── post.odin                     # post-processing: upscale to swapchain
│   ├── scene.odin                    # test geometry (ground plane, boxes, etc.)
│   │
│   ├── gbuffer.glsl                  # G-buffer vertex/fragment (MRT output)
│   ├── shadow.glsl                   # shadow caster vertex/fragment (depth only)
│   ├── lighting.glsl                 # fullscreen lighting fragment (reads G-buf + shadow)
│   ├── splat.glsl                    # splat vertex (reconstruct quad) + fragment (sample lit)
│   ├── background.glsl               # fullscreen sky from probe cubemap
│   └── post.glsl                     # upscale / blit to screen
```

---

## Sokol API Patterns (New View-based API)

### Creating an array texture for render targets

```odin
albedo_img := sg.make_image({
    type = .ARRAY,
    usage = { color_attachment = true },  // NEW: not render_target = true
    width = PROBE_SIZE,
    height = PROBE_SIZE,
    num_slices = 6,  // 6 faces for 1 probe (or 18 for all 3)
    pixel_format = .RGBA8,
    sample_count = 1,
})
```

### Creating views for render target attachment (per face)

```odin
// Color attachment view for face 0
albedo_att_view_face0 := sg.make_view({
    color_attachment = {
        image = albedo_img,
        slice = 0,  // face index
    },
})

// Depth attachment view for face 0
depth_att_view_face0 := sg.make_view({
    depth_stencil_attachment = {
        image = depth_img,
        slice = 0,
    },
})
```

### Creating texture views for sampling in shaders

```odin
// Texture view for sampling the whole array in a later pass
albedo_tex_view := sg.make_view({
    texture = {
        image = albedo_img,
        // slices/mip_levels zero-initialized = all slices, all mips
    },
})
```

### Beginning a render pass with MRT

```odin
sg.begin_pass({
    action = {
        colors = {
            0 = { load_action = .CLEAR, clear_value = {0, 0, 0, 0} },
            1 = { load_action = .CLEAR, clear_value = {0.5, 0.5, 0, 0} },
            2 = { load_action = .CLEAR, clear_value = {1, 0, 0, 0} },
            3 = { load_action = .CLEAR, clear_value = {0, 0, 0, 0} },
        },
    },
    attachments = {
        colors = {
            0 = albedo_att_view_face0,
            1 = normal_att_view_face0,
            2 = radial_att_view_face0,
            3 = eid_att_view_face0,
        },
        depth_stencil = depth_att_view_face0,
    },
})
```

### Binding texture views for sampling

```odin
sg.apply_bindings({
    views = {
        VIEW_albedo_tex = albedo_tex_view,
        VIEW_radial_tex = radial_tex_view,
        // VIEW_* constants generated by sokol-shdc
    },
    samplers = {
        SMP_smp = my_sampler,
    },
})
```

### Instanced draw (no vertex buffer)

```odin
sg.draw(0, 6, PROBE_SIZE * PROBE_SIZE)
// 6 verts per quad, PROBE_SIZE² instances
// Vertex shader uses gl_VertexIndex (0-5) and gl_InstanceIndex
```

### Fullscreen triangle (no vertex buffer)

```odin
sg.draw(0, 3, 1)
// Vertex shader generates positions from gl_VertexIndex
```

---

## Shader Patterns (sokol-shdc GLSL)

### Sokol-shdc annotations

```glsl
@header package game
@header import sg "sokol/gfx"
@ctype mat4 Mat4
@ctype vec4 Vec4

@vs my_vs
// vertex shader
@end

@fs my_fs
// fragment shader
@end

@program my_program my_vs my_fs
```

Generates `gen__my_shader.odin` with `my_program_shader_desc(backend)`.

### MRT fragment output

```glsl
@fs gbuffer_fs
layout(location=0) out vec4 out_albedo;
layout(location=1) out vec4 out_normal;
layout(location=2) out float out_radial;
layout(location=3) out uint out_eid;
void main() {
    // ...
}
@end
```

**Note**: `uint` output (R32UI) may not be supported as render target on all backends.
**Fallback**: pack entity ID into `float` (use `intBitsToFloat` / `floatBitsToInt`) or into
the alpha channel of another rgba8 target. Query at runtime with
`sg.query_pixelformat(.R32UI).render` to check.

### Fullscreen triangle vertex shader

```glsl
@vs fullscreen_vs
out vec2 uv;
void main() {
    uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
@end
```

### Vertex texture fetch (splat vertex shader)

```glsl
@vs splat_vs
@image_sample_type radial_tex unfilterable_float
layout(binding=0) uniform texture2DArray radial_tex;
layout(binding=0) uniform sampler radial_smp;

layout(binding=0) uniform splat_vs_params {
    mat4 view_proj;
    vec3 probe_origin;
    int face;
    float near;
    float far;
};

void main() {
    int texel_idx = gl_InstanceIndex;
    int px = texel_idx % PROBE_SIZE;
    int py = texel_idx / PROBE_SIZE;

    float radial = texelFetch(sampler2DArray(radial_tex, radial_smp),
                              ivec3(px, py, face), 0).r;

    if (radial >= 0.999) {
        gl_Position = vec4(0.0); // degenerate — GPU culls
        return;
    }
    // ... reconstruct world pos, expand quad, project
}
@end
```

### Compute shader (sokol-shdc)

```glsl
@cs my_compute
layout(binding=0) uniform cs_params {
    // uniforms
};

layout(binding=0, rgba8) uniform writeonly image2DArray out_lit;

// Can also use storage buffers:
// layout(binding=0) buffer my_ssbo { ... data[]; };

layout(local_size_x=8, local_size_y=8, local_size_z=1) in;

void main() {
    uvec3 gid = gl_GlobalInvocationID;
    // ...
    imageStore(out_lit, ivec3(gid.xy, layer), vec4(color, 1.0));
}
@end

@program my_compute_program my_compute
```

---

## Milestones

Each milestone produces something visible. Test and verify before moving on.

### Milestone 0: Scaffold

**Goal**: Window opens, clears to a color, hot reload works.

- [ ] Copy build.py from Karl's project, adapt paths
- [ ] Set up `source/main_hot_reload/`, `source/main_release/` from Karl's pattern
- [ ] Minimal game.odin: `game_init` sets up sokol_gfx, `game_frame` clears screen, `game_cleanup` shuts down
- [ ] First-person camera with mouse look + WASD (camera.odin, input.odin)
- [ ] math_utils.odin: Mat4, Vec3, perspective, lookAt, multiply
- [ ] Verify: window opens, camera moves, screen clears to sky color

### Milestone 1: Scene + Shadow Map

**Goal**: Render test geometry with basic shadow mapping.

- [ ] scene.odin: generate a ground plane + a few boxes (vertex buffer: position + normal, 6 floats/vertex)
- [ ] shadow.odin: create shadow map depth texture (2048²), render scene from sun
- [ ] Basic forward-lit shader that samples shadow map — verify traditional rendering works
- [ ] Verify: scene renders with shadows on screen (not texel splatting yet)

This proves sokol setup, new View API, shader compilation, render-to-texture, shadow maps.

### Milestone 2: Single Probe G-Buffer

**Goal**: Render scene into one cubemap probe (6 faces × MRT) and visualize it.

- [ ] gbuffer.odin: create textures for 1 probe (6 layers):
  - albedo (rgba8, 384×384, array with 6 slices)
  - normal (rgba8, 384×384, array with 6 slices)
  - radial (r32f, 384×384, array with 6 slices)
  - eid (r32f or rgba8 — see fallback note above, 384×384, array with 6 slices)
  - depth (depth, 384×384, array with 6 slices)
  - Create attachment views (color + depth) per face
  - Create texture views for sampling
- [ ] gbuffer.glsl: G-buffer shader
  - Vertex: transform by cubemap face viewProj
  - Fragment: output albedo, oct-encoded normal, Chebyshev radial, entity ID
- [ ] probe.odin: `cube_perspective(near, far)` — 90° FOV projection
  - Face view matrices (6 lookAt calls per `TEXEL_SPLATTING_ESSENCE.md` directions)
  - Face uniform buffer: viewProj(64) + origin(12) + near(4) + pad(12) + far(4) = 96 bytes
- [ ] Render all 6 faces of one probe centered at camera
- [ ] Debug vis: fullscreen quad sampling one face of albedo/radial
- [ ] Verify: cubemap faces show scene, radial encodes distance

### Milestone 3: Lighting Pass

**Goal**: Shade each cubemap texel via fullscreen fragment pass, with shadow mapping.

- [ ] lighting.odin: create `lit` texture (rgba8, 384×384, 6 slices), attachment + texture views per face
- [ ] lighting.glsl: fullscreen triangle fragment shader
  - Input: samples albedo, normal, radial textures + shadow map
  - Reconstruct world position from radial + probe origin + cubemap direction
  - Project into light space, sample shadow map (with PCF), compute diffuse lighting
  - Output: lit color
- [ ] Render 6 fullscreen passes, one per face
- [ ] Debug vis: sample lit faces on screen
- [ ] Verify: cubemap shows lit scene with shadows

### Milestone 4: Splat Render (Single Probe)

**Goal**: Splat cubemap texels to screen as world-space quads. Core of the technique.

- [ ] splat.odin: splat pipeline
  - No vertex buffer — derived from instance_index
  - Bind: lit texture view, radial texture view (vertex stage), uniforms
- [ ] splat.glsl vertex shader:
  - Derive face (from uniform), px/py (from instance_index)
  - texelFetch radial — if sky, emit degenerate
  - Reconstruct world pos, expand quad, project
  - Pass (px, py, face) as flat varyings to fragment
- [ ] splat.glsl fragment shader:
  - texelFetch lit texture at (px, py, face)
  - Output color
- [ ] background.glsl: fullscreen triangle sampling probe's lit cubemap
  - View direction from screen UV → cubemap face+UV → texelFetch lit
- [ ] Draw order: background (depth=1.0), then splat instances
- [ ] Per visible face: `sg.draw(0, 6, PROBE_SIZE * PROBE_SIZE)`
- [ ] Verify: **pixelated 3D scene, stable under camera rotation** ← this is the magic moment

**Instance index decoding** (no visibility buffer):
```glsl
// Uniform per draw: u_face (0-5), u_probe_origin
int texel_idx = gl_InstanceIndex;  // 0 .. PROBE_SIZE²-1
int px = texel_idx % PROBE_SIZE;
int py = texel_idx / PROBE_SIZE;
```

**Quad vertex expansion** (6 vertices per quad):
```
vid 0,3 → (u - half, v - half)   bottom-left
vid 1   → (u + half, v - half)   bottom-right
vid 2,4 → (u + half, v + half)   top-right
vid 5   → (u - half, v + half)   top-left

Each corner: worldPos = origin + texelDir(face, cu, cv) * (chebyshev / maxComp)
gl_Position = viewProj * vec4(worldPos, 1.0)
```

### Milestone 5: Grid Probe + Crossfade

**Goal**: Two probes — eye (camera) and grid (snapped) — with Bayer crossfade.

- [ ] Expand textures from 6 to 12 layers (2 probes × 6 faces)
- [ ] probe.odin: transition state
  - Grid-snapped origin tracking, change detection
  - Smooth blend timer adapting to camera speed
- [ ] Face mask culling: cos(98°) for eye, cos(103°) for grid
- [ ] Splat vertex: eye probe gets depth bias, grid uses Bayer discard
- [ ] Verify: grid texels stable, smooth crossfade at boundaries

### Milestone 6: Prev Probe + Full Transition

**Goal**: Third probe (old grid origin), completing crossfade.

- [ ] Expand textures from 12 to 18 layers
- [ ] When grid origin changes: prev = old grid, start blend
- [ ] Prev probe: inverse Bayer dithered discard
- [ ] Prev probe occlusion check in vertex shader
- [ ] Verify: smooth transitions all directions, no popping

### Milestone 7: Edge Masks + Outlines

**Goal**: Clean edges, pixel-art outlines.

- [ ] Edge mask pass (fragment or compute): compare radial with 4 neighbors → 4-bit mask texture
- [ ] Splat vertex: sample edge mask, adjust quad expansion per side
- [ ] Outline detection in lighting pass: entity ID + normal comparison → darken/lighten in OKLab
- [ ] Verify: clean silhouettes, no gaps, visible outlines

### Milestone 8: Posterization + Polish

**Goal**: Final pixel-art look.

- [ ] Posterization in lighting pass: quantize lightness in OKLab (32 bands)
- [ ] Sky rendering into probe lit texture for sky texels
- [ ] Distance haze in splat fragment
- [ ] Post-processing: upscale from render resolution to swapchain (nearest-neighbor)
- [ ] Verify: matches reference aesthetic

---

## Optional: Upgrade to Compute

After Milestone 8 works, these are optional performance improvements using sokol's new compute:

- [ ] Lighting pass → compute shader (`@cs`, `imageStore` to lit texture)
- [ ] Edge mask pass → compute shader
- [ ] GPU cull → compute with storage buffer + atomic counter → indirect draw
  (sokol may not support indirect draw yet — check `sg.draw_indirect` or similar)

These are optimizations, not requirements. The fragment-shader path works fine.

---

## Per-Frame Pass Structure

```
// 1. Shadow map pass
sg.begin_pass(shadow_attachments)  // depth-only
    draw scene from light POV
sg.end_pass()

// 2. G-buffer capture (per visible face per probe)
for probe in [eye, grid, prev]:
    for face in 0..6:
        if not face_visible(face, probe): continue
        sg.begin_pass(gbuffer MRT attachments for this probe*6+face)
            draw scene with cubemap face viewproj
        sg.end_pass()

// 3. Lighting (per visible face per probe)
for probe in [eye, grid, prev]:
    for face in 0..6:
        if not face_visible(face, probe): continue
        sg.begin_pass(lit attachment for this probe*6+face)
            fullscreen triangle — reads albedo/normal/radial/shadow, writes lit
        sg.end_pass()

// 4. Splat to screen
sg.begin_pass(swapchain)
    // Background: fullscreen triangle sampling eye probe lit cubemap
    sg.apply_pipeline(background_pip)
    sg.draw(0, 3, 1)

    // Splat: instanced quads per visible face per probe
    sg.apply_pipeline(splat_pip)
    for each visible (probe, face):
        // set uniforms: probe index, face, origin, near/far, fade state
        sg.apply_uniforms(...)
        sg.draw(0, 6, PROBE_SIZE * PROBE_SIZE)
sg.end_pass()
sg.commit()
```

Total: 1 (shadow) + ~10 (G-buffer) + ~10 (lighting) + 1 (splat) ≈ **22 passes/frame**.

---

## Key Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| R32UI render target not supported everywhere | Use R32F and `intBitsToFloat`/`floatBitsToInt`, or pack EID into albedo.a. Query `sg.query_pixelformat(.R32UI).render` at init. |
| Vertex texture fetch issues on some backends | Test on M2. If broken: pass face/probe as uniform, sample in fragment instead. |
| sokol-shdc doesn't support `texture2DArray` | Use `sampler2DArray` / `texelFetch` with `ivec3`. Test early in M2. If blocked: use 18 separate 2D textures instead of arrays. |
| New View API not well documented yet | Reference sokol_gfx.h header comments (they're thorough). Check `sg.make_view` examples above. |
| Karl's build.py uses older sokol | build.py downloads LATEST sokol on first run. The build script itself is fine — just the game code patterns differ. |
| Too many draw calls (~12 splat draws) | Each is one `sg.draw`. Trivial overhead. Not a real risk. |

---

## What to Read When Implementing

| When implementing... | Read this |
|---|---|
| Cubemap face directions, UV mapping | `TEXEL_SPLATTING_ESSENCE.md` → "Cubemap Face ↔ Direction Mapping" |
| Chebyshev distance, world pos reconstruction | `TEXEL_SPLATTING_ESSENCE.md` → "Distance Encoding", "World Position Reconstruction" |
| Quad expansion, edge masks | `TEXEL_SPLATTING_ESSENCE.md` → "Quad Sizing & Edge Masks" |
| Octahedral normals | `TEXEL_SPLATTING_ESSENCE.md` → "Octahedral Normal Encoding" |
| Face mask culling | `TEXEL_SPLATTING_ESSENCE.md` → "Face Mask Culling" |
| Transition / crossfade | `TEXEL_SPLATTING_ESSENCE.md` → "Transition System" |
| Bayer dithering | `TEXEL_SPLATTING_ESSENCE.md` → "Bayer Dithered Crossfade" |
| Direction → face+UV inverse mapping | `TEXEL_SPLATTING_ESSENCE.md` → "Direction → Face + UV" |
| Posterization algorithm | `TEXEL_SPLATTING_ESSENCE.md` → "Posterization" |
| Shadow mapping | `TEXEL_SPLATTING_ESSENCE.md` → "Shadow Mapping" |
| Splat vertex shader (full WGSL reference) | [texel-splatting](https://github.com/dylanebert/texel-splatting) `src/splat.ts` → search for `fn vs(` in splatShader |
| Lighting shader (full WGSL reference) | [texel-splatting](https://github.com/dylanebert/texel-splatting) `src/splat.ts` → search for `fn main(` in lightingShader |
| Build system, hot reload, shader pipeline | `build.py` (adapted from Karl Zylinski's template) |
| Karl's project structure patterns | Karl Zylinski's [odin-sokol template](https://github.com/nicebyte/odin-sokol-first-person-shadow-mapping) (structure only, not API calls) |
| New sokol View API | sokol_gfx.h header comments (downloaded by build.py into `source/sokol/`) |
