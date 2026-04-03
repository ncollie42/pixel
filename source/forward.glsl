@header package game
@header import sg "sokol/gfx"
@ctype mat4 Mat4
@ctype vec4 Vec4

@vs forward_vs
layout(binding=0) uniform forward_vs_params {
    mat4 mvp;
    mat4 model;
};

layout(location=0) in vec3 position;
layout(location=1) in vec3 normal;

out vec3 v_world_pos;
out vec3 v_normal;

void main() {
    v_world_pos = (model * vec4(position, 1.0)).xyz;
    v_normal = (model * vec4(normal, 0.0)).xyz;
    gl_Position = mvp * vec4(position, 1.0);
}
@end

@fs forward_fs
layout(binding=1) uniform forward_fs_params {
    mat4 light_vp;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 ambient;
    vec4 object_color;
};

layout(binding=0) uniform texture2D shadow_tex;
layout(binding=0) uniform sampler shadow_smp;

in vec3 v_world_pos;
in vec3 v_normal;
out vec4 frag_color;

float decode_depth(vec4 rgba) {
    return dot(rgba, vec4(1.0, 1.0/255.0, 1.0/65025.0, 1.0/16581375.0));
}

void main() {
    vec3 n = normalize(v_normal);
    float ndotl = max(dot(n, normalize(sun_dir.xyz)), 0.0);

    // Shadow mapping
    vec4 light_clip = light_vp * vec4(v_world_pos, 1.0);
    vec3 light_ndc = light_clip.xyz / light_clip.w;
    float frag_depth = light_ndc.z * 0.5 + 0.5;
    vec2 shadow_uv = light_ndc.xy * 0.5 + 0.5;

    float shadow = 1.0;
    if (shadow_uv.x >= 0.0 && shadow_uv.x <= 1.0 &&
        shadow_uv.y >= 0.0 && shadow_uv.y <= 1.0) {

        float texel_size = 1.0 / 2048.0;
        float shadow_sum = 0.0;
        float bias = max(0.005 * (1.0 - ndotl), 0.001);

        for (int x = -1; x <= 1; x++) {
            for (int y = -1; y <= 1; y++) {
                float d = decode_depth(texture(sampler2D(shadow_tex, shadow_smp),
                    shadow_uv + vec2(x, y) * texel_size));
                shadow_sum += (frag_depth - bias > d) ? 0.0 : 1.0;
            }
        }
        shadow = shadow_sum / 9.0;
    }

    vec3 lit = ambient.xyz + sun_color.xyz * ndotl * shadow;
    vec3 color = object_color.xyz * lit;
    color = pow(color, vec3(1.0 / 2.2));
    frag_color = vec4(color, 1.0);
}
@end

@program forward_lit forward_vs forward_fs
