package main_release

import "core:log"
import "core:os"
import "base:runtime"

import game ".."
import sapp "../sokol/app"

main :: proc() {
	if exe_dir, exe_dir_err := os.get_executable_directory(context.temp_allocator); exe_dir_err == nil {
		os.set_working_directory(exe_dir)
	}

	logh, logh_err := os.open("log.txt", {.Create, .Trunc, .Read, .Write})

	if logh_err == os.ERROR_NONE {
		os.stdout = logh
		os.stderr = logh
	}

	logger := logh_err == os.ERROR_NONE ? log.create_file_logger(logh) : log.create_console_logger()
	context.logger = logger
	custom_context = context

	app_desc := game.game_app_default_desc()
	app_desc.init_cb = init
	app_desc.frame_cb = frame
	app_desc.cleanup_cb = cleanup
	app_desc.event_cb = event

	sapp.run(app_desc)

	free_all(context.temp_allocator)

	if logh_err == os.ERROR_NONE {
		log.destroy_file_logger(logger)
	}
}

custom_context: runtime.Context

init :: proc "c" () {
	context = custom_context
	game.game_init()
}

frame :: proc "c" () {
	context = custom_context
	game.game_frame()
}

event :: proc "c" (e: ^sapp.Event) {
	context = custom_context
	game.game_event(e)
}

cleanup :: proc "c" () {
	context = custom_context
	game.game_cleanup()
}

@(export)
NvOptimusEnablement: u32 = 1

@(export)
AmdPowerXpressRequestHighPerformance: i32 = 1
