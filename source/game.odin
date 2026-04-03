// game.odin — Top-level orchestration. Owns Game_Memory and the per-frame pass ordering.
// All persistent state lives in Game_Memory so hot reload can preserve it.
package game

import "core:math"
import sapp "sokol/app"
import sdtx "sokol/debugtext"
import sg "sokol/gfx"
import sglue "sokol/glue"
import slog "sokol/log"

SKY_COLOR :: sg.Color{0.53, 0.81, 0.92, 1.0}
FPS_HISTORY_LEN :: 30

// Debug visualization modes, cycled with Tab key.
Debug_Mode :: enum {
	Splat,     // M4 texel splatting (default) — the magic!
	Forward,   // M1 forward-lit rendering
	Albedo,    // G-buffer albedo for one face
	Normal,    // G-buffer normal (octahedral decoded) for one face
	Radial,    // G-buffer radial distance for one face
	Lit,       // M3 lighting pass output for one face
}

Game_Memory :: struct {
	camera:      Camera,
	scene:       Scene,
	shadow_map:  Shadow_Map,
	gbuffer:     G_Buffer,
	edge_mask:   Edge_Mask,         // M7: per-texel edge mask for quad expansion
	lighting:    Lighting,
	splat:       Splat_Pass,
	post_pass:   Post_Pass,         // M8: offscreen render + nearest-neighbor upscale
	transition:  Transition_State,  // M5: grid-snapped probe crossfade state
	frame_count: u64,               // Monotonic frame counter for alternating probe scheduling
	forward_pip: sg.Pipeline,
	debug_pip:   sg.Pipeline,

	// Debug vis state — cycle mode with Tab, face with 1-6 keys, probe with 7
	debug_mode:  Debug_Mode,
	debug_face:  int,  // 0..5, which cubemap face to show
	debug_probe: int,  // 0 = eye, 1 = grid

	// FPS counter — rolling average over FPS_HISTORY_LEN frames
	fps_dt_history: [FPS_HISTORY_LEN]f32,
	fps_history_idx: int,
	fps_filled: int,
}

g: ^Game_Memory
force_reset: bool

@(export)
game_app_default_desc :: proc() -> sapp.Desc {
	return {
		width        = 1280,
		height       = 720,
		window_title = "Texel Splatting",
		icon         = {sokol_default = true},
		logger       = {func = slog.func},
		high_dpi     = true,
	}
}

@(export)
game_init :: proc() {
	g = new(Game_Memory)

	sg.setup({
		environment = sglue.environment(),
		logger      = {func = slog.func},
	})

	sdtx.setup({
		fonts = {0 = sdtx.font_cpc()},
		logger = {func = slog.func},
	})

	camera_init(&g.camera)
	scene_init(&g.scene)
	shadow_init(&g.shadow_map)
	gbuffer_init(&g.gbuffer)
	edge_mask_init(&g.edge_mask)
	lighting_init(&g.lighting)
	splat_init(&g.splat)
	post_init(&g.post_pass)

	game_hot_reloaded(g)
}

@(export)
game_frame :: proc() {
	dt := f32(sapp.frame_duration())
	camera_update(&g.camera, dt)
	scene_update(&g.scene, dt)
	shadow_update_sun(&g.shadow_map, dt)

	// Handle debug mode switching:
	//   Tab cycles through: Forward → Albedo → Normal → Radial → Forward
	//   Keys 1-6 select which cubemap face to visualize
	if key_pressed[.ToggleDebug] {
		next := int(g.debug_mode) + 1
		max_mode := int(Debug_Mode.Lit)
		if next > max_mode { next = 0 }
		g.debug_mode = Debug_Mode(next)
	}
	if key_pressed[.Face1] { g.debug_face = 0 }
	if key_pressed[.Face2] { g.debug_face = 1 }
	if key_pressed[.Face3] { g.debug_face = 2 }
	if key_pressed[.Face4] { g.debug_face = 3 }
	if key_pressed[.Face5] { g.debug_face = 4 }
	if key_pressed[.Face6] { g.debug_face = 5 }
	if key_pressed[.ProbeToggle] { g.debug_probe = (g.debug_probe + 1) % NUM_PROBES }  // cycle eye→grid→prev

	view := camera_view_matrix(&g.camera)
	proj := camera_proj_matrix(60.0 * math.RAD_PER_DEG)

	// ── Update transition state ──────────────────────────────────────
	// Tracks grid-snapped probe origin and crossfade progress.
	// Must be called before G-buffer/lighting/splat passes.
	transition_update(&g.transition, g.camera.pos, dt)

	// ── Compute face masks for each probe ───────────────────────────
	// Only render cubemap faces the camera is looking toward.
	cam_fwd := camera_forward(&g.camera)
	eye_mask := compute_face_mask(cam_fwd, EYE_CULL_COS)
	grid_mask := compute_face_mask(cam_fwd, GRID_CULL_COS)

	probe_origins := [NUM_PROBES]Vec3{
		g.camera.pos,              // PROBE_EYE
		g.transition.grid_origin,  // PROBE_GRID
		g.transition.prev_origin,  // PROBE_PREV
	}
	// Prev probe only renders during crossfade. Mask=0 when idle → no G-buffer/lighting/splat work.
	prev_mask: u8 = g.transition.blending ? grid_mask : 0
	probe_masks := [NUM_PROBES]u8{
		eye_mask,
		grid_mask,
		prev_mask,
	}

	// ── Alternating frame scheduling ────────────────────────────────
	// The eye probe ALWAYS renders its G-buffer/edge mask/lighting (it tracks
	// the camera). Grid and prev probes alternate frames to cut per-frame
	// G-buffer + edge mask + lighting work by ~33%:
	//   - Grid (idx 1): renders on EVEN frames
	//   - Prev (idx 2): renders on ODD frames (only while blending)
	//
	// Exception: when a probe's origin changes (grid snaps to new cell, or
	// blending starts), it MUST render that frame regardless of parity,
	// because the old texture data is from a different world position.
	// The *_needs_update flags force this first-frame override.
	//
	// The splat pass still draws ALL probes every frame — it reads from
	// the most recently written textures, which persist between frames.
	// See reference: texel-splatting/src/splat.ts:69-73.
	g.frame_count += 1
	should_render_probe := [NUM_PROBES]bool{
		true,                                                            // Eye: always
		(g.frame_count % 2 == 0) || g.transition.grid_needs_update,     // Grid: even frames or forced
		(g.frame_count % 2 == 1) || g.transition.prev_needs_update,     // Prev: odd frames or forced
	}

	// ── Pass 1: Shadow map ──────────────────────────────────────────
	shadow_begin_pass(&g.shadow_map)
	shadow_draw_scene(&g.shadow_map, &g.scene)
	sg.end_pass()

	// ── Pass 2: G-buffer capture (per visible face per probe) ───────
	// Renders scene into cubemap MRT for each visible face of each probe.
	// Eye probe (layers 0-5): origin = camera position.
	// Grid probe (layers 6-11): origin = grid-snapped position.
	// Prev probe (layers 12-17): origin = old grid position (only during crossfade).
	for probe_idx in 0 ..< NUM_PROBES {
		if !should_render_probe[probe_idx] { continue }
		origin := probe_origins[probe_idx]
		mask := probe_masks[probe_idx]
		base_layer := probe_idx * NUM_FACES

		for face in 0 ..< NUM_FACES {
			if !face_visible(face, mask) { continue }
			layer := base_layer + face
			gbuffer_begin_face_pass(&g.gbuffer, layer)
			gbuffer_draw_face(&g.gbuffer, &g.scene, origin, face)
			sg.end_pass()
		}
	}

	// ── Pass 3: Edge mask (per visible face per probe) ──────────────────────
	// Compares each texel's radial depth with 4 neighbors. Writes per-side
	// continuity mask used by splat vertex shader for quad expansion.
	for probe_idx in 0 ..< NUM_PROBES {
		if !should_render_probe[probe_idx] { continue }
		mask := probe_masks[probe_idx]
		base_layer := probe_idx * NUM_FACES

		for face in 0 ..< NUM_FACES {
			if !face_visible(face, mask) { continue }
			layer := base_layer + face
			edge_mask_draw_face(&g.edge_mask, &g.gbuffer, layer)
		}
	}

	// ── Pass 4: Lighting (per visible face per probe) ───────────────────────────────────
	// Fullscreen fragment pass per face: reads G-buffer + shadow map,
	// reconstructs world position, computes diffuse + shadow, writes lit color.
	for probe_idx in 0 ..< NUM_PROBES {
		if !should_render_probe[probe_idx] { continue }
		origin := probe_origins[probe_idx]
		mask := probe_masks[probe_idx]
		base_layer := probe_idx * NUM_FACES

		for face in 0 ..< NUM_FACES {
			if !face_visible(face, mask) { continue }
			layer := base_layer + face
			lighting_draw_face(&g.lighting, &g.gbuffer, &g.shadow_map, origin, face, layer)
		}
	}

	// ── Clear first-frame override flags ────────────────────────────
	// These were set by transition_update when a probe's origin changed.
	// Now that the passes have run for the scheduled probes, clear them.
	if should_render_probe[PROBE_GRID] { g.transition.grid_needs_update = false }
	if should_render_probe[PROBE_PREV] { g.transition.prev_needs_update = false }

	// ── Pass 5: Render to screen ───────────────────────────────────
	switch g.debug_mode {
	case .Splat:
		// M8: Render splats to offscreen at pixel-art resolution,
		// then nearest-neighbor upscale + gamma to swapchain.
		post_begin_pass(&g.post_pass)
		splat_draw(
			&g.splat, &g.gbuffer, &g.lighting, &g.edge_mask,
			&g.camera, &g.transition, view, proj,
			f32(g.post_pass.width), f32(g.post_pass.height),
		)
		sg.end_pass()

		// Blit offscreen → swapchain with nearest-neighbor + gamma
		sg.begin_pass({
			action = {colors = {0 = {load_action = .CLEAR, clear_value = {0, 0, 0, 1}}}},
			swapchain = sglue.swapchain(),
		})
		post_draw(&g.post_pass)

	case .Forward:
		// Forward-lit rendering (M1 fallback) — renders directly to swapchain
		sg.begin_pass({
			action = {
				colors = {0 = {load_action = .CLEAR, clear_value = SKY_COLOR}},
				depth  = {load_action = .CLEAR, clear_value = 1.0},
			},
			swapchain = sglue.swapchain(),
		})
		sg.apply_pipeline(g.forward_pip)
		sg.apply_bindings({
			vertex_buffers = {0 = g.scene.vbuf},
			views          = {VIEW_shadow_tex = g.shadow_map.tex_view},
			samplers       = {SMP_shadow_smp = g.shadow_map.sampler},
		})

		sm := &g.shadow_map
		for &box in g.scene.boxes {
			mdl := scene_box_model(&box)
			mvp := proj * view * mdl

			vs_params := Forward_Vs_Params{mvp = mvp, model = mdl}
			fs_params := Forward_Fs_Params{
				light_vp     = sm.light_vp,
				sun_dir      = {sm.sun_dir.x, sm.sun_dir.y, sm.sun_dir.z, 0},
				sun_color    = {1.0, 0.95, 0.9, 0},
				ambient      = {0.15, 0.15, 0.2, 0},
				object_color = box.color,
			}

			sg.apply_uniforms(UB_forward_vs_params, {ptr = &vs_params, size = size_of(vs_params)})
			sg.apply_uniforms(UB_forward_fs_params, {ptr = &fs_params, size = size_of(fs_params)})
			sg.draw(0, 36, 1)
		}

	case .Albedo, .Normal, .Radial, .Lit:
		// Debug visualization — renders directly to swapchain
		sg.begin_pass({
			action = {
				colors = {0 = {load_action = .CLEAR, clear_value = SKY_COLOR}},
				depth  = {load_action = .CLEAR, clear_value = 1.0},
			},
			swapchain = sglue.swapchain(),
		})
		debug_draw_gbuffer(g)
	}

	// ── FPS overlay ─────────────────────────────────────────────────
	{
		g.fps_dt_history[g.fps_history_idx] = dt
		g.fps_history_idx = (g.fps_history_idx + 1) % FPS_HISTORY_LEN
		g.fps_filled = min(g.fps_filled + 1, FPS_HISTORY_LEN)

		sum: f32 = 0
		for i in 0 ..< g.fps_filled {
			sum += g.fps_dt_history[i]
		}
		avg_dt := sum / f32(g.fps_filled) if g.fps_filled > 0 else 0
		fps := int(1.0 / avg_dt) if avg_dt > 0 else 0

		sdtx.canvas(sapp.widthf() * 0.5, sapp.heightf() * 0.5)
		sdtx.origin(1.0, 1.0)
		sdtx.color3b(255, 255, 255)
		sdtx.printf("FPS: %d  dt: %.1fms", fps, f64(avg_dt * 1000.0))
		sdtx.draw()
	}

	sg.end_pass()
	sg.commit()

	free_all(context.temp_allocator)
	input_reset()
}

@(export)
game_event :: proc(e: ^sapp.Event) {
	process_input(e)
}

@(export)
game_cleanup :: proc() {
	post_cleanup(&g.post_pass)
	splat_cleanup(&g.splat)
	lighting_cleanup(&g.lighting)
	edge_mask_cleanup(&g.edge_mask)
	gbuffer_cleanup(&g.gbuffer)
	scene_cleanup(&g.scene)
	shadow_cleanup(&g.shadow_map)
	sdtx.shutdown()
	sg.shutdown()
	free(g)
}

@(export)
game_memory :: proc() -> rawptr {
	return g
}

@(export)
game_memory_size :: proc() -> int {
	return size_of(Game_Memory)
}

@(export)
game_hot_reloaded :: proc(mem: rawptr) {
	g = (^Game_Memory)(mem)
	refresh_pipelines()
}

@(export)
game_force_restart :: proc() -> bool {
	return force_reset
}

// ── Pipeline management ─────────────────────────────────────────────
// Called on init and hot reload. Pipelines embed shader bytecode pointers
// that become dangling after DLL reload, so they must be recreated.
refresh_pipelines :: proc() {
	shadow_refresh_pipeline(&g.shadow_map)
	gbuffer_refresh_pipeline(&g.gbuffer)
	edge_mask_refresh_pipeline(&g.edge_mask)
	lighting_refresh_pipeline(&g.lighting)
	splat_refresh_pipeline(&g.splat)
	post_refresh_pipeline(&g.post_pass)

	sg.destroy_pipeline(g.forward_pip)
	g.forward_pip = sg.make_pipeline({
		shader = sg.make_shader(forward_lit_shader_desc(sg.query_backend())),
		layout = {
			attrs = {
				ATTR_forward_lit_position = {format = .FLOAT3},
				ATTR_forward_lit_normal   = {format = .FLOAT3},
			},
		},
		depth = {
			compare       = .LESS_EQUAL,
			write_enabled = true,
		},
		cull_mode = .BACK,
		face_winding = .CCW,  // REQUIRED: sokol defaults to .CW but our vertices are CCW (see agents.md § face winding)
	})

	// Debug visualization pipeline — fullscreen triangle, no vertex buffer,
	// no depth test (draws over everything).
	sg.destroy_pipeline(g.debug_pip)
	g.debug_pip = sg.make_pipeline({
		shader = sg.make_shader(debug_vis_shader_desc(sg.query_backend())),
		depth  = {compare = .ALWAYS, write_enabled = false},
	})
}

// ── Debug vis: draw one G-buffer face fullscreen ────────────────────
// Used in non-Forward debug modes to visualize albedo/normal/radial/lit.
debug_draw_gbuffer :: proc(g: ^Game_Memory) {
	gb := &g.gbuffer

	sg.apply_pipeline(g.debug_pip)
	sg.apply_bindings({
		views = {
			VIEW_albedo_tex = gb.albedo_tex_view,
			VIEW_normal_tex = gb.normal_tex_view,
			VIEW_radial_tex = gb.radial_tex_view,
			VIEW_lit_tex    = g.lighting.lit_tex_view,
		},
		samplers = {
			SMP_tex_smp = gb.sampler,
		},
	})

	// mode: 0=albedo, 1=normal, 2=radial, 3=lit (maps to Debug_Mode enum - 2,
	// offset by 2 because Splat=0 and Forward=1 are handled separately)
	mode := f32(int(g.debug_mode) - 2)
	// debug_probe * NUM_FACES + debug_face = layer index (0-11)
	// Selects which probe's data to visualize (7 key toggles probe).
	debug_layer := f32(g.debug_probe * NUM_FACES + g.debug_face)
	params := Debug_Vis_Params{
		settings = {debug_layer, mode, 0, 0},
	}
	sg.apply_uniforms(UB_debug_vis_params, {ptr = &params, size = size_of(params)})

	// Fullscreen triangle — 3 vertices, no vertex buffer
	sg.draw(0, 3, 1)
}
