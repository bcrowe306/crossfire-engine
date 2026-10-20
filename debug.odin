package engine

import "base:runtime"
import "core:fmt"
import sdl "vendor:sdl3"

/*
Debug drawing and the debug overlay, for finding out what a game is doing while it runs.

**Debug shapes** are lines, rectangles, circles and text in the world, queued from anywhere (an
update, a script, a collision handler) and drawn over the scene through its camera, after its
nodes and physics shapes. They last one frame unless given `seconds`, so drawing one every
frame shows something live:

Example:
	// Given: enemy: ^e.Node, facing: [2]f32, hit: e.RayHit
	// Where the enemy is looking, and what it saw
	e.Debug_Line(scene, enemy.position, enemy.position + facing * 200)
	if hit.hit do e.Debug_Circle(scene, hit.point, 6, {255, 60, 60, 255}, seconds = 0.5)

**The overlay** (`Game.debugOverlay`, or F10 in development runs: DEV_KEY_DEBUG_OVERLAY) shows
the frame rate and frame times over the last second or two, the scene, its node, body and tween
counts, and the time scale, in the top-left corner over everything.
*/

// The color debug shapes get when none is given
DEBUG_COLOR :: sdl.Color{80, 255, 120, 255}

// How many frame times the overlay's numbers cover
DEBUG_FRAME_HISTORY :: 120

// What a debug shape is
DebugShapeKind :: enum u8 {
	// A line from `a` to `b`
	Line,
	// A rectangle: `a` the top-left corner, `b` the size
	Rect,
	// A circle: `a` the center, `b.x` the radius
	Circle,
	// Text with its top-left corner at `a`
	Text,
}

// One queued debug shape (`Debug_Line`...), in world pixels
DebugShape :: struct {
	// What it is
	kind: DebugShapeKind,
	// Rect, Circle: filled, or only the outline
	filled: bool,
	// Its color
	color: sdl.Color,
	// Line: from `a` to `b`; Rect: `a` the top-left corner, `b` the size; Circle: `a` the center,
	// `b.x` the radius; Text: `a` the top-left corner
	a, b: [2]f32,
	// Text: the text (owned, on the heap)
	text: string,
	// Seconds it has left; it goes at the first update after this reaches 0
	remaining: f32,
}

// The frame times the debug overlay shows (Game_Update records them, in real time)
FrameStats :: struct {
	// Seconds per frame, a ring of the last DEBUG_FRAME_HISTORY
	times: [DEBUG_FRAME_HISTORY]f32,
	// Where the next one goes, and how many there are (up to DEBUG_FRAME_HISTORY)
	next, count: int,
}

/*
Queues a line in the world, drawn over the scene.

Inputs:
- scene: The scene to draw it over
- from: Start, in world pixels
- to: End, in world pixels
- color: Its color
- seconds: How long it stays (0: this frame)

Example:
	e.Debug_Line(scene, {0, 0}, {200, 100}, sdl.Color{255, 60, 60, 255}, seconds = 1)
*/
Debug_Line :: proc(scene: ^Scene, from, to: [2]f32, color := DEBUG_COLOR, seconds: f32 = 0) {
	queueDebug(scene, {kind = .Line, color = color, a = from, b = to, remaining = seconds})
}

/*
Queues a rectangle in the world, drawn over the scene.

Inputs:
- scene: The scene to draw it over
- rect: World pixels (x, y the top-left corner)
- color: Its color
- filled: Filled, or only its outline
- seconds: How long it stays (0: this frame)
*/
Debug_Rect :: proc(scene: ^Scene, rect: sdl.FRect, color := DEBUG_COLOR, filled := false, seconds: f32 = 0) {
	queueDebug(scene, {kind = .Rect, filled = filled, color = color, a = {rect.x, rect.y}, b = {rect.w, rect.h}, remaining = seconds})
}

/*
Queues a circle in the world, drawn over the scene.

Inputs:
- scene: The scene to draw it over
- center: World pixels
- radius: World pixels
- color: Its color
- filled: Filled, or only its outline
- seconds: How long it stays (0: this frame)
*/
Debug_Circle :: proc(scene: ^Scene, center: [2]f32, radius: f32, color := DEBUG_COLOR, filled := false, seconds: f32 = 0) {
	queueDebug(scene, {kind = .Circle, filled = filled, color = color, a = center, b = {radius, 0}, remaining = seconds})
}

/*
Queues text in the world (the default font, 14 px at zoom 1), drawn over the scene.

Inputs:
- scene: The scene to draw it over
- position: The text's top-left corner, world pixels
- text: What it says (copied)
- color: Its color
- seconds: How long it stays (0: this frame)

Example:
	// Given: enemy: ^e.Node, health: int
	e.Debug_Text(scene, enemy.position + {0, -40}, fmt.tprintf("hp %d", health))
*/
Debug_Text :: proc(scene: ^Scene, position: [2]f32, text: string, color := DEBUG_COLOR, seconds: f32 = 0) {
	queueDebug(scene, {kind = .Text, color = color, a = position, text = text, remaining = seconds})
}

/*
Removes every debug shape a scene has queued, lasting ones too.

Inputs:
- scene: The scene
*/
Debug_Clear :: proc(scene: ^Scene) {
	for shape in scene.debugShapes do delete(shape.text, runtime.heap_allocator())
	clear(&scene.debugShapes)
}

/*
The frame rate and frame times over the frames the game recorded (up to DEBUG_FRAME_HISTORY), in
real time (not scaled by the time scale).

Inputs:
- game: The game

Returns:
- fps: Frames per second, from the average frame time (0 before the first frame)
- average: The average frame time, milliseconds
- worst: The longest frame, milliseconds

Example:
	fps, average, worst := e.Game_GetFrameStats(game)
	log.infof("%.0f fps, %.1f ms (worst %.1f)", fps, average, worst)
*/
Game_GetFrameStats :: proc(game: ^Game) -> (fps, average, worst: f32) {
	stats := &game.frameStats
	if stats.count == 0 do return
	total: f32 = 0
	for time in stats.times[:stats.count] {
		total += time
		worst = max(worst, time)
	}
	averageSeconds := total / f32(stats.count)
	if averageSeconds > 0 do fps = 1 / averageSeconds
	return fps, averageSeconds * 1000, worst * 1000
}

// INTERNAL

@(private="file")
queueDebug :: proc(scene: ^Scene, shape: DebugShape) {
	if scene == nil do return
	shape := shape
	// The heap, like tweens: shapes come and go every frame
	if shape.text != "" do shape.text = fmt.aprint(shape.text, allocator = runtime.heap_allocator())
	if scene.debugShapes == nil do scene.debugShapes = make([dynamic]DebugShape, runtime.heap_allocator())
	append(&scene.debugShapes, shape)
}

// At the start of Scene_Update: shapes whose time is up go, the others count down
@(private)
debugExpire :: proc(scene: ^Scene, deltaTime: f64) {
	kept := 0
	for shape in scene.debugShapes {
		if shape.remaining <= 0 {
			delete(shape.text, runtime.heap_allocator())
			continue
		}
		scene.debugShapes[kept] = shape
		scene.debugShapes[kept].remaining -= f32(deltaTime)
		kept += 1
	}
	resize(&scene.debugShapes, kept)
}

// Draws the queued shapes through the scene's view (Scene_DrawWithView, last)
@(private)
debugDrawShapes :: proc(scene: ^Scene, renderer: ^sdl.Renderer, view: Transform2D) {
	if renderer == nil do return
	SetDrawState(view)
	defer SetDrawState(TRANSFORM2D_IDENTITY)
	for shape in scene.debugShapes {
		switch shape.kind {
		case .Line:
			DrawLine(renderer, sdl.FPoint(shape.a), sdl.FPoint(shape.b), shape.color)
		case .Rect:
			rect := sdl.FRect{shape.a.x, shape.a.y, shape.b.x, shape.b.y}
			if shape.filled do DrawRectangle(renderer, &rect, shape.color)
			else do DrawRectangleOutline(renderer, &rect, shape.color)
		case .Circle:
			if shape.filled do DrawCircle(renderer, sdl.FPoint(shape.a), shape.b.x, shape.color)
			else do DrawCircleOutline(renderer, sdl.FPoint(shape.a), shape.b.x, shape.color)
		case .Text:
			if scene.game != nil do DrawText(&scene.game.resourceManager, sdl.FPoint(shape.a), shape.text, DEFAULT_FONT, 14, shape.color)
		}
	}
}

// Frees a scene's debug shapes (Scene_Destroy)
@(private)
debugDestroy :: proc(scene: ^Scene) {
	Debug_Clear(scene)
	delete(scene.debugShapes)
	scene.debugShapes = nil
}

// Game_Update: one more frame time, in real seconds
@(private)
recordFrameTime :: proc(game: ^Game, seconds: f64) {
	stats := &game.frameStats
	stats.times[stats.next] = f32(seconds)
	stats.next = (stats.next + 1) % DEBUG_FRAME_HISTORY
	stats.count = min(stats.count + 1, DEBUG_FRAME_HISTORY)
}

// The overlay's lines (temp allocated), for drawing and tests
@(private)
debugOverlayLines :: proc(game: ^Game) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	fps, average, worst := Game_GetFrameStats(game)
	append(&lines, fmt.tprintf("%.0f fps  %.1f ms (worst %.1f)", fps, average, worst))
	if scene := game.currentScene; scene != nil {
		bodies := scene.physics != nil ? len(scene.physics.bodies) : 0
		append(&lines, fmt.tprintf("%s%s", scene.name, scene.paused ? " (paused)" : ""))
		append(&lines, fmt.tprintf("%d nodes  %d bodies  %d tweens", len(scene.nodes), bodies, len(scene.tweens)))
	}
	if game.timeScale > 0 && game.timeScale != 1 do append(&lines, fmt.tprintf("time scale %.2f", game.timeScale))
	if game.hitStop > 0 do append(&lines, "hitstop")
	return lines[:]
}

// Game_Draw: the overlay over everything, in screen space
@(private)
drawDebugOverlay :: proc(game: ^Game) {
	renderer := game.renderer
	if renderer == nil do return
	SetDrawState(TRANSFORM2D_IDENTITY)
	lines := debugOverlayLines(game)
	LINE_HEIGHT :: 18
	panel := sdl.FRect{4, 4, 0, f32(len(lines)) * LINE_HEIGHT + 8}
	for line in lines do panel.w = max(panel.w, MeasureText(&game.resourceManager, line, DEFAULT_FONT, 14).x + 12)
	sdl.SetRenderDrawBlendMode(renderer, sdl.BLENDMODE_BLEND)
	DrawRectangle(renderer, &panel, {0, 0, 0, 170})
	for line, i in lines {
		DrawText(&game.resourceManager, {panel.x + 6, panel.y + 4 + f32(i) * LINE_HEIGHT}, line, DEFAULT_FONT, 14, {255, 255, 255, 255})
	}
}
