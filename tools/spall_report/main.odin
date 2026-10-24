/*
Reads Spall traces (`.spall`, the binary format of `core:prof/spall`) and says where the time went,
as text and JSON, so performance work can be measured without Spall's viewer.

	spall_report <trace.spall>... [-skip=<frames>] [-from=<mark>] [-to=<mark>] [-top=<n>] [-json=<file>]
	             [-thread=<name>] [-frame=<scope>]
	spall_report compare <before.json> <after.json> [-threshold=<percent>]

The report:
- **Frames:** spans named `frame` (`-frame=` another name) on the chosen thread (`-thread=`, by the
  name the program gave it; default `main`): how long each took (median, mean, p95, p99, max) and
  the time from one frame's start to the next (the frame rate, waits included). The first `-skip`
  frames (default 30) are warm-up: nothing before the first frame kept is counted anywhere.
- **A window between marks:** `-from=<name>` / `-to=<name>` count only what starts between the
  first span named `mark:<name>` and the first `mark:<to>` after it (the editor's test driver
  writes them: `profile_mark <name>`); `-skip` then defaults to 0, counted from the mark.
- **Scopes:** for each span name on that thread: how many, the total time (inclusive; a name
  nested in itself counts once), the self time (without its children), the mean and the longest,
  and both per frame. Sorted by self time; `-top` limits the rows (default 40).
- **Threads:** each other thread's busy time (its top-level spans).
- **Several traces** (runs of one scenario) make one report: their frames and spans are pooled
  (intervals within each run), which steadies the numbers more than keeping one run.

`compare` reads two reports' JSON and prints what changed: the frame times, and each scope's
time per frame and per call. It exits with 1 when the mean frame time got slower by more than
`-threshold` percent (default 5), so a change can't quietly make things worse. The mean, not the
median: frames are often of two kinds (the editor's viewport renders on a timer, so some frames
hold a scene render and some don't), and the median jumps between them. For a span whose calls
come from a timer, compare its time per call (mean ms), not per frame.

Built and run from the workspace like any tool: `odin run tools/spall_report -o:speed -- <args>`.
The editor's `task profile` and the engine's harness call it.
*/
package spall_report

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// What the file's events are (core:prof/spall's Manual_Event_Type)
EventType :: enum u8 {
	Invalid      = 0,
	Begin        = 3,
	End          = 4,
	Instant      = 5,
	Pad_Skip     = 7,
	Name_Process = 8,
	Name_Thread  = 9,
}

// SPALL_MAGIC starts every Spall binary file.
SPALL_MAGIC :: u64(0x0BADF00D)

// One finished span, in nanoseconds
Span :: struct {
	name:  int,
	start: f64,
	end:   f64,
	// Time in its direct children
	child: f64,
	// Depth on its thread's stack (0: top level)
	depth: int,
	// Whether a span of the same name encloses it (its time is already in that one's total)
	nested: bool,
}

// A thread's spans and the stack of open ones
Thread :: struct {
	tid:   u32,
	name:  string,
	spans: [dynamic]Span,
	stack: [dynamic]Span,
}

// The parsed trace
Trace :: struct {
	names:   [dynamic]string,
	nameIds: map[string]int,
	threads: map[u32]^Thread,
	scale:   f64,
}

// A scope's numbers, as the JSON carries them (milliseconds)
ScopeStats :: struct {
	name:          string,
	count:         int,
	total_ms:      f64,
	self_ms:       f64,
	mean_ms:       f64,
	max_ms:        f64,
	total_per_frame_ms: f64,
	self_per_frame_ms:  f64,
	count_per_frame:    f64,
}

// Frame times (milliseconds)
FrameStats :: struct {
	frames:      int,
	skipped:     int,
	mean_ms:     f64,
	p50_ms:      f64,
	p95_ms:      f64,
	p99_ms:      f64,
	max_ms:      f64,
	min_ms:      f64,
	interval_p50_ms:  f64,
	interval_mean_ms: f64,
	fps:         f64,
}

// A thread's busy time
ThreadStats :: struct {
	name:     string,
	tid:      u32,
	spans:    int,
	busy_ms:  f64,
}

// What `-json` writes and `compare` reads
Report :: struct {
	trace:   string,
	// How many traces (runs) it pools
	runs:    int,
	thread:  string,
	frame:   string,
	from:    string,
	to:      string,
	frames:  FrameStats,
	scopes:  []ScopeStats,
	threads: []ThreadStats,
}

main :: proc() {
	args := os.args[1:]
	if len(args) >= 1 && args[0] == "compare" {
		os.exit(compareMain(args[1:]))
	}
	os.exit(reportMain(args))
}

// The value of `-key=value` among the arguments, or `fallback`
option :: proc(args: []string, key: string, fallback: string) -> string {
	prefix := fmt.tprintf("-%s=", key)
	for a in args do if strings.has_prefix(a, prefix) do return a[len(prefix):]
	return fallback
}

usage :: proc() -> int {
	fmt.eprintln("usage: spall_report <trace.spall> [-skip=<frames>] [-from=<mark>] [-to=<mark>] [-top=<n>] [-json=<file>] [-thread=<name>] [-frame=<scope>]")
	fmt.eprintln("       spall_report compare <before.json> <after.json> [-threshold=<percent>]")
	return 2
}

reportMain :: proc(args: []string) -> int {
	paths := make([dynamic]string, context.temp_allocator)
	for a in args do if !strings.has_prefix(a, "-") do append(&paths, a)
	if len(paths) == 0 do return usage()
	from := option(args, "from", "")
	to := option(args, "to", "")
	skip, _ := strconv.parse_int(option(args, "skip", "30" if from == "" else "0"))
	top, _ := strconv.parse_int(option(args, "top", "40"))
	threadName := option(args, "thread", "main")
	frameName := option(args, "frame", "frame")
	jsonPath := option(args, "json", "")

	traces := make([dynamic]^Trace, context.temp_allocator)
	for path in paths {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintfln("spall_report: can't read %s: %v", path, err)
			return 1
		}
		trace := new(Trace)
		ok: bool
		trace^, ok = parseTrace(data)
		if !ok do return 1
		delete(data)
		append(&traces, trace)
	}

	report, found := makeReport(traces[:], strings.join(paths[:], " "), threadName, frameName, skip, from, to)
	if !found do return 1
	printReport(report, top)
	if jsonPath != "" {
		out, merr := json.marshal(report, {pretty = true, use_spaces = true, spaces = 2})
		if merr != nil || os.write_entire_file(jsonPath, out) != nil {
			fmt.eprintfln("spall_report: can't write %s", jsonPath)
			return 1
		}
		fmt.printfln("\nJSON: %s", jsonPath)
	}
	return 0
}

// Reads the file's buffers into threads of finished spans
parseTrace :: proc(data: []u8) -> (trace: Trace, ok: bool) {
	// Stream header: magic, version, timestamp scale, reserved
	if len(data) < 32 || readU64(data, 0) != SPALL_MAGIC {
		fmt.eprintln("spall_report: not a Spall binary trace (no 0x0BADF00D header)")
		return
	}
	trace.scale = transmute(f64)readU64(data, 16)
	if trace.scale <= 0 do trace.scale = 1
	pos := 32
	// Buffers: size (of the events), tid, pid, first timestamp, then the events
	for pos + 20 <= len(data) {
		size := int(readU32(data, pos))
		tid := readU32(data, pos + 4)
		pos += 20
		end := min(pos + size, len(data))
		thread := threadOf(&trace, tid)
		parseEvents(&trace, thread, data[pos:end])
		pos = end
	}
	// Spans still open at the end close at their thread's last time
	for _, t in trace.threads {
		last: f64
		for s in t.spans do last = max(last, s.end)
		for len(t.stack) > 0 {
			top := pop(&t.stack)
			if top.start > last do last = top.start
			finishSpan(t, top, last)
		}
	}
	return trace, true
}

threadOf :: proc(trace: ^Trace, tid: u32) -> ^Thread {
	if t, found := trace.threads[tid]; found do return t
	t := new(Thread)
	t.tid = tid
	t.name = fmt.aprintf("thread %d", tid)
	trace.threads[tid] = t
	return t
}

nameId :: proc(trace: ^Trace, name: string) -> int {
	if id, found := trace.nameIds[name]; found do return id
	id := len(trace.names)
	owned := strings.clone(name)
	append(&trace.names, owned)
	trace.nameIds[owned] = id
	return id
}

parseEvents :: proc(trace: ^Trace, thread: ^Thread, events: []u8) {
	i := 0
	for i < len(events) {
		switch EventType(events[i]) {
		case .Begin:
			if i + 11 > len(events) do return
			ts := f64(readU64(events, i + 1)) * trace.scale
			nameLen := int(events[i + 9])
			argsLen := int(events[i + 10])
			if i + 11 + nameLen + argsLen > len(events) do return
			name := string(events[i + 11:][:nameLen])
			id := nameId(trace, name)
			nested := false
			for s in thread.stack do if s.name == id { nested = true; break }
			append(&thread.stack, Span{name = id, start = ts, depth = len(thread.stack), nested = nested})
			i += 11 + nameLen + argsLen
		case .End:
			if i + 9 > len(events) do return
			ts := f64(readU64(events, i + 1)) * trace.scale
			if len(thread.stack) > 0 do finishSpan(thread, pop(&thread.stack), ts)
			i += 9
		case .Name_Thread, .Name_Process:
			if i + 2 > len(events) do return
			nameLen := int(events[i + 1])
			if i + 2 + nameLen > len(events) do return
			if EventType(events[i]) == .Name_Thread do thread.name = strings.clone(string(events[i + 2:][:nameLen]))
			i += 2 + nameLen
		case .Pad_Skip:
			if i + 5 > len(events) do return
			i += 5 + int(readU32(events, i + 1))
		case .Instant, .Invalid:
			// Not written by core:prof/spall; nothing after it can be read
			return
		case:
			return
		}
	}
}

finishSpan :: proc(thread: ^Thread, span: Span, end: f64) {
	s := span
	s.end = max(end, s.start)
	if len(thread.stack) > 0 do thread.stack[len(thread.stack) - 1].child += s.end - s.start
	append(&thread.spans, s)
}

// One report over several traces (runs of one scenario): their frames, spans and threads pooled
makeReport :: proc(traces: []^Trace, path, threadName, frameName: string, skip: int, from, to: string) -> (report: Report, ok: bool) {
	report.trace = path
	report.thread = threadName
	report.frame = frameName
	report.from = from
	report.to = to
	report.runs = len(traces)

	durations := make([dynamic]f64, context.temp_allocator)
	intervals := make([dynamic]f64, context.temp_allocator)
	stats := make(map[string]ScopeStats, context.temp_allocator)
	byName := make(map[string]ThreadStats, context.temp_allocator)
	frameCount := 0

	for trace in traces {
		thread: ^Thread
		for _, t in trace.threads do if t.name == threadName do thread = t
		if thread == nil {
			names := make([dynamic]string, context.temp_allocator)
			for _, t in trace.threads do append(&names, t.name)
			fmt.eprintfln("spall_report: no thread named %q (threads: %v)", threadName, names[:])
			return
		}
		frameId, hasFrames := trace.nameIds[frameName]

		// The window between marks (all of the trace without them)
		windowStart, windowEnd := math.inf_f64(-1), math.inf_f64(1)
		if from != "" {
			start, found := markTime(trace, thread, fmt.tprintf("mark:%s", from), windowStart)
			if !found {
				fmt.eprintfln("spall_report: no mark %q on thread %q", from, threadName)
				return
			}
			windowStart = start
		}
		if to != "" {
			end, found := markTime(trace, thread, fmt.tprintf("mark:%s", to), windowStart)
			if !found {
				fmt.eprintfln("spall_report: no mark %q after %q on thread %q", to, from, threadName)
				return
			}
			windowEnd = end
		}

		// The frames in the window, in time order, and where counting starts
		frames := make([dynamic]Span, context.temp_allocator)
		if hasFrames do for s in thread.spans do if s.name == frameId && !s.nested && s.start >= windowStart && s.start < windowEnd do append(&frames, s)
		slice.sort_by(frames[:], proc(a, b: Span) -> bool { return a.start < b.start })
		cutoff := windowStart
		skipped := min(skip, max(len(frames) - 1, 0))
		if skipped > 0 do cutoff = frames[skipped].start
		kept := frames[skipped:]
		frameCount += len(kept)
		report.frames.skipped += skipped
		for f in kept do append(&durations, (f.end - f.start) / 1e6)
		for i in 1 ..< max(len(kept), 1) do append(&intervals, (kept[i].start - kept[i - 1].start) / 1e6)

		// Spans on the chosen thread, by name (ids differ between traces)
		for s in thread.spans {
			if s.start < cutoff || s.start >= windowEnd do continue
			name := trace.names[s.name]
			st := stats[name]
			st.name = name
			st.count += 1
			d := (s.end - s.start) / 1e6
			if !s.nested do st.total_ms += d
			st.self_ms += (s.end - s.start - s.child) / 1e6
			st.max_ms = max(st.max_ms, d)
			stats[name] = st
		}

		// Other threads: their top-level spans' time; threads of one name (each cmd_thread
		// job is a thread) count together
		for _, t in trace.threads {
			ts := byName[t.name]
			ts.name = t.name
			ts.tid = t.tid
			for s in t.spans do if s.depth == 0 && s.start >= cutoff && s.start < windowEnd {
				ts.spans += 1
				ts.busy_ms += (s.end - s.start) / 1e6
			}
			byName[t.name] = ts
		}
	}

	{
		fs := &report.frames
		fs.frames = frameCount
		if len(durations) > 0 {
			slice.sort(durations[:])
			fs.mean_ms = mean(durations[:])
			fs.p50_ms = percentile(durations[:], 50)
			fs.p95_ms = percentile(durations[:], 95)
			fs.p99_ms = percentile(durations[:], 99)
			fs.max_ms = durations[len(durations) - 1]
			fs.min_ms = durations[0]
		}
		if len(intervals) > 0 {
			slice.sort(intervals[:])
			fs.interval_mean_ms = mean(intervals[:])
			fs.interval_p50_ms = percentile(intervals[:], 50)
			if fs.interval_mean_ms > 0 do fs.fps = 1000 / fs.interval_mean_ms
		}
	}

	perFrame := f64(max(frameCount, 1))
	scopes := make([dynamic]ScopeStats, 0, len(stats))
	for _, st in stats {
		sc := st
		sc.mean_ms = sc.total_ms / f64(max(sc.count, 1))
		sc.total_per_frame_ms = sc.total_ms / perFrame
		sc.self_per_frame_ms = sc.self_ms / perFrame
		sc.count_per_frame = f64(sc.count) / perFrame
		append(&scopes, sc)
	}
	slice.sort_by(scopes[:], proc(a, b: ScopeStats) -> bool { return a.self_ms > b.self_ms })
	report.scopes = scopes[:]

	threads := make([dynamic]ThreadStats)
	for _, ts in byName do append(&threads, ts)
	slice.sort_by(threads[:], proc(a, b: ThreadStats) -> bool { return a.busy_ms > b.busy_ms })
	report.threads = threads[:]
	return report, true
}

printReport :: proc(r: Report, top: int) {
	f := r.frames
	fmt.printfln("Trace %s, thread %q", r.trace, r.thread)
	if r.runs > 1 do fmt.printfln("%d runs pooled: their frames and spans counted together", r.runs)
	if r.from != "" do fmt.printfln("Window: from mark %q to %q", r.from, r.to if r.to != "" else "the end")
	if f.frames == 0 {
		fmt.printfln("No %q spans: totals below are for the whole trace.", r.frame)
	} else {
		fmt.printfln("Frames (%q): %d counted, %d skipped as warm-up", r.frame, f.frames, f.skipped)
		fmt.printfln("  work   median %.3f ms  mean %.3f  p95 %.3f  p99 %.3f  max %.3f  min %.3f",
			f.p50_ms, f.mean_ms, f.p95_ms, f.p99_ms, f.max_ms, f.min_ms)
		fmt.printfln("  start to start  median %.3f ms  mean %.3f  (%.1f fps)", f.interval_p50_ms, f.interval_mean_ms, f.fps)
	}
	fmt.println()
	fmt.printfln("%-44s %9s %10s %10s %9s %9s %9s", "scope (by self time)", "count/fr", "self/fr ms", "total/fr", "mean ms", "max ms", "self %")
	selfSum: f64
	for s in r.scopes do selfSum += s.self_ms
	for s, i in r.scopes {
		if i >= top do break
		name := s.name
		if len(name) > 44 do name = name[:44]
		fmt.printfln("%-44s %9s %10s %10s %9s %9s %8s%%", name, num(s.count_per_frame, 1), num(s.self_per_frame_ms, 4),
			num(s.total_per_frame_ms, 4), num(s.mean_ms, 4), num(s.max_ms, 3), num(100 * s.self_ms / max(selfSum, 1e-9), 1))
	}
	if len(r.scopes) > top do fmt.printfln("... %d more (-top=%d)", len(r.scopes) - top, len(r.scopes))
	fmt.println()
	fmt.println("Threads (top-level spans' time after warm-up):")
	for t in r.threads do fmt.printfln("  %-24s %8s spans %10s ms", t.name, fmt.tprint(t.spans), num(t.busy_ms, 2))
}

compareMain :: proc(args: []string) -> int {
	paths := make([dynamic]string, context.temp_allocator)
	for a in args do if !strings.has_prefix(a, "-") do append(&paths, a)
	if len(paths) != 2 do return usage()
	threshold, _ := strconv.parse_f64(option(args, "threshold", "5"))
	before, okA := readReport(paths[0])
	after, okB := readReport(paths[1])
	if !okA || !okB do return 1

	change :: proc(a, b: f64) -> f64 { return a > 0 ? 100 * (b - a) / a : 0 }
	fmt.printfln("Before %s\nAfter  %s\n", before.trace, after.trace)
	rows := [?]struct{ name: string, a, b: f64 }{
		{"median", before.frames.p50_ms, after.frames.p50_ms},
		{"mean", before.frames.mean_ms, after.frames.mean_ms},
		{"p95", before.frames.p95_ms, after.frames.p95_ms},
		{"p99", before.frames.p99_ms, after.frames.p99_ms},
		{"max", before.frames.max_ms, after.frames.max_ms},
		{"start to start", before.frames.interval_mean_ms, after.frames.interval_mean_ms},
	}
	fmt.printfln("%-16s %10s %10s %9s", "frame (ms)", "before", "after", "change")
	for r in rows do fmt.printfln("%-16s %10s %10s %8s%%", r.name, num(r.a, 3), num(r.b, 3), signed(change(r.a, r.b), 1))

	// Scopes by how much their time per frame changed, largest first
	Delta :: struct { name: string, a, b, callA, callB: f64 }
	deltas := make([dynamic]Delta, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for s in before.scopes {
		d := Delta{name = s.name, a = s.self_per_frame_ms, callA = s.mean_ms}
		for t in after.scopes do if t.name == s.name { d.b = t.self_per_frame_ms; d.callB = t.mean_ms; break }
		append(&deltas, d)
		seen[s.name] = true
	}
	for t in after.scopes do if !seen[t.name] do append(&deltas, Delta{name = t.name, b = t.self_per_frame_ms, callB = t.mean_ms})
	slice.sort_by(deltas[:], proc(x, y: Delta) -> bool { return abs(x.b - x.a) > abs(y.b - y.a) })
	fmt.printfln("\n%-40s %10s %10s %10s %12s %12s", "scope (self ms per frame; ms per call)", "before", "after", "change", "call before", "call after")
	for d, i in deltas {
		if i >= 25 do break
		fmt.printfln("%-40s %10s %10s %10s %12s %12s", d.name, num(d.a, 4), num(d.b, 4), signed(d.b - d.a, 4), num(d.callA, 4), num(d.callB, 4))
	}

	// The gate is the mean: an editor's frames are often of two kinds (with and without a
	// render on a timer, like its viewport's), and the median jumps between them
	if change(before.frames.mean_ms, after.frames.mean_ms) > threshold {
		fmt.printfln("\nSlower: the mean frame grew by more than %.1f%%", threshold)
		return 1
	}
	fmt.printfln("\nNot slower than %.1f%% (the mean frame)", threshold)
	return 0
}

readReport :: proc(path: string) -> (r: Report, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("spall_report: can't read %s", path)
		return
	}
	if json.unmarshal(data, &r) != nil {
		fmt.eprintfln("spall_report: %s isn't a report's JSON", path)
		return
	}
	return r, true
}

// When the first span of that name on the thread starts, at or after `after`
markTime :: proc(trace: ^Trace, thread: ^Thread, name: string, after: f64) -> (f64, bool) {
	id, found := trace.nameIds[name]
	if !found do return 0, false
	best := math.inf_f64(1)
	for s in thread.spans do if s.name == id && s.start >= after && s.start < best do best = s.start
	return best, best < math.inf_f64(1)
}

// A number as text with that many decimals (Odin's fmt pads float widths with zeros)
num :: proc(x: f64, decimals: int) -> string {
	return fmt.tprintf("%.*f", decimals, x)
}

// The same with its sign
signed :: proc(x: f64, decimals: int) -> string {
	return fmt.tprintf("%s%.*f", x >= 0 ? "+" : "", decimals, x)
}

readU64 :: proc(b: []u8, at: int) -> u64 {
	v: u64
	for k in 0 ..< 8 do v |= u64(b[at + k]) << (8 * uint(k))
	return v
}

readU32 :: proc(b: []u8, at: int) -> u32 {
	v: u32
	for k in 0 ..< 4 do v |= u32(b[at + k]) << (8 * uint(k))
	return v
}

mean :: proc(xs: []f64) -> f64 {
	sum: f64
	for x in xs do sum += x
	return sum / f64(max(len(xs), 1))
}

// The p-th percentile of sorted values (nearest rank)
percentile :: proc(sorted: []f64, p: f64) -> f64 {
	if len(sorted) == 0 do return 0
	rank := int(math.ceil(p / 100 * f64(len(sorted)))) - 1
	return sorted[clamp(rank, 0, len(sorted) - 1)]
}
