// Splat render — instanced quads from cubemap texels. Core of texel splatting.
// Vertex shader reconstructs world-space quads from G-buffer radial distance.
// Fragment shader samples pre-lit color from lighting pass output.
// Supports 3-probe rendering (eye + grid + prev) with Bayer-dithered crossfade (M6).
// Renders into: swapchain (screen), after background pass.
@header package game
@header import sg "sokol/gfx"
@ctype mat4 Mat4
@ctype vec4 Vec4

// ── Vertex shader ───────────────────────────────────────────────────
// No vertex buffer — everything derived from gl_InstanceIndex and gl_VertexIndex.
// Each instance = one cubemap texel = one quad (6 vertices, 2 triangles).
// Sky texels (radial >= 0.999) emit degenerate triangles, culled by GPU for free.
@vs splat_vs

layout(binding=0) uniform splat_vs_params {
    mat4 view_proj;      // camera view * projection — projects world-space quads to screen
    vec4 probe_origin;   // xyz = probe world position, w = unused
    vec4 face_params;    // x = face index (0–5), y = near, z = far, w = layer index (0-17)
    vec4 splat_params;   // x = probe_idx (0=eye, 1=grid, 2=prev), y = fade_t (0..1), zw = unused
    vec4 camera_pos;     // xyz = camera world position (for viewing angle in edge mask expansion)
};

// Radial texture — array texture, TOTAL_LAYERS slices (3 probes × 6 faces).
// Used in vertex stage to reconstruct world position from Chebyshev distance.
// R32F format. Uses texelFetch (sampler technically unused but required by sokol-shdc).
// ── Data flow: produced by gbuffer.glsl MRT capture, consumed here ──
layout(binding=0) uniform texture2DArray sp_radial;
layout(binding=0) uniform sampler sp_smp;

// Edge mask texture — RGBA8, TOTAL_LAYERS slices.
// Per-side continuity mask: R=left, G=right, B=bottom, A=top.
// 1.0 = continuous (tight fit), 0.0 = discontinuity (expanded fit).
// ── Data flow: produced by edge_mask.glsl, consumed here ──
layout(binding=2) uniform texture2DArray sp_edge_mask;
layout(binding=2) uniform sampler sp_edge_smp;

// Must match PROBE_SIZE in probe.odin
const int PROBE_SIZE_C = 384;

// Expansion factor for gap filling at depth discontinuities.
// See TEXEL_SPLATTING_ESSENCE.md § "Quad Sizing & Edge Masks".
const float EXPANSION = 0.5;

// Flat varyings — same for all fragments in a primitive (no interpolation).
// Passed to fragment shader to index into the lit texture and apply crossfade.
flat out float v_px;
flat out float v_py;
flat out float v_layer;      // array texture layer index (probe_idx * 6 + face)
flat out float v_probe_idx;  // 0 = eye, 1 = grid
flat out float v_fade_t;     // crossfade progress (0 = start/done, 0..1 = active)
flat out float v_haze_dist;  // distance from camera to texel world position (for haze)

// ── Cubemap face direction from UV ──────────────────────────────────
// u, v in [-1, 1]. Returns unnormalized direction from probe origin.
// Matches face_uv_to_dir() in probe.odin and
// TEXEL_SPLATTING_ESSENCE.md § "Cubemap Face ↔ Direction Mapping".
vec3 texel_dir(int face, float u, float v) {
    if (face == 0) return vec3( 1, -v, -u); // +X
    if (face == 1) return vec3(-1, -v,  u); // -X
    if (face == 2) return vec3( u,  1,  v); // +Y
    if (face == 3) return vec3( u, -1, -v); // -Y
    if (face == 4) return vec3( u, -v,  1); // +Z
    return vec3(-u, -v, -1);                // -Z
}

void main() {
    int face = int(face_params.x);
    float near = face_params.y;
    float far  = face_params.z;
    int layer = int(face_params.w);
    int probe_idx = int(splat_params.x);
    float fade_t = splat_params.y;

    // ── Derive texel coordinates from instance index ────────────────
    // Each instance = one cubemap texel. PROBE_SIZE² instances per draw call.
    int texel_idx = gl_InstanceIndex;
    int px = texel_idx % PROBE_SIZE_C;
    int py = texel_idx / PROBE_SIZE_C;

    // Store for fragment shader (as float because flat int varyings
    // can have cross-compilation issues with sokol-shdc)
    v_px = float(px);
    v_py = float(py);
    v_layer = float(layer);
    v_probe_idx = float(probe_idx);
    v_fade_t = fade_t;

    // ── Sample radial distance ──────────────────────────────────────
    // Vertex texture fetch — reads Chebyshev distance for this texel.
    // radial >= 0.999 means sky (no geometry hit) → emit degenerate triangle.
    // GPU culls degenerate primitives at primitive assembly, essentially free.
    // Uses 'layer' to index into correct probe's radial data.
    float radial = texelFetch(sampler2DArray(sp_radial, sp_smp),
                              ivec3(px, py, layer), 0).r;

    if (radial >= 0.999) {
        gl_Position = vec4(0.0, 0.0, 0.0, 0.0);
        return;
    }

    // ── Reconstruct world position ──────────────────────────────────
    // chebyshev = radial * (far - near) + near — undo [0,1] normalization
    // dir = unnormalized direction from face UV
    // worldPos = origin + dir * (chebyshev / max(|dir.x|, |dir.y|, |dir.z|))
    // See TEXEL_SPLATTING_ESSENCE.md § "World Position Reconstruction"
    float chebyshev = radial * (far - near) + near;

    // Texel center UV in [0, 1]
    float sizeF = float(PROBE_SIZE_C);
    float centerU = (float(px) + 0.5) / sizeF;
    float centerV = (float(py) + 0.5) / sizeF;

    // ── Quad expansion with edge mask ─────────────────────────────────
    // Each texel becomes a world-space quad. Two half-size modes:
    //   hs = halfTexel + expansion  (expanded — gap fill at silhouettes)
    //   hsEdge = halfTexel * 1.15 + 0.0005 * tanTheta  (tight, angle-compensated)
    // Edge mask selects per-side: continuous neighbors → tight, discontinuities → expanded.
    // See TEXEL_SPLATTING_ESSENCE.md § "Quad Sizing & Edge Masks".
    float half_texel = 0.5 / sizeF;
    float exp_factor = EXPANSION / sizeF;
    float hs = half_texel + exp_factor;  // expanded half-size (depth discontinuities)

    // ── Compute center world position (needed for viewing angle + haze) ──
    vec3 centerDir = texel_dir(face, centerU * 2.0 - 1.0, centerV * 2.0 - 1.0);
    float centerMaxComp = max(abs(centerDir.x), max(abs(centerDir.y), abs(centerDir.z)));
    vec3 centerPos = probe_origin.xyz + centerDir * (chebyshev / centerMaxComp);

    // ── Distance from camera to texel (for fragment haze) ─────────────
    // Uses camera position, not probe origin — haze is view-dependent.
    // Matches reference: length(input.hazePos - splatScene.cameraPos)
    v_haze_dist = length(centerPos - camera_pos.xyz);

    // ── Face normal (axis-aligned direction for this cubemap face) ────
    vec3 faceNormal;
    if (face == 0) faceNormal = vec3(1.0, 0.0, 0.0);
    else if (face == 1) faceNormal = vec3(-1.0, 0.0, 0.0);
    else if (face == 2) faceNormal = vec3(0.0, 1.0, 0.0);
    else if (face == 3) faceNormal = vec3(0.0, -1.0, 0.0);
    else if (face == 4) faceNormal = vec3(0.0, 0.0, 1.0);
    else faceNormal = vec3(0.0, 0.0, -1.0);

    // ── Viewing angle compensation ───────────────────────────────────
    // At grazing angles, texels appear compressed and need more expansion.
    // cosTheta clamped to 0.14 (~82°) to cap maximum expansion.
    // Matches reference (texel-splatting/src/splat.ts splatShader vs()).
    vec3 viewDir = normalize(centerPos - camera_pos.xyz);
    float cosTheta = max(abs(dot(viewDir, faceNormal)), 0.14);
    float tanTheta = sqrt(1.0 - cosTheta * cosTheta) / cosTheta;
    float hsEdge = half_texel * 1.15 + 0.0005 * tanTheta;  // tight half-size

    // ── Sample edge mask — per-side continuity ────────────────────────
    // R=left, G=right, B=bottom, A=top.
    // 1.0 = continuous (tight), 0.0 = discontinuity (expanded).
    vec4 emask = texelFetch(sampler2DArray(sp_edge_mask, sp_edge_smp),
                            ivec3(px, py, layer), 0);
    float hsL = (emask.r > 0.5) ? hsEdge : hs;  // left  (u-)
    float hsR = (emask.g > 0.5) ? hsEdge : hs;  // right (u+)
    float hsB = (emask.b > 0.5) ? hsEdge : hs;  // bottom (v-)
    float hsT = (emask.a > 0.5) ? hsEdge : hs;  // top    (v+)

    // Per-side corner UVs
    float u0 = centerU - hsL;
    float v0 = centerV - hsB;
    float u1 = centerU + hsR;
    float v1 = centerV + hsT;

    // ── Quad vertex expansion ───────────────────────────────────────
    // 6 vertices per quad (two triangles):
    //   vid 0,3: bottom-left  (u0, v0)
    //   vid 1:   bottom-right (u1, v0)
    //   vid 2,4: top-right    (u1, v1)
    //   vid 5:   top-left     (u0, v1)
    float cu, cv;
    int vid = gl_VertexIndex % 6;
    if      (vid == 0 || vid == 3) { cu = u0; cv = v0; }
    else if (vid == 1)             { cu = u1; cv = v0; }
    else if (vid == 2 || vid == 4) { cu = u1; cv = v1; }
    else                           { cu = u0; cv = v1; }

    // Convert corner UV [0,1] to direction [-1,1] and reconstruct world position
    vec3 raw_dir = texel_dir(face, cu * 2.0 - 1.0, cv * 2.0 - 1.0);
    float max_comp = max(abs(raw_dir.x), max(abs(raw_dir.y), abs(raw_dir.z)));
    vec3 world_pos = probe_origin.xyz + raw_dir * (chebyshev / max_comp);

    gl_Position = view_proj * vec4(world_pos, 1.0);

    // ── Depth jitter ────────────────────────────────────────────────
    // Small hash-based depth bias to reduce z-fighting between adjacent texels.
    // Uses Knuth's multiplicative hash for uniform distribution over [0, 255].
    // Uses 'layer' (not face) to differentiate probes' hash values.
    uint tid = uint(layer * PROBE_SIZE_C * PROBE_SIZE_C + py * PROBE_SIZE_C + px);
    uint h = (tid * 2654435761u) >> 24u;
    gl_Position.z += float(h) * 1e-9 * gl_Position.w;

    // ── Probe depth bias ────────────────────────────────────────────
    // Eye probe gets pushed slightly farther so grid probe wins overlapping
    // depth test. Grid provides the stable base rendering; eye fills gaps.
    // See TEXEL_SPLATTING_ESSENCE.md § "Transition System".
    if (probe_idx == 0) {
        gl_Position.z += 0.001 * gl_Position.w;
    }

    // Clamp depth to [0, w] to prevent behind-camera artifacts
    gl_Position.z = min(gl_Position.z, gl_Position.w);
}
@end

// ── Fragment shader ─────────────────────────────────────────────────
// Samples the pre-lit color from the lighting pass output.
// Applies Bayer-dithered crossfade: grid fades IN, prev fades OUT (inverse Bayer).
@fs splat_fs

// Lit texture — fully-shaded color from lighting pass.
// ── Data flow: produced by lighting.glsl, consumed here for final output ──
layout(binding=1) uniform texture2DArray sp_lit;
layout(binding=1) uniform sampler sp_lit_smp;

flat in float v_px;
flat in float v_py;
flat in float v_layer;
flat in float v_probe_idx;
flat in float v_fade_t;
flat in float v_haze_dist;

out vec4 frag_color;

// ── Distance haze constants ───────────────────────────────────
// Exponential fog blending toward horizon color.
// Must match values in lighting.glsl and background.glsl.
// Reference: sky.ts HAZE_WGSL, elevation=50° daytime values.
const float HAZE_DENSITY = 0.005;
const vec3 HAZE_COLOR = vec3(0.5, 0.56, 0.66);

// ── Bayer 4×4 dithering matrix ──────────────────────────────────────
// Returns a threshold in [0, 15/16] based on screen-space position.
// Used for ordered dithering crossfade between probes.
// See TEXEL_SPLATTING_ESSENCE.md § "Bayer Dithered Crossfade".
float bayer4(uvec2 pos) {
    uint x = pos.x % 4u;
    uint y = pos.y % 4u;
    // Standard 4×4 Bayer matrix, normalized to [0, 15/16]
    float bayer[16] = float[16](
         0.0/16.0,  8.0/16.0,  2.0/16.0, 10.0/16.0,
        12.0/16.0,  4.0/16.0, 14.0/16.0,  6.0/16.0,
         3.0/16.0, 11.0/16.0,  1.0/16.0,  9.0/16.0,
        15.0/16.0,  7.0/16.0, 13.0/16.0,  5.0/16.0
    );
    return bayer[y * 4u + x];
}

void main() {
    // Direct texel fetch — no filtering, exact pixel-art colors
    int px = int(v_px);
    int py = int(v_py);
    int layer = int(v_layer);
    int probe_idx = int(v_probe_idx);
    float fade_t = v_fade_t;

    vec4 lit = texelFetch(sampler2DArray(sp_lit, sp_lit_smp),
                          ivec3(px, py, layer), 0);

    // ── Bayer dithered crossfade (grid + prev probes) ────────────
    // During a grid origin transition (0 < fade_t < 1), grid and prev
    // probes use complementary Bayer patterns so they tile the screen
    // without overlap. Eye probe (idx=0) is always fully visible.
    // See TEXEL_SPLATTING_ESSENCE.md § "Bayer Dithered Crossfade".
    //
    // Grid (idx=1): fades IN — discard if threshold >= fade_t
    //   At fade_t≈0: threshold >= ~0 → mostly discarded (grid barely visible)
    //   At fade_t≈1: threshold >= ~1 never true → nothing discarded (fully visible)
    // Prev (idx=2): fades OUT — discard if threshold < fade_t (inverse of grid)
    //   At fade_t≈0: threshold < ~0 never true → nothing discarded (fully visible)
    //   At fade_t≈1: threshold < ~1 → mostly discarded (prev nearly invisible)
    if (probe_idx == 1 && fade_t > 0.0 && fade_t < 1.0) {
        float threshold = bayer4(uvec2(gl_FragCoord.xy));
        if (threshold >= fade_t) discard;
    }
    if (probe_idx == 2 && fade_t > 0.0 && fade_t < 1.0) {
        float threshold = bayer4(uvec2(gl_FragCoord.xy));
        if (threshold < fade_t) discard;
    }

    // ── Distance haze ───────────────────────────────────────────
    // Exponential fog blending lit color toward haze color at distance.
    // Applied in linear space (lit texture stores linear RGB).
    // Reference: sky.ts HAZE_WGSL applyHaze().
    float haze = 1.0 - exp(-HAZE_DENSITY * v_haze_dist);
    vec3 color = mix(lit.rgb, HAZE_COLOR, haze);

    frag_color = vec4(color, 1.0);
}
@end

@program splat_render splat_vs splat_fs
