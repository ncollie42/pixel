// math_utils.odin — Type aliases and matrix/vector utilities.
// These types are used everywhere AND mapped to GLSL via @ctype in shader files.
// If you rename Mat4/Vec4/Vec3/Vec2, update every .glsl @ctype line too.
package game

import "core:math"
import la "core:math/linalg"

Mat4 :: matrix[4, 4]f32
Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

// Create a perspective projection matrix.
perspective :: proc(fovy_rad: f32, aspect: f32, near: f32, far: f32) -> Mat4 {
	return la.matrix4_perspective(fovy_rad, aspect, near, far)
}

// Create a look-at view matrix.
look_at :: proc(eye: Vec3, target: Vec3, up: Vec3) -> Mat4 {
	return la.matrix4_look_at(eye, target, up)
}

// Create a view matrix from position + yaw/pitch (radians).
view_from_yaw_pitch :: proc(pos: Vec3, yaw: f32, pitch: f32) -> Mat4 {
	fwd := forward_from_yaw_pitch(yaw, pitch)
	return la.matrix4_look_at(pos, pos + fwd, Vec3{0, 1, 0})
}

// Forward direction from yaw/pitch (radians). Y-up, -Z is default forward.
forward_from_yaw_pitch :: proc(yaw: f32, pitch: f32) -> Vec3 {
	cp := math.cos(pitch)
	return Vec3{
		-math.sin(yaw) * cp,
		math.sin(pitch),
		-math.cos(yaw) * cp,
	}
}

// Right direction from yaw (radians).
right_from_yaw :: proc(yaw: f32) -> Vec3 {
	return Vec3{
		math.cos(yaw),
		0,
		-math.sin(yaw),
	}
}

// Create a model matrix from position and non-uniform size.
model_matrix_from_pos_size :: proc(pos: Vec3, size: Vec3, rotation: Mat4 = la.MATRIX4F32_IDENTITY) -> Mat4 {
	return la.matrix4_translate_f32(pos) * rotation * la.matrix4_scale_f32(size)
}

// Create a rotation matrix around the Y axis (radians).
rotation_y :: proc(angle: f32) -> Mat4 {
	c := math.cos(angle)
	s := math.sin(angle)
	m := la.MATRIX4F32_IDENTITY
	m[0, 0] =  c
	m[2, 0] = -s
	m[0, 2] =  s
	m[2, 2] =  c
	return m
}

// Orthographic projection.
ortho :: proc(left, right, bottom, top, near, far: f32) -> Mat4 {
	return la.matrix_ortho3d_f32(left, right, bottom, top, near, far)
}

