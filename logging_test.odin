#+build !js
package crossfire

import "base:runtime"
import "core:log"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// Logging (logging.odin): the line format both ways, categories (given, the default, the
// engine's by location, SDL's), levels and the sink's minimum, several lines, other loggers

// What the sink wrote, on this test's thread (SDL calls the hook on the logging thread)
@(private="file", thread_local)
logged: [dynamic]string

// SDL's hook runs with the platform's default context, not the test's tracking allocator: the
// lines are the heap's either way
@(private="file")
captureLine :: proc(line: string, level: LogLevel, platformLog: bool) {
	if logged == nil do logged = make([dynamic]string, runtime.heap_allocator())
	append(&logged, strings.clone(line, runtime.heap_allocator()))
}

@(private="file")
clearLogged :: proc() {
	for line in logged do delete(line, runtime.heap_allocator())
	clear(&logged)
}

@(test)
log_lines_format_and_parse_back :: proc(t: ^testing.T) {
	line := Log_FormatLine(.Warning, "player", "Low health: 12", context.temp_allocator)
	testing.expect_value(t, line, "[WARN ] [player] Low health: 12")
	level, category, text, ok := Log_ParseLine(line)
	testing.expect(t, ok && level == .Warning && category == "player" && text == "Low health: 12", "parsed back")

	for l in LogLevel {
		formatted := Log_FormatLine(l, "ai", "x", context.temp_allocator)
		parsed, _, _, good := Log_ParseLine(formatted)
		testing.expectf(t, good && parsed == l, "%v round trip: %s", l, formatted)
	}
	// No category: the default; a bracket in one can't end it early
	testing.expect_value(t, Log_FormatLine(.Info, "", "hi", context.temp_allocator), "[INFO ] [game] hi")
	odd := Log_FormatLine(.Error, "a]b", "boom", context.temp_allocator)
	_, category, text, ok = Log_ParseLine(odd)
	testing.expect(t, ok && category == "a_b" && text == "boom", odd)
	// Several lines: each carries the level and category
	testing.expect_value(t, Log_FormatLine(.Info, "save", "one\ntwo\n", context.temp_allocator), "[INFO ] [save] one\n[INFO ] [save] two")
	empty := Log_FormatLine(.Debug, "x", "", context.temp_allocator)
	_, category, text, ok = Log_ParseLine(empty)
	testing.expect(t, ok && category == "x" && text == "", empty)

	// Other output isn't a log line: Odin's console logger, compiler errors, plain prints
	for other in ([]string{"[INFO ] --- [2026-10-15 18:17:10] [main.odin:45:run()] message", "main.odin(3:1) Error: x", "hello", "[NOPE ] [x] y", ""}) {
		_, _, _, isLine := Log_ParseLine(other)
		testing.expectf(t, !isLine, "not a log line: %q", other)
	}
}

@(test)
the_engine_logger_writes_categories_and_levels :: proc(t: ^testing.T) {
	defer { clearLogged(); delete(logged); logged = nil }
	sink := LogSink{minimum = .Info, write = captureLine}
	context.logger = Log_CreateLogger(&sink)

	Log_Info("Spawned %d asteroids", 12)
	Log_Warning("Low health: %d", 3, category = "player")
	Log(.Error, "save", "Couldn't write slot %d", 2)
	Log_Debug("hidden at Info")
	// core:log from the engine's folder (this file) is the engine's
	log.infof("engine says %s", "hi")
	testing.expect_value(t, len(logged), 4)
	if len(logged) == 4 {
		testing.expect_value(t, logged[0], "[INFO ] [game] Spawned 12 asteroids")
		testing.expect_value(t, logged[1], "[WARN ] [player] Low health: 3")
		testing.expect_value(t, logged[2], "[ERROR] [save] Couldn't write slot 2")
		testing.expect_value(t, logged[3], "[INFO ] [engine] engine says hi")
	}

	// Debug lines once the level allows them; the level is the sink's
	clearLogged()
	Log_SetLevel(.Debug)
	testing.expect_value(t, Log_GetLevel(), LogLevel.Debug)
	testing.expect_value(t, sink.minimum, LogLevel.Debug)
	Log_Debug("velocity %v", [2]f32{3, -1}, category = "player")
	Log_SetLevel(.Error)
	Log_Warning("dropped")
	log.warn("dropped too")
	Log_Error("kept")
	testing.expect_value(t, len(logged), 2)
	if len(logged) == 2 {
		testing.expect_value(t, logged[0], "[DEBUG] [player] velocity [3, -1]")
		testing.expect_value(t, logged[1], "[ERROR] [game] kept")
	}

	// A category doesn't stick to the next plain core:log call
	clearLogged()
	Log_SetLevel(.Info)
	Log_Info("a", category = "ai")
	log.info("b")
	testing.expect(t, len(logged) == 2 && strings.has_prefix(logged[1], "[INFO ] [engine]"), "the category was only the call's")
}

@(test)
other_loggers_get_the_category_in_the_text :: proc(t: ^testing.T) {
	Captured :: struct {
		text: string,
		level: log.Level,
	}
	captured: Captured
	context.logger = log.Logger{
		procedure = proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
			c := cast(^Captured)data
			c.text, c.level = strings.clone(text, context.allocator), level
		},
		data = &captured,
		lowest_level = .Debug,
	}
	Log_Warning("careful", category = "ai")
	defer delete(captured.text)
	testing.expect_value(t, captured.text, "[ai] careful")
	testing.expect_value(t, captured.level, log.Level.Warning)
	// Not the engine's logger: the level is the logger's business
	testing.expect_value(t, Log_GetLevel(), LogLevel.Debug)
}

@(test)
sdl_messages_go_through_the_sink :: proc(t: ^testing.T) {
	defer { clearLogged(); delete(logged); logged = nil }
	savedProc: sdl.LogOutputFunction
	savedData: rawptr
	sdl.GetLogOutputFunction(&savedProc, &savedData)
	defer sdl.SetLogOutputFunction(savedProc, savedData)

	sink := LogSink{minimum = .Info, write = captureLine}
	Log_HookSDL(&sink)
	sdl.LogMessage(i32(sdl.LogCategory.APPLICATION), .WARN, "The %s is %d", cstring("answer"), i32(42))
	sdl.LogMessage(i32(sdl.LogCategory.APPLICATION), .DEBUG, "below the sink's minimum")
	sdl.SetLogOutputFunction(savedProc, savedData)
	testing.expect_value(t, len(logged), 1)
	if len(logged) == 1 do testing.expect_value(t, logged[0], "[WARN ] [SDL] The answer is 42")
}
