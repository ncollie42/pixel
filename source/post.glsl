// Post-processing — upscale offscreen render to swapchain.
// Nearest-neighbor sampling preserves pixel-art look.
// Applies gamma correction (lighting pass outputs linear RGB).
// Writes to: swapchain framebuffer.
@header package game
@header import sg "sokol/gfx"

@vs post_vs
out vec2 uv;
void main() {
    uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
@end

@fs post_fs

layout(binding=0) uniform texture2D pt_color;
layout(binding=0) uniform sampler pt_smp;

in vec2 uv;
out vec4 frag_color;

void main() {
    vec3 color = texture(sampler2D(pt_color, pt_smp), uv).rgb;
    // Gamma correction (linear → sRGB)
    color = pow(max(color, vec3(0.0)), vec3(1.0 / 2.2));
    frag_color = vec4(color, 1.0);
}
@end

@program post_blit post_vs post_fs
