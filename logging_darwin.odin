package crossfire

import "base:runtime"
import "core:c"
import "core:strings"

foreign import libc "system:System"

@(private="file", default_calling_convention = "c")
foreign libc {
	syslog :: proc(priority: c.int, format: cstring, #c_vararg args: ..any) ---
}

// syslog's priorities (sys/syslog.h)
@(private="file") LOG_ERR     :: 3
@(private="file") LOG_WARNING :: 4
@(private="file") LOG_INFO    :: 6
@(private="file") LOG_DEBUG   :: 7

// macOS's platform log for exported games (Platform_LogWrite): the unified log (Console.app)
@(private)
platformSystemLog :: proc(line: string, level: LogLevel) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	priority: c.int
	switch level {
	case .Debug:   priority = LOG_DEBUG
	case .Info:    priority = LOG_INFO
	case .Warning: priority = LOG_WARNING
	case .Error:   priority = LOG_ERR
	}
	syslog(priority, "%s", strings.clone_to_cstring(line, context.temp_allocator))
}
