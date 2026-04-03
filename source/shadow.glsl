@header package game
@header import sg "sokol/gfx"
@ctype mat4 Mat4

@vs shadow_vs
layout(binding=0) uniform shadow_vs_params {
    mat4 mvp;
};

layout(location=0) in vec3 position;
layout(location=1) in vec3 normal; // must match forward vertex layout

void main() {
    float _n = normal.x; // suppress unused warning
    gl_Position = mvp * vec4(position, 1.0);
}
@end

@fs shadow_fs
out vec4 frag_color;

vec4 encode_depth(float v) {
    vec4 enc = vec4(1.0, 255.0, 65025.0, 16581375.0) * v;
    enc = fract(enc);
    enc -= enc.yzww * vec4(1.0/255.0, 1.0/255.0, 1.0/255.0, 0.0);
    return enc;
}

void main() {
    frag_color = encode_depth(gl_FragCoord.z);
}
@end

@program shadow_caster shadow_vs shadow_fs
