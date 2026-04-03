# Texel Splatting (Odin + sokol-gfx)

An implementation of [Texel Splatting](https://arxiv.org/abs/2603.14587) — perspective-stable 3D pixel art — written in Odin with sokol-gfx.

The renderer captures the scene into cubemap G-buffers from fixed probe positions, lights each texel with shadows, then splats every texel as a world-space quad to screen. Because the cubemap texels are anchored to probe origins (not to the camera), they don't shimmer or crawl when the camera rotates or translates. The result looks like pixel art that respects 3D perspective.

## How It Works

### Rendering Pipeline (per frame)

```
Shadow Map ─► G-Buffer ─► Edge Mask ─► Lighting ─► Splat ─► Post
  (depth)     (cubemap      (neighbor    (diffuse     (instanced   (nearest-neighbor
   from sun)   MRT capture)  continuity)  + shadow     world-space   upscale + gamma)
                                          + outlines   quads)
                                          + posterize)
```

1. **Shadow map** — Depth-only pass from the sun's POV (2048², RGBA8-encoded depth, orbiting directional light).

2. **G-buffer capture** — For each probe (eye, grid, prev), render the scene into a 384×384 cubemap (6 faces) using MRT: albedo (RGBA8), octahedral normal (RGBA8), Chebyshev radial distance (R32F). 3 probes × 6 faces = 18 layers.

3. **Edge mask** — Fullscreen pass per layer comparing each texel's radial depth with its 4 neighbors. Outputs per-side continuity mask (RGBA8): tight fit for continuous surfaces, expanded fit at depth discontinuities/silhouettes.

4. **Lighting** — Fullscreen pass per layer: reconstructs world position from radial + probe origin + cubemap direction, applies diffuse + 3×3 PCF shadow, entity/normal edge outlines (OKLab lightness step), posterization (32-band OKLab quantization), procedural sky gradient.

5. **Splat** — For each visible cubemap face, draw PROBE_SIZE² instanced quads (6 verts each, no vertex buffer). Vertex shader fetches radial distance, reconstructs world position, expands quad corners using edge mask. Fragment shader fetches pre-lit color, applies Bayer-dithered crossfade between probes and exponential distance haze. Background pass draws pixelated sky at depth 1.0.

6. **Post** — Render splats to a low-resolution offscreen target (≈555p), then nearest-neighbor upscale to the window with gamma correction. This gives the chunky pixel-art look.

### Multi-Probe System

Three probes run simultaneously:

- **Eye probe** (layers 0-5) — origin at camera position, provides close-up detail
- **Grid probe** (layers 6-11) — origin snapped to a 1m grid, provides perspective-stable rendering
- **Prev probe** (layers 12-17) — old grid origin during transitions, fades out via inverse Bayer dithering

When the camera crosses a grid boundary, prev captures the old grid state while grid snaps to the new cell. A Bayer 4×4 ordered dither crossfades between them over 0.5s (speed-adaptive). The eye probe always renders with a slight depth bias so grid texels take priority where they overlap.

## Build & Run

Requires [Odin](https://odin-lang.org/) (dev-2026-04+) and Python 3. Linux (tested on Fedora 43).

```bash
# First build — downloads sokol bindings + shader compiler automatically
python3 build.py -hot-reload

# Subsequent builds (hot-reloads if exe is already running)
python3 build.py -hot-reload

# Release build
python3 build.py -release
```

The build script compiles all `.glsl` shaders via sokol-shdc, builds a hot-reload DLL, and launches the executable. On subsequent builds with the exe already running, it rebuilds only the DLL — the running exe detects the change and hot-reloads.

## Controls

| Key | Action |
|-----|--------|
| **WASD** | Move (horizontal plane) |
| **Space / L-Shift** | Move up / down |
| **L-Ctrl** | Sprint |
| **Mouse** | Look (click to capture, Esc to release) |
| **Tab** | Cycle render mode: Splat → Forward → Albedo → Normal → Radial → Lit |
| **1-6** | Select cubemap face for debug visualization |
| **7** | Cycle debug probe (eye → grid → prev) |
| **F6** | Force restart |

## Tech Stack

- **[Odin](https://odin-lang.org/)** — systems programming language
- **[sokol-gfx](https://github.com/floooh/sokol)** — cross-platform graphics API (GL/Metal/D3D/WebGPU)
- **[sokol-shdc](https://github.com/nicebyte/sokol-shdc)** — shader cross-compiler (GLSL → SPIRV/HLSL/MSL/WGSL)
- Hot-reload DLL architecture (edit code → rebuild DLL → running exe picks up changes)

## Architecture

### File Map

```
source/
├── game.odin              Frame loop, Game_Memory, pass orchestration
├── camera.odin            First-person camera (pos/yaw/pitch → view/proj)
├── input.odin             Key/mouse state from sokol events
├── math_utils.odin        Type aliases (Mat4, Vec3...), matrix builders
├── scene.odin             Test geometry (ground + boxes), vertex buffer
├── shadow.odin + .glsl    Shadow map: 2048² depth-only pass from sun
├── probe.odin             Probe origins, cubemap face matrices, transition state
├── gbuffer.odin + .glsl   G-buffer: MRT capture (albedo/normal/radial), 18 layers
├── edge_mask.odin + .glsl Edge mask: per-texel 4-direction continuity
├── lighting.odin + .glsl  Lighting: diffuse + shadow + outlines + posterization
├── splat.odin + .glsl     Splat: instanced quads + Bayer crossfade + haze
├── background.glsl        Fullscreen sky from eye probe cubemap
├── post.odin + .glsl      Offscreen render + nearest-neighbor upscale + gamma
├── forward.glsl           Forward-lit shader (debug fallback, Tab key)
├── debug_vis.glsl         Debug visualization (albedo/normal/radial/lit modes)
├── gen__*.odin            Generated shader bindings (build artifact)
├── main_hot_reload/       Dev exe entry point (DLL loader + file watcher)
├── main_release/          Release exe entry point (static link)
└── sokol/                 Vendored bindings (auto-downloaded by build.py)
```

### Data Flow

```
scene.odin ──► shadow.odin ──► gbuffer.odin ──► edge_mask.odin ──► lighting.odin ──► splat.odin ──► post.odin
 (geometry)     (depth tex)     (albedo,         (continuity       (lit tex,          (screen         (upscale
                                 normal,          mask per          outlines,           quads)          + gamma)
                                 radial)          side)             posterize)
```

All per-frame state lives in `Game_Memory` (game.odin). Each rendering stage owns one `.odin` + `.glsl` file pair. Data flows forward through the pipeline — later passes read textures produced by earlier passes, never the reverse.

## References

- **Paper**: [Texel Splatting: Perspective-Stable 3D Pixel Art](https://arxiv.org/abs/2603.14587) — Dylan Ebert, 2026
- **Reference implementation**: [texel-splatting](https://github.com/dylanebert/texel-splatting) (TypeScript/WebGPU) — the original by the paper author
- **Build template**: [odin-sokol-hot-reload-template](https://github.com/nicebyte/odin-sokol-hot-reload-template) — Karl Zylinski's hot-reload scaffold
