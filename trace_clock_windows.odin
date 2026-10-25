#+build windows
#+no-instrumentation
package crossfire

import win "core:sys/windows"

// The trace's clocks (trace_native.odin), foreign calls only (see trace_clock_posix.odin)

// Wall time in nanoseconds (the performance counter)
@(private)
@(no_instrumentation)
wallNanoseconds :: proc "contextless" () -> u64 {
	freq, now: win.LARGE_INTEGER
	win.QueryPerformanceFrequency(&freq)
	win.QueryPerformanceCounter(&now)
	if freq <= 0 do return 0
	return u64(i64(now) / i64(freq)) * 1_000_000_000 + u64(i64(now) % i64(freq)) * 1_000_000_000 / u64(freq)
}

// No thread CPU clock here: SPALL_CLOCK=cpu falls back to wall time
@(private)
@(no_instrumentation)
threadCPUNanoseconds :: proc "contextless" () -> (u64, bool) {
	return 0, false
}
