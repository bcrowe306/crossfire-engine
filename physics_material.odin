package crossfire

import "core:encoding/xml"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import b2 "box2d"

/*
Physics materials: a body's surface (friction, bounce) and density in one shared asset, so every
ice block, rubber ball or crate in a game feels the same and changes in one place.

A material is an asset of kind "PhysicsMaterial", a `.material.xml` file:

	<material formatVersion="13" friction="0.05" restitution="0" density="0.9"/>

A body names one with `material` in its scene file (`<node kind="DynamicBody" material=
"materials/ice.material.xml"/>`): the material's values replace the body's own `friction`,
`restitution` and `density`. Bodies without one keep theirs. Games read each file once
(`Game_LoadPhysicsMaterial`, `Game.physicsMaterials`); editors put their unsaved materials there
before building. From code: `PhysicsBody_SetMaterial`.
*/

// A body's surface and density, shared by the bodies that name it
PhysicsMaterial :: struct {
	// Surface friction: 0 = ice, 1 = rubber
	friction: f32 `min:"0" max:"2"`,
	// Bounciness: 0 none, 1 bounces back as high
	restitution: f32 `min:"0" max:"1"`,
	// kg per square meter (100 x 100 px), for dynamic bodies' mass
	density: f32 `min:"0" max:"100"`,
}

// A material with a body's defaults
DEFAULT_PHYSICS_MATERIAL :: PhysicsMaterial{friction = 0.6, restitution = 0, density = 1}

/*
Reads a material file.

Returns:
- The material (fields it lacks keep DEFAULT_PHYSICS_MATERIAL's), and an error for a file that
  isn't one or is from a newer format

Example:
	material, err := e.ParsePhysicsMaterial(`<material friction="0.05"/>`)
*/
ParsePhysicsMaterial :: proc(text: string) -> (PhysicsMaterial, ProjectError) {
	doc, err := xml.parse_string(text)
	if err != .None do return {}, .Invalid_XML
	defer xml.destroy(doc)
	if doc.element_count == 0 || doc.elements[0].ident != "material" do return {}, .Invalid_XML
	m := DEFAULT_PHYSICS_MATERIAL
	for a in doc.elements[0].attribs {
		v, ok := strconv.parse_f32(a.val)
		switch a.key {
		case "formatVersion":
			if n, isInt := strconv.parse_int(a.val); isInt && n > PROJECT_FORMAT_VERSION do return {}, .Unsupported_Version
		case "friction":    if ok do m.friction = max(v, 0)
		case "restitution": if ok do m.restitution = clamp(v, 0, 1)
		case "density":     if ok do m.density = max(v, 0)
		}
	}
	return m, .None
}

/*
Writes a material file.

Returns:
- The file's text (allocated with `allocator`)
*/
FormatPhysicsMaterial :: proc(m: PhysicsMaterial, allocator := context.allocator) -> string {
	return fmt.aprintf(`<material formatVersion="%d" friction="%v" restitution="%v" density="%v"/>` + "\n",
		PROJECT_FORMAT_VERSION, m.friction, m.restitution, m.density, allocator = allocator)
}

/*
A material asset, read once per game (tools put their unsaved materials in
`game.physicsMaterials` first).

Inputs:
- game: The game
- path: The `.material.xml` file, relative to the project

Returns:
- The material, and false when it couldn't be read
*/
Game_LoadPhysicsMaterial :: proc(game: ^Game, path: string) -> (PhysicsMaterial, bool) {
	if game == nil || path == "" do return {}, false
	if found, ok := game.physicsMaterials[path]; ok {
		if found == nil do return {}, false
		return found^, true
	}
	allocator := Game_GetAllocator(game)
	if game.physicsMaterials == nil do game.physicsMaterials = make(map[string]^PhysicsMaterial, allocator)
	full := JoinPath(game.projectDir, path)
	text, read := Platform_ReadFile(full)
	result: ^PhysicsMaterial
	if !read {
		log.errorf("Couldn't read physics material %s", full)
	} else if parsed, err := ParsePhysicsMaterial(string(text)); err != .None {
		log.errorf("Couldn't load physics material %s: %v", full, err)
	} else {
		result = new_clone(parsed, allocator)
	}
	game.physicsMaterials[strings.clone(path, allocator)] = result
	if result == nil do return {}, false
	return result^, true
}

/*
Gives a body a material's surface and density, its shapes too when its Box2D body exists (a
dynamic body's mass follows).

Example:
	// Given: puck: ^e.DynamicBody
	e.PhysicsBody_SetMaterial(puck, {friction = 0.02, restitution = 0.9, density = 0.5})
*/
PhysicsBody_SetMaterial :: proc(body: ^PhysicsBody, m: PhysicsMaterial) {
	if body == nil do return
	body.friction = m.friction
	body.restitution = m.restitution
	body.density = m.density
	if !b2.Body_IsValid(body.bodyId) do return
	count := b2.Body_GetShapeCount(body.bodyId)
	if count <= 0 do return
	shapes := b2.Body_GetShapes(body.bodyId, make([]b2.ShapeId, count, context.temp_allocator))
	for shape in shapes {
		b2.Shape_SetFriction(shape, m.friction)
		b2.Shape_SetRestitution(shape, m.restitution)
		b2.Shape_SetDensity(shape, m.density, true)
	}
}
