// Edge mask pass — compares each texel's radial depth with 4 neighbors.
// Outputs a per-side continuity mask (RGBA8) used by splat vertex shader
// to select tight vs expanded quad half-sizes per side.
// Writes to: edge mask texture (RGBA8, one layer per pass).
// Read by: splat.glsl vertex shader for per-side quad expansion.
@header package game
@header import sg "sokol/gfx"
@ctype vec4 Vec4

// ── Fullscreen triangle vertex shader ───────────────────────────────
@vs edge_mask_vs
out vec2 uv;
void main() {
    uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
@end

// ── Fragment shader ─────────────────────────────────────────────────
// Runs at 384×384 per layer. Reads radial texture, compares with 4 neighbors.
// Output channels encode per-side continuity:
//   R = left  (px-1) continuous: 1.0 = tight fit, 0.0 = expanded (gap fill)
//   G = right (px+1) continuous
//   B = bottom (py-1) continuous
//   A = top   (py+1) continuous
// See TEXEL_SPLATTING_ESSENCE.md § "Quad Sizing & Edge Masks".
@fs edge_mask_fs

// Must match PROBE_SIZE in probe.odin
const int PROBE_RES = 384;

// Relative depth threshold — 0.2% difference triggers discontinuity.
// Matches reference (texel-splatting/src/splat.ts edge mask compute).
const float THRESHOLD = 0.002;

layout(binding=0) uniform edge_mask_params {
    vec4 params;  // x = layer index (0..17), yzw = unused
};

// Radial texture — array texture, TOTAL_LAYERS slices.
// ── Data flow: produced by gbuffer.glsl, consumed here for neighbor comparison ──
layout(binding=0) uniform texture2DArray em_radial;
layout(binding=0) uniform sampler em_smp;

in vec2 uv;
out vec4 out_mask;

void main() {
    int layer = int(params.x);
    ivec2 px = ivec2(gl_FragCoord.xy);

    float radial = texelFetch(sampler2DArray(em_radial, em_smp),
                              ivec3(px, layer), 0).r;

    // Sky texels (no geometry): all sides discontinuous → expanded fit.
    // Doesn't matter in practice since sky texels become degenerate quads.
    if (radial >= 0.999) {
        out_mask = vec4(0.0);
        return;
    }

    // Start with all continuous (tight fit)
    float maskL = 1.0;
    float maskR = 1.0;
    float maskB = 1.0;
    float maskT = 1.0;

    // ── Check left neighbor (px-1) ──────────────────────────────────
    if (px.x > 0) {
        float n = texelFetch(sampler2DArray(em_radial, em_smp),
                             ivec3(px.x - 1, px.y, layer), 0).r;
        if (n >= 0.999 || abs(radial - n) / max(radial, n) >= THRESHOLD) {
            maskL = 0.0;  // discontinuity → expanded fit
        }
    }

    // ── Check right neighbor (px+1) ─────────────────────────────────
    if (px.x < PROBE_RES - 1) {
        float n = texelFetch(sampler2DArray(em_radial, em_smp),
                             ivec3(px.x + 1, px.y, layer), 0).r;
        if (n >= 0.999 || abs(radial - n) / max(radial, n) >= THRESHOLD) {
            maskR = 0.0;
        }
    }

    // ── Check bottom neighbor (py-1) ────────────────────────────────
    if (px.y > 0) {
        float n = texelFetch(sampler2DArray(em_radial, em_smp),
                             ivec3(px.x, px.y - 1, layer), 0).r;
        if (n >= 0.999 || abs(radial - n) / max(radial, n) >= THRESHOLD) {
            maskB = 0.0;
        }
    }

    // ── Check top neighbor (py+1) ───────────────────────────────────
    if (px.y < PROBE_RES - 1) {
        float n = texelFetch(sampler2DArray(em_radial, em_smp),
                             ivec3(px.x, px.y + 1, layer), 0).r;
        if (n >= 0.999 || abs(radial - n) / max(radial, n) >= THRESHOLD) {
            maskT = 0.0;
        }
    }

    out_mask = vec4(maskL, maskR, maskB, maskT);
}
@end

@program edge_mask_pass edge_mask_vs edge_mask_fs
