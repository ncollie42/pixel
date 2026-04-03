// camera.odin — First-person camera. Owns position/orientation and produces view/proj matrices.
// Uses radians for yaw/pitch (not turns like Karl's code). Y-up, -Z is default forward.
package game

import "core:math"
import la "core:math/linalg"
import sapp "sokol/app"

MOUSE_SENSITIVITY :: 0.002
MOVE_SPEED        :: 5.0
SPRINT_SPEED      :: 15.0

Camera :: struct {
	pos:   Vec3,
	yaw:   f32,  // radians
	pitch: f32,  // radians
}

camera_init :: proc(cam: ^Camera) {
	cam.pos = {0, 2, 5}
	cam.yaw = 0
	cam.pitch = 0
}

camera_update :: proc(cam: ^Camera, dt: f32) {
	// Mouse look (only when mouse is locked)
	if sapp.mouse_locked() {
		cam.yaw   -= mouse_move.x * MOUSE_SENSITIVITY
		cam.pitch -= mouse_move.y * MOUSE_SENSITIVITY
		cam.pitch  = clamp(cam.pitch, -math.PI * 0.49, math.PI * 0.49)
	}

	// Movement
	fwd   := forward_from_yaw_pitch(cam.yaw, cam.pitch)
	right := right_from_yaw(cam.yaw)

	move := Vec3{0, 0, 0}
	if key_held[.Forward]  { move += fwd }
	if key_held[.Backward] { move -= fwd }
	if key_held[.Right]    { move += right }
	if key_held[.Left]     { move -= right }
	if key_held[.Up]       { move.y += 1 }
	if key_held[.Down]     { move.y -= 1 }

	len := la.length(move)
	if len > 0.001 {
		move = move / len
		speed := f32(key_held[.Sprint] ? SPRINT_SPEED : MOVE_SPEED)
		cam.pos += move * speed * dt
	}
}

camera_view_matrix :: proc(cam: ^Camera) -> Mat4 {
	return view_from_yaw_pitch(cam.pos, cam.yaw, cam.pitch)
}

camera_proj_matrix :: proc(fovy_rad: f32) -> Mat4 {
	w := sapp.widthf()
	h := sapp.heightf()
	aspect := w / max(h, 1.0)
	return perspective(fovy_rad, aspect, 0.1, 1000.0)
}

camera_forward :: proc(cam: ^Camera) -> Vec3 {
	return forward_from_yaw_pitch(cam.yaw, cam.pitch)
}
