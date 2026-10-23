package crossfire

import "core:log"
import "core:strings"

/*
Animation assets: named animations, each on its own sheet, that AnimatedSprite nodes share, so one
set of animations (a hero's idle, run, jump) is made once and used anywhere.

- **Files:** an `.anim.xml` file (asset kind "Animation": `ParseAnimationSet`, its format there),
  or an **Aseprite file**, read as one (`AnimationSet_FromAseprite`): its frames laid out on a sheet
  (`Aseprite_SheetPixels`; the texture is the file's path plus ASEPRITE_SHEET_SUFFIX, which the
  resource manager turns into that sheet), one animation per tag (its frames, each frame's
  duration, its direction, its repeats; a tag that doesn't say how often loops, as in Aseprite),
  or, without tags, one "default" animation of every frame.
- **Scene files:** an AnimatedSprite's `animations="assets/hero.aseprite"` plays the set instead
  of its own animations; its `autoplay` (when set) picks the first one.
- **Sheets:** every animation has its own (`AnimationData.sheet` and `grid`), loaded through the
  resource manager (shared by the animations and sprites that use it); one that names an Aseprite
  file gives the sprite that file's slices while it plays (`Animation.source`).
- **Code:** `AnimatedSprite_UseAnimations(sprite, ANIMATION_HERO)` switches a sprite to a set.
- `Game_LoadAnimationSet` reads each file once (`Game.animationSets`, in the game's arena);
  editors fill that map with their in-memory sets before building, as they do components.
*/

// The resource manager key suffix for an Aseprite file's sheet of every frame (not its first frame)
ASEPRITE_SHEET_SUFFIX :: "#sheet"

/*
An Aseprite file as an animation set: every frame on a sheet, an animation per tag.

Inputs:
- ase: The file
- path: Its path, relative to the project folder (the sheet's texture is `path` +
  ASEPRITE_SHEET_SUFFIX)
- allocator: For the set's strings and lists

Returns:
- The set (free it with `AnimationSetData_Destroy`)
*/
AnimationSet_FromAseprite :: proc(ase: ^Aseprite, path: string, allocator := context.allocator) -> AnimationSetData {
	context.allocator = allocator
	set: AnimationSetData
	set.animations = make([dynamic]AnimationData)
	// Every animation's sheet: the file's frames on a grid
	columns, rows := Aseprite_SheetGrid(ase)
	sheet := AnimationSheetOf{strings.concatenate({path, ASEPRITE_SHEET_SUFFIX}, context.temp_allocator), {mode = .Cells, columns = columns, rows = rows}}
	AnimationSheetOf :: struct { path: string, grid: SheetGrid }
	clip :: proc(ase: ^Aseprite, sheet: AnimationSheetOf, name: string, from, to: int, direction: AsepriteDirection, repeat: int) -> AnimationData {
		a := AnimationData{name = strings.clone(name), sheet = strings.clone(sheet.path), grid = sheet.grid, start = from, end = to}
		a.durations = make([dynamic]f32)
		a.events = make([dynamic]string)
		total := 0
		anyEvent := false
		for f in from..=to {
			ms := f >= 0 && f < len(ase.frames) ? ase.frames[f].duration : 100
			append(&a.durations, f32(ms) / 1000)
			total += ms
			// Its cels' text and `event` properties (aseprite_nodes.odin)
			events := Aseprite_FrameEvents(ase, f)
			append(&a.events, strings.clone(events))
			if events != "" do anyEvent = true
		}
		if !anyEvent {
			for event in a.events do delete(event)
			clear(&a.events)
		}
		// fps for whatever reads only it: the frames' average
		a.fps = total > 0 ? f32(to - from + 1) * 1000 / f32(total) : DEFAULT_ANIMATION_FPS
		switch direction {
		case .Forward:           a.playMode = .Forward
		case .Reverse:           a.playMode = .Reverse
		case .Ping_Pong:         a.playMode = .PingPong
		case .Ping_Pong_Reverse: a.playMode = .PingPongReverse
		}
		// Aseprite plays a tag without a repeat count forever (its preview); with one, that often
		a.loop = repeat == 0
		a.repeat = repeat
		return a
	}
	for tag in ase.tags {
		from, to := clamp(tag.from, 0, max(len(ase.frames) - 1, 0)), clamp(tag.to, 0, max(len(ase.frames) - 1, 0))
		append(&set.animations, clip(ase, sheet, tag.name, min(from, to), max(from, to), tag.direction, tag.repeat))
	}
	if len(set.animations) == 0 do append(&set.animations, clip(ase, sheet, "default", 0, max(len(ase.frames) - 1, 0), .Forward, 0))
	return set
}

/*
An animation asset's set, read the first time and kept for the game's life, in the game's arena
(sprites share it). A file that can't be read is remembered too: it isn't read again.

Inputs:
- game: The game
- path: The `.anim.xml` or Aseprite file, relative to the project folder (`Game.projectDir`)

Returns:
- The set (don't free it), and false (logged) if it can't be read
*/
Game_LoadAnimationSet :: proc(game: ^Game, path: string) -> (^AnimationSetData, bool) {
	if set, found := game.animationSets[path]; found do return set, set != nil
	allocator := Game_GetAllocator(game)
	if game.animationSets == nil do game.animationSets = make(map[string]^AnimationSetData, allocator)
	full := JoinPath(game.projectDir, path)
	set: ^AnimationSetData
	if Aseprite_IsFile(path) {
		if ase, err := Aseprite_Load(full); err != .None {
			log.errorf("Couldn't read the animations of %s: %v", full, err)
		} else {
			set = new_clone(AnimationSet_FromAseprite(ase, path, allocator), allocator)
			Aseprite_Destroy(ase)
		}
	} else if text, read := Platform_ReadFile(full); !read {
		log.errorf("Couldn't read animations %s", full)
	} else if parsed, err := ParseAnimationSet(string(text), allocator); err != .None {
		log.errorf("Couldn't load animations %s: %v", full, err)
	} else {
		set = new_clone(parsed, allocator)
	}
	game.animationSets[strings.clone(path, allocator)] = set
	return set, set != nil
}

/*
Makes a sprite play a set of animations: its animations become the set's (its old ones go), each
on its own sheet, and it plays `autoplay` (else the set's own, else the first).

Inputs:
- sprite: The AnimatedSprite
- set: The animations (`Game_LoadAnimationSet`)
- projectDir: The folder the animations' sheet paths are relative to
- autoplay: The animation to play ("": the set's choice)

Returns:
- false (logged) if a sheet can't be loaded (its animation is there, drawing nothing)
*/
AnimatedSprite_SetAnimations :: proc(sprite: ^AnimatedSprite, set: ^AnimationSetData, projectDir: string, autoplay: AnimationName = "") -> bool {
	player := &sprite.animation
	if player.allocator.procedure == nil do AnimationPlayer_Init(player, Node_GetAllocator(sprite))
	AnimationPlayer_Clear(player)
	loaded := animatedSpriteAdd(sprite, set.animations[:], projectDir)
	first := autoplay != "" ? autoplay : set.autoplay
	if len(player.animations) > 0 && (first == "" || !(first in player.names) || !AnimationPlayer_Play(player, first)) do AnimationPlayer_Play(player, 0)
	return loaded
}

/*
The Aseprite file the sprite's playing animation shows, if its sheet is one.

Inputs:
- sprite: The AnimatedSprite

Returns:
- The file's full path ("" when the animation's sheet isn't an Aseprite file, or nothing plays),
  and whether its cells are the file's frames (a `#sheet`; false: the first frame cut into cells)
*/
AnimatedSprite_Source :: proc(sprite: ^AnimatedSprite) -> (file: string, frames: bool) {
	animation := AnimationPlayer_Current(&sprite.animation)
	if animation == nil do return "", false
	return animation.source, animation.sourceFrames
}

// Adds animations to a sprite, each on its sheet (loaded through the resource manager; an
// Aseprite file's with the sprite's layers): false (logged) if a sheet can't be loaded
@(private)
animatedSpriteAdd :: proc(sprite: ^AnimatedSprite, animations: []AnimationData, projectDir: string) -> bool {
	allocator := Node_GetAllocator(sprite)
	rm := &sprite.scene.game.resourceManager
	loaded := true
	for a in animations {
		file, part, _ := asepriteTextureKey(a.sheet)
		fromAseprite := Aseprite_IsFile(file)
		texture := loadAsset(rm, projectDir, asepriteLayersKey(a.sheet, fromAseprite ? sprite.layers : ""))
		if texture == nil {
			loaded = false
			if a.sheet != "" do log.warnf("%s: animation '%s' can't load its sheet %s", sprite.name, a.name, a.sheet)
		}
		animation := CreateSheetAnimation(a.name, texture, a.grid, a.fps, a.loop, a.start, a.end, a.playMode, allocator)
		animation.repeat = a.repeat
		if len(a.durations) > 0 do Animation_SetDurations(animation, a.durations[:])
		if len(a.events) > 0 do Animation_SetEvents(animation, a.events[:])
		// An Aseprite file's sheet: its slices follow the frames (the file's first frame: its own)
		if fromAseprite {
			animation.source = strings.clone(JoinPath(projectDir, file), allocator)
			animation.sourceFrames = part == .Sheet
		}
		AnimationPlayer_Add(&sprite.animation, animation)
	}
	return loaded
}

/*
Switches an AnimatedSprite to an animation asset (an `.anim.xml` or Aseprite file), from a script.

Inputs:
- sprite: The sprite
- asset: The animation asset (`ANIMATION_X` in scripts/assets.odin)
- autoplay: The animation to play ("": the asset's choice)

Returns:
- false (logged) if the asset can't be read

Example:
	// Given: sprite: ^e.AnimatedSprite, ANIMATION_HERO_ARMORED: e.AnimationAsset
	e.AnimatedSprite_UseAnimations(sprite, ANIMATION_HERO_ARMORED, "idle")
*/
AnimatedSprite_UseAnimations :: proc(sprite: ^AnimatedSprite, asset: AnimationAsset, autoplay: AnimationName = "") -> bool {
	if asset.path == "" do return false
	game := sprite.scene.game
	set, ok := Game_LoadAnimationSet(game, asset.path)
	if !ok do return false
	return AnimatedSprite_SetAnimations(sprite, set, game.projectDir, autoplay)
}

/*
An animation asset's set (read once, kept by the game).

Inputs:
- game: The game
- asset: The animation asset

Returns:
- The set (the game's), or nil (logged) if it can't be read
*/
Asset_Animations :: proc(game: ^Game, asset: AnimationAsset) -> ^AnimationSetData {
	if asset.path == "" do return nil
	set, _ := Game_LoadAnimationSet(game, asset.path)
	return set
}

// The resource manager key suffix for an Aseprite file's tileset (`#tileset0`: its first; tilemap.odin)
ASEPRITE_TILESET_SUFFIX :: "#tileset"

// What part of an Aseprite file a texture key names
@(private)
AsepriteTexturePart :: enum {
	// Its first frame (the plain path)
	Frame,
	// Every frame on a sheet (ASEPRITE_SHEET_SUFFIX)
	Sheet,
	// A tileset's tiles, one column (ASEPRITE_TILESET_SUFFIX and its index)
	Tileset,
}

// "assets/hero.aseprite#sheet" -> "assets/hero.aseprite", .Sheet; "x.aseprite#tileset1" -> .Tileset, 1
// (a `?layers=` part is left out: asepriteKeyLayers)
@(private)
asepriteTextureKey :: proc(key: string) -> (file: string, part: AsepriteTexturePart, index: int) {
	key, _ := asepriteKeyLayers(key)
	if strings.has_suffix(key, ASEPRITE_SHEET_SUFFIX) do return key[:len(key) - len(ASEPRITE_SHEET_SUFFIX)], .Sheet, 0
	if at := strings.last_index(key, ASEPRITE_TILESET_SUFFIX); at >= 0 {
		digits := key[at + len(ASEPRITE_TILESET_SUFFIX):]
		n := 0
		for ch in digits {
			if ch < '0' || ch > '9' do return key, .Frame, 0
			n = n * 10 + int(ch - '0')
		}
		if len(digits) > 0 do return key[:at], .Tileset, n
	}
	return key, .Frame, 0
}

// The pixels of a part of an Aseprite file (temp allocated), and their size; nil when it has none.
// `layers`: the names a key's `?layers=` gives ("": every visible layer)
@(private)
asepritePartPixels :: proc(ase: ^Aseprite, part: AsepriteTexturePart, index: int, layers := "") -> (pixels: []u8, width, height: int) {
	only := Aseprite_LayersNamed(ase, layers)
	// Named layers that aren't there draw nothing (not everything)
	if layers != "" && len(only) == 0 do only = []int{-1}
	switch part {
	case .Frame:
		return Aseprite_FramePixels(ase, 0, context.temp_allocator, only), ase.width, ase.height
	case .Sheet:
		columns, rows: int
		pixels, columns, rows = Aseprite_SheetPixels(ase, context.temp_allocator, only)
		return pixels, columns * ase.width, rows * ase.height
	case .Tileset:
		if index < 0 || index >= len(ase.tilesets) || ase.tilesets[index].pixels == nil do return nil, 0, 0
		t := &ase.tilesets[index]
		return t.pixels, t.tileWidth, t.tileHeight * t.count
	}
	return nil, 0, 0
}
