#+build !js
package crossfire

import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

/*
Starts a game's live link (live.odin): a thread reads commands from stdin, one per line, for
`LiveLink_Process` to run. The player starts it with `--live` (the editor's Play).

Inputs:
- game: The game
*/
LiveLink_Start :: proc(game: ^Game) {
	if game.live != nil do return
	game.live = new(LiveLink)
	game.live.incoming = make([dynamic]string)
	thread.create_and_start_with_poly_data(game.live, proc(link: ^LiveLink) {
		buffer: [4096]u8
		partial := make([dynamic]u8)
		defer delete(partial)
		for {
			n, err := os.read(os.stdin, buffer[:])
			if n <= 0 || err != nil do return
			append(&partial, ..buffer[:n])
			start := 0
			for b, i in partial {
				if b != '\n' do continue
				line := strings.trim_right(string(partial[start:i]), "\r")
				sync.mutex_lock(&link.lock)
				append(&link.incoming, strings.clone(line))
				sync.mutex_unlock(&link.lock)
				start = i + 1
			}
			remove_range(&partial, 0, start)
		}
	}, self_cleanup = true)
}
