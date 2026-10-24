package crossfire

// Profiling with Spall (https://gravitymoth.com/spall/), compiled out unless asked for.
//
// Build with `-define:SPALL=true` and each `Trace_Scope` becomes a begin / end pair in a `.spall`
// trace, opened in Spall's viewer or read by the Crossfire Editor's `tools/spall_report`; without
// it the procedures are empty and the optimizer removes them. The engine's own scopes cover a
// frame (`Application_Frame`: `frame`, `events`, `update`, `draw`, `present`), `Game_Update`
// (`input`, `audio`, `globals`, `scene_update`), `Scene_Update` (`physics`, `nodes_update`,
// `tweens`, `camera`) and `Scene_DrawWithView` (`scene_draw`: `draw_order`, `nodes_draw`,
// `lighting`).
//
// The trace:
//   - The player starts one (`Trace_Start`) named by the `SPALL_TRACE` environment variable
//     (default `trace.spall`), and stops it when the game ends (`Trace_Stop`).
//   - Each thread writes into its own buffer, made the first time it records something and
//     written when full, when the thread ends (`Trace_ThreadEnd`) or when the trace stops.
//   - A program with its own trace (the editor: Skald's) hands it over with `Trace_Share`, and the
//     engine records into that trace and that thread's buffer, so one thread's events nest.
//   - `-define:SPALL_AUTO=true` records every procedure: a program's main package defines the
//     instrumentation hooks and calls `Trace_AutoEnter` / `Trace_AutoExit` (the player does).
//
// The browser build has none of it (trace_web.odin: the procedures do nothing).

// SPALL turns profiling on (`-define:SPALL=true`).
SPALL :: #config(SPALL, false)

// SPALL_AUTO records every procedure (`-define:SPALL_AUTO=true`, with SPALL; the main package's hooks).
SPALL_AUTO :: #config(SPALL_AUTO, false)

// TRACE_BUFFER_SIZE is the size of each thread's buffer: a full buffer is written to the file.
TRACE_BUFFER_SIZE :: 1 << 20

/*
A procedure giving the calling thread's trace buffer (a `^spall.Buffer`, untyped: the browser
build has no Spall), for `Trace_Share`.
*/
TraceBufferProc :: #type proc "contextless" () -> rawptr

/*
A span from here to the end of the enclosing block, named `name` (nothing without SPALL).

Inputs:
- name: The span's name in the trace
- args: Extra text shown with it

Example:
	update_enemies :: proc() {
		e.Trace_Scope("update_enemies")
		// ...
	}
*/
@(deferred_none = Trace_End, no_instrumentation)
Trace_Scope :: proc "contextless" (name: string, args := "") {
	Trace_Begin(name, args)
}
