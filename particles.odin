package engine

import "core:c"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:reflect"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

/*
Particle emitters: a `ParticleEmitter` node emits particles from its position, moves them
(velocity, acceleration, gravity, wind, spin), changes their size and color over their life
(a start and end color, or a `ColorRamp` of up to MAX_COLOR_STOPS colors) and draws them as
circles, ellipses, rectangles, pixels, lines, a texture, or with code.

Its `settings` (`ParticleSettings`) say how; scene files store the ones that differ from
`DEFAULT_PARTICLE_SETTINGS` in a `<particles>` element (project_format.odin). Their struct tags
(`min`, `max`, `label`, `group`) describe them for editors: `ParticleSettings_Fields`.

Emission runs in cycles of `lifetime` seconds: each cycle emits `amount` particles, spread over
the first `1 - burst` of it (`burst` 1: all at once). A `continuous` emitter starts a new cycle
when one ends; otherwise it stops (`ParticleEmitter_Start` runs it again). A particle lives
`lifetime` seconds too.

Particles move in the world (they stay behind when the emitter moves; their direction turns with
its world rotation), or in its local space with `localSpace` (they move, turn and scale with it).
Angles are degrees clockwise from +X, like rotations; `angle` 270 is up.

Randomness: each `xSpread` is a range around the base value, used in proportion to `xVariance`
(0: none, 1: all of it). `spread` is the half-size of the area particles start in.

Collisions (`collisionEnabled`): particles bounce off each other and, in world space, off the
edges of what the camera shows (or the game area without a camera), keeping `elasticity` of
their speed. It compares every pair of live particles: keep `amount` low with it.

Example:
	sparks := e.CreateParticleEmitter(scene)
	sparks.position = {400, 300}
	sparks.settings.amount = 80
	sparks.settings.angle = 270
	sparks.settings.angleSpread = 40
	sparks.settings.angleVariance = 1
	sparks.settings.shape = .Rectangle

	// A one-shot burst, e.g. an explosion
	boom := e.CreateParticleEmitter(scene)
	boom.settings.burst = 1
	boom.settings.continuous = false
	e.ParticleEmitter_Start(boom)
*/

// Most colors a ColorRamp holds
MAX_COLOR_STOPS :: 8
// Most particles an emitter has alive at once; the oldest are reused past it
MAX_PARTICLES :: 1000

// A color at a point of a particle's life: `position` 0 is when it's emitted, 1 when it dies
ColorStop :: struct {
	position: f32,
	color: sdl.Color,
}

/*
Colors along a particle's life, blended between the stops (kept sorted by position). Scene files
store it as `position:#color` pairs: `"0:#ffe664 0.5:#e63228 1:#28282800"`.
*/
ColorRamp :: struct {
	stops: [MAX_COLOR_STOPS]ColorStop,
	count: int,
}

// Warm yellow when emitted, fiery red at mid-life, fading out at the end
DEFAULT_COLOR_RAMP :: ColorRamp{
	stops = {
		0 = {0, {255, 230, 100, 255}},
		1 = {0.5, {230, 50, 40, 255}},
		2 = {1, {40, 40, 40, 0}},
	},
	count = 3,
}

/*
The color of a ramp at a point of a particle's life.

Inputs:
- ramp: The ramp
- t: 0 (emitted) to 1 (dies); clamped

Returns:
- The blended color (white for an empty ramp)
*/
ColorRamp_Evaluate :: proc(ramp: ColorRamp, t: f32) -> sdl.Color {
	if ramp.count <= 0 do return {255, 255, 255, 255}
	if ramp.count == 1 do return ramp.stops[0].color
	t := math.clamp(t, 0, 1)
	if t <= ramp.stops[0].position do return ramp.stops[0].color
	last := ramp.stops[ramp.count - 1]
	if t >= last.position do return last.color
	for i in 0 ..< ramp.count - 1 {
		a, b := ramp.stops[i], ramp.stops[i + 1]
		if t < a.position || t > b.position do continue
		span := b.position - a.position
		local := span > 0.0001 ? (t - a.position) / span : 0
		return lerpColor(a.color, b.color, local)
	}
	return last.color
}

/*
Sorts a ramp's stops by position.

Inputs:
- ramp: The ramp
- tracking: Optional: a stop's index, updated to where that stop ends up (an editor's selection)
*/
ColorRamp_Sort :: proc(ramp: ^ColorRamp, tracking: ^int = nil) {
	for i in 1 ..< ramp.count {
		key := ramp.stops[i]
		keyTracked := tracking != nil && tracking^ == i
		j := i - 1
		for j >= 0 && ramp.stops[j].position > key.position {
			ramp.stops[j + 1] = ramp.stops[j]
			if tracking != nil && !keyTracked && tracking^ == j do tracking^ = j + 1
			j -= 1
		}
		ramp.stops[j + 1] = key
		if keyTracked do tracking^ = j + 1
	}
}

/*
Adds a stop (kept sorted).

Returns:
- Its index, or -1 if the ramp is full (MAX_COLOR_STOPS)
*/
ColorRamp_AddStop :: proc(ramp: ^ColorRamp, position: f32, color: sdl.Color) -> int {
	if ramp.count >= MAX_COLOR_STOPS do return -1
	index := ramp.count
	ramp.stops[index] = {math.clamp(position, 0, 1), color}
	ramp.count += 1
	ColorRamp_Sort(ramp, &index)
	return index
}

/*
Removes a stop. A ramp keeps at least two.

Returns:
- false if it wasn't removed
*/
ColorRamp_RemoveStop :: proc(ramp: ^ColorRamp, index: int) -> bool {
	if ramp.count <= 2 || index < 0 || index >= ramp.count do return false
	for i in index ..< ramp.count - 1 do ramp.stops[i] = ramp.stops[i + 1]
	ramp.count -= 1
	ramp.stops[ramp.count] = {}
	return true
}

// Formats a ramp the way scene files store it: "0:#ffe664 0.5:#e63228 1:#28282800"
FormatColorRamp :: proc(ramp: ColorRamp, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< clamp(ramp.count, 0, MAX_COLOR_STOPS) {
		if i > 0 do strings.write_byte(&b, ' ')
		fmt.sbprintf(&b, "%v:%s", ramp.stops[i].position, FormatColor(ramp.stops[i].color, context.temp_allocator))
	}
	return strings.to_string(b)
}

/*
Parses `position:#color` pairs separated by spaces (sorted afterwards; extra stops past
MAX_COLOR_STOPS are dropped).

Returns:
- The ramp, and false if a pair couldn't be read (it's skipped)
*/
ParseColorRamp :: proc(text: string) -> (ColorRamp, bool) {
	ramp: ColorRamp
	ok := true
	for part in strings.fields(text, context.temp_allocator) {
		positionText, _, colorText := strings.partition(part, ":")
		position, okPosition := strconv.parse_f32(positionText)
		color, okColor := ParseColor(colorText)
		if !okPosition || !okColor || ramp.count >= MAX_COLOR_STOPS {
			ok = false
			continue
		}
		ramp.stops[ramp.count] = {math.clamp(position, 0, 1), color}
		ramp.count += 1
	}
	ColorRamp_Sort(&ramp)
	return ramp, ok
}

// What a particle is drawn as
ParticleShape :: enum {
	// A circle of radius size.x
	Circle,
	// Radii size.x and size.y, turned by the particle's rotation
	Ellipse,
	// size.x by size.y, centered, turned by the particle's rotation
	Rectangle,
	// One screen pixel
	Pixel,
	// A line size.x long, scale.y thick, along the particle's rotation
	Line,
	// The emitter's texture, size.x by size.y, tinted by the particle's color
	Texture,
	// Drawn by the emitter's `customDraw` (a circle without one)
	Custom,
}

/*
How an emitter emits and what its particles do. Pixels, seconds and degrees (clockwise).

Each field's tags describe it for editors: `min` / `max` (the range a slider covers; code may go
outside it), `label`, and `group` on the first field of each group.
*/
ParticleSettings :: struct {
	// Emits from the start (otherwise ParticleEmitter_Start begins)
	emitting: bool `label:"Emitting" group:"Emission"`,
	// Starts a new cycle when one ends; otherwise stops after one
	continuous: bool `label:"Continuous"`,
	// Particles per cycle
	amount: int `min:"1" max:"500" label:"Amount"`,
	// Seconds a cycle lasts, and a particle lives
	lifetime: f32 `min:"0.01" max:"5" label:"Lifetime"`,
	// 0: particles are spread evenly over the cycle; 1: all emitted at once
	burst: f32 `min:"0" max:"1" label:"Burst"`,
	// Half-size of the area particles start in, around the emitter
	spread: [2]f32 `min:"0" max:"1280" label:"Spread"`,
	// Particles move with the emitter (its local space) instead of staying in the world
	localSpace: bool `label:"Local space"`,

	shape: ParticleShape `label:"Shape" group:"Shape"`,
	size: [2]f32 `min:"0.01" max:"100" label:"Size"`,
	sizeVariance: f32 `min:"0" max:"1" label:"Size var."`,
	sizeSpread: f32 `min:"0" max:"50" label:"Size spread"`,
	// Scale at birth and at death, blended over the particle's life
	scaleStart: [2]f32 `min:"0" max:"1" label:"Scale start"`,
	scaleEnd: [2]f32 `min:"0" max:"1" label:"Scale end"`,

	// Starting rotation of each particle
	rotation: f32 `min:"0" max:"359" label:"Rotation" group:"Rotation"`,
	rotationVariance: f32 `min:"0" max:"1" label:"Rotation var."`,
	rotationSpread: f32 `min:"0" max:"359" label:"Rot. spread"`,
	// Spin, degrees per second, and how fast the spin changes
	torque: f32 `min:"-2000" max:"2000" label:"Torque"`,
	torqueVariance: f32 `min:"0" max:"1" label:"Torque var."`,
	torqueSpread: f32 `min:"0" max:"2000" label:"Torque spread"`,
	torqueAcceleration: f32 `min:"-2000" max:"2000" label:"Torque accel."`,

	// Colors from colorRamp; otherwise from particleColor to colorEnd
	useColorRamp: bool `label:"Color ramp" group:"Color"`,
	colorRamp: ColorRamp `label:"Ramp"`,
	particleColor: sdl.Color `label:"Start color"`,
	colorEnd: sdl.Color `label:"End color"`,
	// Random change of each particle's red, green and blue
	colorVariance: f32 `min:"0" max:"1" label:"Color var."`,

	// Direction particles are emitted in
	angle: f32 `min:"0" max:"359" label:"Angle" group:"Motion"`,
	angleVariance: f32 `min:"0" max:"1" label:"Angle var."`,
	angleSpread: f32 `min:"0" max:"360" label:"Angle spread"`,
	// Starting speed, px/s
	velocity: f32 `min:"0" max:"2000" label:"Velocity"`,
	velocityVariance: f32 `min:"0" max:"1" label:"Velocity var."`,
	velocitySpread: f32 `min:"0" max:"2000" label:"Vel. spread"`,
	// Multiplies how far particles move each frame
	velocityScale: f32 `min:"0" max:"10" label:"Speed scale"`,
	// Speeds particles up (or down) along their emitted direction, px/s²
	acceleration: f32 `min:"-2000" max:"2000" label:"Acceleration"`,

	// Gravity's direction (normalized when used) and strength, px/s²
	gravityDirection: [2]f32 `min:"-1" max:"1" label:"Gravity dir." group:"Forces"`,
	gravityVelocity: f32 `min:"-2000" max:"2000" label:"Gravity"`,
	// Pushes every particle, px/s²
	wind: [2]f32 `min:"-1000" max:"1000" label:"Wind"`,

	collisionEnabled: bool `label:"Collide" group:"Collision"`,
	// Speed kept after a bounce
	elasticity: f32 `min:"0" max:"1" label:"Elasticity"`,
}

// The settings of a new emitter, and of attributes a scene file leaves out
DEFAULT_PARTICLE_SETTINGS :: ParticleSettings{
	emitting = true,
	continuous = true,
	amount = 50,
	lifetime = 2,
	shape = .Circle,
	size = {5, 5},
	scaleStart = {1, 1},
	scaleEnd = {1, 1},
	useColorRamp = true,
	colorRamp = DEFAULT_COLOR_RAMP,
	particleColor = {255, 255, 255, 255},
	colorEnd = {255, 255, 255, 255},
	velocity = 100,
	velocityScale = 1,
	gravityDirection = {0, 1},
	gravityVelocity = 200,
	elasticity = 0.7,
}

// One particle, in the emitter's world or local space (`ParticleSettings.localSpace`)
Particle :: struct {
	position: [2]f32,
	velocity: [2]f32,
	acceleration: [2]f32,
	size: [2]f32,
	scaleStart: [2]f32,
	scaleEnd: [2]f32,
	scale: [2]f32,
	// Degrees, clockwise; torque is its spin (degrees per second)
	rotation: f32,
	torque: f32,
	torqueAcceleration: f32,
	// Seconds it lives, has lived, and the fraction of its life gone (0 to 1)
	lifetime: f32,
	age: f32,
	agePercent: f32,
	// Without a color ramp: blended from colorStart to colorEnd
	colorStart: sdl.Color,
	colorEnd: sdl.Color,
	// Random change of red, green and blue (colorVariance), kept for its whole life
	colorJitter: [3]f32,
	color: sdl.Color,
	alive: bool,
}

/*
A node that emits particles (see the top of particles.odin). Change `settings` at any time; new
particles use the new values, and live ones the forces and colors.
*/
ParticleEmitter :: struct {
	using node: Node,
	settings: ParticleSettings,
	// Emitting now (`settings.emitting` is how it starts; a non-continuous emitter stops after a cycle)
	emitting: bool,
	// For the Texture shape
	texture: ^sdl.Texture,
	/*
	For the Custom shape: draws one particle. The draw state is the particle's space, so the
	Draw* helpers draw at it (origin at the particle, turned by its rotation; sizes aren't
	scaled: use `particle.size * particle.scale`).
	*/
	customDraw: proc(emitter: ^ParticleEmitter, particle: ^Particle, renderer: ^sdl.Renderer),
	// MAX_PARTICLES slots, used as a ring (in the node's arena)
	particles: []Particle,
	// The current cycle: seconds since it started, time toward the next emission, particles emitted
	cycleTime: f32,
	emitTimer: f32,
	emittedInCycle: int,
	cycleStarted: bool,
	// The slot the next particle goes in
	head: int,
}

/*
Creates a particle emitter.

Inputs:
- scene: The scene
- settings: How it emits (DEFAULT_PARTICLE_SETTINGS unless given)

Returns:
- The emitter; it starts emitting on the scene's next update if `settings.emitting`
*/
CreateParticleEmitter :: proc(scene: ^Scene, settings := DEFAULT_PARTICLE_SETTINGS) -> ^ParticleEmitter {
	emitter := CreateNode(scene, ParticleEmitter)
	emitter.settings = settings
	emitter.emitting = settings.emitting
	emitter.particles = make([]Particle, MAX_PARTICLES, Node_GetAllocator(emitter))
	emitter.update = particleEmitterUpdate
	emitter.draw = particleEmitterDraw
	emitter.getBounds = particleEmitterBounds
	return emitter
}

// Starts emitting: a new cycle begins now (live particles carry on)
ParticleEmitter_Start :: proc(emitter: ^ParticleEmitter) {
	emitter.emitting = true
	emitter.cycleStarted = false
	emitter.cycleTime = 0
	emitter.emitTimer = 0
	emitter.emittedInCycle = 0
}

// Stops emitting; live particles finish their lives
ParticleEmitter_Stop :: proc(emitter: ^ParticleEmitter) {
	emitter.emitting = false
	emitter.cycleStarted = false
}

// Removes every live particle
ParticleEmitter_Clear :: proc(emitter: ^ParticleEmitter) {
	for &p in emitter.particles do p.alive = false
}

// How many particles are alive
ParticleEmitter_AliveCount :: proc(emitter: ^ParticleEmitter) -> int {
	count := 0
	for p in emitter.particles do if p.alive do count += 1
	return count
}

/*
Moves the emitter on by `deltaTime` seconds: moves every particle, then emits. Its node's update
does this each frame; call it yourself only for an emitter outside a scene.
*/
ParticleEmitter_Update :: proc(emitter: ^ParticleEmitter, deltaTime: f32) {
	s := &emitter.settings
	// Live particles move first, so new ones start this frame at age 0 (and those emitted at the
	// start of a cycle die as the next one starts)
	gravity: [2]f32
	if lengthSquared := s.gravityDirection.x * s.gravityDirection.x + s.gravityDirection.y * s.gravityDirection.y; lengthSquared > 0.0001 {
		gravity = s.gravityDirection / math.sqrt(lengthSquared) * s.gravityVelocity
	}
	for &p in emitter.particles {
		if !p.alive do continue
		p.velocity += (gravity + s.wind + p.acceleration) * deltaTime
		p.torque += p.torqueAcceleration * deltaTime
		p.rotation += p.torque * deltaTime
		p.position += p.velocity * deltaTime * s.velocityScale
		p.age += deltaTime
		p.agePercent = math.clamp(p.age / max(p.lifetime, 0.0001), 0, 1)
		p.scale = {math.lerp(p.scaleStart.x, p.scaleEnd.x, p.agePercent), math.lerp(p.scaleStart.y, p.scaleEnd.y, p.agePercent)}
		p.color = particleColorAt(s, &p)
		if p.age >= p.lifetime {
			p.alive = false
			p.agePercent = 1
		}
	}

	if emitter.emitting {
		amount := max(s.amount, 0)
		cycle := max(s.lifetime, 0.0001)
		burst := math.clamp(s.burst, 0, 1)
		emitDuration := cycle * (1 - burst)
		interval := amount > 0 ? emitDuration / f32(amount) : 0
		begin :: proc(emitter: ^ParticleEmitter, interval: f32) {
			// So the first particle comes at the very start of the cycle
			emitter.emitTimer = interval
			emitter.emittedInCycle = 0
			emitter.cycleStarted = true
		}

		if !emitter.cycleStarted {
			emitter.cycleTime = 0
			begin(emitter, interval)
		} else {
			emitter.cycleTime += deltaTime
			if emitter.cycleTime >= cycle {
				if s.continuous {
					emitter.cycleTime = math.mod(emitter.cycleTime, cycle)
					begin(emitter, interval)
				} else {
					ParticleEmitter_Stop(emitter)
				}
			}
		}

		if emitter.emitting && emitter.emittedInCycle < amount {
			world := Node_GetWorldTransform(emitter)
			if burst >= 1 || emitDuration <= 0.0001 {
				for emitter.emittedInCycle < amount {
					emitParticle(emitter, world)
					emitter.emittedInCycle += 1
				}
			} else if interval > 0.00001 {
				emitter.emitTimer += deltaTime
				for emitter.emitTimer >= interval && emitter.emittedInCycle < amount {
					emitParticle(emitter, world)
					emitter.emittedInCycle += 1
					emitter.emitTimer -= interval
				}
			}
		}
	}
	if s.collisionEnabled do collideParticles(emitter)
}

/*
The settings' fields, for editors: name, type and the tags (`min`, `max`, `label`, `group`).
Temp allocated.
*/
ParticleSettings_Fields :: proc() -> []ParticleFieldInfo {
	fields := reflect.struct_fields_zipped(ParticleSettings)
	infos := make([]ParticleFieldInfo, len(fields), context.temp_allocator)
	for field, i in fields {
		info := ParticleFieldInfo{name = field.name, type = field.type.id}
		info.label = string(reflect.struct_tag_get(field.tag, "label"))
		if info.label == "" do info.label = field.name
		info.group = string(reflect.struct_tag_get(field.tag, "group"))
		if text, ok := reflect.struct_tag_lookup(field.tag, "min"); ok do info.min, _ = strconv.parse_f32(string(text))
		if text, ok := reflect.struct_tag_lookup(field.tag, "max"); ok {
			info.max, _ = strconv.parse_f32(string(text))
			info.ranged = true
		}
		infos[i] = info
	}
	return infos
}

// A ParticleSettings field, described by its tags (`ParticleSettings_Fields`)
ParticleFieldInfo :: struct {
	name: string,
	type: typeid,
	label: string,
	// Set on the first field of each group
	group: string,
	// The slider range (when `ranged`)
	min, max: f32,
	ranged: bool,
}

/*
A setting's value as scene files store it (numbers, `true`/`false`, "x,y", `#rrggbb[aa]`, enum
names, a ramp's `position:#color` pairs).

Returns:
- The text (temp allocated), and false for an unknown name
*/
ParticleSettings_Get :: proc(settings: ParticleSettings, name: string) -> (string, bool) {
	settings := settings
	value := reflect.struct_field_value_by_name(settings, name)
	if value.data == nil do return "", false
	switch v in value {
	case f32: return fmt.tprintf("%v", v), true
	case int: return fmt.tprintf("%d", v), true
	case bool: return v ? "true" : "false", true
	case [2]f32: return fmt.tprintf("%v,%v", v.x, v.y), true
	case sdl.Color: return FormatColor(v, context.temp_allocator), true
	case ParticleShape: return fmt.tprintf("%v", v), true
	case ColorRamp: return FormatColorRamp(v, context.temp_allocator), true
	}
	return "", false
}

/*
Sets a setting from text (the format of `ParticleSettings_Get`).

Returns:
- false if the name is unknown or the text isn't a value for it (nothing changes)
*/
ParticleSettings_Set :: proc(settings: ^ParticleSettings, name, text: string) -> bool {
	field := reflect.struct_field_by_name(ParticleSettings, name)
	if field.type == nil do return false
	at := rawptr(uintptr(settings) + field.offset)
	text := strings.trim_space(text)
	switch field.type.id {
	case f32:
		v := strconv.parse_f32(text) or_return
		(cast(^f32)at)^ = v
	case int:
		v := strconv.parse_int(text) or_return
		(cast(^int)at)^ = v
	case bool:
		switch text {
		case "true", "1": (cast(^bool)at)^ = true
		case "false", "0": (cast(^bool)at)^ = false
		case: return false
		}
	case [2]f32:
		xs, _, ys := strings.partition(text, ",")
		x := strconv.parse_f32(strings.trim_space(xs)) or_return
		y := strconv.parse_f32(strings.trim_space(ys)) or_return
		(cast(^[2]f32)at)^ = {x, y}
	case sdl.Color:
		(cast(^sdl.Color)at)^ = ParseColor(text) or_return
	case ParticleShape:
		(cast(^ParticleShape)at)^ = reflect.enum_from_name(ParticleShape, text) or_return
	case ColorRamp:
		ramp, ok := ParseColorRamp(text)
		if !ok || ramp.count == 0 do return false
		(cast(^ColorRamp)at)^ = ramp
	case:
		return false
	}
	return true
}

/*
The settings that differ from DEFAULT_PARTICLE_SETTINGS, as name/value text in field order: the
attributes of a scene file's `<particles>` element.

Returns:
- The pairs (temp allocated)
*/
FormatParticleSettings :: proc(settings: ParticleSettings) -> []ScriptPropData {
	pairs := make([dynamic]ScriptPropData, context.temp_allocator)
	for field in reflect.struct_fields_zipped(ParticleSettings) {
		value, _ := ParticleSettings_Get(settings, field.name)
		defaultValue, _ := ParticleSettings_Get(DEFAULT_PARTICLE_SETTINGS, field.name)
		if value != defaultValue do append(&pairs, ScriptPropData{field.name, value})
	}
	return pairs[:]
}

// INTERNAL

@(private="file")
particleEmitterUpdate :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	ParticleEmitter_Update(cast(^ParticleEmitter)node, f32(deltaTime))
}

@(private="file")
emitParticle :: proc(emitter: ^ParticleEmitter, world: Transform2D) {
	s := &emitter.settings
	p := &emitter.particles[emitter.head]
	emitter.head = (emitter.head + 1) % len(emitter.particles)
	around :: proc(value, spread: f32) -> f32 {
		return spread > 0 ? value + rand.float32_range(-spread, spread) : value
	}

	offset := [2]f32{around(0, s.spread.x), around(0, s.spread.y)}
	angle := around(s.angle, s.angleSpread * s.angleVariance)
	if s.localSpace {
		p.position = offset
	} else {
		p.position = Transform2D_Apply(world, offset)
		angle += Transform2D_Rotation(world)
	}
	sizeSpread := s.sizeSpread * s.sizeVariance
	p.size = {around(s.size.x, sizeSpread), around(s.size.y, sizeSpread)}
	p.scaleStart, p.scaleEnd, p.scale = s.scaleStart, s.scaleEnd, s.scaleStart
	p.rotation = around(s.rotation, s.rotationSpread * s.rotationVariance)
	p.torque = around(s.torque, s.torqueSpread * s.torqueVariance)
	p.torqueAcceleration = s.torqueAcceleration

	radians := math.to_radians(angle)
	direction := [2]f32{math.cos(radians), math.sin(radians)}
	p.velocity = direction * around(s.velocity, s.velocitySpread * s.velocityVariance)
	p.acceleration = direction * s.acceleration
	p.lifetime = s.lifetime
	p.age, p.agePercent = 0, 0

	p.colorJitter = {}
	if s.colorVariance > 0 {
		v := s.colorVariance
		p.colorJitter = {rand.float32_range(-v, v) * 255, rand.float32_range(-v, v) * 255, rand.float32_range(-v, v) * 255}
	}
	p.colorStart = jitter(s.particleColor, p.colorJitter)
	p.colorEnd = jitter(s.colorEnd, p.colorJitter)
	p.color = particleColorAt(s, p)
	p.alive = true
}

// A particle's color at its age
@(private="file")
particleColorAt :: proc(s: ^ParticleSettings, p: ^Particle) -> sdl.Color {
	if s.useColorRamp do return jitter(ColorRamp_Evaluate(s.colorRamp, p.agePercent), p.colorJitter)
	return lerpColor(p.colorStart, p.colorEnd, p.agePercent)
}

@(private="file")
jitter :: proc(color: sdl.Color, offset: [3]f32) -> sdl.Color {
	if offset == {} do return color
	return {
		u8(math.clamp(f32(color.r) + offset.x, 0, 255)),
		u8(math.clamp(f32(color.g) + offset.y, 0, 255)),
		u8(math.clamp(f32(color.b) + offset.z, 0, 255)),
		color.a,
	}
}

@(private="file")
lerpColor :: proc(a, b: sdl.Color, t: f32) -> sdl.Color {
	mix :: proc(x, y: u8, t: f32) -> u8 { return u8(math.clamp(math.lerp(f32(x), f32(y), t) + 0.5, 0, 255)) }
	return {mix(a.r, b.r, t), mix(a.g, b.g, t), mix(a.b, b.b, t), mix(a.a, b.a, t)}
}

// Bounces live particles off each other and, in world space, off the edges of the view
@(private="file")
collideParticles :: proc(emitter: ^ParticleEmitter) {
	s := &emitter.settings
	live := make([dynamic]int, 0, 64, context.temp_allocator)
	for p, i in emitter.particles do if p.alive do append(&live, i)
	radius :: proc(p: ^Particle) -> f32 {
		r := p.size.x * (p.scale.x > 0 ? p.scale.x : 1) * 0.5
		return r <= 0.01 ? 1 : r
	}

	for a, n in live {
		pa := &emitter.particles[a]
		ra := radius(pa)
		for b in live[n + 1:] {
			pb := &emitter.particles[b]
			minDistance := ra + radius(pb)
			delta := pb.position - pa.position
			distanceSquared := delta.x * delta.x + delta.y * delta.y
			if distanceSquared >= minDistance * minDistance || distanceSquared <= 0.0001 do continue
			distance := math.sqrt(distanceSquared)
			normal := delta / distance
			overlap := minDistance - distance
			pa.position -= normal * (overlap * 0.5)
			pb.position += normal * (overlap * 0.5)
			relative := pb.velocity - pa.velocity
			along := relative.x * normal.x + relative.y * normal.y
			if along < 0 {
				impulse := -(1 + s.elasticity) * along * 0.5
				pa.velocity -= normal * impulse
				pb.velocity += normal * impulse
			}
		}
	}

	// The edges of what the camera shows, in the world (particles in local space have none)
	if s.localSpace || emitter.scene == nil || emitter.scene.game == nil do return
	size := emitter.scene.game.size
	lo, hi := [2]f32{0, 0}, size
	if camera := emitter.scene.camera; camera != nil {
		toWorld := Transform2D_Inverse(Camera2D_ViewTransform(camera))
		lo, hi = max(f32), min(f32)
		for corner in ([4][2]f32{{0, 0}, {size.x, 0}, {0, size.y}, size}) {
			p := Transform2D_Apply(toWorld, corner)
			lo, hi = {min(lo.x, p.x), min(lo.y, p.y)}, {max(hi.x, p.x), max(hi.y, p.y)}
		}
	}
	for i in live {
		p := &emitter.particles[i]
		r := radius(p)
		for axis in 0 ..< 2 {
			if p.position[axis] - r < lo[axis] {
				p.position[axis] = lo[axis] + r
				p.velocity[axis] = -p.velocity[axis] * s.elasticity
			} else if p.position[axis] + r > hi[axis] {
				p.position[axis] = hi[axis] - r
				p.velocity[axis] = -p.velocity[axis] * s.elasticity
			}
		}
	}
}

/*
Draws every live particle. Shapes are batched into one geometry call (the texture's into
another); custom ones are drawn one by one by `customDraw`.
*/
@(private="file")
particleEmitterDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	emitter := cast(^ParticleEmitter)node
	s := &emitter.settings
	base, tint := drawState().transform, drawState().tint
	// Particle space to the screen: the node's (local space), or the world's
	view := base
	if !s.localSpace {
		world := Node_GetRenderWorldTransform(node)
		if abs(world.x.x * world.y.y - world.y.x * world.x.y) < 1e-12 do return
		view = Transform2D_Multiply(base, Transform2D_Inverse(world))
	}
	viewScale := Transform2D_UniformScale(view)

	vertices := make([dynamic]sdl.Vertex, 0, 256, context.temp_allocator)
	indices := make([dynamic]c.int, 0, 512, context.temp_allocator)
	useTexture := s.shape == .Texture && emitter.texture != nil

	for &particle in emitter.particles {
		if !particle.alive do continue
		p := &particle
		color := multiplyColor(p.color, tint)
		if color.a == 0 do continue
		fc := sdl.FColor{f32(color.r) / 255, f32(color.g) / 255, f32(color.b) / 255, f32(color.a) / 255}
		size := p.size * p.scale
		// The particle's own space: at its position, turned by its rotation
		space := Transform2D_Multiply(view, Transform2D_Make(p.position, p.rotation, {1, 1}))

		shape := s.shape
		if shape == .Texture && !useTexture do shape = .Rectangle
		if shape == .Custom && emitter.customDraw == nil do shape = .Circle
		switch shape {
		case .Circle, .Ellipse:
			rx := size.x
			ry := shape == .Circle ? size.x : size.y
			segments := clamp(int(max(rx, ry) * viewScale * 0.5), 8, 32)
			first := c.int(len(vertices))
			append(&vertices, sdl.Vertex{position = toFPoint(Transform2D_Apply(space, {0, 0})), color = fc})
			for k in 0 ..< segments {
				a := f32(k) / f32(segments) * math.TAU
				append(&vertices, sdl.Vertex{position = toFPoint(Transform2D_Apply(space, {math.cos(a) * rx, math.sin(a) * ry})), color = fc})
			}
			for k in 0 ..< segments {
				append(&indices, first, first + 1 + c.int(k), first + 1 + c.int((k + 1) % segments))
			}
		case .Rectangle, .Texture:
			h := size * 0.5
			corners := [4][2]f32{{-h.x, -h.y}, {h.x, -h.y}, {h.x, h.y}, {-h.x, h.y}}
			uvs := [4]sdl.FPoint{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
			addQuad(&vertices, &indices, space, corners, uvs, fc)
		case .Line:
			half := size.x * 0.5
			// At least a screen pixel thick
			thickness := max(p.scale.y, 1 / max(viewScale, 0.0001)) * 0.5
			corners := [4][2]f32{{-half, -thickness}, {half, -thickness}, {half, thickness}, {-half, thickness}}
			addQuad(&vertices, &indices, space, corners, {}, fc)
		case .Pixel:
			center := Transform2D_Apply(view, p.position)
			corners := [4][2]f32{center, center + {1, 0}, center + {1, 1}, center + {0, 1}}
			addQuad(&vertices, &indices, TRANSFORM2D_IDENTITY, corners, {}, fc)
		case .Custom:
			SetDrawState(space, tint)
			emitter.customDraw(emitter, p, renderer)
		}
	}
	SetDrawState(base, tint)
	if len(indices) == 0 do return
	if useTexture do sdl.SetTextureBlendMode(emitter.texture, GetDrawBlend())
	sdl.RenderGeometry(renderer, useTexture ? emitter.texture : nil, raw_data(vertices), c.int(len(vertices)), raw_data(indices), c.int(len(indices)))
}

@(private="file")
addQuad :: proc(vertices: ^[dynamic]sdl.Vertex, indices: ^[dynamic]c.int, space: Transform2D, corners: [4][2]f32, uvs: [4]sdl.FPoint, color: sdl.FColor) {
	first := c.int(len(vertices))
	for corner, k in corners {
		append(vertices, sdl.Vertex{position = toFPoint(Transform2D_Apply(space, corner)), color = color, tex_coord = uvs[k]})
	}
	append(indices, first, first + 1, first + 2, first, first + 2, first + 3)
}

@(private="file")
toFPoint :: proc(p: [2]f32) -> sdl.FPoint {
	return {p.x, p.y}
}

// Where particles start (the spread area) plus a particle's size: what an editor picks and outlines
@(private="file")
particleEmitterBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	s := &(cast(^ParticleEmitter)node).settings
	half := s.spread + max(s.size.x, s.size.y, 8)
	return {-half.x, -half.y, half.x * 2, half.y * 2}, true
}
