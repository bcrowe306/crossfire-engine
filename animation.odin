package engine

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
	name: string,
	// First source frame played, inclusive
	startFrame: int,
	// Last source frame played, inclusive
	endFrame: int,
	// Frames per second. 0 or less holds the current frame
	fps: f32,
	// Restart after the last frame instead of ending
	loop: bool,
	playMode: AnimationPlayMode,

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
Frees an animation created by one of the Create* procedures. Animations added to an
AnimationPlayer are freed by `AnimationPlayer_Destroy`; don't free them yourself.

Inputs:
- animation: The animation to free
*/
Animation_Destroy :: proc(animation: ^Animation) {
	if animation == nil do return
	allocator := animation.allocator
	if animation.destroyData != nil do animation.destroyData(animation)
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
	using animation: Animation,
	texture: ^sdl.Texture,
	columns: int,
	rows: int,
	// Pixels around the outside of the grid
	margin: f32,
	// Pixels between neighboring cells
	spacing: f32,
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

@(private="file")
spriteSheetFrameCount :: proc(animation: ^Animation) -> int {
	sheet := cast(^SpriteSheetAnimation)animation
	return sheet.columns * sheet.rows
}

@(private="file")
spriteSheetFrameSize :: proc(animation: ^Animation, frame: int) -> [2]f32 {
	sheet := cast(^SpriteSheetAnimation)animation
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
	using animation: Animation,
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
- fps, loop, startFrame, endFrame, playMode, allocator: As for `CreateFrameAnimation`

Returns:
- The new animation

Example:
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
