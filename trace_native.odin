#+build !js
#+no-instrumentation
package crossfire

import "base:runtime"
@(require) import "core:os"
import "core:prof/spall"
import "core:sync"

// The trace's state (trace.odin): the engine's own trace, or one shared by the program
@(private="file") traceCtx: spall.Context
@(private="file") traceRunning: bool
@(private="file") traceLock: sync.Mutex
@(private="file") traceBuffers: [dynamic]^spall.Buffer
@(private="file") @(thread_local) traceBuffer: ^spall.Buffer
// Set while a thread makes its buffer: allocating runs instrumented procedures (SPALL_AUTO)
@(private="file") @(thread_local) traceBusy: bool
// A program's trace (Trace_Share), used instead of the engine's
@(private="file") sharedCtx: ^spall.Context
@(private="file") sharedBuffer: TraceBufferProc

/*
Starts the engine's trace, writing to `path` (the `SPALL_TRACE` environment variable when empty,
else `trace.spall`). Does nothing without SPALL, when a trace is running or one is shared.

Inputs:
- path: The `.spall` file to write

Returns:
- true when a trace is running afterwards

Example:
	traced := e.Trace_Start("game.spall")
	defer if traced do e.Trace_Stop()
*/
Trace_Start :: proc(path := "") -> bool {
	when SPALL {
		if traceRunning || sharedCtx != nil do return true
		file := path
		if file == "" do file = os.get_env("SPALL_TRACE", context.temp_allocator)
		if file == "" do file = "trace.spall"
		// Ticks in nanoseconds (scale 1): no two-second clock calibration at startup
		ctx, ok := spall.context_create_with_scale(file, false, 1)
		if !ok do return false
		traceCtx = ctx
		traceRunning = true
		Trace_NameThread("main")
		return true
	} else {
		return false
	}
}

/*
Stops the engine's trace: every thread's buffer is written and freed, and the file closed.
Threads still recording must have finished. A shared trace is its owner's to stop.
*/
Trace_Stop :: proc() {
	when SPALL {
		if !traceRunning do return
		// No recording while the buffers go (freeing runs instrumented procedures)
		traceBusy = true
		defer traceBusy = false
		traceBuffer = nil
		sync.lock(&traceLock)
		for b in traceBuffers {
			spall.buffer_destroy(&traceCtx, b)
			traceBufferFree(b)
		}
		delete(traceBuffers)
		traceBuffers = nil
		sync.unlock(&traceLock)
		traceRunning = false
		spall.context_destroy(&traceCtx)
	}
}

/*
Records into a program's own trace instead of the engine's: its context (a `^spall.Context`)
and the procedure giving each thread's buffer, so events from the program and the engine on one
thread nest in one buffer. The Crossfire Editor shares Skald's (`skald.prof_context`,
`skald.prof_thread_buffer`). Pass nil to stop sharing.

Inputs:
- ctx: The program's running trace (a `^spall.Context`)
- buffer: The calling thread's buffer in it
*/
Trace_Share :: proc(ctx: rawptr, buffer: TraceBufferProc) {
	when SPALL {
		sharedCtx = (^spall.Context)(ctx)
		sharedBuffer = buffer if ctx != nil else nil
	}
}

/*
Whether a trace is being written (the engine's own or a shared one).

Returns:
- true while recording
*/
Trace_Running :: proc "contextless" () -> bool {
	when SPALL do return traceRunning || sharedCtx != nil
	else do return false
}

// The trace and the calling thread's buffer in it, made the first time (nil, nil without one)
@(private="file")
traceTarget :: proc "contextless" () -> (^spall.Context, ^spall.Buffer) {
	when SPALL {
		if sharedCtx != nil {
			if sharedBuffer == nil do return nil, nil
			b := (^spall.Buffer)(sharedBuffer())
			return (sharedCtx if b != nil else nil), b
		}
		if traceBusy do return nil, nil
		if traceBuffer != nil do return &traceCtx, traceBuffer
		if !traceRunning do return nil, nil
		traceBusy = true
		defer traceBusy = false
		context = Platform_DefaultContext()
		data, err := make([]u8, TRACE_BUFFER_SIZE, heapAllocator())
		if err != nil do return nil, nil
		b := new(spall.Buffer, heapAllocator())
		b^ = spall.buffer_create(data, u32(sync.current_thread_id()), u32(os.get_pid()))
		sync.lock(&traceLock)
		append(&traceBuffers, b)
		sync.unlock(&traceLock)
		traceBuffer = b
		return &traceCtx, b
	} else {
		return nil, nil
	}
}

/*
Writes and frees the calling thread's buffer in the engine's own trace: call it before a thread
that recorded ends. The thread gets a new buffer if it records again. (A shared trace's buffers
are its owner's.)
*/
Trace_ThreadEnd :: proc "contextless" () {
	when SPALL {
		b := traceBuffer
		if b == nil do return
		traceBusy = true
		defer traceBusy = false
		traceBuffer = nil
		context = Platform_DefaultContext()
		sync.lock(&traceLock)
		for x, i in traceBuffers do if x == b {
			unordered_remove(&traceBuffers, i)
			break
		}
		sync.unlock(&traceLock)
		if traceRunning do spall.buffer_destroy(&traceCtx, b)
		traceBufferFree(b)
	}
}

/*
Names the calling thread in the trace.

Inputs:
- name: The thread's name
*/
Trace_NameThread :: proc "contextless" (name: string) {
	when SPALL {
		if ctx, b := traceTarget(); b != nil do spall._buffer_name_thread(ctx, b, name)
	}
}

/*
Begins a named span on the calling thread; `Trace_End` ends the innermost one. Prefer
`Trace_Scope` (trace.odin), which ends itself.

Inputs:
- name: The span's name in the trace
- args: Extra text shown with it
*/
Trace_Begin :: proc "contextless" (name: string, args := "") {
	when SPALL {
		if ctx, b := traceTarget(); b != nil do spall._buffer_begin(ctx, b, name, args)
	}
}

// Trace_End ends the calling thread's innermost span.
Trace_End :: proc "contextless" () {
	when SPALL {
		if ctx, b := traceTarget(); b != nil do spall._buffer_end(ctx, b)
	}
}

/*
What a main package's `@(instrumentation_enter)` hook calls with SPALL_AUTO: a span named by
the procedure's location.

Inputs:
- loc: The entered procedure's location
*/
Trace_AutoEnter :: proc "contextless" (loc: runtime.Source_Code_Location) {
	when SPALL {
		if ctx, b := traceTarget(); b != nil do spall._buffer_begin(ctx, b, "", "", loc)
	}
}

// Trace_AutoExit is what a main package's `@(instrumentation_exit)` hook calls: the span's end.
Trace_AutoExit :: proc "contextless" () {
	when SPALL {
		if ctx, b := traceTarget(); b != nil do spall._buffer_end(ctx, b)
	}
}

@(private="file")
traceBufferFree :: proc "contextless" (b: ^spall.Buffer) {
	context = Platform_DefaultContext()
	delete(b.data, heapAllocator())
	free(b, heapAllocator())
}
