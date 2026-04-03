// splat.odin — Splat rendering pass. Owns the splat + background pipelines.
// Draws instanced world-space quads from cubemap texels to screen.
// This is the core of texel splatting — produces perspective-stable pixel art.
//
// M5: Two probes (eye + grid) with face mask culling and Bayer crossfade.
// Eye probe at camera position provides close-up detail; grid probe at
// grid-snapped position provides perspective-stable rendering.
//
// ── Data flow ──
// Reads: G-buffer radial texture (gbuffer.odin) for world position reconstruction
//        Lit texture (lighting.odin) for pre-shaded texel colors
// Writes: swapchain framebuffer (screen)
// Draw order: background (depth=1.0) → eye splat quads → grid splat quads
package game

import "core:math"
import la "core:math/linalg"
import sg "sokol/gfx"

Splat_Pass :: struct {
	// Pipeline for instanced splat quads (no vertex buffer, no backface culling)
	splat_pip: sg.Pipeline,
	// Pipeline for fullscreen background triangle (draws at depth 1.0)
	bg_pip:    sg.Pipeline,
}

// Nothing to initialize — splat pass borrows textures from gbuffer and lighting.
// Pipelines are created in splat_refresh_pipeline().
splat_init :: proc(sp: ^Splat_Pass) {
	// No owned GPU resources — pipelines created in refresh_pipeline
}

// Recreate pipelines. Called on init and hot reload.
// Pipelines embed shader bytecode pointers → must be recreated after DLL reload.
splat_refresh_pipeline :: proc(sp: ^Splat_Pass) {
	// ── Splat pipeline ──────────────────────────────────────────────
	// No vertex buffer — everything derived from instance_index/vertex_index.
	// No backface culling — quads can face arbitrary directions.
	// Depth test: LESS_EQUAL with write — closer quads occlude farther ones.
	sg.destroy_pipeline(sp.splat_pip)
	sp.splat_pip = sg.make_pipeline({
		shader = sg.make_shader(splat_render_shader_desc(sg.query_backend())),
		// No vertex layout — no vertex buffer
		depth = {
			compare       = .LESS_EQUAL,
			write_enabled = true,
		},
		cull_mode = .NONE,  // quads may face any direction
	})

	// ── Background pipeline ─────────────────────────────────────────
	// Fullscreen triangle at depth 1.0. Renders sky/background behind splats.
	// Depth test: LESS_EQUAL with write — sets depth to 1.0 for background pixels.
	sg.destroy_pipeline(sp.bg_pip)
	sp.bg_pip = sg.make_pipeline({
		shader = sg.make_shader(bg_render_shader_desc(sg.query_backend())),
		// No vertex layout — fullscreen triangle from gl_VertexIndex
		depth = {
			compare       = .LESS_EQUAL,
			write_enabled = true,
		},
	})
}

// Draw the splat pass: background + instanced splat quads for all probes.
// Must be called inside an active swapchain render pass.
//
// Draw order:
//   1. Background (fullscreen triangle sampling eye probe's lit cubemap)
//   2. Eye probe splat quads (with depth bias pushing slightly farther)
//   3. Grid probe splat quads (with Bayer-dithered crossfade during transitions)
//   4. Prev probe splat quads (inverse Bayer dithered, only during crossfade)
//
// Grid probe wins depth test for overlapping texels because eye has a positive
// depth bias. Grid provides the stable base rendering; eye fills gaps.
// render_w, render_h: the actual render target dimensions (internal resolution
// from Post_Pass for splat mode, or window size for debug modes).
// Used for background shader viewport_fov uniform.
splat_draw :: proc(
	sp: ^Splat_Pass,
	gb: ^G_Buffer,
	lt: ^Lighting,
	em: ^Edge_Mask,
	cam: ^Camera,
	ts: ^Transition_State,
	view: Mat4,
	proj: Mat4,
	render_w: f32,
	render_h: f32,
) {
	vp := proj * view

	// ── Camera vectors for background ray computation ───────────────
	// Background shader needs camera right/up/forward to compute view direction
	// from screen UV, then maps to cubemap face+UV for lit texture lookup.
	cam_fwd := camera_forward(cam)
	cam_right := right_from_yaw(cam.yaw)
	// up = cross(right, forward) — both are unit length and perpendicular
	cam_up := la.cross(cam_right, cam_fwd)

	// FOV must match camera_proj_matrix() — 60° vertical FOV
	fov_rad := f32(60.0 * math.RAD_PER_DEG)
	tan_half_fov := math.tan(fov_rad * 0.5)

	// ── Face mask culling ───────────────────────────────────────────
	// Only render cubemap faces the camera is looking toward.
	// Eye probe: cos(98°) ≈ -0.139 (slightly past 90°)
	// Grid probe: cos(103°) ≈ -0.225 (wider, covers transitions)
	// See TEXEL_SPLATTING_ESSENCE.md § "Face Mask Culling".
	eye_mask := compute_face_mask(cam_fwd, EYE_CULL_COS)
	grid_mask := compute_face_mask(cam_fwd, GRID_CULL_COS)

	// Crossfade state: fade_t is 0..1 during transition, 0 or 1 when idle.
	// Passed to the splat fragment shader for Bayer dithering.
	fade_t := ts.blending ? ts.fade_t : f32(0)

	// ── 1. Background pass ──────────────────────────────────────────
	// Fullscreen triangle sampling eye probe's lit cubemap.
	// Draws at depth=1.0 so splat quads render in front.
	// Always uses eye probe (layers 0-5).
	sg.apply_pipeline(sp.bg_pip)
	sg.apply_bindings({
		views = {
			VIEW_bg_lit    = lt.lit_tex_view,
			VIEW_bg_radial = gb.radial_tex_view,  // for background haze
		},
		samplers = {
			SMP_bg_smp       = gb.sampler,  // nearest — texelFetch style
			SMP_bg_radial_smp = gb.sampler,  // nearest — texelFetch
		},
	})

	// Haze density matches lighting.glsl and splat.glsl constants.
	// PROBE_NEAR/FAR for un-normalizing radial in background haze.
	bg_params := Bg_Params{
		cam_right    = {cam_right.x, cam_right.y, cam_right.z, 0},
		cam_up       = {cam_up.x, cam_up.y, cam_up.z, 0},
		cam_forward  = {cam_fwd.x, cam_fwd.y, cam_fwd.z, 0},
		viewport_fov = {render_w, render_h, tan_half_fov, 0},
		haze_params  = {0.005, PROBE_NEAR, PROBE_FAR, 0},  // density, near, far
		haze_color   = {0.5, 0.56, 0.66, 0},                // linear RGB
	}
	sg.apply_uniforms(UB_bg_params, {ptr = &bg_params, size = size_of(bg_params)})
	sg.draw(0, 3, 1)  // fullscreen triangle

	// ── 2. Splat quads ──────────────────────────────────────────────
	// Three probes: eye (camera pos), grid (grid-snapped pos), prev (old grid pos).
	// Each draws one call per visible cubemap face, with PROBE_SIZE² instances.
	// Vertex shader discards sky texels (degenerate triangles).
	sg.apply_pipeline(sp.splat_pip)
	sg.apply_bindings({
		views = {
			VIEW_sp_radial    = gb.radial_tex_view,     // vertex stage — world pos reconstruction
			VIEW_sp_lit       = lt.lit_tex_view,         // fragment stage — final color
			VIEW_sp_edge_mask = em.edge_mask_tex_view,   // vertex stage — per-side quad expansion
		},
		samplers = {
			SMP_sp_smp      = gb.sampler,  // nearest — texelFetch
			SMP_sp_lit_smp  = gb.sampler,  // nearest — texelFetch
			SMP_sp_edge_smp = gb.sampler,  // nearest — texelFetch
		},
	})

	// Probe origins: eye = camera, grid = grid-snapped, prev = old grid
	probe_origins := [NUM_PROBES]Vec3{
		cam.pos,           // PROBE_EYE
		ts.grid_origin,    // PROBE_GRID
		ts.prev_origin,    // PROBE_PREV
	}
	// Prev probe: same face culling as grid, but only rendered during crossfade.
	// When not blending, mask=0 → no faces visible → no draw calls.
	prev_mask: u8 = ts.blending ? grid_mask : 0
	probe_masks := [NUM_PROBES]u8{
		eye_mask,
		grid_mask,
		prev_mask,
	}

	for probe_idx in 0 ..< NUM_PROBES {
		origin := probe_origins[probe_idx]
		mask := probe_masks[probe_idx]

		for face in 0 ..< NUM_FACES {
			if !face_visible(face, mask) { continue }

			layer := probe_idx * NUM_FACES + face

			vs_params := Splat_Vs_Params{
				view_proj    = vp,
				probe_origin = {origin.x, origin.y, origin.z, 0},
				face_params  = {f32(face), PROBE_NEAR, PROBE_FAR, f32(layer)},
				splat_params = {f32(probe_idx), fade_t, 0, 0},
				camera_pos   = {cam.pos.x, cam.pos.y, cam.pos.z, 0},
			}
			sg.apply_uniforms(UB_splat_vs_params, {ptr = &vs_params, size = size_of(vs_params)})

			// 6 vertices per quad, PROBE_SIZE² quads per face.
			// Sky texels → degenerate triangles → culled by GPU hardware.
			// TODO: GPU visibility culling — the reference implementation uses a compute pass
			// to build a compact buffer of only visible (non-sky) texels, then drawIndirect.
			// This avoids wasting vertex shader invocations on sky texels (~50% of a face).
			// See texel-splatting/src/splat.ts:166-198 (cull shader).
			// Requires: compute pipeline + storage buffer + indirect draw support in sokol.
			sg.draw(0, 6, PROBE_SIZE * PROBE_SIZE)
		}
	}
}

splat_cleanup :: proc(sp: ^Splat_Pass) {
	// No owned GPU resources to destroy — pipelines are handles, not heap allocs
}
