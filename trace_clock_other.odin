#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
#+build !js
#+no-instrumentation
package crossfire

// No thread CPU clock here: SPALL_CLOCK=cpu falls back to wall time (trace_native.odin)
@(private)
threadCPUNanoseconds :: proc "contextless" () -> (u64, bool) {
	return 0, false
}
