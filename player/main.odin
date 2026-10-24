/*
The game player for projects without scripts: runs a project saved by the editor.

	player <project folder>

Everything happens in `e.Player_Run` (player.odin), called through `e.Player_Main` so this file
also builds for the browser. A project with scripts gets its own player, which the editor
generates: the same call, with the project's scripts package imported.

Exit codes: 0 after a normal quit, 1 if the project couldn't be loaded.

Built with `-define:SPALL=true -define:SPALL_AUTO=true`, it records every procedure into its
Spall trace (the engine's trace.odin): Odin's instrumentation hooks must be in one package of the
program, and the main package is the program's.
*/
package player

@(require) import "base:runtime"
import e ".."

main :: proc() {
	e.Player_Main()
}

when e.SPALL && e.SPALL_AUTO {
	@(instrumentation_enter)
	traceEnter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		e.Trace_AutoEnter(loc)
	}

	@(instrumentation_exit)
	traceExit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		e.Trace_AutoExit()
	}
}
