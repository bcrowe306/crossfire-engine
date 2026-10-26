package crossfire

import "core:math"
import "core:slice"
import sdl "vendor:sdl3"

/*
2D lighting: a scene drawn dark (its ambient light) and lit by Light2D nodes, with shadows cast
by LightOccluder nodes (and, if the scene says so, its static bodies' shapes).

	<scene name="Cave" lighting="true" ambient="#202436" bodyShadows="true">
		<node kind="Light2D" name="Torch" x="200" y="120" color="#ffb060" energy="1.2" lightRadius="260"/>
		<node kind="LightOccluder" name="Pillar" x="300" y="160" width="40" height="120"/>
	</scene>

- **Turning it on** (`SceneSettings.lighting`, `ambient`; `Scene.lighting` at run time): the
  world layers are multiplied by a light map: the ambient color everywhere (black: pitch dark;
  white: fully lit), plus each light. Screen layers (HUDs, menus) aren't lit.
- **Lights** (`Light2D`, `LightSettings`): a point light shines all around, a spot light in a cone
  (`angle` degrees wide) the way the node faces (its world rotation; 0 is right). Its `color`
  times `energy` at its center fades to nothing at `radius`. Lights add up.
- **Shadows** (`shadows` on the light): a light stops at the edges of occluders: `LightOccluder`
  nodes (a rectangle, circle, polygon or segment, like a CollisionShape's) and, with the scene's
  `bodyShadows`, the shapes of its static bodies (a TileMap's or LDtk level's walls).
  `Light_Visibility` computes what a light reaches: the polygon its light fills.
- **How it draws:** the light map is a render target the size of the screen (`Scene.lighting`
  keeps it); lights are triangle fans over it with their brightness in the vertices' colors, added
  together, and the map is drawn over the world with multiply blending. No shaders, so it works
  with every renderer, the software one and the web's included. Normal-mapped sprites need
  shaders (a later feature).
*/

// What a light is shaped like
LightKind :: enum {
	// All around it
	Point,
	// A cone the way it faces
	Spot,
}

/*
A light's settings (`SceneNodeData.light`; a Light2D's `settings`).
*/
LightSettings :: struct {
	// Point or Spot
	kind: LightKind,
	// Its color at the center
	color: sdl.Color,
	// How bright: the color times this (2 is twice as bright, up to white)
	energy: f32,
	// How far it reaches, in pixels (world units)
	radius: f32,
	// Spot lights: the cone's width in degrees
	angle: f32,
	// It stops at occluders
	shadows: bool,
}

// A light's settings when the scene file sets none: a warm white point light
DEFAULT_LIGHT_SETTINGS :: LightSettings{kind = .Point, color = {255, 240, 220, 255}, energy = 1, radius = 200, angle = 60, shadows = true}

// A scene's light: see the file's overview
Light2D :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Its settings (change them any time)
	settings: LightSettings,
}

// A shape that stops light: see the file's overview
LightOccluder :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Rectangle (`size`), Circle (`radius`), Polygon or Segment (`points`); a Capsule is its box
	shape: CollisionShapeKind,
	// Rectangle: width and height, centered on the node
	size: [2]f32,
	// Circle
	radius: f32,
	// Polygon, Segment: points in the node's space
	points: [dynamic][2]f32,
}

// A scene's lighting at run time (`Scene.lighting`)
SceneLighting :: struct {
	// The world layers are lit (dark outside the lights)
	enabled: bool,
	// The light everywhere, before the lights
	ambient: sdl.Color,
	// Static bodies' shapes cast shadows too
	bodyShadows: bool,
	// The light map, made and resized as needed
	target: ^RenderTarget,
	// One light at a time is drawn here, then added to the map: its triangles overwrite each other
	// (added straight to the map, the software renderer lit their shared edges twice: bright seams)
	scratch: ^RenderTarget,
}

// A scene's ambient light when its file sets none
DEFAULT_AMBIENT :: sdl.Color{40, 42, 60, 255}

// Rays a shadowless point light's circle is drawn with (and shadowed lights' edges between)
LIGHT_SEGMENTS :: 48

/*
Creates a Light2D and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- settings: Its settings

Returns:
- The light

Example:
	torch := e.CreateLight2D(scene, {kind = .Point, color = {255, 180, 90, 255}, energy = 1.2, radius = 240, shadows = true})
	torch.position = {320, 200}
	e.Scene_SetLighting(scene, true, {20, 22, 34, 255})
*/
CreateLight2D :: proc(scene: ^Scene, settings := DEFAULT_LIGHT_SETTINGS) -> ^Light2D {
	light := CreateNode(scene, Light2D)
	light.settings = settings
	light.getBounds = proc(node: ^Node) -> (sdl.FRect, bool) {
		r := (cast(^Light2D)node).settings.radius
		return {-r, -r, r * 2, r * 2}, r > 0
	}
	return light
}

/*
Creates a LightOccluder and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- size: A rectangle's width and height, centered on the node

Returns:
- The occluder

Example:
	wall := e.CreateLightOccluder(scene, {40, 120})
	wall.position = {300, 160}
*/
CreateLightOccluder :: proc(scene: ^Scene, size := [2]f32{32, 32}) -> ^LightOccluder {
	o := CreateNode(scene, LightOccluder)
	o.shape = .Rectangle
	o.size = size
	o.radius = 16
	o.points = make([dynamic][2]f32, Node_GetAllocator(o))
	o.getBounds = proc(node: ^Node) -> (sdl.FRect, bool) {
		o := cast(^LightOccluder)node
		lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
		for p in occluderOutline(o, TRANSFORM2D_IDENTITY, context.temp_allocator) do lo, hi = {min(lo.x, p.x), min(lo.y, p.y)}, {max(hi.x, p.x), max(hi.y, p.y)}
		if lo.x > hi.x do return {}, false
		return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, true
	}
	return o
}

/*
Turns a scene's lighting on or off.

Inputs:
- scene: The scene
- enabled: Light the world layers (dark outside the lights)
- ambient: The light everywhere (black: pitch dark)
- bodyShadows: Static bodies' shapes cast shadows too

Example:
	e.Scene_SetLighting(scene, true, {10, 10, 20, 255})
*/
Scene_SetLighting :: proc(scene: ^Scene, enabled: bool, ambient := DEFAULT_AMBIENT, bodyShadows := false) {
	scene.lighting.enabled = enabled
	scene.lighting.ambient = ambient
	scene.lighting.bodyShadows = bodyShadows
}

/*
What a light reaches: the polygon its light fills, in world coordinates, as seen from its
position (occluders' edges stop it when it has shadows; a spot light's cone limits it).

Inputs:
- light: The light (its scene's occluders are used)
- allocator: For the points

Returns:
- The polygon's points, around the light in angle order (a spot light's: from one edge of its
  cone to the other; the light's position isn't included)
*/
Light_Visibility :: proc(light: ^Light2D, allocator := context.allocator) -> [][2]f32 {
	outlines: []LightOutline
	if light.settings.shadows && light.scene != nil do outlines = lightOutlines(light.scene)
	return lightVisibility(light, outlines, allocator)
}

// INTERNAL

// What a light reaches (Light_Visibility), its shadows from outlines gathered already
// (`lightOutlines`: Lighting_Apply gathers them once a frame for all its lights)
@(private="file")
lightVisibility :: proc(light: ^Light2D, outlines: []LightOutline, allocator := context.allocator) -> [][2]f32 {
	center := Node_GetWorldPosition(light)
	s := light.settings
	segments := make([dynamic][2][2]f32, context.temp_allocator)
	if s.shadows do lightSegments(outlines, center, s.radius, &segments)
	// The rays: evenly around (or across the cone), plus just either side of every corner
	angles := make([dynamic]f32, context.temp_allocator)
	spot := s.kind == .Spot
	facing := Transform2D_Rotation(Node_GetWorldTransform(light)) * math.RAD_PER_DEG
	half := clamp(s.angle, 1, 359) * 0.5 * math.RAD_PER_DEG
	inCone :: proc(a, facing, half: f32) -> bool {
		d := math.mod(a - facing + math.PI * 3, math.TAU) - math.PI
		return abs(d) <= half
	}
	if spot {
		steps := max(int(f32(LIGHT_SEGMENTS) * half / math.PI), 4)
		for i in 0..=steps do append(&angles, facing - half + 2 * half * f32(i) / f32(steps))
	} else {
		for i in 0..<LIGHT_SEGMENTS do append(&angles, f32(i) * math.TAU / LIGHT_SEGMENTS)
	}
	even := len(angles)
	for seg in segments do for p in seg {
		a := math.atan2(p.y - center.y, p.x - center.x)
		for d in ([3]f32{-0.0005, 0, 0.0005}) {
			if !spot || inCone(a + d, facing, half) do append(&angles, a + d)
		}
	}
	// In angle order (a spot's from its cone's first edge)
	key :: proc(a, start: f32) -> f32 { return math.mod(a - start + math.TAU * 4, math.TAU) }
	start := spot ? facing - half : f32(0)
	Ray :: struct { key, angle: f32 }
	rays := make([]Ray, len(angles), context.temp_allocator)
	for a, i in angles do rays[i] = {key(a, start), a}
	if spot do for &r in rays do if r.key > 2 * half + 0.001 do r.key -= math.TAU
	// The evenly spaced rays are in order already: only the corners' are sorted, then the two
	// runs merged (2026-10-26: sorting every ray was most of a light's time; rays with equal keys
	// point the same way, so the order among them doesn't change the polygon)
	byKey :: proc(a, b: Ray) -> bool { return a.key < b.key }
	if !slice.is_sorted_by(rays[:even], byKey) do slice.sort_by(rays[:even], byKey)
	slice.sort_by(rays[even:], byKey)
	if even > 0 && even < len(rays) {
		merged := make([]Ray, len(rays), context.temp_allocator)
		i, j := 0, even
		for k in 0..<len(merged) {
			if j >= len(rays) || (i < even && rays[i].key <= rays[j].key) {
				merged[k] = rays[i]
				i += 1
			} else {
				merged[k] = rays[j]
				j += 1
			}
		}
		rays = merged
	}
	points := make([dynamic][2]f32, 0, len(rays), allocator)
	for r in rays {
		dir := [2]f32{math.cos(r.angle), math.sin(r.angle)}
		reach := s.radius
		for seg in segments {
			if t, hit := raySegment(center, dir, seg[0], seg[1]); hit && t < reach do reach = t
		}
		append(&points, center + dir * reach)
	}
	return points[:]
}

// Where a ray (origin + dir * t, t >= 0) meets a segment, if it does
@(private="file")
raySegment :: proc(origin, dir, a, b: [2]f32) -> (f32, bool) {
	edge := b - a
	denom := dir.x * edge.y - dir.y * edge.x
	if abs(denom) < 1e-9 do return 0, false
	d := a - origin
	t := (d.x * edge.y - d.y * edge.x) / denom
	u := (d.x * dir.y - d.y * dir.x) / denom
	// A little past the ends: a ray through a corner hits one of its edges (it slipped between
	// them, a bright sliver across the shadow)
	if t < 0 || u < -1e-4 || u > 1 + 1e-4 do return 0, false
	return t, true
}

// An occluder's outline in world coordinates (`world`: its world transform)
@(private="file")
occluderOutline :: proc(o: ^LightOccluder, world: Transform2D, allocator := context.temp_allocator) -> [][2]f32 {
	local := make([dynamic][2]f32, context.temp_allocator)
	switch o.shape {
	case .Rectangle, .Capsule:
		h := o.shape == .Capsule ? [2]f32{o.radius, o.size.y * 0.5} : o.size * 0.5
		append(&local, [2]f32{-h.x, -h.y}, [2]f32{h.x, -h.y}, [2]f32{h.x, h.y}, [2]f32{-h.x, h.y})
	case .Circle:
		for i in 0..<16 {
			a := f32(i) * math.TAU / 16
			append(&local, [2]f32{math.cos(a), math.sin(a)} * o.radius)
		}
	case .Polygon, .Segment:
		append(&local, ..o.points[:])
	}
	out := make([][2]f32, len(local), allocator)
	for p, i in local do out[i] = Transform2D_Apply(world, p)
	return out
}

// An outline that stops light, in world coordinates, and the box around it
@(private="file")
LightOutline :: struct {
	points: [][2]f32,
	closed: bool,
	lo, hi: [2]f32,
}

// The outlines that stop light in a scene: occluders', and static bodies' shapes if the scene
// says so (temp allocated). Gathered once for every light of a frame: each light walking the
// scene's nodes itself was a third of its time (2026-10-26, the demo's hollow: ten lights)
@(private="file")
lightOutlines :: proc(scene: ^Scene) -> []LightOutline {
	out := make([dynamic]LightOutline, context.temp_allocator)
	add :: proc(out: ^[dynamic]LightOutline, points: [][2]f32, closed: bool) {
		if len(points) == 0 do return
		lo, hi := points[0], points[0]
		for p in points do lo, hi = {min(lo.x, p.x), min(lo.y, p.y)}, {max(hi.x, p.x), max(hi.y, p.y)}
		append(out, LightOutline{points, closed, lo, hi})
	}
	for node in scene.nodes {
		if !Node_IsVisibleInTree(node) do continue
		if Node_Is(node, LightOccluder) {
			o := cast(^LightOccluder)node
			add(&out, occluderOutline(o, Node_GetWorldTransform(o)), o.shape != .Segment)
		} else if scene.lighting.bodyShadows && Node_Is(node, CollisionShape) {
			shape := cast(^CollisionShape)node
			if shape.disabled || shape.oneWay do continue
			body := shape.parent
			for body != nil && !Node_IsPhysicsBody(body) do body = body.parent
			if body == nil || !Node_Is(body, StaticBody) do continue
			o := LightOccluder{shape = shape.shape, size = shape.size, radius = shape.radius, points = shape.points}
			if shape.shape == .Capsule do o.size = {shape.radius * 2, shape.height}
			add(&out, occluderOutline(&o, Node_GetWorldTransform(shape)), shape.shape != .Segment)
		}
	}
	return out[:]
}

// The edges that stop a light near `center`: those of the outlines whose box is in its reach
@(private="file")
lightSegments :: proc(outlines: []LightOutline, center: [2]f32, radius: f32, out: ^[dynamic][2][2]f32) {
	for o in outlines {
		// Skip what's wholly out of reach
		if o.lo.x > center.x + radius || o.hi.x < center.x - radius || o.lo.y > center.y + radius || o.hi.y < center.y - radius do continue
		n := len(o.points)
		for i in 0..<n {
			if !o.closed && i == n - 1 do break
			append(out, [2][2]f32{o.points[i], o.points[(i + 1) % n]})
		}
	}
}

// Lights the world layers drawn so far: the light map (ambient + lights through `view`) multiplied
// over the screen. Called by Scene_DrawWithView after the last lit layer
@(private)
Lighting_Apply :: proc(scene: ^Scene, renderer: ^sdl.Renderer, view: Transform2D) {
	if renderer == nil || scene.game == nil do return
	// The screen's size: the logical presentation's, else the viewport's
	w, h: i32
	mode: sdl.RendererLogicalPresentation
	sdl.GetRenderLogicalPresentation(renderer, &w, &h, &mode)
	if mode == .DISABLED || w <= 0 || h <= 0 {
		viewport: sdl.Rect
		sdl.GetRenderViewport(renderer, &viewport)
		w, h = viewport.w, viewport.h
	}
	if w <= 0 || h <= 0 do return
	size := [2]f32{f32(w), f32(h)}
	l := &scene.lighting
	if l.target != nil && l.target.size != size {
		RenderTarget_Destroy(l.target)
		RenderTarget_Destroy(l.scratch)
		l.target, l.scratch = nil, nil
	}
	if l.target == nil {
		game := scene.game
		saved := game.renderer
		game.renderer = renderer
		l.target = RenderTarget_Create(game, size, smooth = true)
		l.scratch = RenderTarget_Create(game, size, smooth = true)
		game.renderer = saved
		if l.target == nil || l.scratch == nil do return
	}
	SetDrawState(TRANSFORM2D_IDENTITY)
	RenderTarget_Begin(renderer, l.target, clear = true, clearColor = {l.ambient.r, l.ambient.g, l.ambient.b, 255})
	sdl.SetTextureBlendMode(l.scratch.texture, sdl.BLENDMODE_ADD)
	// GPU renderers add each light's fan straight into the map: two target switches for the whole
	// map instead of two more per light (each switch can wait on the GPU: 1.1 ms a light on SDL's
	// Vulkan renderer). Only SDL's software renderer draws a fan's shared edges twice when
	// blending (bright seams), so it draws each fan alone into the scratch target first
	software := isSoftwareRenderer(renderer)
	if !software do sdl.SetRenderDrawBlendMode(renderer, sdl.BLENDMODE_ADD)
	full := sdl.FRect{0, 0, size.x, size.y}
	outlines: []LightOutline
	gathered := false
	for node in scene.nodes {
		if !Node_Is(node, Light2D) || !Node_IsVisibleInTree(node) do continue
		light := cast(^Light2D)node
		s := light.settings
		if s.radius <= 0 || s.energy <= 0 do continue
		center := Node_GetWorldPosition(light)
		base := node.layer in scene.screenLayers ? TRANSFORM2D_IDENTITY : view
		Trace_Begin("light_visibility")
		if s.shadows && !gathered do outlines, gathered = lightOutlines(scene), true
		ring := lightVisibility(light, outlines, context.temp_allocator)
		Trace_End()
		if len(ring) < 2 do continue
		bright := sdl.FColor{min(f32(s.color.r) / 255 * s.energy, 1), min(f32(s.color.g) / 255 * s.energy, 1), min(f32(s.color.b) / 255 * s.energy, 1), 1}
		vertices := make([dynamic]sdl.Vertex, 0, len(ring) + 1, context.temp_allocator)
		indices := make([dynamic]i32, 0, len(ring) * 3, context.temp_allocator)
		c := Transform2D_Apply(base, center)
		append(&vertices, sdl.Vertex{position = {c.x, c.y}, color = bright})
		for p in ring {
			// Linear falloff along each ray: the vertex's brightness by its distance
			t := clamp(1 - math.sqrt((p.x - center.x) * (p.x - center.x) + (p.y - center.y) * (p.y - center.y)) / s.radius, 0, 1)
			q := Transform2D_Apply(base, p)
			append(&vertices, sdl.Vertex{position = {q.x, q.y}, color = {bright.r * t, bright.g * t, bright.b * t, 1}})
		}
		n := i32(len(ring))
		last := s.kind == .Spot ? n - 1 : n
		for i in 0..<last do append(&indices, 0, i + 1, (i + 1) % n + 1)
		Trace_Scope("light_draw")
		if !software {
			sdl.RenderGeometry(renderer, nil, raw_data(vertices), i32(len(vertices)), raw_data(indices), i32(len(indices)))
			continue
		}
		// Drawn alone (overwriting), then added to the map
		sdl.SetRenderTarget(renderer, l.scratch.texture)
		sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
		sdl.RenderClear(renderer)
		sdl.SetRenderDrawBlendMode(renderer, sdl.BLENDMODE_NONE)
		sdl.RenderGeometry(renderer, nil, raw_data(vertices), i32(len(vertices)), raw_data(indices), i32(len(indices)))
		sdl.SetRenderTarget(renderer, l.target.texture)
		sdl.RenderTexture(renderer, l.scratch.texture, nil, &full)
	}
	sdl.SetRenderDrawBlendMode(renderer, sdl.BLENDMODE_BLEND)
	sdl.SetTextureBlendMode(l.scratch.texture, sdl.BLENDMODE_BLEND)
	Trace_Begin("light_map")
	RenderTarget_End(renderer, l.target)
	sdl.SetTextureBlendMode(l.target.texture, sdl.BLENDMODE_MOD)
	dst := sdl.FRect{0, 0, size.x, size.y}
	sdl.RenderTexture(renderer, l.target.texture, nil, &dst)
	sdl.SetTextureBlendMode(l.target.texture, sdl.BLENDMODE_BLEND)
	Trace_End()
}

// Frees the scene's light map (Scene_Destroy)
@(private)
Lighting_Destroy :: proc(scene: ^Scene) {
	RenderTarget_Destroy(scene.lighting.target)
	RenderTarget_Destroy(scene.lighting.scratch)
	scene.lighting.target, scene.lighting.scratch = nil, nil
}
