// input.odin — Key/mouse state. Processes sokol_app events into held/pressed state.
// Other files read key_held[], key_pressed[], mouse_move directly (package-level vars).
// input_reset() must be called at end of frame to clear per-frame state.
package game

import sapp "sokol/app"

Key :: enum {
	None,
	Forward,
	Backward,
	Left,
	Right,
	Up,
	Down,
	Sprint,
	ToggleDebug,  // Tab: cycle debug visualization mode
	Face1,        // 1-6: select cubemap face for debug vis
	Face2,
	Face3,
	Face4,
	Face5,
	Face6,
	ProbeToggle,  // 7: toggle debug probe (eye/grid)
}

key_pressed: [Key]bool
key_held:    [Key]bool

key_mapping := #partial #sparse [sapp.Keycode]Key{
	.W             = .Forward,
	.S             = .Backward,
	.A             = .Left,
	.D             = .Right,
	.SPACE         = .Up,
	.LEFT_SHIFT    = .Down,
	.LEFT_CONTROL  = .Sprint,
	.TAB           = .ToggleDebug,
	._1            = .Face1,
	._2            = .Face2,
	._3            = .Face3,
	._4            = .Face4,
	._5            = .Face5,
	._6            = .Face6,
	._7            = .ProbeToggle,
}

// Accumulated mouse delta this frame. Reset at end of frame by input_reset().
// Only meaningful when sapp.mouse_locked() is true (click to lock, Esc to unlock).
mouse_move: Vec2

process_input :: proc(e: ^sapp.Event) {
	#partial switch e.type {
	case .MOUSE_MOVE:
		mouse_move += {e.mouse_dx, e.mouse_dy}

	case .KEY_DOWN:
		if e.key_repeat {
			break
		}

		key := key_mapping[e.key_code]
		if key != .None {
			key_held[key] = true
			key_pressed[key] = true
		}

		if e.key_code == .ESCAPE {
			sapp.lock_mouse(false)
		}

		if e.key_code == .F6 {
			force_reset = true
		}

	case .KEY_UP:
		key := key_mapping[e.key_code]
		if key != .None {
			key_held[key] = false
		}

	case .MOUSE_DOWN:
		if e.mouse_button == .LEFT {
			sapp.lock_mouse(true)
		}
	}
}

input_reset :: proc() {
	key_pressed = {}
	mouse_move = {}
}
