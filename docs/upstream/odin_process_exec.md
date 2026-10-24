# Draft: `os.process_exec` loses output from programs that print and exit at once

A draft of an issue for [odin-lang/Odin](https://github.com/odin-lang/Odin/issues), not filed yet.
The engine works around it with its own `Process_Exec` (`process_exec.odin`).

---

**Title:** `core:os`: `process_exec` sometimes returns empty stdout/stderr for a program that
prints and exits quickly (POLLHUP read as "no more data")

## Context

- Odin: `dev-2026-10-nightly:84bc3fc`
- OS: Linux 7.2.5 x86_64 (Arch-based), glibc 2.44
- Found when an application ran `git status` many times through `os.process_exec`: now and then
  it got empty output with exit code 0.

## Symptom

`os.process_exec` now and then returns an empty `stdout` (or `stderr`) although the program wrote
to it, and `err == nil` and the exit code are correct. It happens with short-lived programs, more
often when the machine is busy.

## Repro

```odin
// Repro: os.process_exec loses a quick program's output now and then
package main

import "core:fmt"
import "core:os"
import "core:strconv"

main :: proc() {
	runs := 5000
	if len(os.args) > 1 do runs, _ = strconv.parse_int(os.args[1])
	lostOut, lostErr := 0, 0
	for _ in 0 ..< runs {
		state, stdout, stderr, err := os.process_exec({command = {"sh", "-c", "printf out; printf err >&2"}}, context.temp_allocator)
		if err != nil || state.exit_code != 0 do fmt.panicf("couldn't run sh: %v %v", err, state)
		if string(stdout) != "out" do lostOut += 1
		if string(stderr) != "err" do lostErr += 1
		free_all(context.temp_allocator)
	}
	fmt.printfln("%d runs: stdout lost %d times, stderr lost %d times", runs, lostOut, lostErr)
}
```

`odin build . -o:speed -out:repro`, then (on an 8-CPU laptop):

| How it ran | Result |
|---|---|
| `./repro 5000`, idle machine | 0 lost in 5000 runs |
| `./repro 5000` beside 16 `yes > /dev/null` | stdout lost 3 times, stderr 4 times |
| 8 copies of `./repro 2000` at once | 13 lost in 16 000 runs (each copy lost 1-2) |

So about one run in a thousand loses a stream under load; idle, it's rare enough not to show up
in 5000 runs.

## Cause

`process_exec` (core/os/process.odin) loops over both pipes calling `pipe_has_data` and only reads
when it returns true; when it returns `.Broken_Pipe` the stream is marked done without reading:

```odin
has_data, err = pipe_has_data(stdout_r)
if has_data {
	n, err = read(stdout_r, buf[:])
}
switch err {
case nil:
	_, err = append(&stdout_b, ..buf[:n])
case .EOF, .Broken_Pipe:
	stdout_done = true      // <- data still in the pipe is never read
	err = nil
}
```

`_pipe_has_data` (core/os/pipe_linux.odin, the same in pipe_posix.odin) polls with timeout 0 and
returns `false, .Broken_Pipe` when `revents` has `HUP` without `IN`.

Linux's `pipe_poll` (fs/pipe.c) computes the two bits one after the other, without the pipe's
lock (its comment calls them "the racy tests"): it reads the pipe's head and tail (`IN` if not
empty), then `pipe->writers` (`HUP` if zero). When the child writes and exits (closing the last
write end) between those two reads, `poll` reports `HUP` alone although the pipe holds the data.
A blocking `poll` would be woken again and see `IN`; with timeout 0 the snapshot is all there is,
and `process_exec` takes it as the end.

More generally, `POLLHUP` only says there are no writers; it never says the pipe is empty (POSIX
lets both be set, and data can be left behind a hang-up). A reader has to read until `read`
returns 0.

A second, smaller issue: the loop never waits. With timeout 0 and no data it spins at 100% of a
CPU for as long as the child runs (which also makes the race more likely, since it polls
constantly).

## Suggested fix

Treat a hang-up as "read until EOF", and wait in `poll` instead of spinning:

```odin
has_data, err = pipe_has_data(stdout_r)
if has_data || err == .Broken_Pipe {
	// After a hang-up, read: it returns what is left, then 0 (EOF)
	n, err = read(stdout_r, buf[:])
}
switch err {
case nil:
	_, err = append(&stdout_b, ..buf[:n])
case .EOF, .Broken_Pipe:
	stdout_done = true
	err = nil
}
```

(`read` on a pipe with no writers and no data returns 0, which `_read` turns into `.EOF`.) And
either `poll` both read ends together with a timeout (-1 or some milliseconds), or sleep briefly
when neither had anything. The Crossfire Engine's `Process_Exec` does the first part and sleeps a
millisecond when nothing was read; with it, a test running the program above 4800 times on eight
threads at once never loses output, where `os.process_exec` lost a stream in 5 of 10 runs of the test (1-2 runs of 4800 each time).
