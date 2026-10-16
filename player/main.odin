/*
The game player for projects without scripts: runs a project saved by the editor.

	player <project folder>

Everything happens in `e.Player_Run` (player.odin), called through `e.Player_Main` so this file
also builds for the browser. A project with scripts gets its own player, which the editor
generates: the same call, with the project's scripts package imported.

Exit codes: 0 after a normal quit, 1 if the project couldn't be loaded.
*/
package player

import e ".."

main :: proc() {
	e.Player_Main()
}
