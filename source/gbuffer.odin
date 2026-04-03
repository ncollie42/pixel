// gbuffer.odin — G-buffer textures and per-face attachment views for cubemap MRT capture.
// Owns albedo/normal/radial/depth textures (array textures with TOTAL_LAYERS slices
// for 3 probes: eye 0-5, grid 6-11, prev 12-17), per-layer attachment views for rendering,
// and texture views for sampling.
//
// ── Data flow ──
// Written by: G-buffer capture pass (gbuffer.glsl, drawn per face from probe POV)
// Read by:    lighting pass (lighting.glsl, samples albedo/normal/radial)
//             debug_vis pass (debug_vis.glsl, for visual inspection)
// Formats:    albedo=RGBA8, normal=RGBA8, radial=R32F, depth=DEPTH
// Lifetime:   created in gbuffer_init(), destroyed in gbuffer_cleanup()
package game

import sg "sokol/gfx"

G_Buffer :: struct {
	// Array textures (TOTAL_LAYERS slices = 6 cubemap faces × 3 probes)
	// Eye probe: layers 0-5, Grid probe: layers 6-11, Prev probe: layers 12-17
	albedo_img: sg.Image,
	normal_img: sg.Image,
	radial_img: sg.Image,
	depth_img:  sg.Image,

	// Per-layer attachment views for rendering into each face of each probe
	// Index: probe_idx * NUM_FACES + face (0..17)
	albedo_att_views: [TOTAL_LAYERS]sg.View,
	normal_att_views: [TOTAL_LAYERS]sg.View,
	radial_att_views: [TOTAL_LAYERS]sg.View,
	depth_att_views:  [TOTAL_LAYERS]sg.View,

	// Texture views for sampling the whole array in later passes
	albedo_tex_view: sg.View,
	normal_tex_view: sg.View,
	radial_tex_view: sg.View,

	// Pipeline and sampler for G-buffer capture
	pip:     sg.Pipeline,
	sampler: sg.Sampler,  // nearest sampler for debug vis / texelFetch fallback
}

gbuffer_init :: proc(gb: ^G_Buffer) {
	// ── Albedo: RGBA8, 384×384, TOTAL_LAYERS slices ─────────────────
	// Stores object color per texel. Written by gbuffer_fs location 0.
	gb.albedo_img = sg.make_image({
		type         = .ARRAY,
		usage        = {color_attachment = true},
		width        = PROBE_SIZE,
		height       = PROBE_SIZE,
		num_slices   = TOTAL_LAYERS,
		pixel_format = .RGBA8,
		sample_count = 1,
	})

	// ── Normal: RGBA8, 384×384, TOTAL_LAYERS slices ─────────────────
	// Stores octahedral-encoded world-space normal in RG channels.
	// Written by gbuffer_fs location 1.
	gb.normal_img = sg.make_image({
		type         = .ARRAY,
		usage        = {color_attachment = true},
		width        = PROBE_SIZE,
		height       = PROBE_SIZE,
		num_slices   = TOTAL_LAYERS,
		pixel_format = .RGBA8,
		sample_count = 1,
	})

	// ── Radial: R32F, 384×384, TOTAL_LAYERS slices ──────────────────
	// Stores Chebyshev distance (L∞ norm) from probe origin, normalized to [0,1].
	// Written by gbuffer_fs location 2. Sky texels get radial ≈ 1.0.
	gb.radial_img = sg.make_image({
		type         = .ARRAY,
		usage        = {color_attachment = true},
		width        = PROBE_SIZE,
		height       = PROBE_SIZE,
		num_slices   = TOTAL_LAYERS,
		pixel_format = .R32F,
		sample_count = 1,
	})

	// ── Depth: hardware depth buffer, 384×384, TOTAL_LAYERS slices ──
	// Used only as z-buffer during G-buffer capture. Not sampled.
	gb.depth_img = sg.make_image({
		type         = .ARRAY,
		usage        = {depth_stencil_attachment = true},
		width        = PROBE_SIZE,
		height       = PROBE_SIZE,
		num_slices   = TOTAL_LAYERS,
		pixel_format = .DEPTH,
		sample_count = 1,
	})

	// ── Per-layer attachment views ──────────────────────────────────
	// Each layer (probe × face) gets its own set of color + depth attachment
	// views so we can render into one slice at a time via begin_pass.
	for layer in 0 ..< TOTAL_LAYERS {
		gb.albedo_att_views[layer] = sg.make_view({
			color_attachment = {image = gb.albedo_img, slice = i32(layer)},
		})
		gb.normal_att_views[layer] = sg.make_view({
			color_attachment = {image = gb.normal_img, slice = i32(layer)},
		})
		gb.radial_att_views[layer] = sg.make_view({
			color_attachment = {image = gb.radial_img, slice = i32(layer)},
		})
		gb.depth_att_views[layer] = sg.make_view({
			depth_stencil_attachment = {image = gb.depth_img, slice = i32(layer)},
		})
	}

	// ── Texture views for sampling the whole array ──────────────────
	// Used by debug vis, lighting, and splat passes.
	gb.albedo_tex_view = sg.make_view({texture = {image = gb.albedo_img}})
	gb.normal_tex_view = sg.make_view({texture = {image = gb.normal_img}})
	gb.radial_tex_view = sg.make_view({texture = {image = gb.radial_img}})

	// Nearest-neighbor sampler — matches pixel-art intent and texelFetch style sampling.
	gb.sampler = sg.make_sampler({
		min_filter = .NEAREST,
		mag_filter = .NEAREST,
		wrap_u     = .CLAMP_TO_EDGE,
		wrap_v     = .CLAMP_TO_EDGE,
	})
}

// Recreate the G-buffer capture pipeline. Called on init and hot reload.
// Pipeline embeds shader bytecode pointers → must be recreated after DLL reload.
gbuffer_refresh_pipeline :: proc(gb: ^G_Buffer) {
	sg.destroy_pipeline(gb.pip)
	gb.pip = sg.make_pipeline({
		shader = sg.make_shader(gbuffer_capture_shader_desc(sg.query_backend())),
		layout = {
			attrs = {
				ATTR_gbuffer_capture_position = {format = .FLOAT3},
				ATTR_gbuffer_capture_normal   = {format = .FLOAT3},
			},
		},
		// MRT: 3 color targets matching gbuffer_fs layout locations
		color_count = 3,
		colors = {
			0 = {pixel_format = .RGBA8},  // albedo
			1 = {pixel_format = .RGBA8},  // normal (octahedral)
			2 = {pixel_format = .R32F},   // radial (Chebyshev distance)
		},
		depth = {
			pixel_format  = .DEPTH,
			compare       = .LESS_EQUAL,
			write_enabled = true,
		},
		cull_mode = .BACK,
		face_winding = .CCW,  // REQUIRED: sokol defaults to .CW but our vertices are CCW (see agents.md § face winding)
		sample_count = 1,
	})
}

// Render one cubemap face of the G-buffer. Call between begin_pass/end_pass.
// Draws all scene geometry with the given face's view-projection matrix.
// face = cubemap face direction (0-5), independent of which probe layer we're rendering to.
gbuffer_draw_face :: proc(gb: ^G_Buffer, scene: ^Scene, origin: Vec3, face: int) {
	vp := cube_face_view_proj(origin, face)

	sg.apply_pipeline(gb.pip)

	for &box in scene.boxes {
		mdl := scene_box_model(&box)

		sg.apply_bindings({
			vertex_buffers = {0 = scene.vbuf},
		})

		vs_params := Gbuffer_Vs_Params{
			view_proj    = vp,  // cube face view*proj — shader multiplies by model separately
			model        = mdl,
			probe_origin = {origin.x, origin.y, origin.z, 0},
		}

		fs_params := Gbuffer_Fs_Params{
			object_color = box.color,
			probe_data   = {origin.x, origin.y, origin.z, 0},
			// z = entity ID normalized to [0,1] for RGBA8 storage in albedo.a.
			// Used by lighting.glsl outline detection to identify object boundaries.
			near_far     = {PROBE_NEAR, PROBE_FAR, f32(box.entity_id) / 255.0, 0},
		}

		sg.apply_uniforms(UB_gbuffer_vs_params, {ptr = &vs_params, size = size_of(vs_params)})
		sg.apply_uniforms(UB_gbuffer_fs_params, {ptr = &fs_params, size = size_of(fs_params)})
		sg.draw(0, 36, 1)
	}
}

// Begin the render pass for one G-buffer layer. Sets up MRT attachments.
// layer = probe_idx * NUM_FACES + face (0..11).
gbuffer_begin_face_pass :: proc(gb: ^G_Buffer, layer: int) {
	sg.begin_pass({
		action = {
			colors = {
				// Albedo: clear to black (no geometry = sky)
				0 = {load_action = .CLEAR, clear_value = {0, 0, 0, 0}},
				// Normal: clear to (0.5, 0.5, 0, 1) — encodes straight-up normal
				1 = {load_action = .CLEAR, clear_value = {0.5, 0.5, 0, 1}},
				// Radial: clear to 1.0 — maximum distance = sky sentinel.
				// Splat vertex shader treats radial >= 0.999 as sky → degenerate quad.
				2 = {load_action = .CLEAR, clear_value = {1, 0, 0, 0}},
			},
			depth = {load_action = .CLEAR, clear_value = 1.0},
		},
		attachments = {
			colors = {
				0 = gb.albedo_att_views[layer],
				1 = gb.normal_att_views[layer],
				2 = gb.radial_att_views[layer],
			},
			depth_stencil = gb.depth_att_views[layer],
		},
	})
}

gbuffer_cleanup :: proc(gb: ^G_Buffer) {
	// Destroy texture views
	sg.destroy_view(gb.albedo_tex_view)
	sg.destroy_view(gb.normal_tex_view)
	sg.destroy_view(gb.radial_tex_view)

	// Destroy per-layer attachment views
	for layer in 0 ..< TOTAL_LAYERS {
		sg.destroy_view(gb.albedo_att_views[layer])
		sg.destroy_view(gb.normal_att_views[layer])
		sg.destroy_view(gb.radial_att_views[layer])
		sg.destroy_view(gb.depth_att_views[layer])
	}

	// Destroy images
	sg.destroy_image(gb.albedo_img)
	sg.destroy_image(gb.normal_img)
	sg.destroy_image(gb.radial_img)
	sg.destroy_image(gb.depth_img)

	// Destroy sampler
	sg.destroy_sampler(gb.sampler)
}
