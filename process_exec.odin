#+build !js
package crossfire

import "base:runtime"
import "core:os"
import "core:time"

/*
Running other programs (the shader tools, msdf-atlas-gen; the editor's git, odin, ffmpeg) and
reading what they printed. `os.process_exec` loses output now and then: `Process_Exec` is its
replacement, and every program the engine and the editor run goes through it. Native only.
*/

/*
Runs a program, waits for it, and gives what it printed: `os.process_exec`, without its lost
output.

`os.process_exec` stops reading a pipe when `poll` says the other end hung up and nothing is
waiting (`os.pipe_has_data` returns `.Broken_Pipe`). Linux's pipe poll reads "is there data" and
"are there writers" one after the other without a lock, so a program that writes and exits
between the two looks hung up with nothing written: its output is lost and it seems to have
printed nothing. Under load it happened about once in 1000 runs of a program that prints and
exits at once (eight at a time, or one beside busy CPUs; docs/upstream/odin_process_exec.md has
the report and a repro), and the editor's Git tab once read an empty `git status`. Here a
hang-up is followed by a read, which returns what's left and then the end. It also waits a
millisecond when neither pipe had anything, instead of spinning.

Inputs:
- desc: The program, as for `os.process_exec` (its `stdout` and `stderr` must not be set)
- allocator: For `stdout` and `stderr`

Returns:
- The program's state (check `exit_code`: Windows always sets `success`), its output and its
  errors (allocated with `allocator`, also when it failed), and whether it could run

Example:
	state, stdout, stderr, err := e.Process_Exec({command = {"git", "--version"}}, context.temp_allocator)
	if err == nil && state.exit_code == 0 {
		fmt.println(string(stdout))
	} else {
		fmt.eprintln(string(stderr), err)
	}
*/
Process_Exec :: proc(desc: os.Process_Desc, allocator: runtime.Allocator) -> (state: os.Process_State, stdout, stderr: []byte, err: os.Error) {
	assert(desc.stdout == nil && desc.stderr == nil, "Process_Exec captures stdout and stderr")
	stdoutR, stdoutW := os.pipe() or_return
	defer os.close(stdoutR)
	stderrR, stderrW, pipeErr := os.pipe()
	if pipeErr != nil {
		os.close(stdoutW)
		return state, nil, nil, pipeErr
	}
	defer os.close(stderrR)

	process: os.Process
	{
		// Our write ends close whatever happens: the reads see the end once the program's do
		defer os.close(stdoutW)
		defer os.close(stderrW)
		desc := desc
		desc.stdout = stdoutW
		desc.stderr = stderrW
		process = os.process_start(desc) or_return
	}

	out := make([dynamic]byte, allocator)
	errs := make([dynamic]byte, allocator)
	buffer: [4096]u8 = ---
	outDone, errDone := false, false
	for err == nil && (!outDone || !errDone) {
		progressed := false
		if !outDone {
			p, e := processDrain(stdoutR, &out, &outDone, buffer[:])
			progressed ||= p
			err = e
		}
		if err == nil && !errDone {
			p, e := processDrain(stderrR, &errs, &errDone, buffer[:])
			progressed ||= p
			err = e
		}
		if !progressed && err == nil do time.sleep(time.Millisecond)
	}
	stdout, stderr = out[:], errs[:]
	if err != nil {
		state, _ = os.process_wait(process, timeout = 0)
		if !state.exited {
			_ = os.process_kill(process)
			state, _ = os.process_wait(process)
		}
		return
	}
	state, err = os.process_wait(process)
	return
}

// One pipe: true when something was read (or it ended)
@(private="file")
processDrain :: proc(r: ^os.File, into: ^[dynamic]byte, done: ^bool, buffer: []u8) -> (progressed: bool, err: os.Error) {
	has, pollErr := os.pipe_has_data(r)
	if pollErr != nil && pollErr != .Broken_Pipe do return false, pollErr
	// A hang-up may still have data behind it: read until the read says it's the end
	if !has && pollErr != .Broken_Pipe do return false, nil
	n, readErr := os.read(r, buffer)
	switch readErr {
	case nil:
		if n == 0 {
			// A read of nothing after a hang-up is the end (some systems say so instead of EOF)
			if pollErr == .Broken_Pipe do done^ = true
			return pollErr == .Broken_Pipe, nil
		}
		_, appendErr := append(into, ..buffer[:n])
		if appendErr != nil do return false, appendErr
		return true, nil
	case .EOF, .Broken_Pipe:
		done^ = true
		return true, nil
	}
	return false, readErr
}
