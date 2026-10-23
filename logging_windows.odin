package crossfire

import "base:runtime"
import "core:strings"
import win32 "core:sys/windows"

// Windows' platform log for exported games (Platform_LogWrite): the debugger's output
@(private)
platformSystemLog :: proc(line: string, level: LogLevel) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	win32.OutputDebugStringW(win32.utf8_to_wstring(strings.concatenate({line, "\r\n"}, context.temp_allocator), context.temp_allocator))
}
