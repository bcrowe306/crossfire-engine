#+build !js
package crossfire

// Used only off Windows (the test has nothing to run there): required, so -vet-unused accepts them
@(require) import "core:mem"
@(require) import "core:os"
@(require) import "core:sync"
import "core:testing"
@(require) import "core:thread"

// How many programs run at once, and how many times each, in process_exec_keeps_quick_output
@(private="file")
PROCESS_TEST_THREADS :: 8
@(private="file")
PROCESS_TEST_RUNS :: 600

@(private="file")
ProcessTestCounts :: struct {
	runs, lostOut, lostErr, badExit, failed: int,
}

/*
Process_Exec gets everything a program prints when it prints and exits at once, the case
os.process_exec loses (process_exec.odin; docs/upstream/odin_process_exec.md): eight threads
running `sh -c` 600 times each (more threads than CPUs made the loss rarer, not likelier).
os.process_exec lost a stream in about one run of 3000 like this: with it, this test failed in 5
of 10 runs. The race needs the parent busy polling: a loss here is real, a pass proves little.
*/
@(test)
process_exec_keeps_quick_output :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// No sh on Windows: the race is Linux's pipe poll anyway
		return
	} else {
		counts: ProcessTestCounts
		lock: sync.Mutex
		Work :: struct {
			counts: ^ProcessTestCounts,
			lock:   ^sync.Mutex,
		}
		work := Work{&counts, &lock}
		threads: [PROCESS_TEST_THREADS]^thread.Thread
		for &th in threads {
			th = thread.create_and_start_with_poly_data(&work, proc(work: ^Work) {
				// Each thread has its own memory: the test's allocators aren't shared across threads
				buffer := make([]byte, 256 * 1024, os.heap_allocator())
				defer delete(buffer, os.heap_allocator())
				arena: mem.Arena
				mem.arena_init(&arena, buffer)
				context.allocator = mem.arena_allocator(&arena)
				context.temp_allocator = context.allocator
				mine: ProcessTestCounts
				for _ in 0 ..< PROCESS_TEST_RUNS {
					state, stdout, stderr, err := Process_Exec({command = {"sh", "-c", "printf out; printf err >&2; exit 3"}}, context.allocator)
					mine.runs += 1
					if err != nil do mine.failed += 1
					else {
						if string(stdout) != "out" do mine.lostOut += 1
						if string(stderr) != "err" do mine.lostErr += 1
						if !state.exited || state.exit_code != 3 do mine.badExit += 1
					}
					free_all(context.allocator)
				}
				sync.guard(work.lock)
				work.counts.runs += mine.runs
				work.counts.lostOut += mine.lostOut
				work.counts.lostErr += mine.lostErr
				work.counts.badExit += mine.badExit
				work.counts.failed += mine.failed
			}, init_context = context)
		}
		thread.join_multiple(..threads[:])
		for th in threads do thread.destroy(th)
		testing.expect_value(t, counts.runs, PROCESS_TEST_THREADS * PROCESS_TEST_RUNS)
		testing.expectf(t, counts.failed == 0, "%d of %d runs couldn't start sh", counts.failed, counts.runs)
		testing.expectf(t, counts.lostOut == 0 && counts.lostErr == 0, "output lost in %d runs, errors in %d, of %d", counts.lostOut, counts.lostErr, counts.runs)
		testing.expectf(t, counts.badExit == 0, "%d of %d runs didn't exit with 3", counts.badExit, counts.runs)
	}
}
