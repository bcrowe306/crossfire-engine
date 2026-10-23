package crossfire

import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

/*
Aseprite files in a running game, beyond their pixels (aseprite.odin reads them):

- **Slices** (`Aseprite_SliceAt`: a slice's key for a frame):
  - a Sprite's or AnimatedSprite's `pivotSlice` puts that slice's pivot on the node's origin,
    frame by frame (`Sprite_Origin`);
  - a Sprite's `nineSlice` draws that 9-patch slice stretched to `nineSize` (the corners keep
    their size, the edges and middle stretch);
  - a CollisionShape's `slice` takes that slice's rectangle, frame by frame (hitboxes, hurtboxes,
    a sword's reach): it follows the nearest Sprite or AnimatedSprite showing an Aseprite file
    (an ancestor, or a child of an ancestor), turns off where the slice is hidden, and rebuilds
    its body's shapes when it changes.
- **Frame events** (`Aseprite_FrameEvents`): a cel's text in Aseprite (its Properties > User
  Data), or its `event` property, on any layer (hidden ones too: an "events" layer works), is an
  event of that frame; an AnimatedSprite playing the file's tags sends it through
  `animation.onFrameEvent` (data: the name) when the frame shows.
- **Layers** (`asepriteLayers`, the scene file's `layers`): a Sprite or AnimatedSprite draws only
  the named layers (a group's name brings its layers), so a body and its sword can be two nodes.
  Their textures are keyed `<file>?layers=Body,Sword` (with `#sheet` before it for a sheet).
- `Game_LoadAseprite` keeps each file the game reads (`Game.aseprites`); development runs read a
  saved file again (`Game_ReloadChangedAseprites`), so slices and events follow Aseprite too.
*/

// The resource manager key suffix naming the layers a texture of an Aseprite file draws
ASEPRITE_LAYERS_SUFFIX :: "?layers="

/*
A file the game read, kept for its life (nil, logged, when it can't be read; asked again, it
stays nil until it's saved again in a development run).

Inputs:
- game: The game
- path: The file (as the resource manager has it: the project folder joined)

Returns:
- The file's data (the game's: don't free it), or nil
*/
Game_LoadAseprite :: proc(game: ^Game, path: string) -> ^Aseprite {
	if entry, found := game.aseprites[path]; found do return entry.ase
	if game.aseprites == nil do game.aseprites = make(map[string]AsepriteEntry, Game_GetAllocator(game))
	ase, err := Aseprite_Load(path)
	if err != .None do log.errorf("Couldn't read %s: %v", path, err)
	game.aseprites[strings.clone(path, Game_GetAllocator(game))] = {ase, fileModified(path)}
	return ase
}

// A file the game keeps, and its time when read
@(private)
AsepriteEntry :: struct {
	ase: ^Aseprite,
	modified: i64,
}

/*
Frees the Aseprite files the game keeps (Game_Destroy does it; editors' preview games too).

Inputs:
- game: The game
*/
Game_ForgetAseprites :: proc(game: ^Game) {
	for _, entry in game.aseprites do Aseprite_Destroy(entry.ase)
	game.aseprites = nil
}

/*
Reads again the Aseprite files the game keeps that were saved since (nothing keeps a file's
pointer: nodes look it up when they need it). Development runs call it twice a second; editors
for their previews.

Inputs:
- game: The game
*/
Game_ReloadChangedAseprites :: proc(game: ^Game) {
	for path, &entry in game.aseprites {
		modified := fileModified(path)
		if modified == 0 || modified == entry.modified do continue
		entry.modified = modified
		ase, err := Aseprite_Load(path)
		if err != .None {
			log.warnf("Reloading %s: %v", path, err)
			continue
		}
		Aseprite_Destroy(entry.ase)
		entry.ase = ase
	}
}

/*
A slice's shape in a frame: its key for the last frame at or before it.

Inputs:
- ase: The file
- name: The slice's name
- frame: The frame

Returns:
- The key, and false when there's no such slice, it starts later, or it's hidden in that frame
  (0 wide or high)
*/
Aseprite_SliceAt :: proc(ase: ^Aseprite, name: string, frame: int) -> (key: AsepriteSliceKey, ok: bool) {
	if ase == nil do return {}, false
	for &slice in ase.slices {
		if slice.name != name do continue
		for k in slice.keys do if k.frame <= frame do key, ok = k, true
		return key, ok && key.bounds[2] > 0 && key.bounds[3] > 0
	}
	return {}, false
}

/*
A frame's events: its cels' text and `event` properties, on every layer (in layer order).

Inputs:
- ase: The file
- frame: The frame

Returns:
- The events, comma-separated ("" for none; temp allocated)
*/
Aseprite_FrameEvents :: proc(ase: ^Aseprite, frame: int) -> string {
	if frame < 0 || frame >= len(ase.frames) do return ""
	names := make([dynamic]string, context.temp_allocator)
	for layer in 0..<len(ase.layers) {
		cel := Aseprite_Cel(ase, frame, layer)
		if cel == nil do continue
		if text := strings.trim_space(cel.userData.text); text != "" do append(&names, text)
		if value, ok := Aseprite_Property(cel.userData, "event"); ok {
			if text, isText := value.(string); isText && text != "" do append(&names, text)
		}
	}
	return strings.join(names[:], ",", context.temp_allocator)
}

/*
The layers named (a group's name brings every layer in it), for drawing only them.

Inputs:
- ase: The file
- names: Layer names separated by commas ("" for none)

Returns:
- Their indices (temp allocated), nil when none are named
*/
Aseprite_LayersNamed :: proc(ase: ^Aseprite, names: string) -> []int {
	if strings.trim_space(names) == "" do return nil
	wanted := strings.split(names, ",", context.temp_allocator)
	for &w in wanted do w = strings.trim_space(w)
	picked := make([dynamic]int, context.temp_allocator)
	for _, i in ase.layers {
		in_ := false
		for at := i; at >= 0 && !in_; at = ase.layers[at].parent {
			for w in wanted do if w == ase.layers[at].name do in_ = true
		}
		if in_ do append(&picked, i)
	}
	return picked[:]
}

/*
The point of a sprite's picture drawn at the node's origin: its pivot slice's pivot in that frame,
else the picture's middle.

Inputs:
- node: A Sprite or AnimatedSprite

Returns:
- The point, in the picture's pixels
*/
Sprite_Origin :: proc(node: ^Node) -> [2]f32 {
	source, pivot, frame, size := spritePicture(node)
	if pivot != "" && source != "" {
		if key, ok := Aseprite_SliceAt(Game_LoadAseprite(node.scene.game, source), pivot, frame); ok {
			return {f32(key.bounds[0] + key.pivot[0]), f32(key.bounds[1] + key.pivot[1])}
		}
	}
	return size * 0.5
}

// What a sprite shows: its Aseprite file (full path, "" when it isn't one), pivot slice, the file's
// frame showing, and its picture's size
@(private="file")
spritePicture :: proc(node: ^Node) -> (source, pivot: string, frame: int, size: [2]f32) {
	if Node_Is(node, Sprite) {
		s := cast(^Sprite)node
		size = spriteSize(s)
		return s.source, s.pivotSlice, 0, size
	}
	if Node_Is(node, AnimatedSprite) {
		s := cast(^AnimatedSprite)node
		frame = 0
		file, frames := AnimatedSprite_Source(s)
		if frames {
			if animation := AnimationPlayer_Current(&s.animation); animation != nil do frame = animation.startFrame + s.animation.frame
		}
		return file, s.pivotSlice, frame, AnimationPlayer_FrameSize(&s.animation)
	}
	return
}

@(private)
Sprite_draw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	sprite := cast(^Sprite)node
	if sprite.texture == nil do return
	size := spriteSize(sprite)
	if sprite.nineSlice != "" && sprite.source != "" {
		if key, ok := Aseprite_SliceAt(Game_LoadAseprite(sprite.scene.game, sprite.source), sprite.nineSlice, 0); ok {
			drawNineSlice(renderer, sprite.texture, key, nineSize(sprite, key))
			return
		}
	}
	origin := Sprite_Origin(node)
	// An atlas region: that part of the picture
	src: Maybe(sdl.FRect) = sprite.region.w > 0 ? sprite.region : nil
	DrawTexture(renderer, sprite.texture, {-origin.x, -origin.y, size.x, size.y}, src = src)
}

// What a sprite draws: its atlas region's size, else its texture's
@(private="file")
spriteSize :: proc(sprite: ^Sprite) -> [2]f32 {
	if sprite.region.w > 0 && sprite.region.h > 0 do return {sprite.region.w, sprite.region.h}
	if sprite.texture == nil do return {}
	return {f32(sprite.texture.w), f32(sprite.texture.h)}
}

@(private)
Sprite_getBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	sprite := cast(^Sprite)node
	if sprite.texture == nil do return {}, false
	if sprite.nineSlice != "" && sprite.source != "" {
		if key, ok := Aseprite_SliceAt(Game_LoadAseprite(sprite.scene.game, sprite.source), sprite.nineSlice, 0); ok {
			s := nineSize(sprite, key)
			return {-s.x * 0.5, -s.y * 0.5, s.x, s.y}, true
		}
	}
	origin := Sprite_Origin(node)
	size := spriteSize(sprite)
	return {-origin.x, -origin.y, size.x, size.y}, true
}

// A 9-patch's size: the sprite's, else the slice's own
@(private="file")
nineSize :: proc(sprite: ^Sprite, key: AsepriteSliceKey) -> [2]f32 {
	if sprite.nineSize.x > 0 && sprite.nineSize.y > 0 do return sprite.nineSize
	return {f32(key.bounds[2]), f32(key.bounds[3])}
}

// A 9-patch slice stretched to `size`, centered on the origin: corners as they are, edges and
// middle stretched (a slice without a center: stretched whole)
@(private="file")
drawNineSlice :: proc(renderer: ^sdl.Renderer, texture: ^sdl.Texture, key: AsepriteSliceKey, size: [2]f32) {
	b := [4]f32{f32(key.bounds[0]), f32(key.bounds[1]), f32(key.bounds[2]), f32(key.bounds[3])}
	c := [4]f32{f32(key.center[0]), f32(key.center[1]), f32(key.center[2]), f32(key.center[3])}
	if c[2] <= 0 || c[3] <= 0 {
		DrawTexture(renderer, texture, {-size.x * 0.5, -size.y * 0.5, size.x, size.y}, 0, sdl.FRect{b[0], b[1], b[2], b[3]})
		return
	}
	// Source and destination edges, each way: start, center's start, center's end, end
	right := b[2] - c[0] - c[2]
	bottom := b[3] - c[1] - c[3]
	sx := [4]f32{b[0], b[0] + c[0], b[0] + c[0] + c[2], b[0] + b[2]}
	sy := [4]f32{b[1], b[1] + c[1], b[1] + c[1] + c[3], b[1] + b[3]}
	dx := [4]f32{0, c[0], max(size.x - right, c[0]), max(size.x, c[0] + right)} - size.x * 0.5
	dy := [4]f32{0, c[1], max(size.y - bottom, c[1]), max(size.y, c[1] + bottom)} - size.y * 0.5
	for row in 0..<3 do for column in 0..<3 {
		src := sdl.FRect{sx[column], sy[row], sx[column + 1] - sx[column], sy[row + 1] - sy[row]}
		dst := sdl.FRect{dx[column], dy[row], dx[column + 1] - dx[column], dy[row + 1] - dy[row]}
		if src.w <= 0 || src.h <= 0 || dst.w <= 0 || dst.h <= 0 do continue
		DrawTexture(renderer, texture, dst, 0, src)
	}
}

@(private)
AnimatedSprite_getBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	size := AnimationPlayer_FrameSize(&(cast(^AnimatedSprite)node).animation)
	if size == {} do return {}, false
	origin := Sprite_Origin(node)
	return {-origin.x, -origin.y, size.x, size.y}, true
}

@(private)
AnimatedSprite_draw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	sprite := cast(^AnimatedSprite)node
	size := AnimationPlayer_FrameSize(&sprite.animation)
	origin := Sprite_Origin(node)
	AnimationPlayer_Draw(&sprite.animation, renderer, {-origin.x, -origin.y, size.x, size.y})
}

// The sprite a slice-following shape takes its slice from: the nearest ancestor that's a sprite
// showing an Aseprite file, or such a sprite among an ancestor's children
@(private="file")
sliceSprite :: proc(shape: ^Node) -> ^Node {
	shows :: proc(n: ^Node) -> bool {
		source, _, _, _ := spritePicture(n)
		return source != ""
	}
	for at := shape.parent; at != nil; at = at.parent {
		if shows(at) do return at
		for child in at.children do if child != shape && shows(child) do return child
	}
	return nil
}

// A CollisionShape following a slice: its rectangle in its parent's space from the slice in the
// sprite's frame, its body's shapes rebuilt when that changes
@(private)
sliceShapeUpdate :: proc(node: ^Node, _: []sdl.Event, _: f64) {
	shape := cast(^CollisionShape)node
	sprite := sliceSprite(shape)
	if sprite == nil do return
	source, _, frame, _ := spritePicture(sprite)
	key, ok := Aseprite_SliceAt(Game_LoadAseprite(shape.scene.game, source), shape.slice, frame)
	disabled := !ok
	position, size := shape.position, shape.size
	if ok {
		origin := Sprite_Origin(sprite)
		lo := [2]f32{f32(key.bounds[0]), f32(key.bounds[1])} - origin
		hi := lo + {f32(key.bounds[2]), f32(key.bounds[3])}
		// Through the sprite's world transform into the shape's parent's space (mirrored sprites
		// mirror the hitbox)
		toParent := Transform2D_Multiply(Transform2D_Inverse(Node_GetWorldTransform(shape.parent)), Node_GetWorldTransform(sprite))
		a, b := Transform2D_Apply(toParent, lo), Transform2D_Apply(toParent, hi)
		position = (a + b) * 0.5
		size = {abs(b.x - a.x), abs(b.y - a.y)}
	}
	if disabled == shape.disabled && (disabled || (position == shape.position && size == shape.size)) do return
	shape.disabled = disabled
	shape.position, shape.size = position, size
	shape.shape = .Rectangle
	if body := CollisionShape_GetBody(shape); body != nil do PhysicsBody_RebuildShapes(body)
}

// A texture key's layers part, split off ("x.aseprite#sheet?layers=A,B" -> "x.aseprite#sheet", "A,B")
@(private)
asepriteKeyLayers :: proc(key: string) -> (rest, layers: string) {
	at := strings.index(key, ASEPRITE_LAYERS_SUFFIX)
	if at < 0 do return key, ""
	return key[:at], key[at + len(ASEPRITE_LAYERS_SUFFIX):]
}

// A texture key for some layers of an Aseprite texture ("" layers: the key as it is)
@(private)
asepriteLayersKey :: proc(key, layers: string) -> string {
	if layers == "" do return key
	return strings.concatenate({key, ASEPRITE_LAYERS_SUFFIX, layers}, context.temp_allocator)
}
