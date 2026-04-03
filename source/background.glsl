// Background pass — fullscreen triangle sampling probe's lit cubemap.
// Draws at depth 1.0 (far plane) so splat quads render in front.
// Maps screen pixel → world direction → cubemap face + UV → texelFetch lit.
// This provides a pixelated sky/background behind the splat quads.
@header package game
@header import sg "sokol/gfx"
@ctype mat4 Mat4
@ctype vec4 Vec4

// ── Vertex shader ───────────────────────────────────────────────────
// Fullscreen triangle at maximum depth (z/w = 1.0).
// No vertex buffer needed — positions generated from gl_VertexIndex.
@vs bg_vs
out vec2 uv;
void main() {
    // Standard fullscreen triangle trick:
    //   vertex 0: uv=(0,0), pos=(-1,-1)  → bottom-left
    //   vertex 1: uv=(2,0), pos=(3,-1)   → right
    //   vertex 2: uv=(0,2), pos=(-1,3)   → top
    uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    // z = 1.0, w = 1.0 → depth = z/w = 1.0 (at far plane)
    // Background sits behind all splat quads.
    gl_Position = vec4(uv * 2.0 - 1.0, 1.0, 1.0);
}
@end

// ── Fragment shader ─────────────────────────────────────────────────
// Computes view direction from screen UV, maps to cubemap face + texel,
// fetches the lit color from the eye probe's cubemap.
@fs bg_fs

// Camera vectors, viewport info, and haze parameters
layout(binding=0) uniform bg_params {
    vec4 cam_right;     // xyz = camera right direction (unit vector), w = unused
    vec4 cam_up;        // xyz = camera up direction (unit vector), w = unused
    vec4 cam_forward;   // xyz = camera forward direction (unit vector), w = unused
    vec4 viewport_fov;  // x = viewport width, y = viewport height, z = tan(fov/2), w = unused
    vec4 haze_params;   // x = density, y = near, z = far, w = unused
    vec4 haze_color;    // rgb = haze color (linear RGB), a = unused
};

// Lit texture — fully-shaded cubemap from lighting pass.
// ── Data flow: produced by lighting.glsl, consumed here for sky/background ──
layout(binding=0) uniform texture2DArray bg_lit;
layout(binding=0) uniform sampler bg_smp;

// Radial texture — Chebyshev distance for haze computation.
// ── Data flow: produced by gbuffer.glsl, consumed here for distance haze ──
layout(binding=1) uniform texture2DArray bg_radial;
layout(binding=1) uniform sampler bg_radial_smp;

// Must match PROBE_SIZE in probe.odin
const int PROBE_SIZE_C = 384;

in vec2 uv;
out vec4 frag_color;

// ── Direction → cubemap face + UV ───────────────────────────────────
// Inverse of texel_dir(). Given a world direction, returns (face, u, v)
// where u, v are in [0, 1].
// Matches TEXEL_SPLATTING_ESSENCE.md § "Direction → Face + UV".
vec3 dir_to_face_uv(vec3 dir) {
    vec3 a = abs(dir);
    float face_f, u, v;

    if (a.x >= a.y && a.x >= a.z) {
        if (dir.x > 0.0) {
            face_f = 0.0; u = -dir.z / a.x; v = -dir.y / a.x;
        } else {
            face_f = 1.0; u =  dir.z / a.x; v = -dir.y / a.x;
        }
    } else if (a.y >= a.x && a.y >= a.z) {
        if (dir.y > 0.0) {
            face_f = 2.0; u = dir.x / a.y; v =  dir.z / a.y;
        } else {
            face_f = 3.0; u = dir.x / a.y; v = -dir.z / a.y;
        }
    } else {
        if (dir.z > 0.0) {
            face_f = 4.0; u =  dir.x / a.z; v = -dir.y / a.z;
        } else {
            face_f = 5.0; u = -dir.x / a.z; v = -dir.y / a.z;
        }
    }

    return vec3(face_f, u * 0.5 + 0.5, v * 0.5 + 0.5);
}

void main() {
    // ── Compute view direction from screen UV ───────────────────────
    // Convert screen UV [0,1] to NDC [-1,1]
    // OpenGL NDC: -1 at bottom/left, +1 at top/right
    float aspect = viewport_fov.x / viewport_fov.y;
    float tan_half_fov = viewport_fov.z;

    vec2 ndc = uv * 2.0 - 1.0;

    // Ray direction in world space:
    //   In view space, a ray through NDC (x,y) is (x*aspect*tan(fov/2), y*tan(fov/2), -1).
    //   Transform to world using camera basis: right, up, forward.
    //   Since forward = -Z_view, the ray in world space is:
    //     dir = right * ndcX * aspect * tan(fov/2) + up * ndcY * tan(fov/2) + forward
    vec3 dir = normalize(
        cam_right.xyz * ndc.x * aspect * tan_half_fov +
        cam_up.xyz * ndc.y * tan_half_fov +
        cam_forward.xyz
    );

    // ── Map direction to cubemap face + texel ───────────────────────
    vec3 fuv = dir_to_face_uv(dir);
    int face = int(fuv.x);
    float fSize = float(PROBE_SIZE_C);
    int fpx = clamp(int(fuv.y * fSize), 0, PROBE_SIZE_C - 1);
    int fpy = clamp(int(fuv.z * fSize), 0, PROBE_SIZE_C - 1);

    // ── Sample lit cubemap ──────────────────────────────────────────
    // Direct texel fetch — nearest-neighbor for pixel-art aesthetic.
    vec4 lit = texelFetch(sampler2DArray(bg_lit, bg_smp), ivec3(fpx, fpy, face), 0);

    // ── Distance haze for non-sky background texels ─────────────────
    // Sky texels already have correct sky gradient from lighting pass.
    // Non-sky texels get exponential fog based on Chebyshev distance.
    // Reference: splat.ts background fragment — applyHaze(litColor, hazeDist).
    float radial = texelFetch(sampler2DArray(bg_radial, bg_radial_smp),
                              ivec3(fpx, fpy, face), 0).r;
    if (radial < 0.999 && haze_params.x > 0.0) {
        float chebyshev = radial * (haze_params.z - haze_params.y) + haze_params.y;
        vec3 normDir = normalize(dir);
        float maxC = max(abs(normDir.x), max(abs(normDir.y), abs(normDir.z)));
        float hazeDist = chebyshev / maxC;
        float haze = 1.0 - exp(-haze_params.x * hazeDist);
        lit.rgb = mix(lit.rgb, haze_color.rgb, haze);
    }

    frag_color = vec4(lit.rgb, 1.0);
}
@end

@program bg_render bg_vs bg_fs
