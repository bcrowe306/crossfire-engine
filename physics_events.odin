package engine

import b2 "box2d"

/*
Collision and area events: Box2D's contact and sensor events turned into node events, per body
pair.

Box2D reports a begin and an end per pair of shapes. Bodies with several shapes would hear about
the same body several times, so each body counts its contacts per other body
(`PhysicsBody.contacts`, and `areas` for the Areas it's in): `onCollisionEnter` when the first
shape pair starts touching, `onCollisionExit` when the last one stops. For an Area, its contacts
are the bodies inside it. A body hears about Areas with `onAreaEnter` / `onAreaExit`, and can ask
at any time (`PhysicsBody_GetAreas`, `PhysicsBody_IsInArea`: a list read, no world query).

When a body is removed, everything it touched (and every Area it was in, and every body inside
it, for an Area) gets its exit right away (`physicsForgetBody`). Box2D's own end events for
destroyed shapes come a step later with stale ids: the world's `shapes` table still knows which
body a destroyed shape belonged to (for shapes rebuilt on a living body) or has forgotten it (a
removed body: already handled).
*/

// One body's contacts with another, counted per shape pair (internal)
BodyContact :: struct {
	// The other body
	body: ^PhysicsBody,
	// Shape pairs touching now (it's removed from the list at 0)
	count: int,
}

// Who a Box2D shape belongs to (the world's shape table)
@(private)
ShapeOwner :: struct {
	body: ^PhysicsBody,
	// nil once the shape node is gone
	shape: ^CollisionShape,
	// Steps left before a destroyed shape's entry is dropped (its end events have come by then)
	expires: int,
}

/*
The Areas a body is inside right now. Updated by every physics step, from Box2D's sensor events.
Areas only see bodies on the layers in their mask.

Inputs:
- body: The body
- allocator: For the result (the frame's temp allocator by default)

Returns:
- The Areas, in the order it entered them

Example:
	// Given: hero: ^e.CharacterMover
	for area in e.PhysicsBody_GetAreas(hero) do if area.name == "Water" do hero.velocity *= 0.9
*/
PhysicsBody_GetAreas :: proc(body: ^PhysicsBody, allocator := context.temp_allocator) -> []^Area {
	areas := make([]^Area, len(body.areas), allocator)
	for contact, i in body.areas do areas[i] = cast(^Area)contact.body
	return areas
}

/*
Whether a body is inside an Area right now (a list read, no world query).

Inputs:
- body: The body
- area: The Area

Returns:
- true while any of their shapes overlap
*/
PhysicsBody_IsInArea :: proc(body: ^PhysicsBody, area: ^Area) -> bool {
	for contact in body.areas do if contact.body == area do return true
	return false
}

/*
Whether two bodies are touching right now (for an Area: whether `other` is inside it). A list
read, no world query.

Inputs:
- body: One body
- other: The other

Returns:
- true while any of their shapes touch
*/
PhysicsBody_IsTouching :: proc(body, other: ^PhysicsBody) -> bool {
	for contact in body.contacts do if contact.body == other do return true
	return false
}

/*
The bodies touching a body right now (for an Area: the bodies inside it). Updated by every
physics step; a CharacterMover's by its moves.

Inputs:
- body: The body
- allocator: For the result (the frame's temp allocator by default)

Returns:
- The bodies, in the order they started touching
*/
PhysicsBody_GetContacts :: proc(body: ^PhysicsBody, allocator := context.temp_allocator) -> []^PhysicsBody {
	bodies := make([]^PhysicsBody, len(body.contacts), allocator)
	for contact, i in body.contacts do bodies[i] = contact.body
	return bodies
}

// Box2D's events after a step, as node events
@(private)
sendEvents :: proc(world: ^PhysicsWorld) {
	ppm := world.settings.pixelsPerMeter
	contacts := b2.World_GetContactEvents(world.id)
	for event in contacts.beginEvents[:contacts.beginCount] {
		a, okA := world.shapes[event.shapeIdA]
		b, okB := world.shapes[event.shapeIdB]
		if !okA || !okB do continue
		point: [2]f32
		if event.manifold.pointCount > 0 do point = event.manifold.points[0].point * ppm
		beginTouch(a.body, b.body, a.shape, b.shape, point, event.manifold.normal)
	}
	for event in contacts.endEvents[:contacts.endCount] {
		a, okA := world.shapes[event.shapeIdA]
		b, okB := world.shapes[event.shapeIdB]
		if !okA || !okB do continue
		endTouch(a.body, b.body, a.shape, b.shape)
	}
	sensors := b2.World_GetSensorEvents(world.id)
	for event in sensors.beginEvents[:sensors.beginCount] {
		area, okA := world.shapes[event.sensorShapeId]
		visitor, okV := world.shapes[event.visitorShapeId]
		if !okA || !okV do continue
		beginOverlap(area.body, visitor.body, area.shape, visitor.shape)
	}
	for event in sensors.endEvents[:sensors.endCount] {
		area, okA := world.shapes[event.sensorShapeId]
		visitor, okV := world.shapes[event.visitorShapeId]
		if !okA || !okV do continue
		endOverlap(area.body, visitor.body, area.shape, visitor.shape)
	}

	// Destroyed shapes' events have been reported: forget them
	expired := make([dynamic]b2.ShapeId, context.temp_allocator)
	for id, &owner in world.shapes {
		if owner.expires == 0 do continue
		owner.expires -= 1
		if owner.expires == 0 do append(&expired, id)
	}
	for id in expired do delete_key(&world.shapes, id)
}

// A shape pair started touching
@(private)
beginTouch :: proc(a, b: ^PhysicsBody, shapeA, shapeB: ^CollisionShape, point, normal: [2]f32) {
	if a == nil || b == nil || a == b do return
	first := addContact(&a.contacts, b)
	addContact(&b.contacts, a)
	if !first do return
	notify(a, b, shapeA, shapeB, point, normal, .Collision_Enter)
	notify(b, a, shapeB, shapeA, point, -normal, .Collision_Enter)
}

// A shape pair stopped touching
@(private)
endTouch :: proc(a, b: ^PhysicsBody, shapeA, shapeB: ^CollisionShape) {
	if a == nil || b == nil || a == b do return
	last := removeContact(&a.contacts, b)
	removeContact(&b.contacts, a)
	if !last do return
	notify(a, b, shapeA, shapeB, {}, {}, .Collision_Exit)
	notify(b, a, shapeB, shapeA, {}, {}, .Collision_Exit)
}

// A visitor's shape entered an Area's
@(private="file")
beginOverlap :: proc(area, visitor: ^PhysicsBody, areaShape, visitorShape: ^CollisionShape) {
	if area == nil || visitor == nil do return
	first := addContact(&area.contacts, visitor)
	addContact(&visitor.areas, area)
	if !first do return
	notify(area, visitor, areaShape, visitorShape, {}, {}, .Collision_Enter)
	notify(visitor, area, visitorShape, areaShape, {}, {}, .Area_Enter)
}

@(private="file")
endOverlap :: proc(area, visitor: ^PhysicsBody, areaShape, visitorShape: ^CollisionShape) {
	if area == nil || visitor == nil do return
	last := removeContact(&area.contacts, visitor)
	removeContact(&visitor.areas, area)
	if !last do return
	notify(area, visitor, areaShape, visitorShape, {}, {}, .Collision_Exit)
	notify(visitor, area, visitorShape, areaShape, {}, {}, .Area_Exit)
}

/*
A CharacterMover's contacts come from its moves: Box2D makes no contacts between kinematic and
static bodies. The bodies its last move touched count as one contact each.
*/
@(private)
moverContacts :: proc(mover: ^CharacterMover, touched: []^PhysicsBody) {
	now := make([dynamic]^PhysicsBody, context.temp_allocator)
	for body in touched {
		known := false
		for b in now do if b == body do known = true
		if !known do append(&now, body)
	}
	for body in now {
		was := false
		for b in mover.touching do if b == body do was = true
		if !was do beginTouch(mover, body, nil, nil, {}, {})
	}
	for body in mover.touching {
		still := false
		for b in now do if b == body do still = true
		if !still do endTouch(mover, body, nil, nil)
	}
	clear(&mover.touching)
	append(&mover.touching, ..now[:])
}

/*
A body is being removed: whatever it touched, and the Areas it was in (the bodies inside it, for
an Area), get their exits now, and forget it.
*/
@(private)
physicsForgetBody :: proc(world: ^PhysicsWorld, body: ^PhysicsBody) {
	for len(body.contacts) > 0 {
		other := body.contacts[0].body
		dropContact(&body.contacts, other)
		dropContact(&other.contacts, body)
		if Node_Is(other, CharacterMover) do removeFromSlice(&(cast(^CharacterMover)other).touching, body)
		if Node_Is(body, Area) {
			// Bodies inside a removed Area leave it
			dropContact(&other.areas, body)
			notify(other, body, nil, nil, {}, {}, .Area_Exit)
		} else {
			notify(other, body, nil, nil, {}, {}, .Collision_Exit)
		}
	}
	for len(body.areas) > 0 {
		area := body.areas[0].body
		dropContact(&body.areas, area)
		dropContact(&area.contacts, body)
		notify(area, body, nil, nil, {}, {}, .Collision_Exit)
	}
	if Node_Is(body, CharacterMover) do clear(&(cast(^CharacterMover)body).touching)
	// Its shapes' late Box2D events have nothing to report to
	if b2.Body_IsValid(body.bodyId) {
		shapes: [64]b2.ShapeId
		for id in b2.Body_GetShapes(body.bodyId, shapes[:]) do delete_key(&world.shapes, id)
	}
	for id, owner in world.shapes do if owner.body == body do world.shapes[id] = {expires = 1}
}

@(private="file")
EventKind :: enum {
	Collision_Enter,
	Collision_Exit,
	Area_Enter,
	Area_Exit,
}

// Sends one side of an event: the body's event subject, then its script's hook
@(private="file")
notify :: proc(body, other: ^PhysicsBody, shape, otherShape: ^CollisionShape, point, normal: [2]f32, kind: EventKind) {
	if !body.inScene do return
	collision := Collision{body = body, other = other, shape = shape, otherShape = otherShape, point = point, normal = normal}
	subject: ^EventSubject
	switch kind {
	case .Collision_Enter: subject = &body.onCollisionEnter
	case .Collision_Exit:  subject = &body.onCollisionExit
	case .Area_Enter:      subject = &body.onAreaEnter
	case .Area_Exit:       subject = &body.onAreaExit
	}
	subject->notify(body, EventData(rawptr(&collision)))
	if info := body.script.info; info != nil {
		hook: proc(self: rawptr, collision: ^Collision)
		switch kind {
		case .Collision_Enter: hook = info.collisionEnter
		case .Collision_Exit:  hook = info.collisionExit
		case .Area_Enter:      hook = info.areaEnter
		case .Area_Exit:       hook = info.areaExit
		}
		if hook != nil do hook(body.script.data, &collision)
	}
}

// Counts one more contact with `other`. Returns whether it's the first
@(private="file")
addContact :: proc(list: ^[dynamic]BodyContact, other: ^PhysicsBody) -> bool {
	for &contact in list {
		if contact.body == other {
			contact.count += 1
			return false
		}
	}
	append(list, BodyContact{other, 1})
	return true
}

// Counts one contact less. Returns whether it was the last
@(private="file")
removeContact :: proc(list: ^[dynamic]BodyContact, other: ^PhysicsBody) -> bool {
	for &contact, i in list {
		if contact.body != other do continue
		contact.count -= 1
		if contact.count > 0 do return false
		ordered_remove(list, i)
		return true
	}
	return false
}

// Forgets every contact with `other`
@(private="file")
dropContact :: proc(list: ^[dynamic]BodyContact, other: ^PhysicsBody) {
	for contact, i in list {
		if contact.body == other {
			ordered_remove(list, i)
			return
		}
	}
}
