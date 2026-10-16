/*
The game player: runs a project saved by the editor.

	player <project folder>

Loads `<project folder>/project.xml`, builds every scene with the engine's project loader and
runs the start scene. The editor's Play button builds and launches this program, and exports
will ship it next to the project's files.

Exit codes: 0 after a normal quit, 1 if the project couldn't be loaded.
*/
package player

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import e ".."

// The project being played. Game.build has no user data, so it reads this
@(private="file")
project: e.ProjectData
@(private="file")
projectDir: string

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	exitCode := run()
	os.exit(exitCode)
}

@(private="file")
run :: proc() -> int {
	args := os.args
	projectDir = len(args) > 1 ? args[1] : "."
	projectFile, _ := filepath.join({projectDir, "project.xml"}, context.allocator)

	err: e.ProjectError
	project, err = e.LoadProjectFile(projectFile)
	if err != .None {
		log.errorf("Couldn't load project %s: %v", projectFile, err)
		return 1
	}
	defer e.ProjectData_Destroy(&project)
	log.infof("Playing '%s' (%d scenes, start: %s)", project.name, len(project.scenes), project.startScene)

	app := e.Application{}
	if !e.Application_Setup(&app, fmt.tprintf("%s", project.name), project.size) {
		return 1
	}
	defer e.Application_Cleanup(&app)

	game := new(e.Game)
	game.size = project.size
	game.scaleMode = project.scaleMode
	game.build = proc(game: ^e.Game) {
		if !e.Game_LoadProject(game, &project, projectDir) {
			log.warn("Some scenes failed to load")
		}
	}
	e.Application_Run(&app, game)
	log.info("Game closed")
	return 0
}
