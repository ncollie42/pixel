// post.odin — Post-processing pass. Renders scene at internal pixel-art resolution,
// then upscales to swapchain with nearest-neighbor sampling + gamma correction.
//
// Internal resolution follows TEXEL_SPLATTING_ESSENCE.md formula:
//   viewport_height = 2.5 * PROBE_SIZE * tan(fov/2)
// This makes each cubemap texel cover about 2.5 screen pixels.
//
// ── Data flow ──
// Written by: Splat pass (background + splat quads → offscreen color+depth)
// Read by:    Post blit (nearest-neighbor sample → swapchain with gamma)
// Format:     RGBA8 color (linear RGB) + DEPTH, internal resolution
// Lifetime:   created in post_init(), destroyed in post_cleanup()
package game

import "core:math"
import sapp "sokol/app"
import sg "sokol/gfx"

Post_Pass :: struct {
	width:  i32,  // internal render width
	height: i32,  // internal render height

	// Offscreen render targets
	color_img: sg.Image,  // RGBA8, stores linear RGB (gamma applied in blit)
	depth_img: sg.Image,  // DEPTH, used for z-buffer during splat rendering

	// Views for rendering into offscreen targets
	color_att_view: sg.View,
	depth_att_view: sg.View,

	// Texture view for sampling in blit shader
	color_tex_view: sg.View,

	// Pipeline and sampler for the blit pass
	pip:     sg.Pipeline,
	sampler: sg.Sampler,  // nearest-neighbor for pixel-art upscale
}

post_init :: proc(pp: ^Post_Pass) {
	// ── Compute internal resolution ─────────────────────────────────
	// Reference formula: height = ceil(2.5 * PROBE_SIZE * tan(fov/2))
	// With 60° FOV: height ≈ 555. Width from window aspect ratio.
	fov_rad := f32(60.0 * math.RAD_PER_DEG)
	tan_half := math.tan(fov_rad * 0.5)
	pp.height = max(i32(math.ceil(2.5 * f32(PROBE_SIZE) * tan_half)), 1)
	aspect := sapp.widthf() / max(sapp.heightf(), 1.0)
	pp.width = max(i32(math.ceil(f32(pp.height) * aspect)), 1)

	// ── Offscreen color target (RGBA8, linear RGB) ──────────────────
	pp.color_img = sg.make_image({
		type         = ._2D,
		usage        = {color_attachment = true},
		width        = pp.width,
		height       = pp.height,
		pixel_format = .RGBA8,
		sample_count = 1,
	})

	// ── Offscreen depth target ──────────────────────────────────────
	pp.depth_img = sg.make_image({
		type         = ._2D,
		usage        = {depth_stencil_attachment = true},
		width        = pp.width,
		height       = pp.height,
		pixel_format = .DEPTH,
		sample_count = 1,
	})

	// ── Attachment views for rendering ──────────────────────────────
	pp.color_att_view = sg.make_view({
		color_attachment = {image = pp.color_img},
	})
	pp.depth_att_view = sg.make_view({
		depth_stencil_attachment = {image = pp.depth_img},
	})

	// ── Texture view for sampling in blit ───────────────────────────
	pp.color_tex_view = sg.make_view({
		texture = {image = pp.color_img},
	})

	// ── Nearest-neighbor sampler ────────────────────────────────────
	// Preserves pixel-art look during upscale to swapchain.
	pp.sampler = sg.make_sampler({
		min_filter = .NEAREST,
		mag_filter = .NEAREST,
		wrap_u     = .CLAMP_TO_EDGE,
		wrap_v     = .CLAMP_TO_EDGE,
	})
}

// Recreate blit pipeline. Called on init and hot reload.
post_refresh_pipeline :: proc(pp: ^Post_Pass) {
	sg.destroy_pipeline(pp.pip)
	pp.pip = sg.make_pipeline({
		shader = sg.make_shader(post_blit_shader_desc(sg.query_backend())),
		// No vertex layout — fullscreen triangle from gl_VertexIndex
		// No depth — blit covers full screen, no depth testing
		depth = {compare = .ALWAYS, write_enabled = false},
	})
}

// Begin the offscreen render pass. Call before splat_draw().
// Clears to black — background shader covers all pixels anyway.
post_begin_pass :: proc(pp: ^Post_Pass) {
	sg.begin_pass({
		action = {
			colors = {0 = {load_action = .CLEAR, clear_value = {0, 0, 0, 1}}},
			depth  = {load_action = .CLEAR, clear_value = 1.0},
		},
		attachments = {
			colors        = {0 = pp.color_att_view},
			depth_stencil = pp.depth_att_view,
		},
	})
}

// Blit offscreen texture to swapchain with nearest-neighbor upscale + gamma.
// Must be called inside an active swapchain render pass.
post_draw :: proc(pp: ^Post_Pass) {
	sg.apply_pipeline(pp.pip)
	sg.apply_bindings({
		views = {
			VIEW_pt_color = pp.color_tex_view,
		},
		samplers = {
			SMP_pt_smp = pp.sampler,
		},
	})
	// Fullscreen triangle — 3 vertices, no vertex buffer
	sg.draw(0, 3, 1)
}

post_cleanup :: proc(pp: ^Post_Pass) {
	sg.destroy_view(pp.color_tex_view)
	sg.destroy_view(pp.depth_att_view)
	sg.destroy_view(pp.color_att_view)
	sg.destroy_sampler(pp.sampler)
	sg.destroy_image(pp.depth_img)
	sg.destroy_image(pp.color_img)
}
