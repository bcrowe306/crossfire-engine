#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
#+build !windows
#+build !js
#+no-instrumentation
package crossfire

import "core:time"

// The trace's clocks (trace_native.odin) elsewhere: core:time's, which SPALL_AUTO instruments
// (don't use SPALL_AUTO here)
@(private)
@(no_instrumentation)
wallNanoseconds :: proc "contextless" () -> u64 {
	return u64(time.tick_now()._nsec)
}

// No thread CPU clock here: SPALL_CLOCK=cpu falls back to wall time
@(private)
@(no_instrumentation)
threadCPUNanoseconds :: proc "contextless" () -> (u64, bool) {
	return 0, false
}
