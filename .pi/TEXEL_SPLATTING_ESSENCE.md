# Texel Splatting — Technical Essence

> Reference distilled from [dylanebert/texel-splatting](https://github.com/dylanebert/texel-splatting)
> ([paper](https://arxiv.org/abs/2603.14587))

## The Problem

Traditional 3D pixel art shimmers when the camera rotates or translates because screen pixels don't align with world texels. Cubemap sampling also has distortion/stability issues.

## The Core Idea

**Render the scene into cubemap G-buffers from fixed probe origins, then splat each cubemap texel to the screen as a world-space quad.** Because probe origins are snapped to a grid and cubemap texels have fixed world positions, the pixel art is **perspective-stable** — no shimmer under rotation or translation.

---

## Pipeline (4 stages per frame)

```
1. Shadow Map         → Render scene from sun (standard depth pass)
2. G-Buffer Capture   → Render scene into cubemap faces (per-probe, MRT)
3. Lighting Pass      → Fullscreen fragment shader per layer (shade each texel)
4. Splat Render       → Instanced quads, vertex shader discards sky texels
```

### Stage 1: Shadow Map

Standard shadow mapping — render the scene from the sun/moon into a depth texture.
One extra pass, replaces the reference's BVH ray tracing entirely.

- Render scene from light POV → depth texture (e.g. 2048² or 4096²)
- In Stage 3, project reconstructed world positions into light space and compare depths
- Simpler than BVH construction + traversal, no storage buffers needed

### Stage 2: G-Buffer Capture

- Maintain **3 probes** × 6 cubemap faces = **18 layers** of 384×384 textures:
  - **Eye probe** (index 0): origin = camera position, closest detail
  - **Grid probe** (index 1): origin = camera snapped to grid (`round(pos / GRID_STEP) * GRID_STEP`)
  - **Prev probe** (index 2): origin = previous grid position (for crossfade)
- Each face renders into a **4-target MRT**:
  - `albedo` (rgba8unorm)
  - `normal` (rgba8unorm, octahedral encoded)
  - `radial` (r32float) — **Chebyshev distance** normalized: `(chebyshev - near) / (far - near)`, where `chebyshev = max(|dx|, |dy|, |dz|)` from probe origin
  - `eid` (r32uint) — entity ID for edge detection
- **Face culling optimization**: only render cubemap faces the camera is looking at (`computeFaceMask` using dot product threshold)
- Uses standard 90° FOV perspective per face

### Stage 3: Lighting Pass

Fullscreen fragment shader pass per layer — reads G-buffer textures, writes lit color.

This is pure per-pixel work (no shared memory, no scatter writes, no workgroup sync),
so a fragment shader is functionally identical to the reference's compute shader.

- For each texel: reconstruct world position from `radial` + probe origin + cubemap direction
- Sample shadow map: project world position into light space, compare depths (PCF filtering)
- Apply: diffuse sun lighting, point lights, posterization
- Edge detection/outlines for grid/prev probes (compare neighbor entity IDs and normals)
- Sky texels (`radial >= 0.999`) get sky color directly
- Writes to `lit` texture (rgba8unorm render target)

### Stage 4: Splat Render

No GPU cull needed. Draw ALL texels per visible face with fixed instance count.
Vertex shader samples radial texture — sky texels emit degenerate triangles, which
GPU hardware culls at primitive assembly (before rasterization, essentially free).

**Numbers**: 384² ≈ 147K instances × 6 verts = ~900K vertex invocations per draw call.
Modern GPUs process billions of vertices/sec. This is negligible.

Each non-sky texel becomes a **world-space quad** (6 vertices, 2 triangles):

**Vertex shader** (instanced, fixed instance count per draw call):
- Derive probe/face/pixel from `instance_index` + uniforms identifying current draw
- Sample radial texture — if sky (`>= 0.999`), emit degenerate triangle (all verts at origin)
- Reconstruct world position: `origin + dir * (chebyshev / maxComponent)`
- Expand quad corners: half-texel ± expansion in UV space, project through cubemap direction to world
- **Edge mask** controls expansion per-side: smooth edges use tight fit, depth discontinuities use expanded fit (edge masks stored in a texture, written during lighting or a separate fragment pass)
- Z-bias: hash-based jitter + probe priority (eye probe gets slight depth push to win over grid)
- **Prev probe occlusion**: skip if eye probe covers same entity at that direction

**Fragment shader**:
- Sample `lit` texture (already fully shaded)
- Apply distance haze
- **Bayer dithered crossfade** between grid and prev probes during transitions (no alpha blending, just ordered dithering discard)

**Background pass** (fullscreen triangle): renders sky by sampling eye probe's lit cubemap with nearest-texel lookup.

---

## Key Details

### Distance Encoding — Chebyshev (L∞ norm)

Uses Chebyshev distance, not Euclidean. This maps naturally to cubemap geometry where the max axis component determines the face.

```
chebyshev = max(|x - origin.x|, |y - origin.y|, |z - origin.z|)
radial = (chebyshev - NEAR) / (FAR - NEAR)
```

### World Position Reconstruction

From a cubemap texel:

```
dir = faceUVtoDir(face, u, v)      // unnormalized direction from face+UV
maxComp = max(|dir.x|, |dir.y|, |dir.z|)
worldPos = origin + dir * (chebyshev / maxComp)
```

### Octahedral Normal Encoding

Normals packed into 2 channels (rg of rgba8unorm):

```
// Encode (in G-buffer fragment shader)
p = n.xy / (|n.x| + |n.y| + |n.z|)
if n.z < 0: wrap octahedrally
result = p * 0.5 + 0.5

// Decode (in lighting fragment shader)
f = encoded * 2.0 - 1.0
n = vec3(f, 1.0 - |f.x| - |f.y|)
if n.z < 0: unwrap
normalize(n)
```

### Cubemap Face ↔ Direction Mapping

```
face 0 (+X): dir = ( 1, -v, -u)
face 1 (-X): dir = (-1, -v,  u)
face 2 (+Y): dir = ( u,  1,  v)
face 3 (-Y): dir = ( u, -1, -v)
face 4 (+Z): dir = ( u, -v,  1)
face 5 (-Z): dir = (-u, -v, -1)

where u,v = texelCoord * 2.0 - 1.0  (range [-1, 1])
```

### Direction → Face + UV (inverse mapping)

Used by splat background pass and prev-probe occlusion check:

```
absDir = abs(dir)
if absDir.x >= absDir.y && absDir.x >= absDir.z:
    if dir.x > 0: face=0, u=-dir.z/absDir.x, v=-dir.y/absDir.x
    else:         face=1, u= dir.z/absDir.x, v=-dir.y/absDir.x
else if absDir.y >= absDir.x && absDir.y >= absDir.z:
    if dir.y > 0: face=2, u=dir.x/absDir.y, v= dir.z/absDir.y
    else:         face=3, u=dir.x/absDir.y, v=-dir.z/absDir.y
else:
    if dir.z > 0: face=4, u= dir.x/absDir.z, v=-dir.y/absDir.z
    else:         face=5, u=-dir.x/absDir.z, v=-dir.y/absDir.z
uv = vec2(u, v) * 0.5 + 0.5
px = clamp(uint(uv.x * PROBE_SIZE), 0, PROBE_SIZE-1)
py = clamp(uint(uv.y * PROBE_SIZE), 0, PROBE_SIZE-1)
```

### Face Mask Culling

Only render/process cubemap faces the camera is looking toward:

```
computeFaceMask(fwd, threshold):
    mask = 0
    if  fwd.x >= threshold: mask |= 1   // +X
    if -fwd.x >= threshold: mask |= 2   // -X
    if  fwd.y >= threshold: mask |= 4   // +Y
    if -fwd.y >= threshold: mask |= 8   // -Y
    if  fwd.z >= threshold: mask |= 16  // +Z
    if -fwd.z >= threshold: mask |= 32  // -Z

// Thresholds (cosine of angle from forward):
//   eye probe:  cos(98°)  ≈ -0.139  (slightly past 90°)
//   grid probe: cos(103°) ≈ -0.225  (wider, covers transitions)
```

### Transition System (Grid Probe Crossfade)

- Camera position snapped to `GRID_STEP = 1.0` grid
- When snap changes: store prev origin, start blend (`BLEND_DURATION = 0.5s`)
- Blend rate adapts to camera speed: `max(1/BLEND_DURATION, smoothedSpeed/GRID_STEP) * dt`
- Bayer 4×4 dithering for crossfade (no transparency needed)

### Quad Sizing & Edge Masks

```
base half-size = 0.5 / PROBE_SIZE               // one texel
expanded       = base + EXPANSION / PROBE_SIZE   // gap fill

// Per-side edge mask (4 neighbors):
// Compare radial depth with neighbor. If continuous → tight fit.
// If discontinuity (radial differs > 0.2%) → expanded fit.
// At edges, compensate for viewing angle: halfTexel * 1.15 + 0.0005 * tan(theta)
```

Edge masks are stored in a texture (R8UI or similar), written during the lighting pass
or a dedicated fragment pass, then sampled by the splat vertex shader.

### Edge Detection (Outlines)

In the lighting pass, for grid/prev probes:
- Compare each texel's entity ID and normal with 4 neighbors
- Different entity ID across edge → darken (entity boundary outline)
- Normal dot product < 0.7 → lighten or darken based on view alignment
- Applied in OKLab perceptual space for clean posterized look

### Bayer Dithered Crossfade

```
bayer4x4[16] = { 0/16, 8/16, 2/16, 10/16, 12/16, 4/16, ... }

// Grid probe (current): discard if threshold >= fadeT  (fades OUT)
// Prev probe:           discard if threshold <  fadeT  (fades IN)
// Eye probe:            always visible (alpha = 1)
```

No blending required — purely discard-based, works with depth buffer.

### Shadow Mapping (replaces BVH ray tracing)

The reference traces rays through a BVH for shadows. A standard shadow map is
equivalent and simpler — one render pass from the light, sample in lighting shader.

```
// In lighting fragment shader:
light_space_pos = light_viewproj * vec4(world_pos, 1.0)
light_space_pos.xyz /= light_space_pos.w
shadow_uv = light_space_pos.xy * 0.5 + 0.5
shadow_depth = texture(shadow_map, shadow_uv).r
in_shadow = (light_space_pos.z - bias) > shadow_depth

// PCF (percentage-closer filtering) for softer edges:
// Sample 3×3 or 5×5 neighbors, average results
```

For a posterized pixel-art look, even basic PCF is more than sufficient.

### Posterization

The reference posterizes colors in OKLab space for perceptually uniform banding:

```
BANDS = 32.0

fn posterize(color: vec3) -> vec3:
    lab = toOKLab(color)
    lab.x = round(lab.x * BANDS) / BANDS   // quantize lightness
    return fromOKLab(lab)
```

---

## Constants

| Name | Value | Purpose |
|------|-------|---------|
| `PROBE_SIZE` | 384 | Cubemap face resolution |
| `NEAR` | 0.1 | Near plane |
| `FAR` | 200 | Far plane |
| `GRID_STEP` | 1.0 | Grid snap interval |
| `BLEND_DURATION` | 0.5 | Crossfade time (seconds) |
| `EXPANSION` | 0.5 | Quad gap-fill factor |
| `PROBE_LAYERS` | 18 | 3 probes × 6 faces |
| `FACE_TEXELS` | 147456 | 384² per face |
| Viewport height | `2.5 * 384 * tan(fov/2)` | Pixel-art resolution |

---

## Texture & Buffer Layout

### G-Buffer Textures (18 layers = 3 probes × 6 faces)

| Texture | Format | Size | Usage |
|---------|--------|------|-------|
| albedo | rgba8unorm | 384×384×18 | render target + sample |
| normal | rgba8unorm | 384×384×18 | render target + sample |
| radial | r32float | 384×384×18 | render target + sample (including vertex stage) |
| eid | r32uint | 384×384×18 | render target + sample (including vertex stage) |
| depth | depth24plus | 384×384×18 | render target only (z-buffer for G-buffer capture) |
| lit | rgba8unorm | 384×384×18 | render target (lighting output) + sample |
| edgeMask | r8ui | 384×384×18 | render target (edge pass output) + sample in vertex |

### Shadow Map

| Texture | Format | Size | Usage |
|---------|--------|------|-------|
| shadow depth | depth (e.g. D16/D24/D32) | 2048²–4096² | render target + sample in lighting |

### Uniform Buffers

| Buffer | Size | Content |
|--------|------|---------|
| faceUniforms | 96 bytes × 18 | viewProj(64) + origin(12) + near(4) + pad(12) + far(4) |
| probeParams | 128 bytes | origins[3](48) + ranges[3](24) + masks(16) + state(16) |
| lightingParams | ~128 bytes | probe origin, sun dir, sun color, ambient, shadow fade, masks |
| splatScene | 80 bytes | viewProj(64) + cameraPos(12) + pad(4) |
| lightViewProj | 64 bytes | shadow map view-projection matrix |

---

## Per-Frame Pass Structure

```
// 1. Shadow map pass
begin_pass(shadow_attachments)  // depth-only
    draw scene from light POV
end_pass()

// 2. G-buffer capture (per visible face per probe)
for probe in [eye, grid, prev]:
    for face in 0..6:
        if not face_visible(face, probe): continue
        begin_pass(gbuffer_attachments[probe*6 + face])  // 4 MRT + depth
            draw scene with cubemap face viewproj
        end_pass()

// 3. Lighting (per visible face per probe)
for probe in [eye, grid, prev]:
    for face in 0..6:
        if not face_visible(face, probe): continue
        begin_pass(lit_attachments[probe*6 + face])
            fullscreen triangle — reads albedo/normal/radial/eid/shadow_map,
                                  writes lit color + edge mask
        end_pass()

// 4. Splat to screen
begin_pass(swapchain)
    // Background: fullscreen triangle sampling eye probe lit cubemap
    draw(0, 3, 1)

    // Splat: instanced quads per visible face per probe
    for each visible (probe, face):
        set uniforms identifying probe index, face index, origin, etc.
        draw(0, 6, PROBE_SIZE * PROBE_SIZE)  // vertex shader discards sky
end_pass()
commit()
```

Total passes per frame: 1 (shadow) + ~10 (G-buffer) + ~10 (lighting) + 1 (splat) ≈ **22 passes**.
Each G-buffer/lighting pass is small (384²). The splat pass is the main screen-resolution work.

---

## Implementation Order

1. **Single probe cubemap capture** — 6 faces, MRT (albedo + normal + radial + eid)
2. **Shadow map** — render scene from sun, single depth pass
3. **Lighting fragment pass** — fullscreen triangle per face, sample G-buffer + shadow map, write lit
4. **Splat render** — instanced quads, vertex shader reconstructs world pos from cubemap texel
5. **Background sky** — fullscreen triangle sampling eye probe lit texture
6. **Edge masks** — write during lighting or separate pass, use in splat vertex shader
7. **Grid probe + transition** — second probe snapped to grid, Bayer crossfade
8. **Prev probe** — third probe for smooth transitions
9. **Outlines** — entity ID / normal edge detection in lighting pass
10. **Posterization** — OKLab quantization in lighting pass
11. **Haze / post-processing** — distance fog, god rays, upscale to screen

---

## Source File Map (reference repo)

| File | Role |
|------|------|
| `src/splat.ts` | **Core technique**: G-buffer, lighting, cull, splat (1669 lines) |
| `src/cubemap.ts` | Simpler cubemap-only renderer (comparison baseline) |
| `src/lighting.ts` | Shared: face uniforms, shadow WGSL, lighting WGSL |
| `src/bvh.ts` | BVH traversal WGSL + triangle upload (replaced by shadow maps) |
| `src/lbvh.ts` | GPU LBVH construction (replaced by shadow maps) |
| `src/math.ts` | perspective, lookAt, multiply |
| `src/sky.ts` | Sky rendering, gradient, haze |
| `src/oklab.ts` | OKLab color space for posterization |
| `src/post.ts` | Post-processing (upscale to screen) |
| `src/godrays.ts` | Volumetric god rays |
| `demo/main.ts` | Demo app: scene setup, camera, render loop |
| `demo/scene.ts` | Stone circle + sphere geometry generation |
