package crossfire

import "core:log"
import "core:strings"

/*
Animation assets: a sheet and named animations that AnimatedSprite nodes share, so one set of
animations (a hero's idle, run, jump) is made once and used anywhere.

- **Files:** an `.anim.xml` file (asset kind "Animation": `ParseAnimationSet`, its format there),
  or an **Aseprite file**, read as one (`AnimationSet_FromAseprite`): its frames laid out on a sheet
  (`Aseprite_SheetPixels`; the texture is the file's path plus ASEPRITE_SHEET_SUFFIX, which the
  resource manager turns into that sheet), one animation per tag (its frames, each frame's
  duration, its direction, its repeats; a tag that doesn't say how often loops, as in Aseprite),
  or, without tags, one "default" animation of every frame.
- **Scene files:** an AnimatedSprite's `animations="assets/hero.aseprite"` plays the set instead
  of its own sheet and animations; its `autoplay` (when set) picks the first one.
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
	set := AnimationSetData{texture = strings.concatenate({path, ASEPRITE_SHEET_SUFFIX})}
	set.columns, set.rows = Aseprite_SheetGrid(ase)
	set.animations = make([dynamic]AnimationData)
	clip :: proc(ase: ^Aseprite, name: string, from, to: int, direction: AsepriteDirection, repeat: int) -> AnimationData {
		a := AnimationData{name = strings.clone(name), start = from, end = to}
		a.durations = make([dynamic]f32)
		total := 0
		for f in from..=to {
			ms := f >= 0 && f < len(ase.frames) ? ase.frames[f].duration : 100
			append(&a.durations, f32(ms) / 1000)
			total += ms
		}
		// fps for whatever reads only it: the frames' average
		a.fps = total > 0 ? f32(to - from + 1) * 1000 / f32(total) : DEFAULT_SCENE_NODE.fps
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
		append(&set.animations, clip(ase, tag.name, min(from, to), max(from, to), tag.direction, tag.repeat))
	}
	if len(set.animations) == 0 do append(&set.animations, clip(ase, "default", 0, max(len(ase.frames) - 1, 0), .Forward, 0))
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
Makes a sprite play a set of animations: its animations become the set's (its old ones go), on
the set's sheet, and it plays `autoplay` (else the set's own, else the first).

Inputs:
- sprite: The AnimatedSprite
- set: The animations (`Game_LoadAnimationSet`)
- projectDir: The folder the set's texture path is relative to
- autoplay: The animation to play ("": the set's choice)

Returns:
- false (logged) if the set's sheet can't be loaded
*/
AnimatedSprite_SetAnimations :: proc(sprite: ^AnimatedSprite, set: ^AnimationSetData, projectDir: string, autoplay := "") -> bool {
	allocator := Node_GetAllocator(sprite)
	player := &sprite.animation
	if player.allocator.procedure == nil do AnimationPlayer_Init(player, allocator)
	AnimationPlayer_Clear(player)
	texture := loadAsset(&sprite.scene.game.resourceManager, projectDir, set.texture)
	if texture == nil do return false
	for a in set.animations {
		animation := CreateSpriteSheetAnimation(a.name, texture, set.columns, set.rows, a.fps, a.loop, a.start, a.end, a.playMode, set.margin, set.spacing, allocator)
		animation.repeat = a.repeat
		if len(a.durations) > 0 do Animation_SetDurations(animation, a.durations[:])
		AnimationPlayer_Add(player, animation)
	}
	first := autoplay != "" ? autoplay : set.autoplay
	if first == "" || !(first in player.names) || !AnimationPlayer_Play(player, first) do AnimationPlayer_Play(player, 0)
	return true
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
AnimatedSprite_UseAnimations :: proc(sprite: ^AnimatedSprite, asset: AnimationAsset, autoplay := "") -> bool {
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

// "assets/hero.aseprite#sheet" -> "assets/hero.aseprite", true
@(private)
asepriteSheetFile :: proc(key: string) -> (string, bool) {
	if !strings.has_suffix(key, ASEPRITE_SHEET_SUFFIX) do return key, false
	return key[:len(key) - len(ASEPRITE_SHEET_SUFFIX)], true
}
