package crossfire

import "core:log"
import "core:mem"
import "core:strings"
import sdl "vendor:sdl3"

/*
How an animation steps through its frames.
*/
AnimationPlayMode :: enum {
	// startFrame -> endFrame
	Forward,
	// endFrame -> startFrame
	Reverse,
	// startFrame -> endFrame -> startFrame. One full there-and-back counts as one loop
	PingPong,
	// endFrame -> startFrame -> endFrame (Aseprite's "Ping-pong Reverse")
	PingPongReverse,
}

/*
Base type of every animation. Specific animation types embed it with `using`:

	MyAnimation :: struct {
		using animation: Animation,
		... // the frames' source data
	}

and fill in the procedure fields, which is how the AnimationPlayer draws any animation type
without knowing what it is. Use the Create* procedures rather than building one by hand.

Frames are numbered by the animation's source (sprite sheet cell or texture index).
`startFrame..endFrame` (both inclusive) selects which of them this animation plays, so one
sprite sheet can hold several animations.
*/
Animation :: struct {
	// Name the AnimationPlayer plays it by (owned, allocated with `allocator`)
	name: string,
	// First source frame played, inclusive
	startFrame: int,
	// Last source frame played, inclusive
	endFrame: int,
	// Frames per second. 0 or less holds the current frame
	fps: f32,
	// Restart after the last frame instead of ending
	loop: bool,
	// Times it plays before it ends, when it doesn't loop (0 or 1: once; Aseprite's tag repeats).
	// A ping-pong's are passes, one way each, as Aseprite counts them (0: two, there and back;
	// an odd number stops on the far end)
	repeat: int,
	// How it steps through its frames
	playMode: AnimationPlayMode,
	// Seconds each frame shows (relative frames: 0 is startFrame), overriding `fps` for the frames
	// it covers (Aseprite frames each have their own duration). Owned, with `allocator`
	durations: []f32,
	// Each frame's events, comma-separated ("" for none), sent by its player's `onFrameEvent` when
	// the frame shows (relative frames; owned, with `allocator`)
	events: []string,
	// The Aseprite file its frames come from (its full path, owned with `allocator`; "" when they
	// don't): a sprite showing it takes its slices and pivots from that file
	source: string,
	// Its frames are the source file's frames (an Aseprite sheet of every frame), so slices follow
	// the frame playing; false: the file's first frame cut into cells
	sourceFrames: bool,

	// Number of frames this animation plays: endFrame - startFrame + 1
	totalFrames: proc(animation: ^Animation) -> int,
	// Number of frames available in the source (sheet cells, textures)
	sourceFrameCount: proc(animation: ^Animation) -> int,
	// Native pixel size of a source frame
	frameSize: proc(animation: ^Animation, frame: int) -> [2]f32,
	// Draws a source frame into dest (world coordinates, camera aware)
	drawFrame: proc(animation: ^Animation, renderer: ^sdl.Renderer, frame: int, dest: sdl.FRect, rotation: f32, tint: sdl.Color, flip: sdl.FlipMode),

	// Allocator the animation and its data were created with; used to free them
	allocator: mem.Allocator,
	// Frees subtype data. Called by Animation_Destroy
	destroyData: proc(animation: ^Animation),
}

/*
Number of frames an animation plays.

Inputs:
- animation: Any animation

Returns:
- endFrame - startFrame + 1
*/
Animation_TotalFrames :: proc(animation: ^Animation) -> int {
	return animation.endFrame - animation.startFrame + 1
}

/*
How long a frame of an animation shows: its duration when the animation has one for it, else
1 / fps.

Inputs:
- animation: Any animation
- frame: A frame relative to its startFrame

Returns:
- Seconds (0: it holds, for an fps of 0 or less without a duration)
*/
Animation_FrameDuration :: proc(animation: ^Animation, frame: int) -> f32 {
	if frame >= 0 && frame < len(animation.durations) && animation.durations[frame] > 0 do return animation.durations[frame]
	return animation.fps > 0 ? 1 / animation.fps : 0
}

/*
Sets how long each frame shows, overriding fps for those frames.

Inputs:
- animation: Any animation
- durations: Seconds per frame, relative to its startFrame (copied; empty: back to fps)

Example:
	// Given: animation: ^e.Animation
	e.Animation_SetDurations(animation, {0.1, 0.1, 0.3})
*/
Animation_SetDurations :: proc(animation: ^Animation, durations: []f32) {
	delete(animation.durations, animation.allocator)
	animation.durations = nil
	if len(durations) > 0 {
		animation.durations = make([]f32, len(durations), animation.allocator)
		copy(animation.durations, durations)
	}
}

/*
Sets each frame's events, which the player sends with `onFrameEvent` as the frame shows.

Inputs:
- animation: Any animation
- events: Per frame (relative to its startFrame), comma-separated names ("" for none); copied

Example:
	// Given: animation: ^e.Animation
	e.Animation_SetEvents(animation, {"", "step", "", "step,dust"})
*/
Animation_SetEvents :: proc(animation: ^Animation, events: []string) {
	for event in animation.events do delete(event, animation.allocator)
	delete(animation.events, animation.allocator)
	animation.events = nil
	if len(events) == 0 do return
	animation.events = make([]string, len(events), animation.allocator)
	for event, i in events do animation.events[i] = strings.clone(event, animation.allocator)
}

/*
Frees an animation created by one of the Create* procedures. Animations added to an
AnimationPlayer are freed by `AnimationPlayer_Destroy`; don't free them yourself.

Inputs:
- animation: The animation to free
*/
Animation_Destroy :: proc(animation: ^Animation) {
	if animation == nil do return
	allocator := animation.allocator
	if animation.destroyData != nil do animation.destroyData(animation)
	delete(animation.durations, allocator)
	for event in animation.events do delete(event, allocator)
	delete(animation.events, allocator)
	delete(animation.source, allocator)
	delete(animation.name, allocator)
	free(animation, allocator)
}


// SPRITE SHEET

/*
An animation whose frames are cells of one texture, laid out on a grid.

Cells are numbered left to right, then top to bottom, starting at 0:

	+---+---+---+
	| 0 | 1 | 2 |
	+---+---+---+
	| 3 | 4 | 5 |
	+---+---+---+
*/
SpriteSheetAnimation :: struct {
	// The animation part: name, frame range, fps, procedures
	using animation: Animation,
	// The sprite sheet (not owned: the resource manager's, usually)
	texture: ^sdl.Texture,
	// Number of cells across
	columns: int,
	// Number of cells down
	rows: int,
	// Pixels around the outside of the grid
	margin: f32,
	// Pixels between neighboring cells
	spacing: f32,
	// Each cell's size in pixels (0: the sheet divided into columns x rows; set by
	// `CreateSheetAnimation` for a grid of cell sizes)
	cellSize: [2]f32,
}

/*
Creates an animation from a sprite sheet (texture atlas) divided into a grid.

Inputs:
- name: Name used to play the animation from an AnimationPlayer
- texture: The sprite sheet
- columns: Number of cells across
- rows: Number of cells down
- fps: Frames per second
- loop: Restart after the last frame instead of ending
- startFrame: First cell played, inclusive
- endFrame: Last cell played, inclusive. -1 means the last cell of the sheet
- playMode: Forward, Reverse or PingPong
- margin: Pixels around the outside of the grid
- spacing: Pixels between neighboring cells
- allocator: Allocator for the animation. Use the owning node's (`Node_GetAllocator`) to free it with the node

Returns:
- The new animation. Add it to a player with `AnimationPlayer_Add`

Example:
	// A 4x2 sheet: walk is the top row, jump the bottom row
	rm := &game.resourceManager
	sheet := rm->loadTexture("hero.png")
	walk := e.CreateSpriteSheetAnimation("walk", sheet, 4, 2, fps = 10, loop = true, startFrame = 0, endFrame = 3)
	jump := e.CreateSpriteSheetAnimation("jump", sheet, 4, 2, fps = 12, startFrame = 4, endFrame = 7)
*/
CreateSpriteSheetAnimation :: proc(
	name: string,
	texture: ^sdl.Texture,
	columns, rows: int,
	fps: f32,
	loop := false,
	startFrame := 0,
	endFrame := -1,
	playMode := AnimationPlayMode.Forward,
	margin: f32 = 0,
	spacing: f32 = 0,
	allocator := context.allocator,
) -> ^SpriteSheetAnimation {
	animation := new(SpriteSheetAnimation, allocator)
	animation.texture = texture
	animation.columns = max(columns, 1)
	animation.rows = max(rows, 1)
	animation.margin = margin
	animation.spacing = spacing
	animation.sourceFrameCount = spriteSheetFrameCount
	animation.frameSize = spriteSheetFrameSize
	animation.drawFrame = spriteSheetDrawFrame
	initAnimation(animation, name, fps, loop, startFrame, endFrame, playMode, allocator)
	return animation
}

/*
Creates an animation from a sprite sheet cut by a `SheetGrid`: columns x rows, or cells of a size
in pixels (the columns and rows that fit the texture).

Inputs:
- name: Name used to play the animation from an AnimationPlayer
- texture: The sprite sheet
- grid: How the sheet is cut into cells
- fps: Frames per second
- loop: Restart after the last frame instead of ending
- startFrame: First cell played, inclusive
- endFrame: Last cell played, inclusive. -1 means the last cell of the sheet
- playMode: Forward, Reverse, PingPong or PingPongReverse
- allocator: Allocator for the animation. Use the owning node's (`Node_GetAllocator`) to free it with the node

Returns:
- The new animation. Add it to a player with `AnimationPlayer_Add`

Example:
	// 32 x 32 px cells, however many fit the sheet
	rm := &game.resourceManager
	sheet := rm->loadTexture("hero_run.png")
	run := e.CreateSheetAnimation("run", sheet, {mode = .Size, cellSize = {32, 32}}, fps = 12, loop = true)
*/
CreateSheetAnimation :: proc(
	name: string,
	texture: ^sdl.Texture,
	grid: SheetGrid,
	fps: f32,
	loop := false,
	startFrame := 0,
	endFrame := -1,
	playMode := AnimationPlayMode.Forward,
	allocator := context.allocator,
) -> ^SpriteSheetAnimation {
	size := texture != nil ? [2]f32{f32(texture.w), f32(texture.h)} : {}
	columns, rows, cell := SheetGrid_Layout(grid, size)
	animation := new(SpriteSheetAnimation, allocator)
	animation.texture = texture
	animation.columns = columns
	animation.rows = rows
	animation.margin = grid.margin
	animation.spacing = grid.spacing
	if grid.mode == .Size do animation.cellSize = cell
	animation.sourceFrameCount = spriteSheetFrameCount
	animation.frameSize = spriteSheetFrameSize
	animation.drawFrame = spriteSheetDrawFrame
	initAnimation(animation, name, fps, loop, startFrame, endFrame, playMode, allocator)
	return animation
}

/*
How a sprite sheet is cut into cells.
*/
SheetGridMode :: enum {
	// A number of columns and rows: the cells share the sheet (less its margin and gaps) evenly
	Cells,
	// Cells of a size in pixels: as many columns and rows as fit the sheet
	Size,
}

/*
How a sprite sheet is cut into cells: `columns` x `rows`, or cells of `cellSize` pixels (`mode`),
`margin` pixels around them and `spacing` between them. Cells are numbered left to right, then
top to bottom, from 0. The other mode's values are worked out from the sheet's size
(`SheetGrid_Layout`). The zero value is one cell (columns and rows below 1 count as 1).
*/
SheetGrid :: struct {
	// Which values cut the sheet: columns x rows, or the cell size
	mode: SheetGridMode,
	// Cells across and down (.Cells)
	columns, rows: int,
	// A cell's width and height in pixels (.Size)
	cellSize: [2]f32,
	// Pixels around the grid
	margin: f32,
	// Pixels between neighboring cells
	spacing: f32,
}

// One cell: the whole sheet
DEFAULT_SHEET_GRID :: SheetGrid{mode = .Cells, columns = 1, rows = 1}

/*
A grid's columns, rows and cell size on a sheet of a given size: the cells of a .Cells grid share
the sheet evenly; a .Size grid has as many columns and rows as fit (at least one each).

Inputs:
- grid: The grid
- sheetSize: The sheet's size in pixels (0 when unknown: a .Size grid is then one cell)

Returns:
- Its columns, rows (at least 1 each) and the size of a cell in pixels

Example:
	columns, rows, cell := e.SheetGrid_Layout({mode = .Size, cellSize = {16, 16}, spacing = 2}, {70, 34})
	// 4 x 2 cells of 16 x 16
*/
SheetGrid_Layout :: proc(grid: SheetGrid, sheetSize: [2]f32) -> (columns, rows: int, cell: [2]f32) {
	switch grid.mode {
	case .Cells:
		columns, rows = max(grid.columns, 1), max(grid.rows, 1)
		cells := [2]f32{f32(columns), f32(rows)}
		cell = (sheetSize - grid.margin * 2 - grid.spacing * (cells - 1)) / cells
	case .Size:
		cell = grid.cellSize
		fit :: proc(sheet, cell, margin, spacing: f32) -> int {
			if cell <= 0 || sheet <= 0 do return 1
			return max(int((sheet - margin * 2 + spacing) / (cell + spacing)), 1)
		}
		columns = fit(sheetSize.x, cell.x, grid.margin, grid.spacing)
		rows = fit(sheetSize.y, cell.y, grid.margin, grid.spacing)
	}
	return
}

/*
The pixels a grid leaves over at the right and bottom of a sheet: a .Size grid's cells that don't
fill the sheet (what's past the last whole cell and the margin). They're never drawn: frames are
all one size, and what's left over is usually padding. A .Cells grid shares the sheet evenly, so
it leaves none (but its cells may not be whole pixels).

Inputs:
- grid: The grid
- sheetSize: The sheet's size in pixels (0 when unknown: none left over)

Returns:
- The pixels left over across (x) and down (y), 0 or more

Example:
	left := e.SheetGrid_Leftover({mode = .Size, cellSize = {16, 16}}, {70, 32})
	// {6, 0}: 4 cells across use 64 of the 70 pixels
*/
SheetGrid_Leftover :: proc(grid: SheetGrid, sheetSize: [2]f32) -> [2]f32 {
	if grid.mode != .Size || sheetSize.x <= 0 || sheetSize.y <= 0 do return {}
	columns, rows, cell := SheetGrid_Layout(grid, sheetSize)
	counts := [2]f32{f32(columns), f32(rows)}
	used := grid.margin * 2 + counts * cell + (counts - 1) * grid.spacing
	return {max(sheetSize.x - used.x, 0), max(sheetSize.y - used.y, 0)}
}

/*
How many cells a grid cuts a sheet into.

Inputs:
- grid: The grid
- sheetSize: The sheet's size in pixels

Returns:
- columns x rows (at least 1)
*/
SheetGrid_CellCount :: proc(grid: SheetGrid, sheetSize: [2]f32) -> int {
	columns, rows, _ := SheetGrid_Layout(grid, sheetSize)
	return columns * rows
}

/*
A cell's rectangle in a sheet cut by a grid (editors use it for thumbnails).

Inputs:
- grid: The grid
- sheetSize: The sheet's size in pixels
- frame: The cell (left to right, top to bottom, from 0)

Returns:
- The cell's rectangle in texture pixels
*/
SheetGrid_CellRect :: proc(grid: SheetGrid, sheetSize: [2]f32, frame: int) -> sdl.FRect {
	columns, _, cell := SheetGrid_Layout(grid, sheetSize)
	column := frame % columns
	row := frame / columns
	return {grid.margin + f32(column) * (cell.x + grid.spacing), grid.margin + f32(row) * (cell.y + grid.spacing), cell.x, cell.y}
}

/*
Pixel rectangle of a cell in a sprite sheet. Useful for drawing a single cell yourself.

Inputs:
- animation: The sprite sheet animation
- frame: Cell index in the sheet

Returns:
- The cell's rectangle in texture pixels
*/
SpriteSheetAnimation_FrameRect :: proc(animation: ^SpriteSheetAnimation, frame: int) -> sdl.FRect {
	size := spriteSheetFrameSize(animation, frame)
	column := frame % animation.columns
	row := frame / animation.columns
	return {
		animation.margin + f32(column) * (size.x + animation.spacing),
		animation.margin + f32(row) * (size.y + animation.spacing),
		size.x,
		size.y,
	}
}

/*
A cell's rectangle in a sprite sheet of a given size, without an animation (editors use it for
thumbnails). Cells are numbered left to right, top to bottom.

Inputs:
- sheetSize: The texture's size in pixels
- columns: Number of cells across
- rows: Number of cells down
- margin: Pixels around the grid
- spacing: Pixels between cells
- frame: The cell

Returns:
- The cell's rectangle in texture pixels
*/
SpriteSheet_CellRect :: proc(sheetSize: [2]f32, columns, rows: int, margin, spacing: f32, frame: int) -> sdl.FRect {
	return SheetGrid_CellRect({mode = .Cells, columns = columns, rows = rows, margin = margin, spacing = spacing}, sheetSize, frame)
}

@(private="file")
spriteSheetFrameCount :: proc(animation: ^Animation) -> int {
	sheet := cast(^SpriteSheetAnimation)animation
	return sheet.columns * sheet.rows
}

@(private="file")
spriteSheetFrameSize :: proc(animation: ^Animation, frame: int) -> [2]f32 {
	sheet := cast(^SpriteSheetAnimation)animation
	if sheet.cellSize.x > 0 && sheet.cellSize.y > 0 do return sheet.cellSize
	if sheet.texture == nil do return {}
	usable := [2]f32{f32(sheet.texture.w), f32(sheet.texture.h)} - sheet.margin * 2
	cells := [2]f32{f32(sheet.columns), f32(sheet.rows)}
	return (usable - sheet.spacing * (cells - 1)) / cells
}

@(private="file")
spriteSheetDrawFrame :: proc(animation: ^Animation, renderer: ^sdl.Renderer, frame: int, dest: sdl.FRect, rotation: f32, tint: sdl.Color, flip: sdl.FlipMode) {
	sheet := cast(^SpriteSheetAnimation)animation
	DrawTexture(renderer, sheet.texture, dest, rotation, SpriteSheetAnimation_FrameRect(sheet, frame), tint, flip)
}


// FRAME (one texture per frame)

/*
An animation where every frame is a separate texture. Frames are numbered by their
position in `frames`, starting at 0.
*/
FrameAnimation :: struct {
	// The animation part: name, frame range, fps, procedures
	using animation: Animation,
	// The frame textures, in order (the slice is owned; the textures aren't)
	frames: []^sdl.Texture,
}

/*
Creates an animation from a list of textures, one per frame.

Inputs:
- name: Name used to play the animation from an AnimationPlayer
- frames: The frame textures, in order. The list is copied
- fps: Frames per second
- loop: Restart after the last frame instead of ending
- startFrame: First frame played, inclusive
- endFrame: Last frame played, inclusive. -1 means the last texture
- playMode: Forward, Reverse or PingPong
- allocator: Allocator for the animation. Use the owning node's (`Node_GetAllocator`) to free it with the node

Returns:
- The new animation. Add it to a player with `AnimationPlayer_Add`

Example:
	rm := &game.resourceManager
	blink := e.CreateFrameAnimation("blink", {rm->loadTexture("eye_open.png"), rm->loadTexture("eye_closed.png")}, fps = 4, loop = true)
*/
CreateFrameAnimation :: proc(
	name: string,
	frames: []^sdl.Texture,
	fps: f32,
	loop := false,
	startFrame := 0,
	endFrame := -1,
	playMode := AnimationPlayMode.Forward,
	allocator := context.allocator,
) -> ^FrameAnimation {
	animation := new(FrameAnimation, allocator)
	animation.frames = make([]^sdl.Texture, len(frames), allocator)
	copy(animation.frames, frames)
	animation.sourceFrameCount = frameAnimationFrameCount
	animation.frameSize = frameAnimationFrameSize
	animation.drawFrame = frameAnimationDrawFrame
	animation.destroyData = frameAnimationDestroyData
	initAnimation(animation, name, fps, loop, startFrame, endFrame, playMode, allocator)
	return animation
}

/*
Creates a FrameAnimation by loading each frame through the resource manager.

Inputs:
- rm: Resource manager to load (and cache) the textures with
- name: Name used to play the animation from an AnimationPlayer
- paths: Image file paths, one per frame, in order
- fps: Frames per second
- loop: Restart after the last frame instead of ending
- startFrame: First frame played, inclusive
- endFrame: Last frame played, inclusive. -1 means the last texture
- playMode: Forward, Reverse or PingPong
- allocator: Allocator for the animation. Use the owning node's (`Node_GetAllocator`) to free it with the node

Returns:
- The new animation

Example:
	rm := &game.resourceManager
	light := e.CreateFrameAnimationFromFiles(rm, "blink", {"light_off.png", "light_on.png"}, fps = 2, loop = true)
*/
CreateFrameAnimationFromFiles :: proc(
	rm: ^ResourceManager,
	name: string,
	paths: []string,
	fps: f32,
	loop := false,
	startFrame := 0,
	endFrame := -1,
	playMode := AnimationPlayMode.Forward,
	allocator := context.allocator,
) -> ^FrameAnimation {
	textures := make([]^sdl.Texture, len(paths), context.temp_allocator)
	for path, i in paths {
		textures[i] = rm->loadTexture(path)
	}
	return CreateFrameAnimation(name, textures, fps, loop, startFrame, endFrame, playMode, allocator)
}

@(private="file")
frameAnimationFrameCount :: proc(animation: ^Animation) -> int {
	return len((cast(^FrameAnimation)animation).frames)
}

@(private="file")
frameAnimationFrameSize :: proc(animation: ^Animation, frame: int) -> [2]f32 {
	frames := (cast(^FrameAnimation)animation).frames
	if frame < 0 || frame >= len(frames) || frames[frame] == nil do return {}
	return {f32(frames[frame].w), f32(frames[frame].h)}
}

@(private="file")
frameAnimationDrawFrame :: proc(animation: ^Animation, renderer: ^sdl.Renderer, frame: int, dest: sdl.FRect, rotation: f32, tint: sdl.Color, flip: sdl.FlipMode) {
	frames := (cast(^FrameAnimation)animation).frames
	if frame < 0 || frame >= len(frames) do return
	DrawTexture(renderer, frames[frame], dest, rotation, nil, tint, flip)
}

@(private="file")
frameAnimationDestroyData :: proc(animation: ^Animation) {
	delete((cast(^FrameAnimation)animation).frames, animation.allocator)
}


// SHARED

// Fills in the base fields once the subtype's procedures are set, validating the frame range
@(private="file")
initAnimation :: proc(animation: ^Animation, name: string, fps: f32, loop: bool, startFrame, endFrame: int, playMode: AnimationPlayMode, allocator: mem.Allocator) {
	animation.name = strings.clone(name, allocator)
	animation.fps = fps
	animation.loop = loop
	animation.playMode = playMode
	animation.allocator = allocator
	animation.totalFrames = Animation_TotalFrames

	last := max(animation->sourceFrameCount() - 1, 0)
	end := endFrame < 0 ? last : endFrame
	start := clamp(startFrame, 0, last)
	end = clamp(end, start, last)
	if start != startFrame || (endFrame >= 0 && end != endFrame) {
		log.warnf("Animation '%s': frames %d..%d don't fit the %d available, using %d..%d", name, startFrame, endFrame, last + 1, start, end)
	}
	animation.startFrame = start
	animation.endFrame = end
}
