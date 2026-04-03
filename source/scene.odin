// scene.odin — Test geometry: ground plane + boxes. Single vertex buffer, drawn with per-object transforms.
package game

import sg "sokol/gfx"
import la "core:math/linalg"

Scene_Vertex :: struct {
	position: Vec3,
	normal:   Vec3,
}

Box_Instance :: struct {
	pos:       Vec3,
	size:      Vec3,
	color:     Vec4,
	entity_id: u32,  // unique ID for edge detection outlines (0 = sky/none, 1+ = objects)
	rot_speed: f32,  // Y-axis rotation speed in rad/s (0 = static)
	rot_angle: f32,  // current Y-axis rotation in radians
}

Scene :: struct {
	vbuf:  sg.Buffer,
	boxes: [dynamic]Box_Instance,
}

// Unit box centered at origin, half-extent 0.5. 36 vertices (non-indexed), CCW winding.
UNIT_BOX_VERTICES :: [36]Scene_Vertex{
	// +X face
	{{+0.5, -0.5, +0.5}, {1, 0, 0}},
	{{+0.5, -0.5, -0.5}, {1, 0, 0}},
	{{+0.5, +0.5, -0.5}, {1, 0, 0}},
	{{+0.5, -0.5, +0.5}, {1, 0, 0}},
	{{+0.5, +0.5, -0.5}, {1, 0, 0}},
	{{+0.5, +0.5, +0.5}, {1, 0, 0}},
	// -X face
	{{-0.5, -0.5, -0.5}, {-1, 0, 0}},
	{{-0.5, -0.5, +0.5}, {-1, 0, 0}},
	{{-0.5, +0.5, +0.5}, {-1, 0, 0}},
	{{-0.5, -0.5, -0.5}, {-1, 0, 0}},
	{{-0.5, +0.5, +0.5}, {-1, 0, 0}},
	{{-0.5, +0.5, -0.5}, {-1, 0, 0}},
	// +Y face
	{{-0.5, +0.5, +0.5}, {0, 1, 0}},
	{{+0.5, +0.5, +0.5}, {0, 1, 0}},
	{{+0.5, +0.5, -0.5}, {0, 1, 0}},
	{{-0.5, +0.5, +0.5}, {0, 1, 0}},
	{{+0.5, +0.5, -0.5}, {0, 1, 0}},
	{{-0.5, +0.5, -0.5}, {0, 1, 0}},
	// -Y face
	{{-0.5, -0.5, -0.5}, {0, -1, 0}},
	{{+0.5, -0.5, -0.5}, {0, -1, 0}},
	{{+0.5, -0.5, +0.5}, {0, -1, 0}},
	{{-0.5, -0.5, -0.5}, {0, -1, 0}},
	{{+0.5, -0.5, +0.5}, {0, -1, 0}},
	{{-0.5, -0.5, +0.5}, {0, -1, 0}},
	// +Z face
	{{-0.5, -0.5, +0.5}, {0, 0, 1}},
	{{+0.5, -0.5, +0.5}, {0, 0, 1}},
	{{+0.5, +0.5, +0.5}, {0, 0, 1}},
	{{-0.5, -0.5, +0.5}, {0, 0, 1}},
	{{+0.5, +0.5, +0.5}, {0, 0, 1}},
	{{-0.5, +0.5, +0.5}, {0, 0, 1}},
	// -Z face
	{{+0.5, -0.5, -0.5}, {0, 0, -1}},
	{{-0.5, -0.5, -0.5}, {0, 0, -1}},
	{{-0.5, +0.5, -0.5}, {0, 0, -1}},
	{{+0.5, -0.5, -0.5}, {0, 0, -1}},
	{{-0.5, +0.5, -0.5}, {0, 0, -1}},
	{{+0.5, +0.5, -0.5}, {0, 0, -1}},
}

scene_init :: proc(scene: ^Scene) {
	verts := UNIT_BOX_VERTICES
	scene.vbuf = sg.make_buffer({
		data = {ptr = &verts, size = size_of(verts)},
	})

	// Ground plane
	append(&scene.boxes, Box_Instance{pos = {0, -0.5, 0}, size = {20, 1, 20}, color = {0.7, 0.7, 0.7, 1}, entity_id = 1})

	// Assorted boxes — each gets a unique entity_id for outline detection
	append(&scene.boxes, Box_Instance{pos = {2, 0.5, -2}, size = {1, 1, 1}, color = {0.9, 0.3, 0.3, 1}, entity_id = 2})
	append(&scene.boxes, Box_Instance{pos = {-1, 1.0, -1}, size = {1, 2, 1}, color = {0.3, 0.9, 0.3, 1}, entity_id = 3})
	append(&scene.boxes, Box_Instance{pos = {0, 0.25, 2}, size = {2, 0.5, 1}, color = {0.3, 0.3, 0.9, 1}, entity_id = 4})
	append(&scene.boxes, Box_Instance{pos = {-3, 0.75, 0}, size = {1, 1.5, 1}, color = {0.9, 0.9, 0.3, 1}, entity_id = 5})
	append(&scene.boxes, Box_Instance{pos = {3, 1.5, 1}, size = {0.5, 3, 0.5}, color = {0.9, 0.3, 0.9, 1}, entity_id = 6})
	append(&scene.boxes, Box_Instance{pos = {-2, 0.5, 3}, size = {1.5, 1, 0.5}, color = {0.3, 0.9, 0.9, 1}, entity_id = 7})

	// Spinning box — demonstrates dynamic geometry
	append(&scene.boxes, Box_Instance{
		pos = {0, 1.0, -4}, size = {1.2, 1.2, 1.2},
		color = {1.0, 0.6, 0.1, 1}, entity_id = 8,
		rot_speed = 0.8,  // ~45°/s
	})
}

scene_update :: proc(scene: ^Scene, dt: f32) {
	for &box in scene.boxes {
		if box.rot_speed != 0 {
			box.rot_angle += box.rot_speed * dt
		}
	}
}

// Build the model matrix for a box, including its current rotation.
scene_box_model :: proc(box: ^Box_Instance) -> Mat4 {
	rot := box.rot_speed != 0 ? rotation_y(box.rot_angle) : la.MATRIX4F32_IDENTITY
	return model_matrix_from_pos_size(box.pos, box.size, rot)
}

scene_cleanup :: proc(scene: ^Scene) {
	sg.destroy_buffer(scene.vbuf)
	delete(scene.boxes)
}
