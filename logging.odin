package crossfire

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import sdl "vendor:sdl3"

/*
Logging for games: a level and a category on every line, formatted text.

Scripts log with `Log_Debug`, `Log_Info`, `Log_Warning` and `Log_Error` (fmt-style text, an
optional `category`, "game" by default), or `Log` with both given. They go through `core:log`
(`context.logger`), so the engine's own `log.info` / `log.warnf` calls and a script's direct
`core:log` calls end up in the same place: the engine's are in the "engine" category (they come
from the engine's folder), anything else without a category is "game". SDL's messages are in the
"SDL" category (`Log_HookSDL`).

The player (`Player_Run`) installs the engine's logger (`Log_CreateLogger`). Every line it writes
has the same readable form, which tools parse back with `Log_ParseLine`:

	[INFO ] [engine] Playing 'Asteroids' (3 scenes, start: Title, 2 scripts registered)
	[WARN ] [player] Low health: 12
	[ERROR] [SDL] Couldn't open the audio device

A message of several lines is written as several lines, each with the level and category.

- **Played from the editor** (`--dev`): lines go to standard output, which the editor reads into
  its Console with their level and category; debug lines are shown.
- **Exported games**: lines go to standard output and to the platform's log as well (the
  debugger's output on Windows, the unified log on macOS; on Linux standard output is the log;
  the browser's console on the web). Debug lines are left out unless the game calls
  `Log_SetLevel(.Debug)`.

Example:
	e.Log_Info("Spawned %d asteroids", 12)
	e.Log_Warning("Low health: %d", 12, category = "player")
	e.Log(.Error, "save", "Couldn't write slot %d", 2)
*/

// How important a log line is, least first
LogLevel :: enum u8 {
	// Details for finding problems; exported games leave them out unless `Log_SetLevel(.Debug)`
	Debug,
	// What happens as the game runs
	Info,
	// Something unexpected the game carries on from
	Warning,
	// Something that failed
	Error,
}

// The category of lines a game logs without naming one
LOG_DEFAULT_CATEGORY :: "game"
// The category of the engine's own messages
LOG_ENGINE_CATEGORY :: "engine"
// The category of SDL's messages (`Log_HookSDL`)
LOG_SDL_CATEGORY :: "SDL"

// Each level's tag at the start of a line, all five characters wide
@(rodata)
LOG_LEVEL_TAGS := [LogLevel]string {
	.Debug   = "DEBUG",
	.Info    = "INFO ",
	.Warning = "WARN ",
	.Error   = "ERROR",
}

/*
Where the engine's logger sends its lines, and which ones (`Log_CreateLogger`). One sink can serve
several loggers and threads: writing is locked.
*/
LogSink :: struct {
	// Lines below this level are dropped (`Log_SetLevel`)
	minimum: LogLevel,
	// Also send each line to the platform's log (exported games)
	platformLog: bool,
	// Writes one finished line (no line break); nil: standard output and, with `platformLog`, the
	// platform's log (`Platform_LogWrite`). Tests and tools set their own
	write: proc(line: string, level: LogLevel, platformLog: bool),
	// Keeps lines from different threads (SDL's) whole
	lock: sync.Mutex,
}

// The category the next line of this thread has (`Log` sets it around its call to core:log)
@(private="file", thread_local)
pendingCategory: string

// The engine's source folder: core:log calls from files in it are the engine's
@(private="file")
ENGINE_SOURCE_DIR :: #directory

/*
A `core:log` logger that writes through `sink` in the engine's line format (see the file's
overview). The player makes one for the whole game; `context.logger = e.Log_CreateLogger(&sink)`
does the same in a program of your own.

Inputs:
- sink: Where lines go and which; it must outlive the logger

Returns:
- The logger (it filters by `sink.minimum`, so its own lowest level is Debug)

Example:
	sink := e.LogSink{minimum = .Info}
	context.logger = e.Log_CreateLogger(&sink)
	e.Log_Info("Ready")
*/
Log_CreateLogger :: proc "contextless" (sink: ^LogSink) -> log.Logger {
	return {procedure = engineLoggerProc, data = sink, lowest_level = .Debug}
}

/*
Logs a line at a level, in a category. The text is formatted like `fmt.printf`. With the engine's
logger (`Log_CreateLogger`, what the player uses) the line carries the category; another
`context.logger` gets it as a `[category] ` prefix of the text.

Inputs:
- level: How important it is
- category: What it's about ("player", "ai"...; "" means `LOG_DEFAULT_CATEGORY`)
- format: The text, with `fmt` verbs (`%d`, `%v`, `%.2f`...)
- args: The values for the verbs

Example:
	e.Log(.Warning, "ai", "No path from %v to %v", [2]f32{0, 0}, [2]f32{100, 40})
*/
Log :: proc(level: LogLevel, category: string, format: string, args: ..any, location := #caller_location) {
	category := category == "" ? LOG_DEFAULT_CATEGORY : category
	logger := context.logger
	if logger.procedure == engineLoggerProc {
		if sink := cast(^LogSink)logger.data; sink != nil && level < sink.minimum do return
		saved := pendingCategory
		pendingCategory = category
		defer pendingCategory = saved
		log.logf(logLevelToCore(level), format, ..args, location = location)
		return
	}
	if logger.procedure == nil do return
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	log.logf(logLevelToCore(level), "[%s] %s", category, fmt.tprintf(format, ..args), location = location)
}

/*
Logs a debug line: details for finding problems. Exported games leave them out unless they call
`Log_SetLevel(.Debug)`; games played from the editor show them.

Inputs:
- format: The text, with `fmt` verbs
- args: The values for the verbs
- category: What it's about (`LOG_DEFAULT_CATEGORY`, "game", if not given)

Example:
	e.Log_Debug("Velocity %v", [2]f32{3, -1}, category = "player")
*/
Log_Debug :: proc(format: string, args: ..any, category := LOG_DEFAULT_CATEGORY, location := #caller_location) {
	Log(.Debug, category, format, ..args, location = location)
}

/*
Logs an info line: what happens as the game runs.

Inputs:
- format: The text, with `fmt` verbs
- args: The values for the verbs
- category: What it's about (`LOG_DEFAULT_CATEGORY`, "game", if not given)

Example:
	e.Log_Info("Level %d started", 3)
*/
Log_Info :: proc(format: string, args: ..any, category := LOG_DEFAULT_CATEGORY, location := #caller_location) {
	Log(.Info, category, format, ..args, location = location)
}

/*
Logs a warning: something unexpected the game carries on from.

Inputs:
- format: The text, with `fmt` verbs
- args: The values for the verbs
- category: What it's about (`LOG_DEFAULT_CATEGORY`, "game", if not given)

Example:
	e.Log_Warning("Low health: %d", 12, category = "player")
*/
Log_Warning :: proc(format: string, args: ..any, category := LOG_DEFAULT_CATEGORY, location := #caller_location) {
	Log(.Warning, category, format, ..args, location = location)
}

/*
Logs an error: something that failed.

Inputs:
- format: The text, with `fmt` verbs
- args: The values for the verbs
- category: What it's about (`LOG_DEFAULT_CATEGORY`, "game", if not given)

Example:
	e.Log_Error("Couldn't load %s", "level3.xml", category = "levels")
*/
Log_Error :: proc(format: string, args: ..any, category := LOG_DEFAULT_CATEGORY, location := #caller_location) {
	Log(.Error, category, format, ..args, location = location)
}

/*
Sets the lowest level the engine's logger writes (lines below it are dropped), for the whole game:
every logger on the same sink. Does nothing when `context.logger` isn't the engine's.

Inputs:
- level: The lowest level written

Example:
	e.Log_SetLevel(.Debug) // an exported game's debug lines too
*/
Log_SetLevel :: proc(level: LogLevel) {
	if context.logger.procedure != engineLoggerProc do return
	if sink := cast(^LogSink)context.logger.data; sink != nil do sink.minimum = level
}

/*
The lowest level the engine's logger writes (`Log_SetLevel`).

Returns:
- The level; Debug when `context.logger` isn't the engine's (it then decides for itself)
*/
Log_GetLevel :: proc() -> LogLevel {
	if context.logger.procedure != engineLoggerProc do return .Debug
	if sink := cast(^LogSink)context.logger.data; sink != nil do return sink.minimum
	return .Debug
}

/*
Writes a log line in the engine's format: `[LEVEL] [category] text`, the level's tag five
characters wide (`LOG_LEVEL_TAGS`). Text of several lines gives as many lines, each with the
level and category. Characters that would end the category early (`]`, line breaks) become `_`.

Inputs:
- level: The line's level
- category: Its category ("" means `LOG_DEFAULT_CATEGORY`)
- text: The message
- allocator: Allocates the result

Returns:
- The line(s), without a final line break

Example:
	line := e.Log_FormatLine(.Warning, "player", "Low health", context.temp_allocator)
	assert(line == "[WARN ] [player] Low health")
*/
Log_FormatLine :: proc(level: LogLevel, category, text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	category := category == "" ? LOG_DEFAULT_CATEGORY : category
	header :: proc(b: ^strings.Builder, level: LogLevel, category: string) {
		strings.write_byte(b, '[')
		strings.write_string(b, LOG_LEVEL_TAGS[level])
		strings.write_string(b, "] [")
		for r in category do strings.write_rune(b, r == ']' || r == '\n' || r == '\r' ? '_' : r)
		strings.write_string(b, "] ")
	}
	text := strings.trim_right(text, "\r\n")
	if text == "" {
		// No text at all: the line still says how important and what about
		header(&b, level, category)
		return strings.to_string(b)
	}
	first := true
	for part in strings.split_lines_iterator(&text) {
		if !first do strings.write_byte(&b, '\n')
		first = false
		header(&b, level, category)
		strings.write_string(&b, strings.trim_right(part, "\r"))
	}
	return strings.to_string(b)
}

/*
Reads a line the engine's logger wrote (`Log_FormatLine`) back into its parts. Tools reading a
game's output use it (the editor's Console).

Inputs:
- line: One line of output

Returns:
- level, category, text: The line's parts (slices of `line`)
- ok: false if the line isn't in the engine's format

Example:
	level, category, text, ok := e.Log_ParseLine("[WARN ] [player] Low health")
	assert(ok && level == .Warning && category == "player" && text == "Low health")
*/
Log_ParseLine :: proc(line: string) -> (level: LogLevel, category: string, text: string, ok: bool) {
	// "[LEVEL] [" is 9 bytes
	if len(line) < 10 || line[0] != '[' || line[6] != ']' || line[7] != ' ' || line[8] != '[' do return
	found := false
	for tag, l in LOG_LEVEL_TAGS {
		if line[1:6] == tag {
			level, found = l, true
			break
		}
	}
	if !found do return
	rest := line[9:]
	end := strings.index_byte(rest, ']')
	if end < 0 do return
	category = rest[:end]
	text = rest[end + 1:]
	if strings.has_prefix(text, " ") do text = text[1:]
	return level, category, text, true
}

/*
Sends SDL's own messages (`SDL_Log`, its errors and warnings) through `sink`, in the "SDL"
category (`LOG_SDL_CATEGORY`). Call it before SDL starts, so its first messages are caught too;
the player does. SDL may log from its own threads: the sink locks around each line.

Inputs:
- sink: Where SDL's lines go; it must outlive SDL's use of it

Example:
	sink := e.LogSink{minimum = .Info}
	e.Log_HookSDL(&sink)
*/
Log_HookSDL :: proc(sink: ^LogSink) {
	sdl.SetLogOutputFunction(sdlLogOutput, sink)
}

@(private="file")
sdlLogOutput :: proc "c" (userdata: rawptr, category: sdl.LogCategory, priority: sdl.LogPriority, message: cstring) {
	context = Platform_DefaultContext()
	sink := cast(^LogSink)userdata
	if sink == nil do return
	level := LogLevel.Info
	#partial switch priority {
	case .TRACE, .VERBOSE, .DEBUG: level = .Debug
	case .INFO:                    level = .Info
	case .WARN:                    level = .Warning
	case .ERROR, .CRITICAL:        level = .Error
	}
	logSinkWrite(sink, level, LOG_SDL_CATEGORY, string(message))
}

@(private="file")
engineLoggerProc :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	sink := cast(^LogSink)data
	if sink == nil do return
	ours := logLevelFromCore(level)
	category := pendingCategory
	if category == "" {
		category = strings.has_prefix(location.file_path, ENGINE_SOURCE_DIR) ? LOG_ENGINE_CATEGORY : LOG_DEFAULT_CATEGORY
	}
	logSinkWrite(sink, ours, category, text)
}

// Formats and writes one message (several lines if it has line breaks), locked
@(private="file")
logSinkWrite :: proc(sink: ^LogSink, level: LogLevel, category, text: string) {
	if level < sink.minimum do return
	line := Log_FormatLine(level, category, text)
	defer delete(line)
	sync.mutex_lock(&sink.lock)
	defer sync.mutex_unlock(&sink.lock)
	if sink.write != nil {
		sink.write(line, level, sink.platformLog)
	} else {
		Platform_LogWrite(line, level, sink.platformLog)
	}
}

@(private="file")
logLevelToCore :: proc(level: LogLevel) -> log.Level {
	switch level {
	case .Debug:   return .Debug
	case .Info:    return .Info
	case .Warning: return .Warning
	case .Error:   return .Error
	}
	return .Info
}

@(private="file")
logLevelFromCore :: proc(level: log.Level) -> LogLevel {
	switch {
	case level < .Info:    return .Debug
	case level < .Warning: return .Info
	case level < .Error:   return .Warning
	}
	return .Error
}
