// Debug visualization — fullscreen quad sampling a G-buffer layer.
// Used via Tab key to inspect albedo, normal, radial, and lit textures.
@header package game
@header import sg "sokol/gfx"
@ctype mat4 Mat4
@ctype vec4 Vec4

// ── Fullscreen triangle vertex shader ───────────────────────────────
// Generates a fullscreen triangle from gl_VertexIndex (0,1,2).
// No vertex buffer needed.
@vs debug_vis_vs
out vec2 uv;
void main() {
    // Standard fullscreen triangle trick:
    // vertex 0: (-1, -1), vertex 1: (3, -1), vertex 2: (-1, 3)
    uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
@end

// ── Fragment shader ─────────────────────────────────────────────────
// Samples one layer of a texture2DArray at the given face index.
// mode selects what to visualize: 0=albedo, 1=normal, 2=radial, 3=lit.
@fs debug_vis_fs
layout(binding=0) uniform debug_vis_params {
    vec4 settings;  // x = layer index (probe*6+face), y = mode (0=albedo,1=normal,2=radial,3=lit), zw = unused
};

layout(binding=0) uniform texture2DArray albedo_tex;
layout(binding=0) uniform sampler tex_smp;
layout(binding=1) uniform texture2DArray normal_tex;
layout(binding=2) uniform texture2DArray radial_tex;
layout(binding=3) uniform texture2DArray lit_tex;

in vec2 uv;
out vec4 frag_color;

void main() {
    int face = int(settings.x);
    int mode = int(settings.y);

    if (mode == 0) {
        // Albedo: show RGB directly
        vec4 c = texelFetch(sampler2DArray(albedo_tex, tex_smp), ivec3(uv * 384.0, face), 0);
        frag_color = vec4(c.rgb, 1.0);
    } else if (mode == 1) {
        // Normal: decode octahedral → show as color
        vec4 c = texelFetch(sampler2DArray(normal_tex, tex_smp), ivec3(uv * 384.0, face), 0);
        // Octahedral decode
        vec2 f = c.rg * 2.0 - 1.0;
        vec3 n = vec3(f, 1.0 - abs(f.x) - abs(f.y));
        if (n.z < 0.0) {
            n.xy = (1.0 - abs(n.yx)) * vec2(
                n.x >= 0.0 ? 1.0 : -1.0,
                n.y >= 0.0 ? 1.0 : -1.0
            );
        }
        n = normalize(n);
        frag_color = vec4(n * 0.5 + 0.5, 1.0);
    } else if (mode == 2) {
        // Radial: show as grayscale (0=near → black, 1=far → white)
        vec4 c = texelFetch(sampler2DArray(radial_tex, tex_smp), ivec3(uv * 384.0, face), 0);
        frag_color = vec4(vec3(c.r), 1.0);
    } else {
        // Lit: show fully-shaded color from lighting pass.
        // Apply gamma since lighting pass outputs linear RGB (gamma moved to post.glsl).
        vec4 c = texelFetch(sampler2DArray(lit_tex, tex_smp), ivec3(uv * 384.0, face), 0);
        vec3 color = pow(max(c.rgb, vec3(0.0)), vec3(1.0 / 2.2));
        frag_color = vec4(color, 1.0);
    }
}
@end

@program debug_vis debug_vis_vs debug_vis_fs
