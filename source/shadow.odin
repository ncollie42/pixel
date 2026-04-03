// shadow.odin — Shadow map: depth texture (2048²), render scene from sun, provide texture for sampling.
package game

import "core:math"
import sg "sokol/gfx"
import la "core:math/linalg"

SHADOW_MAP_SIZE :: 2048

SUN_ORBIT_SPEED :: f32(0.3)  // radians/s — full circle in ~21s
SUN_ELEVATION   :: f32(0.9)  // radians above horizon (~52°)

Shadow_Map :: struct {
	// GPU resources
	color_img:     sg.Image,  // RGBA8 encoded depth
	depth_img:     sg.Image,  // hardware depth buffer
	color_att_view: sg.View,
	depth_att_view: sg.View,
	tex_view:      sg.View,   // for sampling in forward pass
	pip:           sg.Pipeline,
	sampler:       sg.Sampler,

	// Light parameters
	light_vp:  Mat4,
	sun_dir:   Vec3,
	sun_angle: f32,  // current orbit angle (radians)
}

shadow_init :: proc(sm: ^Shadow_Map) {
	sm.color_img = sg.make_image({
		type         = ._2D,
		usage        = {color_attachment = true},
		width        = SHADOW_MAP_SIZE,
		height       = SHADOW_MAP_SIZE,
		pixel_format = .RGBA8,
		sample_count = 1,
	})

	sm.depth_img = sg.make_image({
		type         = ._2D,
		usage        = {depth_stencil_attachment = true},
		width        = SHADOW_MAP_SIZE,
		height       = SHADOW_MAP_SIZE,
		pixel_format = .DEPTH,
		sample_count = 1,
	})

	sm.color_att_view = sg.make_view({
		color_attachment = {image = sm.color_img},
	})
	sm.depth_att_view = sg.make_view({
		depth_stencil_attachment = {image = sm.depth_img},
	})
	sm.tex_view = sg.make_view({
		texture = {image = sm.color_img},
	})

	sm.sampler = sg.make_sampler({
		wrap_u       = .CLAMP_TO_BORDER,
		wrap_v       = .CLAMP_TO_BORDER,
		border_color = .OPAQUE_WHITE,
		min_filter   = .NEAREST,
		mag_filter   = .NEAREST,
	})

	// Initial sun angle (radians around Y axis, elevated ~60° above horizon)
	sm.sun_angle = 0
	shadow_update_sun(sm, 0)
}

shadow_refresh_pipeline :: proc(sm: ^Shadow_Map) {
	sg.destroy_pipeline(sm.pip)
	sm.pip = sg.make_pipeline({
		shader       = sg.make_shader(shadow_caster_shader_desc(sg.query_backend())),
		layout       = {
			attrs = {
				ATTR_shadow_caster_position = {format = .FLOAT3},
				ATTR_shadow_caster_normal   = {format = .FLOAT3},
			},
		},
		colors       = {0 = {pixel_format = .RGBA8}},
		depth        = {
			pixel_format  = .DEPTH,
			compare       = .LESS_EQUAL,
			write_enabled = true,
		},
		cull_mode    = .BACK,
		face_winding = .CCW,  // REQUIRED: sokol defaults to .CW but our vertices are CCW (see agents.md § face winding)
		sample_count = 1,
	})
}

shadow_begin_pass :: proc(sm: ^Shadow_Map) {
	sg.begin_pass({
		action = {
			colors = {0 = {load_action = .CLEAR, clear_value = {1, 1, 1, 1}}},
			depth  = {load_action = .CLEAR, clear_value = 1.0},
		},
		attachments = {
			colors       = {0 = sm.color_att_view},
			depth_stencil = sm.depth_att_view,
		},
	})
	sg.apply_pipeline(sm.pip)
}

// Update sun position — call once per frame before shadow_begin_pass.
shadow_update_sun :: proc(sm: ^Shadow_Map, dt: f32) {
	sm.sun_angle += SUN_ORBIT_SPEED * dt

	// Sun orbits in a circle at a fixed elevation above the horizon.
	// cos/sin give the XZ position, elevation lifts it.
	cp := math.cos(SUN_ELEVATION)
	sp := math.sin(SUN_ELEVATION)
	sm.sun_dir = la.normalize(Vec3{
		math.cos(sm.sun_angle) * cp,
		sp,
		math.sin(sm.sun_angle) * cp,
	})

	sun_pos := sm.sun_dir * 50.0
	light_view := look_at(sun_pos, {0, 0, 0}, {0, 1, 0})
	light_proj := ortho(-15, 15, -15, 15, 1, 150)
	sm.light_vp = light_proj * light_view
}

shadow_draw_scene :: proc(sm: ^Shadow_Map, scene: ^Scene) {
	sg.apply_bindings({vertex_buffers = {0 = scene.vbuf}})

	for &box in scene.boxes {
		mdl := scene_box_model(&box)
		mvp := sm.light_vp * mdl

		vs_params := Shadow_Vs_Params{mvp = mvp}
		sg.apply_uniforms(UB_shadow_vs_params, {ptr = &vs_params, size = size_of(vs_params)})
		sg.draw(0, 36, 1)
	}
}

shadow_cleanup :: proc(sm: ^Shadow_Map) {
	sg.destroy_view(sm.tex_view)
	sg.destroy_view(sm.depth_att_view)
	sg.destroy_view(sm.color_att_view)
	sg.destroy_sampler(sm.sampler)
	sg.destroy_image(sm.depth_img)
	sg.destroy_image(sm.color_img)
}
