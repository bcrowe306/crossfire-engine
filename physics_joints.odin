package engine

import "core:log"
import "core:math"
import "core:math/linalg"
import b2 "box2d"

/*
Joints: a Joint node connects two bodies, at the node's position (its anchor).

- Body A is the body the joint is under (its nearest body ancestor) unless `bodyA` names one; with
  neither, it's the world itself (pin a body to a point in the world).
- Body B is named by `bodyB`: a node name or a path ("World/Crate"), found with
  `Scene_FindNode`.
- The joint is made when both bodies exist (the first physics sync after they enter the scene),
  from where the bodies are then: anchors, axes and angles are taken from that pose.

Kinds (`JointKind`), and what their settings mean:

	Revolute   a hinge or pin at the anchor. Limit: lower/upper angle (degrees). Motor: speed in
	           degrees per second, maxMotor torque in kg·px²/s². Spring: pulls back to the start angle
	Distance   keeps the anchor and `offset` (relative to the joint, on body B) apart: a rod, or
	           with limits a rope (lower/upper length in px), with a spring a spring.
	           Motor: speed in px/s along the line, maxMotor force in kg·px/s²
	Prismatic  body B slides along the joint's X axis (rotate the joint to aim it), without
	           turning. Limit: lower/upper translation (px). Motor: px/s and force
	Weld       glues the bodies together. A spring (hertz > 0) makes it bendy
	Wheel      body B slides along the joint's X axis on a spring (suspension) and turns freely:
	           the motor spins it (degrees per second, torque)

Springs: `hertz` is how stiff (cycles per second; 0 = off), `dampingRatio` how quickly it settles
(0 = bounces forever, 1 = no bounce).

When either body is removed, Box2D removes the joint with it.

Example:
	hinge := e.CreateJoint(scene, .Revolute)
	hinge.position = {300, 100}  // the pin, in the world (no body above it: body A is the world)
	hinge.bodyB = "Door"
	hinge.enableLimit, hinge.lower, hinge.upper = true, -90, 0
*/

JointKind :: enum {
	Revolute,
	Distance,
	Prismatic,
	Weld,
	Wheel,
}

Joint :: struct {
	using node: Node,
	kind: JointKind,
	// Name or path of body A ("" = the body the joint is under, or the world) and of body B
	bodyA: string,
	bodyB: string,
	// Distance: where body B's anchor is, relative to the joint (its length is the distance)
	offset: [2]f32,
	// Whether the two bodies still collide with each other
	collideConnected: bool,
	enableLimit: bool,
	// Revolute: degrees; Distance: lengths in px; Prismatic, Wheel: translations in px
	lower: f32,
	upper: f32,
	enableMotor: bool,
	// Revolute, Wheel: degrees per second; Distance, Prismatic: px/s
	motorSpeed: f32,
	// Revolute, Wheel: max torque (kg·px²/s²); Distance, Prismatic: max force (kg·px/s²)
	maxMotor: f32,
	enableSpring: bool,
	hertz: f32,
	dampingRatio: f32,

	// The Box2D joint (internal), and the bodies it connected
	jointId: b2.JointId,
	connectedA: ^PhysicsBody,
	connectedB: ^PhysicsBody,
	// Its bodies couldn't be found (reported once; not retried)
	failed: bool,
}

// Creates a Joint (set `bodyB`, and `position`: the anchor)
CreateJoint :: proc(scene: ^Scene, kind: JointKind) -> ^Joint {
	joint := CreateNode(scene, Joint)
	joint.kind = kind
	joint.offset = {0, 100}
	joint.dampingRatio = 0.5
	joint.hertz = 0
	world := Scene_GetPhysics(scene)
	append(&world.joints, joint)
	joint.destroy = proc(node: ^Node) {
		joint := cast(^Joint)node
		if b2.Joint_IsValid(joint.jointId) do b2.DestroyJoint(joint.jointId)
		if world := node.scene.physics; world != nil do removeFromSlice(&world.joints, joint)
	}
	return joint
}

// Whether the joint exists in the physics world (both bodies were found and are still there)
Joint_IsActive :: proc(joint: ^Joint) -> bool {
	return b2.Joint_IsValid(joint.jointId)
}

/*
Changes a joint's motor speed while it runs (degrees per second for Revolute and Wheel, px/s for
Distance and Prismatic). Turns the motor on.
*/
Joint_SetMotorSpeed :: proc(joint: ^Joint, speed: f32) {
	joint.motorSpeed, joint.enableMotor = speed, true
	if !b2.Joint_IsValid(joint.jointId) do return
	ppm := pixelsPerMeter(joint.scene)
	switch joint.kind {
	case .Revolute:
		b2.RevoluteJoint_EnableMotor(joint.jointId, true)
		b2.RevoluteJoint_SetMotorSpeed(joint.jointId, math.to_radians(speed))
	case .Wheel:
		b2.WheelJoint_EnableMotor(joint.jointId, true)
		b2.WheelJoint_SetMotorSpeed(joint.jointId, math.to_radians(speed))
	case .Prismatic:
		b2.PrismaticJoint_EnableMotor(joint.jointId, true)
		b2.PrismaticJoint_SetMotorSpeed(joint.jointId, speed / ppm)
	case .Distance:
		b2.DistanceJoint_EnableMotor(joint.jointId, true)
		b2.DistanceJoint_SetMotorSpeed(joint.jointId, speed / ppm)
	case .Weld:
	}
	b2.Joint_WakeBodies(joint.jointId)
}

// A Revolute joint's angle, degrees from where it started (clockwise)
Joint_GetAngle :: proc(joint: ^Joint) -> f32 {
	if joint.kind != .Revolute || !b2.Joint_IsValid(joint.jointId) do return 0
	return math.to_degrees(b2.RevoluteJoint_GetAngle(joint.jointId))
}

// A Prismatic joint's translation (px from the start), or a Distance joint's current length
Joint_GetTranslation :: proc(joint: ^Joint) -> f32 {
	if !b2.Joint_IsValid(joint.jointId) do return 0
	ppm := pixelsPerMeter(joint.scene)
	#partial switch joint.kind {
	case .Prismatic: return b2.PrismaticJoint_GetTranslation(joint.jointId) * ppm
	case .Distance:  return b2.DistanceJoint_GetCurrentLength(joint.jointId) * ppm
	}
	return 0
}

/*
How hard the joint pulls on its bodies right now (kg·px/s²): compare it to a limit to make
breakable joints (`scene->removeNode(joint.id)` breaks it).
*/
Joint_GetForce :: proc(joint: ^Joint) -> [2]f32 {
	if !b2.Joint_IsValid(joint.jointId) do return {}
	return b2.Joint_GetConstraintForce(joint.jointId) * pixelsPerMeter(joint.scene)
}

// The joint's anchors in world pixels (A at the joint, B on body B), for drawing
Joint_GetAnchors :: proc(joint: ^Joint) -> (a, b: [2]f32, ok: bool) {
	if !b2.Joint_IsValid(joint.jointId) do return
	ppm := pixelsPerMeter(joint.scene)
	a = b2.Body_GetWorldPoint(b2.Joint_GetBodyA(joint.jointId), b2.Joint_GetLocalAnchorA(joint.jointId)) * ppm
	b = b2.Body_GetWorldPoint(b2.Joint_GetBodyB(joint.jointId), b2.Joint_GetLocalAnchorB(joint.jointId)) * ppm
	return a, b, true
}

// Makes the Box2D joint once both bodies exist (Physics_Sync)
@(private)
createJoint :: proc(world: ^PhysicsWorld, joint: ^Joint) {
	a := findBody(joint, joint.bodyA, true)
	b := findBody(joint, joint.bodyB, false)
	if b == nil {
		log.warnf("Joint %s: no body named '%s' (bodyB)", joint.name, joint.bodyB)
		joint.failed = true
		return
	}
	if joint.bodyA != "" && a == nil {
		log.warnf("Joint %s: no body named '%s' (bodyA)", joint.name, joint.bodyA)
		joint.failed = true
		return
	}
	if a == b {
		log.warnf("Joint %s connects %s to itself", joint.name, b.name)
		joint.failed = true
		return
	}
	// Wait until both bodies are in the world
	if !b2.Body_IsValid(b.bodyId) || a != nil && !b2.Body_IsValid(a.bodyId) do return

	ppm := world.settings.pixelsPerMeter
	idA := a != nil ? a.bodyId : groundBody(world)
	idB := b.bodyId
	xf := Node_GetWorldTransform(joint)
	anchor := xf.origin / ppm
	axis := linalg.normalize0(xf.x)
	localA := b2.Body_GetLocalPoint(idA, anchor)
	localB := b2.Body_GetLocalPoint(idB, anchor)
	referenceAngle := b2.Rot_GetAngle(b2.Body_GetRotation(idB)) - b2.Rot_GetAngle(b2.Body_GetRotation(idA))
	speedAngular := math.to_radians(joint.motorSpeed)

	switch joint.kind {
	case .Revolute:
		def := b2.DefaultRevoluteJointDef()
		def.bodyIdA, def.bodyIdB = idA, idB
		def.localAnchorA, def.localAnchorB = localA, localB
		def.referenceAngle = referenceAngle
		def.enableLimit = joint.enableLimit
		def.lowerAngle, def.upperAngle = math.to_radians(min(joint.lower, joint.upper)), math.to_radians(max(joint.lower, joint.upper))
		def.enableMotor = joint.enableMotor
		def.motorSpeed = speedAngular
		def.maxMotorTorque = joint.maxMotor / (ppm * ppm)
		def.enableSpring, def.hertz, def.dampingRatio = joint.enableSpring, joint.hertz, joint.dampingRatio
		def.collideConnected = joint.collideConnected
		def.userData = joint
		joint.jointId = b2.CreateRevoluteJoint(world.id, def)
	case .Distance:
		def := b2.DefaultDistanceJointDef()
		other := Transform2D_Apply(xf, joint.offset) / ppm
		def.bodyIdA, def.bodyIdB = idA, idB
		def.localAnchorA, def.localAnchorB = localA, b2.Body_GetLocalPoint(idB, other)
		def.length = max(linalg.length(other - anchor), 0.005)
		def.enableLimit = joint.enableLimit
		def.minLength, def.maxLength = min(joint.lower, joint.upper) / ppm, max(joint.lower, joint.upper) / ppm
		def.enableMotor = joint.enableMotor
		def.motorSpeed = joint.motorSpeed / ppm
		def.maxMotorForce = joint.maxMotor / ppm
		def.enableSpring, def.hertz, def.dampingRatio = joint.enableSpring, joint.hertz, joint.dampingRatio
		def.collideConnected = joint.collideConnected
		def.userData = joint
		joint.jointId = b2.CreateDistanceJoint(world.id, def)
	case .Prismatic:
		def := b2.DefaultPrismaticJointDef()
		def.bodyIdA, def.bodyIdB = idA, idB
		def.localAnchorA, def.localAnchorB = localA, localB
		def.localAxisA = b2.Body_GetLocalVector(idA, axis)
		def.referenceAngle = referenceAngle
		def.enableLimit = joint.enableLimit
		def.lowerTranslation, def.upperTranslation = min(joint.lower, joint.upper) / ppm, max(joint.lower, joint.upper) / ppm
		def.enableMotor = joint.enableMotor
		def.motorSpeed = joint.motorSpeed / ppm
		def.maxMotorForce = joint.maxMotor / ppm
		def.enableSpring, def.hertz, def.dampingRatio = joint.enableSpring, joint.hertz, joint.dampingRatio
		def.collideConnected = joint.collideConnected
		def.userData = joint
		joint.jointId = b2.CreatePrismaticJoint(world.id, def)
	case .Weld:
		def := b2.DefaultWeldJointDef()
		def.bodyIdA, def.bodyIdB = idA, idB
		def.localAnchorA, def.localAnchorB = localA, localB
		def.referenceAngle = referenceAngle
		if joint.enableSpring {
			def.linearHertz, def.angularHertz = joint.hertz, joint.hertz
			def.linearDampingRatio, def.angularDampingRatio = joint.dampingRatio, joint.dampingRatio
		}
		def.collideConnected = joint.collideConnected
		def.userData = joint
		joint.jointId = b2.CreateWeldJoint(world.id, def)
	case .Wheel:
		def := b2.DefaultWheelJointDef()
		def.bodyIdA, def.bodyIdB = idA, idB
		def.localAnchorA, def.localAnchorB = localA, localB
		def.localAxisA = b2.Body_GetLocalVector(idA, axis)
		def.enableSpring = joint.enableSpring
		def.hertz, def.dampingRatio = joint.hertz, joint.dampingRatio
		def.enableLimit = joint.enableLimit
		def.lowerTranslation, def.upperTranslation = min(joint.lower, joint.upper) / ppm, max(joint.lower, joint.upper) / ppm
		def.enableMotor = joint.enableMotor
		def.motorSpeed = speedAngular
		def.maxMotorTorque = joint.maxMotor / (ppm * ppm)
		def.collideConnected = joint.collideConnected
		def.userData = joint
		joint.jointId = b2.CreateWheelJoint(world.id, def)
	}
	joint.connectedA, joint.connectedB = a, b
}

// A joint's body: by name or path, or (body A without a name) the nearest body above the joint
@(private="file")
findBody :: proc(joint: ^Joint, name: string, isA: bool) -> ^PhysicsBody {
	if name == "" {
		if !isA do return nil
		for n := joint.parent; n != nil; n = n.parent do if Node_IsPhysicsBody(n) do return cast(^PhysicsBody)n
		return nil
	}
	node := Scene_FindNode(joint.scene, name)
	if node == nil && joint.parent != nil do node = Node_FindChild(joint.parent, name)
	return Node_IsPhysicsBody(node) ? cast(^PhysicsBody)node : nil
}

// The world's static body at the origin, for joints with no body A
@(private="file")
groundBody :: proc(world: ^PhysicsWorld) -> b2.BodyId {
	if !b2.Body_IsValid(world.ground) {
		def := b2.DefaultBodyDef()
		world.ground = b2.CreateBody(world.id, def)
	}
	return world.ground
}
