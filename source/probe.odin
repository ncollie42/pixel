// probe.odin — Probe origin and cubemap face matrices.
// Owns the 90° FOV cube perspective projection, per-face view matrices,
// and the face direction helpers used by G-buffer capture.
//
// Face ordering matches TEXEL_SPLATTING_ESSENCE.md § "Cubemap Face ↔ Direction Mapping":
//   0 = +X, 1 = -X, 2 = +Y, 3 = -Y, 4 = +Z, 5 = -Z
package game

import "core:math"

PROBE_SIZE :: 384
PROBE_NEAR :: f32(0.1)
PROBE_FAR  :: f32(200.0)
NUM_FACES  :: 6

// ── Multi-probe constants ────────────────────────────────────────────
// M6: 3 probes (eye + grid + prev). Prev stores old grid origin during crossfade.
NUM_PROBES   :: 3
TOTAL_LAYERS :: NUM_PROBES * NUM_FACES  // 18 = 3 probes × 6 faces

// Probe indices — used to compute texture layer offsets (probe_idx * NUM_FACES + face).
PROBE_EYE  :: 0
PROBE_GRID :: 1
PROBE_PREV :: 2  // old grid origin — only rendered during crossfade

// Grid snap interval — probe origins snap to this spacing.
// See TEXEL_SPLATTING_ESSENCE.md § "Transition System".
GRID_STEP      :: f32(1.0)
BLEND_DURATION :: f32(0.5)  // seconds for crossfade

// Face mask culling thresholds — cosine of acceptance angle.
// Eye probe uses narrower cone (98°), grid uses wider (103°) to cover transitions.
// See TEXEL_SPLATTING_ESSENCE.md § "Face Mask Culling".
EYE_CULL_COS  :: f32(-0.139)  // cos(98°)
GRID_CULL_COS :: f32(-0.225)  // cos(103°)

// ── Cube perspective ────────────────────────────────────────────────
// 90° vertical FOV, aspect = 1:1, producing a square cubemap face.
cube_perspective :: proc(near: f32, far: f32) -> Mat4 {
	return perspective(math.PI / 2.0, 1.0, near, far)
}

// ── Per-face look-at directions ─────────────────────────────────────
// Each face has a target direction and an up vector.
// Matches TEXEL_SPLATTING_ESSENCE.md § "Cubemap Face ↔ Direction Mapping":
//   face 0 (+X): dir = ( 1, -v, -u)  → look along +X, up = (0,-1,0)
//   face 1 (-X): dir = (-1, -v,  u)  → look along -X, up = (0,-1,0)
//   face 2 (+Y): dir = ( u,  1,  v)  → look along +Y, up = (0, 0,1)
//   face 3 (-Y): dir = ( u, -1, -v)  → look along -Y, up = (0, 0,-1)
//   face 4 (+Z): dir = ( u, -v,  1)  → look along +Z, up = (0,-1,0)
//   face 5 (-Z): dir = (-u, -v, -1)  → look along -Z, up = (0,-1,0)
//
// The up vectors are chosen so that the resulting UV layout matches the
// faceUVtoDir mapping in the essence doc (u maps to texture x, v maps to texture y).
FACE_TARGETS :: [NUM_FACES]Vec3{
	{ 1,  0,  0}, // +X
	{-1,  0,  0}, // -X
	{ 0,  1,  0}, // +Y
	{ 0, -1,  0}, // -Y
	{ 0,  0,  1}, // +Z
	{ 0,  0, -1}, // -Z
}
FACE_UPS :: [NUM_FACES]Vec3{
	{0, -1,  0}, // +X
	{0, -1,  0}, // -X
	{0,  0,  1}, // +Y
	{0,  0, -1}, // -Y
	{0, -1,  0}, // +Z
	{0, -1,  0}, // -Z
}

// Build the view matrix for one cubemap face from a given probe origin.
cube_face_view :: proc(origin: Vec3, face: int) -> Mat4 {
	targets := FACE_TARGETS
	ups := FACE_UPS
	return look_at(origin, origin + targets[face], ups[face])
}

// Build view * projection for one cubemap face.
cube_face_view_proj :: proc(origin: Vec3, face: int) -> Mat4 {
	proj := cube_perspective(PROBE_NEAR, PROBE_FAR)
	view := cube_face_view(origin, face)
	return proj * view
}

// ── Face mask culling ───────────────────────────────────────────────
// Returns a 6-bit mask indicating which cubemap faces are visible from the
// camera's forward direction. Threshold is the cosine of the acceptance angle.
// See TEXEL_SPLATTING_ESSENCE.md § "Face Mask Culling".
//   eye probe:  cos(98°)  ≈ -0.139
//   grid probe: cos(103°) ≈ -0.225
compute_face_mask :: proc(fwd: Vec3, threshold: f32) -> u8 {
	mask: u8 = 0
	if  fwd.x >= threshold { mask |= 1 }   // +X
	if -fwd.x >= threshold { mask |= 2 }   // -X
	if  fwd.y >= threshold { mask |= 4 }   // +Y
	if -fwd.y >= threshold { mask |= 8 }   // -Y
	if  fwd.z >= threshold { mask |= 16 }  // +Z
	if -fwd.z >= threshold { mask |= 32 }  // -Z
	return mask
}

// Check if a specific face is set in a face mask.
face_visible :: proc(face: int, mask: u8) -> bool {
	return (mask & (1 << u8(face))) != 0
}

// ── Transition state ────────────────────────────────────────────────
// Tracks the grid-snapped probe origin and crossfade progress.
// When the camera crosses a grid boundary, the grid origin snaps to the
// new cell and a Bayer-dithered crossfade begins.
// See TEXEL_SPLATTING_ESSENCE.md § "Transition System".
Transition_State :: struct {
	grid_origin:    Vec3,    // current grid-snapped probe origin
	prev_origin:    Vec3,    // previous grid origin — rendered during crossfade as layers 12-17
	fade_t:         f32,     // 0..1 crossfade progress
	smoothed_speed: f32,     // exponentially smoothed camera speed (units/sec)
	last_cam_pos:   Vec3,    // camera position on previous frame
	blending:       bool,    // true while a crossfade is active
	initialized:    bool,    // false until first transition_update call

	// First-frame override flags for alternating frame scheduling.
	// When a probe's origin changes, it must render that frame regardless
	// of frame parity, because old texture data is from a different position.
	// Set by transition_update(), cleared by game_frame() after passes run.
	grid_needs_update: bool,  // grid origin just changed → force render
	prev_needs_update: bool,  // blend started → prev has new origin → force render
}

// Update the transition state for the current frame.
// Snaps camera position to grid, detects origin changes, advances crossfade.
// Must be called once per frame before G-buffer/lighting/splat passes.
transition_update :: proc(ts: ^Transition_State, cam_pos: Vec3, dt: f32) {
	dt_clamped := min(dt, f32(0.1))

	// ── Smooth camera speed tracking ────────────────────────────────
	// Used to adapt crossfade rate to camera velocity.
	// Exponential moving average with time constant 0.05s.
	if ts.initialized && dt_clamped > 0.0001 {
		dx := cam_pos.x - ts.last_cam_pos.x
		dy := cam_pos.y - ts.last_cam_pos.y
		dz := cam_pos.z - ts.last_cam_pos.z
		instant_speed := math.sqrt(dx*dx + dy*dy + dz*dz) / dt_clamped
		alpha := f32(1.0) - math.exp(-dt_clamped / 0.05)
		ts.smoothed_speed = alpha * instant_speed + (1.0 - alpha) * ts.smoothed_speed
	}
	ts.last_cam_pos = cam_pos

	// ── Grid snap ───────────────────────────────────────────────────
	snap := Vec3{
		math.round(cam_pos.x / GRID_STEP) * GRID_STEP,
		math.round(cam_pos.y / GRID_STEP) * GRID_STEP,
		math.round(cam_pos.z / GRID_STEP) * GRID_STEP,
	}

	// ── First frame: initialize without triggering blend ────────────
	if !ts.initialized {
		ts.grid_origin = snap
		ts.prev_origin = snap
		ts.initialized = true
		ts.grid_needs_update = true  // Force first render regardless of frame parity
		return
	}

	// ── Detect grid origin change ───────────────────────────────────
	// Only start a new blend if we're not already blending.
	// Grid origin changes are queued until the current blend completes.
	if !ts.blending {
		if snap.x != ts.grid_origin.x || snap.y != ts.grid_origin.y || snap.z != ts.grid_origin.z {
			ts.prev_origin = ts.grid_origin
			ts.grid_origin = snap
			ts.fade_t = 0
			ts.blending = true
			ts.grid_needs_update = true   // New origin — must render this frame
			ts.prev_needs_update = true   // Old origin captured — must render this frame
		}
	}

	// ── Advance crossfade ───────────────────────────────────────────
	// Not gated by `else` — runs on the same frame the blend starts.
	// This ensures fade_t > 0 on the first frame, enabling Bayer dithering
	// immediately and avoiding a one-frame "double vision" where both grid
	// and prev are fully visible simultaneously without dithering.
	// Rate adapts to camera speed: faster movement → faster fade.
	if ts.blending {
		base_rate := f32(1.0) / BLEND_DURATION
		velocity_rate := ts.smoothed_speed / GRID_STEP
		ts.fade_t += max(base_rate, velocity_rate) * dt_clamped
		if ts.fade_t >= 1.0 {
			ts.fade_t = 1.0
			ts.blending = false
		}
	}
}
