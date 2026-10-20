package engine

import "core:log"
import "core:mem"
import sdl "vendor:sdl3"

/*
Holds a set of animations, plays one at a time and draws its current frame.

The player is a plain struct, not a Node: embed it in the node that uses it, call
`AnimationPlayer_Update` from the node's update and `AnimationPlayer_Draw` from its draw.

Animations are referenced by name or by the index `AnimationPlayer_Add` returned. Frame
numbers reported by the player (events, `frame`) are relative to the playing animation:
0 is its startFrame, `totalFrames() - 1` its endFrame.

Events: subscribe with `player.onFrameChanged->subscribe(callback, userData)`. Every
event's `source` is the ^AnimationPlayer; `data` is described on each event below.

Example:
	Enemy :: struct {
		using node: e.Node,
		pos: [2]f32,
		anim: e.AnimationPlayer,
	}

	CreateEnemy :: proc(scene: ^e.Scene) -> ^Enemy {
		enemy := e.CreateNode(scene, Enemy)
		enemy.update = Enemy_update
		enemy.draw = Enemy_draw

		rm := &scene.game.resourceManager
		allocator := e.Node_GetAllocator(enemy) // Animations and listeners are freed with the enemy

		e.AnimationPlayer_Init(&enemy.anim, allocator)
		sheet := rm->loadTexture("enemy.png") // 6x1 grid
		e.AnimationPlayer_Add(&enemy.anim, e.CreateSpriteSheetAnimation("idle", sheet, 6, 1, fps = 6, loop = true, endFrame = 3, allocator = allocator))
		e.AnimationPlayer_Add(&enemy.anim, e.CreateSpriteSheetAnimation("die", sheet, 6, 1, fps = 10, startFrame = 4, allocator = allocator))

		// Remove the enemy once the death animation finishes. Its memory, including this
		// player, its animations and listeners, is freed at the start of the next update
		enemy.anim.onAnimationEnded->subscribe(proc(event: ^e.EventSubject, source: rawptr, data: e.EventData, userData: rawptr) {
			player := cast(^e.AnimationPlayer)source
			if e.AnimationPlayer_CurrentName(player) == "die" {
				enemy := cast(^Enemy)userData
				enemy.scene->removeNode(enemy.id)
			}
		}, enemy)

		e.AnimationPlayer_Play(&enemy.anim, "idle")
		return enemy
	}

	Enemy_update :: proc(node: ^e.Node, events: []sdl.Event, deltaTime: f64) {
		enemy := cast(^Enemy)node
		e.AnimationPlayer_Update(&enemy.anim, deltaTime)
	}

	Enemy_draw :: proc(node: ^e.Node, renderer: ^sdl.Renderer) {
		enemy := cast(^Enemy)node
		size := e.AnimationPlayer_FrameSize(&enemy.anim)
		e.AnimationPlayer_Draw(&enemy.anim, renderer, {enemy.pos.x, enemy.pos.y, size.x, size.y})
	}
*/
AnimationPlayer :: struct {
	// The animations it owns, by the index `AnimationPlayer_Add` returned
	animations: [dynamic]^Animation,
	// Animation name -> index in `animations`
	names: map[string]int,

	// Index of the current animation, -1 if none
	current: int,
	// Index of the animation that was current before the last change, -1 if none
	previous: int,
	// Current frame, relative to the current animation's startFrame
	frame: int,
	// True while frames are advancing
	playing: bool,
	// True after a non-looping animation reached its end
	finished: bool,
	// Playback speed multiplier. 1 is normal, 2 double speed, 0 frozen
	speed: f32,

	// Seconds spent on the current frame
	elapsed: f32,
	// +1 or -1: direction frames are currently moving (PingPong flips it)
	direction: int,

	// data: int, the new relative frame. Also sent when an animation starts on its first frame
	onFrameChanged: EventSubject,
	// data: int, index of the new animation (the old one is in `previous`)
	onAnimationChanged: EventSubject,
	// data: int, index of the animation that started (or restarted)
	onAnimationStarted: EventSubject,
	// data: int, index of the animation. Sent when a non-looping animation finishes
	onAnimationEnded: EventSubject,
	// data: int, index of the animation. Sent each time a looping animation wraps around
	onAnimationLooped: EventSubject,
	// data: int, index of the animation. Sent by AnimationPlayer_Stop
	onAnimationStopped: EventSubject,

	// Allocator of its lists and event listeners (`AnimationPlayer_Init`)
	allocator: mem.Allocator,
}

/*
Prepares a player for use.

Inputs:
- player: The player to initialize
- allocator: Allocator for the player's lists and event listeners. Use the owning node's
  allocator (`Node_GetAllocator`) so they are freed with the node
*/
AnimationPlayer_Init :: proc(player: ^AnimationPlayer, allocator := context.allocator) {
	player.allocator = allocator
	player.animations = make([dynamic]^Animation, allocator)
	player.names = make(map[string]int, allocator = allocator)
	player.current = -1
	player.previous = -1
	player.speed = 1
	player.direction = 1
	EventSubject_Init(&player.onFrameChanged, allocator)
	EventSubject_Init(&player.onAnimationChanged, allocator)
	EventSubject_Init(&player.onAnimationStarted, allocator)
	EventSubject_Init(&player.onAnimationEnded, allocator)
	EventSubject_Init(&player.onAnimationLooped, allocator)
	EventSubject_Init(&player.onAnimationStopped, allocator)
}

/*
Frees the player's animations, lists and event listeners.

Not needed when the player and its animations use their node's allocator
(`Node_GetAllocator`): everything, including event listeners, is freed with the node.

Inputs:
- player: The player to free
*/
AnimationPlayer_Destroy :: proc(player: ^AnimationPlayer) {
	for animation in player.animations do Animation_Destroy(animation)
	delete(player.animations)
	delete(player.names)
	Event_Destroy(&player.onFrameChanged)
	Event_Destroy(&player.onAnimationChanged)
	Event_Destroy(&player.onAnimationStarted)
	Event_Destroy(&player.onAnimationEnded)
	Event_Destroy(&player.onAnimationLooped)
	Event_Destroy(&player.onAnimationStopped)
	player^ = {}
	player.current = -1
	player.previous = -1
}

/*
Adds an animation to the player, which takes ownership of it.

Inputs:
- player: The player
- animation: Any animation type (SpriteSheetAnimation, FrameAnimation, ...)

Returns:
- The animation's index, usable instead of its name. -1 (logged) if the name is already taken: the
  player then doesn't own it, so free it yourself unless it uses a node's allocator

Example:
	// Given: player: ^e.AnimationPlayer, sheet: ^sdl.Texture
	e.AnimationPlayer_Add(player, e.CreateSpriteSheetAnimation("run", sheet, 8, 1, fps = 12, loop = true))
*/
AnimationPlayer_Add :: proc(player: ^AnimationPlayer, animation: ^Animation) -> int {
	if animation.name in player.names {
		log.warnf("AnimationPlayer already has an animation named '%s'", animation.name)
		return -1
	}
	index := len(player.animations)
	append(&player.animations, animation)
	player.names[animation.name] = index
	return index
}

/*
Starts playing an animation by name or index.

If that animation is already playing it keeps going unless `restart` is true, so it is safe
to call every frame (e.g. `Play("run")` while a movement key is held).

Sends onAnimationChanged (if it differs from the current one), onAnimationStarted and
onFrameChanged for its first frame.

Inputs:
- player: The player
- name: Which animation to play, by name (`AnimationPlayer_PlayByName`; an unknown name is logged)
- index: Or by the index `AnimationPlayer_Add` returned (`AnimationPlayer_PlayByIndex`)
- restart: Restart from the first frame even if it is already playing

Returns:
- false if no such animation exists

Example:
	// Given: player: ^e.AnimationPlayer
	e.AnimationPlayer_Play(player, "thrust")
	e.AnimationPlayer_Play(player, 0, restart = true)
*/
AnimationPlayer_Play :: proc{AnimationPlayer_PlayByName, AnimationPlayer_PlayByIndex}

// `AnimationPlayer_Play` by the animation's name
AnimationPlayer_PlayByName :: proc(player: ^AnimationPlayer, name: string, restart := false) -> bool {
	index, ok := player.names[name]
	if !ok {
		log.warnf("AnimationPlayer has no animation named '%s'", name)
		return false
	}
	return AnimationPlayer_PlayByIndex(player, index, restart)
}

// `AnimationPlayer_Play` by the index `AnimationPlayer_Add` returned
AnimationPlayer_PlayByIndex :: proc(player: ^AnimationPlayer, index: int, restart := false) -> bool {
	if index < 0 || index >= len(player.animations) {
		log.warnf("AnimationPlayer has no animation at index %d", index)
		return false
	}
	if index == player.current && player.playing && !restart do return true

	changed := index != player.current
	if changed {
		player.previous = player.current
		player.current = index
	}

	animation := player.animations[index]
	player.playing = true
	player.finished = false
	player.elapsed = 0
	if animation.playMode == .Reverse {
		player.frame = animation->totalFrames() - 1
		player.direction = -1
	} else {
		player.frame = 0
		player.direction = 1
	}

	// Notify only once the new state is in place, so listeners see the new animation
	if changed do player.onAnimationChanged->notify(player, index)
	player.onAnimationStarted->notify(player, index)
	player.onFrameChanged->notify(player, player.frame)
	return true
}

/*
Pauses playback on the current frame. Resume with `AnimationPlayer_Resume`.

Inputs:
- player: The player
*/
AnimationPlayer_Pause :: proc(player: ^AnimationPlayer) {
	player.playing = false
}

/*
Continues a paused animation from its current frame. Does nothing if the animation finished.

Inputs:
- player: The player
*/
AnimationPlayer_Resume :: proc(player: ^AnimationPlayer) {
	if player.current >= 0 && !player.finished do player.playing = true
}

/*
Stops playback and rewinds to the first frame of the current animation. Sends onAnimationStopped.

Inputs:
- player: The player
*/
AnimationPlayer_Stop :: proc(player: ^AnimationPlayer) {
	if player.current < 0 do return
	animation := player.animations[player.current]
	player.playing = false
	player.finished = false
	player.elapsed = 0
	player.direction = animation.playMode == .Reverse ? -1 : 1
	rewound := animation.playMode == .Reverse ? animation->totalFrames() - 1 : 0
	if rewound != player.frame {
		player.frame = rewound
		player.onFrameChanged->notify(player, player.frame)
	}
	player.onAnimationStopped->notify(player, player.current)
}

/*
Jumps to a frame of the current animation without changing whether it is playing.

Inputs:
- player: The player
- frame: Frame relative to the animation's startFrame. Clamped to the animation's frames
*/
AnimationPlayer_SetFrame :: proc(player: ^AnimationPlayer, frame: int) {
	if player.current < 0 do return
	frame := clamp(frame, 0, player.animations[player.current]->totalFrames() - 1)
	player.elapsed = 0
	if frame != player.frame {
		player.frame = frame
		player.onFrameChanged->notify(player, player.frame)
	}
}

/*
Advances the current animation. Call once per frame from the owning node's update.

Inputs:
- player: The player
- deltaTime: Seconds since the last frame

Example:
	// Given: player: ^e.AnimationPlayer
	e.AnimationPlayer_Update(player, deltaTime)
*/
AnimationPlayer_Update :: proc(player: ^AnimationPlayer, deltaTime: f64) {
	if !player.playing || player.current < 0 do return
	animation := player.animations[player.current]
	if animation.fps <= 0 do return

	frameTime := 1 / animation.fps
	player.elapsed += f32(deltaTime) * max(player.speed, 0)

	// A long frame (or high speed) can cover several animation frames at once
	for player.elapsed >= frameTime {
		player.elapsed -= frameTime
		playing := player.current
		advanceFrame(player, animation)
		// Stop if it ended, or an event callback switched or stopped the animation
		if !player.playing || player.current != playing do return
	}
}

/*
Draws the current frame of the current animation. Camera aware, like `DrawTexture`.

Inputs:
- player: The player
- renderer: The renderer to draw with
- dest: Where to draw, in world coordinates. Use `AnimationPlayer_FrameSize` for the native size
- rotation: Degrees, clockwise around the center of `dest`
- tint: Multiplies the frame's colors and alpha
- flip: Mirror horizontally and/or vertically, e.g. to face left

Example:
	// Given: player: ^e.AnimationPlayer
	size := e.AnimationPlayer_FrameSize(player)
	e.AnimationPlayer_Draw(player, renderer, {100, 100, size.x * 2, size.y * 2}, flip = .HORIZONTAL)
*/
AnimationPlayer_Draw :: proc(
	player: ^AnimationPlayer,
	renderer: ^sdl.Renderer,
	dest: sdl.FRect,
	rotation: f32 = 0,
	tint := sdl.Color{255, 255, 255, 255},
	flip := sdl.FlipMode.NONE,
) {
	animation := AnimationPlayer_Current(player)
	if animation == nil || animation.drawFrame == nil do return
	animation->drawFrame(renderer, animation.startFrame + player.frame, dest, rotation, tint, flip)
}

/*
Native pixel size of the frame currently showing.

Inputs:
- player: The player

Returns:
- The frame's width and height, or {0, 0} if nothing is playing
*/
AnimationPlayer_FrameSize :: proc(player: ^AnimationPlayer) -> [2]f32 {
	animation := AnimationPlayer_Current(player)
	if animation == nil || animation.frameSize == nil do return {}
	return animation->frameSize(animation.startFrame + player.frame)
}

/*
Looks up an animation by name or index.

Inputs:
- player: The player
- name: Which animation, by name (`AnimationPlayer_GetByName`)
- index: Or by index (`AnimationPlayer_GetByIndex`)

Returns:
- The animation, or nil if there is none. Cast to the subtype to change type-specific settings
*/
AnimationPlayer_Get :: proc{AnimationPlayer_GetByName, AnimationPlayer_GetByIndex}

// `AnimationPlayer_Get` by name
AnimationPlayer_GetByName :: proc(player: ^AnimationPlayer, name: string) -> ^Animation {
	index, ok := player.names[name]
	return ok ? player.animations[index] : nil
}

// `AnimationPlayer_Get` by index
AnimationPlayer_GetByIndex :: proc(player: ^AnimationPlayer, index: int) -> ^Animation {
	if index < 0 || index >= len(player.animations) do return nil
	return player.animations[index]
}

/*
Index of an animation by name.

Inputs:
- player: The player
- name: The animation's name

Returns:
- The index and true, or -1 and false if there is no such animation
*/
AnimationPlayer_IndexOf :: proc(player: ^AnimationPlayer, name: string) -> (int, bool) {
	index, ok := player.names[name]
	return ok ? index : -1, ok
}

/*
The current animation.

Inputs:
- player: The player

Returns:
- The animation, or nil if none has been played
*/
AnimationPlayer_Current :: proc(player: ^AnimationPlayer) -> ^Animation {
	return AnimationPlayer_GetByIndex(player, player.current)
}

/*
Name of the current animation.

Inputs:
- player: The player

Returns:
- The name (the animation's string), or "" if none has been played
*/
AnimationPlayer_CurrentName :: proc(player: ^AnimationPlayer) -> string {
	animation := AnimationPlayer_Current(player)
	return animation != nil ? animation.name : ""
}

/*
Whether the named animation is the current one and is playing (not paused, stopped or finished).

Inputs:
- player: The player
- name: The animation's name

Returns:
- true if it is playing
*/
AnimationPlayer_IsPlaying :: proc(player: ^AnimationPlayer, name: string) -> bool {
	return player.playing && AnimationPlayer_CurrentName(player) == name
}

// Steps one frame according to the animation's play mode, handling the ends
@(private="file")
advanceFrame :: proc(player: ^AnimationPlayer, animation: ^Animation) {
	last := animation->totalFrames() - 1
	next := player.frame + player.direction
	wrapped := false

	// A single frame animation completes a cycle every frame, whatever the mode
	if last == 0 {
		if !animation.loop { endAnimation(player); return }
		player.onAnimationLooped->notify(player, player.current)
		return
	}

	switch animation.playMode {
	case .Forward:
		if next > last {
			if !animation.loop { endAnimation(player); return }
			next = 0
			wrapped = true
		}
	case .Reverse:
		if next < 0 {
			if !animation.loop { endAnimation(player); return }
			next = last
			wrapped = true
		}
	case .PingPong:
		// One cycle is start -> end -> start. Arriving back on the start frame completes it;
		// a non-looping animation then shows that frame once more before ending
		if next > last {
			player.direction = -1
			next = last - 1
		} else if next < 0 {
			if !animation.loop { endAnimation(player); return }
			player.direction = 1
			next = 1
		}
		wrapped = next == 0 && player.direction == -1 && animation.loop
	}

	changed := next != player.frame
	player.frame = next
	if wrapped do player.onAnimationLooped->notify(player, player.current)
	if changed && player.playing do player.onFrameChanged->notify(player, player.frame)
}

@(private="file")
endAnimation :: proc(player: ^AnimationPlayer) {
	player.playing = false
	player.finished = true
	player.elapsed = 0
	player.onAnimationEnded->notify(player, player.current)
}
