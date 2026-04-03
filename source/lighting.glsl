// Lighting pass — fullscreen triangle per cubemap face.
// Reads G-buffer (albedo, normal, radial) + shadow map.
// Reconstructs world position from radial + probe origin + cubemap direction,
// projects into light space for shadow comparison, computes diffuse lighting.
// Writes to: lit texture (RGBA8, one face per pass).
@header package game
@header import sg "sokol/gfx"
@ctype mat4 Mat4
@ctype vec4 Vec4

// ── Fullscreen triangle vertex shader ───────────────────────────────
// Same pattern as debug_vis_vs — generates a screen-filling triangle
// from gl_VertexIndex (0,1,2). No vertex buffer needed.
@vs lighting_vs
out vec2 uv;
void main() {
    uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
@end

// ── Fragment shader ─────────────────────────────────────────────────
// Runs at 384×384 per face. Each invocation reads one G-buffer texel,
// reconstructs its world position, applies shadow + diffuse lighting.
// For grid/prev probes (layer >= 6): detects entity/normal edges and
// applies OKLab lightness adjustment for pixel-art outlines.
@fs lighting_fs

// Must match PROBE_SIZE in probe.odin
const int PROBE_RES = 384;

// Outline constants — match reference (texel-splatting/src/splat.ts).
// See TEXEL_SPLATTING_ESSENCE.md § "Edge Detection (Outlines)".
const float OUTLINE_NORMAL_THRESH = 0.7;  // dot product below this → normal edge
const float OUTLINE_DARKEN = 1.0;         // darken by this many bands
const float OUTLINE_HIGHLIGHT = 1.0;      // highlight by this many bands
const float BANDS = 32.0;                 // posterization band count (used for outline step size)

layout(binding=0) uniform lighting_params {
    mat4 light_vp;       // shadow map view-projection matrix
    vec4 sun_dir;        // xyz = sun direction (unit vector), w = unused
    vec4 sun_color;      // rgb = sun light color, a = unused
    vec4 ambient;        // rgb = ambient light color, a = unused
    vec4 probe_origin;   // xyz = probe world position, w = unused
    vec4 face_near_far;  // x = face index (0–5), y = near, z = far, w = layer index (0–17)
};

// G-buffer textures (array textures, 6 slices = 6 cubemap faces)
// Names prefixed with lt_ to avoid sokol-shdc constant conflicts with debug_vis.glsl
// ── Data flow: produced by gbuffer.glsl MRT capture, consumed here ──
layout(binding=0) uniform texture2DArray lt_albedo;
layout(binding=0) uniform sampler lt_smp;       // nearest — we use texelFetch
layout(binding=1) uniform texture2DArray lt_normal;
layout(binding=2) uniform texture2DArray lt_radial;

// Shadow map — RGBA8 encoded depth, produced by shadow.glsl
// ── Data flow: produced by shadow.odin depth-only pass, consumed here ──
layout(binding=3) uniform texture2D lt_shadow;
layout(binding=1) uniform sampler lt_shadow_smp; // nearest + clamp-to-border(white)

in vec2 uv;
out vec4 frag_color;

// ── Decode RGBA8-packed depth ───────────────────────────────────────
// Must match encode_depth() in shadow.glsl exactly.
float decode_depth(vec4 rgba) {
    return dot(rgba, vec4(1.0, 1.0/255.0, 1.0/65025.0, 1.0/16581375.0));
}

// ── Octahedral normal decode ────────────────────────────────────────
// Inverse of oct_encode() in gbuffer.glsl.
// See TEXEL_SPLATTING_ESSENCE.md § "Octahedral Normal Encoding".
vec3 oct_decode(vec2 e) {
    vec2 f = e * 2.0 - 1.0;
    vec3 n = vec3(f, 1.0 - abs(f.x) - abs(f.y));
    if (n.z < 0.0) {
        n.xy = (1.0 - abs(n.yx)) * vec2(
            n.x >= 0.0 ? 1.0 : -1.0,
            n.y >= 0.0 ? 1.0 : -1.0
        );
    }
    return normalize(n);
}

// ── Sky gradient constants (reference sky.ts, elevation=50°, high sun) ────
// See TEXEL_SPLATTING_ESSENCE.md § "Posterization".
const vec3 SKY_ZENITH  = vec3(0.25, 0.47, 0.815);  // deep blue at top
const vec3 SKY_HORIZON = vec3(0.55, 0.61, 0.7);     // lighter blue-gray at sides
const float HAZE_DENSITY = 0.005;                   // exponential distance haze
const vec3 HAZE_COLOR = vec3(0.5, 0.56, 0.66);      // blue-gray haze (linear RGB)

// ── OKLab color space conversion ────────────────────────────────
// Used for perceptually uniform outline adjustment and posterization.
// Input/output in linear RGB. Matches reference (texel-splatting/src/oklab.ts).
vec3 toOKLab(vec3 c) {
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2220049174 * c.g + 0.6896926207 * c.b;
    // Cube root (clamp to avoid pow of negative due to precision)
    float l_ = pow(max(l, 0.0), 1.0 / 3.0);
    float m_ = pow(max(m, 0.0), 1.0 / 3.0);
    float s_ = pow(max(s, 0.0), 1.0 / 3.0);
    return vec3(
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    );
}

vec3 fromOKLab(vec3 lab) {
    float l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
    float l = l_ * l_ * l_;
    float m = m_ * m_ * m_;
    float s = s_ * s_ * s_;
    return vec3(
         4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    );
}

// ── Posterization ───────────────────────────────────────────────
// Quantizes OKLab lightness to BANDS levels for pixel-art color banding.
// Adds a subtle blue chroma shift for darker values.
// Matches reference (texel-splatting/src/oklab.ts posterize function).
// See TEXEL_SPLATTING_ESSENCE.md § "Posterization".
vec3 posterize(vec3 color) {
    vec3 lab = toOKLab(color);
    float L = clamp(lab.x, 0.0, 1.0);
    lab.x = floor(L * BANDS + 0.5) / BANDS;
    lab.z += (lab.x - 0.5) * 0.05;  // subtle chroma shift
    return max(fromOKLab(lab), vec3(0.0));
}

// ── Edge detection for outlines ─────────────────────────────────
// Compares center texel's entity ID and normal with 4 neighbors.
// Returns: 0 = no edge, 1 = darken, 2 = highlight.
// See TEXEL_SPLATTING_ESSENCE.md § "Edge Detection (Outlines)".
// Matches reference detectEdge() in texel-splatting/src/splat.ts.
int detectEdge(ivec2 coord, int layer, int centerEid, vec3 centerNormal,
               float centerRadial, vec3 viewDir) {
    for (int i = 0; i < 4; i++) {
        // Neighbor offset: right, left, down, up
        int dx = 0, dy = 0;
        if (i == 0) dx = 1;
        else if (i == 1) dx = -1;
        else if (i == 2) dy = 1;
        else dy = -1;

        int nx = coord.x + dx;
        int ny = coord.y + dy;
        if (nx < 0 || ny < 0 || nx >= PROBE_RES || ny >= PROBE_RES) continue;

        ivec3 nc = ivec3(nx, ny, layer);

        // Entity ID comparison — detect object boundaries
        int nEid = int(texelFetch(sampler2DArray(lt_albedo, lt_smp), nc, 0).a * 255.0 + 0.5);
        if (nEid != 0 && centerEid != 0 && nEid != centerEid) {
            // Entity boundary: the closer texel (lower radial) gets darkened.
            // The farther texel skips — the outline appears on the front object.
            float nRadial = texelFetch(sampler2DArray(lt_radial, lt_smp), nc, 0).r;
            if (centerRadial <= nRadial) return 1;  // darken (we're in front)
            continue;  // we're behind — skip, other side will darken
        }

        // Normal comparison — detect creases / surface orientation changes
        vec3 nNormal = oct_decode(texelFetch(sampler2DArray(lt_normal, lt_smp), nc, 0).rg);
        if (dot(centerNormal, nNormal) < OUTLINE_NORMAL_THRESH) {
            // Normal discontinuity: surface facing camera more → highlight,
            // surface facing away more → darken.
            if (dot(centerNormal, viewDir) > dot(nNormal, viewDir)) return 2;
            return 1;
        }
    }
    return 0;  // no edge
}

// ── Cubemap face UV → direction ─────────────────────────────────────
// Returns unnormalized direction from probe origin through this texel.
// u, v in [-1, 1]. Matches face_uv_to_dir() in probe.odin and
// TEXEL_SPLATTING_ESSENCE.md § "Cubemap Face ↔ Direction Mapping".
vec3 face_uv_to_dir(int face, float u, float v) {
    if (face == 0) return vec3( 1, -v, -u); // +X
    if (face == 1) return vec3(-1, -v,  u); // -X
    if (face == 2) return vec3( u,  1,  v); // +Y
    if (face == 3) return vec3( u, -1, -v); // -Y
    if (face == 4) return vec3( u, -v,  1); // +Z
    return vec3(-u, -v, -1);                // -Z
}

void main() {
    int face = int(face_near_far.x);   // cubemap face direction (0-5)
    float near = face_near_far.y;
    float far  = face_near_far.z;
    int layer = int(face_near_far.w);   // array texture layer (probe_idx * 6 + face)

    // Texel coordinates — gl_FragCoord is in [0.5, 383.5] for a 384×384 target.
    // Sokol auto-sets viewport to match attachment size.
    ivec2 px = ivec2(gl_FragCoord.xy);

    // ── Sample G-buffer ─────────────────────────────────────────────
    // Use 'layer' (not 'face') to index into the correct probe's data.
    vec3 albedo  = texelFetch(sampler2DArray(lt_albedo, lt_smp), ivec3(px, layer), 0).rgb;
    vec2 enc_nrm = texelFetch(sampler2DArray(lt_normal, lt_smp), ivec3(px, layer), 0).rg;
    float radial = texelFetch(sampler2DArray(lt_radial, lt_smp), ivec3(px, layer), 0).r;

    // ── Compute cubemap direction ────────────────────────────────
    // Needed for both sky gradient and world position reconstruction.
    float u_coord = gl_FragCoord.x / float(PROBE_RES) * 2.0 - 1.0;
    float v_coord = gl_FragCoord.y / float(PROBE_RES) * 2.0 - 1.0;
    vec3 dir = face_uv_to_dir(face, u_coord, v_coord);

    // ── Sky texels → procedural sky gradient ────────────────────────
    // radial >= 0.999 means no geometry hit. Render a direction-based
    // zenith/horizon gradient, posterized for pixel-art look.
    // See sky.ts sampleSky() and TEXEL_SPLATTING_ESSENCE.md § "Posterization".
    if (radial >= 0.999) {
        vec3 normDir = normalize(dir);
        // pow(y, 0.25) gives rapid blend from horizon to zenith.
        // clamp(y, 0..1) means below-horizon is pure horizon color.
        float t = pow(clamp(normDir.y, 0.0, 1.0), 0.25);
        vec3 skyColor = mix(SKY_HORIZON, SKY_ZENITH, t);

        // Horizon haze — makes lower sky blend toward haze color
        // Reference: sky.ts sampleSky() horizon haze section
        float horizonFactor = 1.0 - clamp(normDir.y, 0.0, 1.0);
        float hazeAmount = pow(horizonFactor, 2.0) * min(HAZE_DENSITY * 5.0, 1.0);
        skyColor = mix(skyColor, HAZE_COLOR, hazeAmount);

        frag_color = vec4(posterize(skyColor), 1.0);
        return;
    }

    // ── Decode normal ───────────────────────────────────────────────
    vec3 normal = oct_decode(enc_nrm);

    // ── Reconstruct world position ──────────────────────────────────
    // See TEXEL_SPLATTING_ESSENCE.md § "World Position Reconstruction":
    //   dir = faceUVtoDir(face, u, v)          — unnormalized direction
    //   maxComp = max(|dir.x|, |dir.y|, |dir.z|)
    //   chebyshev = radial * (far - near) + near  — undo normalization
    //   worldPos = origin + dir * (chebyshev / maxComp)
    float max_comp = max(max(abs(dir.x), abs(dir.y)), abs(dir.z));
    float chebyshev = radial * (far - near) + near;
    vec3 world_pos = probe_origin.xyz + dir * (chebyshev / max_comp);

    // ── Diffuse lighting ────────────────────────────────────────────
    float ndotl = max(dot(normal, normalize(sun_dir.xyz)), 0.0);

    // ── Shadow mapping ──────────────────────────────────────────────
    // Project reconstructed world pos into light clip space, compare
    // with RGBA8-encoded depth from shadow pass. 3×3 PCF for soft edges.
    // Same technique as forward.glsl — proven working in M1.
    vec4 light_clip = light_vp * vec4(world_pos, 1.0);
    vec3 light_ndc  = light_clip.xyz / light_clip.w;
    float frag_depth = light_ndc.z * 0.5 + 0.5;
    vec2  shadow_uv  = light_ndc.xy * 0.5 + 0.5;

    float shadow = 1.0;
    if (shadow_uv.x >= 0.0 && shadow_uv.x <= 1.0 &&
        shadow_uv.y >= 0.0 && shadow_uv.y <= 1.0) {

        // 1.0/2048.0 — must match SHADOW_MAP_SIZE in shadow.odin
        float texel_size = 1.0 / 2048.0;
        float shadow_sum = 0.0;
        // Bias: larger for surfaces at grazing angle to the light
        float bias = max(0.005 * (1.0 - ndotl), 0.001);

        // 3×3 PCF — sample 9 neighbors for soft shadow edges
        for (int x = -1; x <= 1; x++) {
            for (int y = -1; y <= 1; y++) {
                float d = decode_depth(texture(sampler2D(lt_shadow, lt_shadow_smp),
                    shadow_uv + vec2(x, y) * texel_size));
                shadow_sum += (frag_depth - bias > d) ? 0.0 : 1.0;
            }
        }
        shadow = shadow_sum / 9.0;
    }

    // ── Final color (linear RGB) ─────────────────────────────────────
    vec3 lit = ambient.xyz + sun_color.xyz * ndotl * shadow;
    vec3 color = albedo * lit;

    // ── Outline detection (grid + prev probes only) ─────────────────
    // Entity ID / normal edge detection produces pixel-art outlines.
    // Eye probe (layers 0-5) skips outlines — it's at camera pos, outlines
    // would look wrong at close range. Grid/prev (layers 6+) get outlines.
    // See TEXEL_SPLATTING_ESSENCE.md § "Edge Detection (Outlines)".
    int probeIdx = layer / 6;
    if (probeIdx >= 1) {
        // Entity ID from albedo.a (stored as f32(id)/255.0 in gbuffer.glsl)
        int centerEid = int(texelFetch(sampler2DArray(lt_albedo, lt_smp),
                                       ivec3(px, layer), 0).a * 255.0 + 0.5);

        // View direction: from world position toward probe origin.
        // Used to determine which side of a normal edge faces the camera.
        vec3 viewDir = normalize(probe_origin.xyz - world_pos);

        int edge = detectEdge(px, layer, centerEid, normal, radial, viewDir);
        if (edge != 0) {
            // Adjust lightness in OKLab by one posterization band.
            // edge == 1: darken (entity boundary or normal edge facing camera)
            // edge == 2: highlight (normal edge facing away from camera)
            float bandSize = 1.0 / BANDS;
            vec3 lab = toOKLab(color);
            if (edge == 1) {
                lab.x -= OUTLINE_DARKEN * bandSize;
            } else {
                lab.x += OUTLINE_HIGHLIGHT * bandSize;
            }
            lab.x = clamp(lab.x, 0.0, 1.0);
            color = max(fromOKLab(lab), vec3(0.0));
        }
    }

    // Posterize — quantize lightness for pixel-art color banding.
    // Applied after outlines so outline adjustments are also quantized.
    color = posterize(color);

    // Output linear RGB — gamma correction moved to post.glsl
    frag_color = vec4(color, 1.0);
}
@end

@program lighting_pass lighting_vs lighting_fs
