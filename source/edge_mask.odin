// edge_mask.odin — Edge mask pass. Per-texel 4-direction continuity mask.
// Compares each texel's radial depth with its 4 neighbors. Continuous surfaces
// get tight quad fitting; depth discontinuities (silhouettes) get expanded fitting.
// Used by splat vertex shader for per-side quad half-size selection.
//
// ── Data flow ──
// Written by: Edge mask pass (edge_mask.glsl, one fullscreen triangle per layer)
// Read by:    splat.glsl vertex shader (texelFetch for per-side quad expansion)
// Format:     RGBA8, 384×384, TOTAL_LAYERS slices
//             R=left, G=right, B=bottom, A=top (1.0=continuous, 0.0=discontinuity)
// Lifetime:   created in edge_mask_init(), destroyed in edge_mask_cleanup()
package game

import sg "sokol/gfx"

Edge_Mask :: struct {
	// RGBA8 array texture — one layer per probe×face (TOTAL_LAYERS = 18).
	// Each channel encodes continuity with one neighbor direction.
	edge_mask_img: sg.Image,

	// Per-layer attachment views for rendering into each face of each probe
	edge_mask_att_views: [TOTAL_LAYERS]sg.View,

	// Texture view for sampling the whole array in splat vertex shader
	edge_mask_tex_view: sg.View,

	// Pipeline for the fullscreen edge mask pass
	pip: sg.Pipeline,
}

edge_mask_init :: proc(em: ^Edge_Mask) {
	// ── Edge mask texture: RGBA8, same resolution as G-buffer ───────
	// R=left continuous, G=right, B=bottom, A=top.
	// 1.0 = continuous (tight fit), 0.0 = discontinuity (expanded fit).
	em.edge_mask_img = sg.make_image({
		type         = .ARRAY,
		usage        = {color_attachment = true},
		width        = PROBE_SIZE,
		height       = PROBE_SIZE,
		num_slices   = TOTAL_LAYERS,
		pixel_format = .RGBA8,
		sample_count = 1,
	})

	// ── Per-layer attachment views ──────────────────────────────────
	for layer in 0 ..< TOTAL_LAYERS {
		em.edge_mask_att_views[layer] = sg.make_view({
			color_attachment = {image = em.edge_mask_img, slice = i32(layer)},
		})
	}

	// ── Texture view for sampling in splat vertex shader ────────────
	em.edge_mask_tex_view = sg.make_view({texture = {image = em.edge_mask_img}})
}

// Recreate the edge mask pipeline. Called on init and hot reload.
edge_mask_refresh_pipeline :: proc(em: ^Edge_Mask) {
	sg.destroy_pipeline(em.pip)
	em.pip = sg.make_pipeline({
		shader = sg.make_shader(edge_mask_pass_shader_desc(sg.query_backend())),
		// Single color target: RGBA8 for the edge mask
		colors = {0 = {pixel_format = .RGBA8}},
		// No depth — fullscreen triangle, no depth testing.
		sample_count = 1,
	})
}

// Render the edge mask for one layer (probe×face).
// Draws a fullscreen triangle that reads radial texture and writes per-side continuity mask.
// Encapsulates begin_pass → draw → end_pass.
edge_mask_draw_face :: proc(em: ^Edge_Mask, gb: ^G_Buffer, layer: int) {
	sg.begin_pass({
		action = {
			// Clear to 0 (all discontinuous). The fullscreen triangle writes every pixel,
			// so this only matters if something goes wrong.
			colors = {0 = {load_action = .CLEAR, clear_value = {0, 0, 0, 0}}},
		},
		attachments = {
			colors = {0 = em.edge_mask_att_views[layer]},
		},
	})

	sg.apply_pipeline(em.pip)

	sg.apply_bindings({
		views = {
			VIEW_em_radial = gb.radial_tex_view,
		},
		samplers = {
			SMP_em_smp = gb.sampler,  // nearest — for texelFetch
		},
	})

	params := Edge_Mask_Params{
		params = {f32(layer), 0, 0, 0},
	}
	sg.apply_uniforms(UB_edge_mask_params, {ptr = &params, size = size_of(params)})

	// Fullscreen triangle — 3 vertices, no vertex buffer
	sg.draw(0, 3, 1)

	sg.end_pass()
}

edge_mask_cleanup :: proc(em: ^Edge_Mask) {
	sg.destroy_view(em.edge_mask_tex_view)
	for layer in 0 ..< TOTAL_LAYERS {
		sg.destroy_view(em.edge_mask_att_views[layer])
	}
	sg.destroy_image(em.edge_mask_img)
}
