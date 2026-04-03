// G-buffer capture — renders scene into MRT per cubemap face.
// Writes to: albedo (RGBA8), normal (RGBA8, octahedral), radial (R32F, Chebyshev).
// Read by: lighting pass (lighting.glsl, samples these textures to shade each texel).
@header package game
@header import sg "sokol/gfx"
@ctype mat4 Mat4
@ctype vec4 Vec4
@ctype vec3 Vec3

// ── Vertex shader ───────────────────────────────────────────────────
@vs gbuffer_vs
layout(binding=0) uniform gbuffer_vs_params {
    mat4 view_proj;  // cube face view * projection
    mat4 model;      // object model matrix
    vec4 probe_origin; // xyz = probe origin, w = unused
};

layout(location=0) in vec3 position;
layout(location=1) in vec3 normal;

out vec3 v_world_pos;
out vec3 v_world_normal;

void main() {
    vec4 world = model * vec4(position, 1.0);
    v_world_pos = world.xyz;
    // Transform normal by model matrix (assumes no non-uniform scale on normals,
    // acceptable for axis-aligned boxes)
    v_world_normal = (model * vec4(normal, 0.0)).xyz;
    gl_Position = view_proj * world;
}
@end

// ── Fragment shader ─────────────────────────────────────────────────
// MRT output:
//   location 0: albedo (RGBA8)
//   location 1: normal (RGBA8, octahedral encoded in RG)
//   location 2: radial (R32F, Chebyshev distance normalized to [0,1])
@fs gbuffer_fs
layout(binding=1) uniform gbuffer_fs_params {
    vec4 object_color;   // rgb = albedo, a = unused
    vec4 probe_data;     // xyz = probe origin, w = unused
    vec4 near_far;       // x = near, y = far, z = entity ID (normalized), w = unused
};

in vec3 v_world_pos;
in vec3 v_world_normal;

layout(location=0) out vec4 out_albedo;
layout(location=1) out vec4 out_normal;
layout(location=2) out vec4 out_radial;

// ── Octahedral normal encoding ──────────────────────────────────────
// Packs a unit normal into 2 floats in [0,1].
// See TEXEL_SPLATTING_ESSENCE.md § "Octahedral Normal Encoding".
vec2 oct_encode(vec3 n) {
    // Project onto L1 unit octahedron
    vec2 p = n.xy / (abs(n.x) + abs(n.y) + abs(n.z));
    // Wrap lower hemisphere
    if (n.z < 0.0) {
        p = (1.0 - abs(p.yx)) * vec2(
            p.x >= 0.0 ? 1.0 : -1.0,
            p.y >= 0.0 ? 1.0 : -1.0
        );
    }
    return p * 0.5 + 0.5;
}

void main() {
    // Albedo: RGB = object color, A = entity ID (normalized to [0,1] for RGBA8 storage).
    // Entity ID 0 = sky/no geometry (from clear value), 1+ = objects.
    // Used by lighting.glsl for outline detection at entity boundaries.
    float entity_id = near_far.z;  // passed as f32(id)/255.0 from gbuffer.odin
    out_albedo = vec4(object_color.rgb, entity_id);

    // Normal: octahedral-encode the world-space normal into RG
    vec3 n = normalize(v_world_normal);
    vec2 enc = oct_encode(n);
    out_normal = vec4(enc, 0.0, 1.0);

    // Radial: Chebyshev distance from probe origin, normalized to [0,1].
    // chebyshev = max(|dx|, |dy|, |dz|) — the L-infinity norm.
    // See TEXEL_SPLATTING_ESSENCE.md § "Distance Encoding".
    vec3 diff = v_world_pos - probe_data.xyz;
    float chebyshev = max(max(abs(diff.x), abs(diff.y)), abs(diff.z));
    float radial = (chebyshev - near_far.x) / (near_far.y - near_far.x);
    radial = clamp(radial, 0.0, 1.0);
    out_radial = vec4(radial, 0.0, 0.0, 0.0);
}
@end

@program gbuffer_capture gbuffer_vs gbuffer_fs
