#+build !js
#+no-instrumentation
package crossfire

import "base:runtime"
@(require) import "core:os"
import "core:prof/spall"
import "core:sync"

// Every procedure here is @(no_instrumentation) (the file tag alone left them instrumented), and
// the ones slicing a buffer are #no_bounds_check: the runtime's bounds-check helpers are inlined
// with SPALL_AUTO's hooks, which would call back into Trace_Begin forever (spall's own code says
// so too)
// The trace's state (trace.odin): the engine's own trace, or a program's shared one
@(private="file") traceCtx: spall.Context
@(private="file") traceRunning: bool
// SPALL_CLOCK=cpu: timestamps are the thread's CPU time
@(private="file") traceCPUClock: bool
@(private="file") traceLock: sync.Mutex
// Held while a buffer is written to the file (threads flush on their own)
@(private="file") traceWriteLock: sync.Mutex
@(private="file") traceBuffers: [dynamic]^spall.Buffer
@(private="file") @(thread_local) traceBuffer: ^spall.Buffer
// Set while a thread makes or frees its buffer: allocating runs instrumented procedures
// (SPALL_AUTO), which would ask for the buffer again or write into one being freed
@(private="file") @(thread_local) traceBusy: bool
// A program's trace (Trace_Share): its begin and end, used instead of the engine's
@(private="file") sharedBegin: TraceBeginProc
@(private="file") sharedEnd: TraceEndProc

/*
Starts the engine's trace, writing to `path` (the `SPALL_TRACE` environment variable when empty,
else `trace.spall`), on the clock `SPALL_CLOCK` names (`cpu`: each thread's CPU time; else wall
time). Does nothing without SPALL, when a trace is running or one is shared.

Inputs:
- path: The `.spall` file to write

Returns:
- true when a trace is running afterwards

Example:
	traced := e.Trace_Start("game.spall")
	defer if traced do e.Trace_Stop()
*/
@(no_instrumentation)
Trace_Start :: proc(path := "") -> bool {
	when SPALL {
		if traceRunning || sharedBegin != nil do return true
		file := path
		if file == "" do file = os.get_env("SPALL_TRACE", context.temp_allocator)
		if file == "" do file = "trace.spall"
		// Timestamps in nanoseconds (scale 1): no two-second clock calibration at startup
		ctx, ok := spall.context_create_with_scale(file, false, 1)
		if !ok do return false
		traceCtx = ctx
		traceCPUClock = os.get_env("SPALL_CLOCK", context.temp_allocator) == "cpu"
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
@(no_instrumentation)
Trace_Stop :: proc() {
	when SPALL {
		if !traceRunning do return
		traceBusy = true
		defer traceBusy = false
		traceBuffer = nil
		sync.lock(&traceLock)
		for b in traceBuffers {
			traceBufferWrite(b)
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
Records into a program's own trace instead of the engine's: the engine's spans go through the
program's begin and end procedures, so a thread's events from both land in one buffer, nested,
on one clock. The Crossfire Editor passes Skald's (`skald.prof_begin`, `skald.prof_end`). Pass
nil, nil to stop sharing.

Inputs:
- begin: The program's begin-a-span procedure
- end: Its end-the-innermost-span procedure
*/
@(no_instrumentation)
Trace_Share :: proc(begin: TraceBeginProc, end: TraceEndProc) {
	when SPALL {
		sharedBegin = begin
		sharedEnd = end if begin != nil else nil
	}
}

/*
Whether a trace is being written (the engine's own or a shared one).

Returns:
- true while recording
*/
@(no_instrumentation)
Trace_Running :: proc "contextless" () -> bool {
	when SPALL do return traceRunning || sharedBegin != nil
	else do return false
}

// The engine's own trace's clock: nanoseconds of wall time, or of the thread's CPU time
@(private="file")
@(no_instrumentation)
traceNow :: proc "contextless" () -> u64 {
	if traceCPUClock {
		if ns, ok := threadCPUNanoseconds(); ok do return ns
	}
	return wallNanoseconds()
}

// The calling thread's buffer in the engine's own trace, made the first time (nil without one)
@(private="file")
@(no_instrumentation)
traceThreadBuffer :: proc "contextless" () -> ^spall.Buffer {
	when SPALL {
		if traceBusy do return nil
		if traceBuffer != nil || !traceRunning do return traceBuffer
		traceBusy = true
		defer traceBusy = false
		context = Platform_DefaultContext()
		data, err := make([]u8, TRACE_BUFFER_SIZE, heapAllocator())
		if err != nil do return nil
		b := new(spall.Buffer, heapAllocator())
		b^ = spall.buffer_create(data, u32(sync.current_thread_id()), u32(os.get_pid()))
		b.first_ts = traceNow()
		sync.lock(&traceLock)
		append(&traceBuffers, b)
		sync.unlock(&traceLock)
		traceBuffer = b
		return b
	} else {
		return nil
	}
}

/*
Writes and frees the calling thread's buffer in the engine's own trace: call it before a thread
that recorded ends. The thread gets a new buffer if it records again. (A shared trace's buffers
are its owner's.)
*/
@(no_instrumentation)
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
		if traceRunning do traceBufferWrite(b)
		traceBufferFree(b)
	}
}

/*
Names the calling thread in the engine's own trace (a shared trace's threads are named by its
owner).

Inputs:
- name: The thread's name
*/
@(no_instrumentation)
Trace_NameThread :: proc "contextless" (name: string) #no_bounds_check {
	when SPALL {
		if sharedBegin != nil do return
		if b := traceThreadBuffer(); b != nil {
			if b.head + spall.NAME_EVENT_MAX > len(b.data) do traceBufferWrite(b)
			b.head += spall._build_name_event(b.data[b.head:], name, .Name_Thread)
		}
	}
}

/*
Begins a named span on the calling thread; `Trace_End` ends the innermost one. Prefer
`Trace_Scope` (trace.odin), which ends itself.

Inputs:
- name: The span's name in the trace
- args: Extra text shown with it
*/
@(no_instrumentation)
Trace_Begin :: proc "contextless" (name: string, args := "") #no_bounds_check {
	when SPALL {
		if sharedBegin != nil {
			sharedBegin(name, args)
			return
		}
		if b := traceThreadBuffer(); b != nil {
			if b.head + spall.BEGIN_EVENT_MAX > len(b.data) do traceBufferWrite(b)
			b.head += spall._build_begin(b.data[b.head:], name, args, traceNow())
		}
	}
}

// Trace_End ends the calling thread's innermost span.
@(no_instrumentation)
Trace_End :: proc "contextless" () #no_bounds_check {
	when SPALL {
		if sharedEnd != nil {
			sharedEnd()
			return
		}
		if b := traceThreadBuffer(); b != nil {
			ts := traceNow()
			if b.head + size_of(spall.End_Event) > len(b.data) do traceBufferWrite(b)
			b.head += spall._build_end(b.data[b.head:], ts)
		}
	}
}

/*
What a main package's `@(instrumentation_enter)` hook calls with SPALL_AUTO: a span named by
the procedure's location.

Inputs:
- loc: The entered procedure's location
*/
@(no_instrumentation)
Trace_AutoEnter :: proc "contextless" (loc: runtime.Source_Code_Location) {
	when SPALL do Trace_Begin(loc.procedure)
}

// Trace_AutoExit is what a main package's `@(instrumentation_exit)` hook calls: the span's end.
@(no_instrumentation)
Trace_AutoExit :: proc "contextless" () {
	when SPALL do Trace_End()
}

// Writes a buffer's events to the file and empties it (spall's buffer_flush, without the
// wall-clock "flush" event it adds)
@(private="file")
@(no_instrumentation)
traceBufferWrite :: proc "contextless" (b: ^spall.Buffer) #no_bounds_check {
	if len(b.data) == 0 || b.head <= size_of(spall.Manual_Buffer_Header) do return
	// Locking and writing run instrumented procedures (SPALL_AUTO): no recording meanwhile
	was := traceBusy
	traceBusy = true
	defer traceBusy = was
	hdr := (^spall.Manual_Buffer_Header)(raw_data(b.data))
	hdr.size = u32le(b.head - size_of(spall.Manual_Buffer_Header))
	hdr.pid = u32le(b.pid)
	hdr.tid = u32le(b.tid)
	hdr.first_ts = u64le(b.first_ts)
	context = Platform_DefaultContext()
	sync.lock(&traceWriteLock)
	_, _ = os.write(traceCtx.file, b.data[:b.head])
	sync.unlock(&traceWriteLock)
	b.head = size_of(spall.Manual_Buffer_Header)
	b.first_ts = traceNow()
}

@(private="file")
@(no_instrumentation)
traceBufferFree :: proc "contextless" (b: ^spall.Buffer) {
	context = Platform_DefaultContext()
	delete(b.data, heapAllocator())
	free(b, heapAllocator())
}
