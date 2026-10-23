package crossfire

import "core:math"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

/*
Skeletal animation: bones, skinned meshes and inverse kinematics.

- **Bone2D** nodes are bones: a node like any other (position, rotation, scale relative to its
  parent, so a bone's children follow it), pointing along its local x axis for `length` pixels.
  A tree of them under a **Skeleton2D** node is a character's skeleton. Sprites under a bone move
  with it rigidly (a cut-out character); the Animator and the Timeline key bones' rotation,
  position and scale like any node's.
- **SkinnedMesh** nodes bend one picture over several bones: a mesh of triangles over the
  picture (`MeshData`: vertices in the node's space, the picture's pixels under them, up to four
  weighted bones per vertex). The pose the scene file has is the **rest pose**: when the mesh is
  built, each bone's place relative to the mesh is remembered (`SkinnedMesh_Bind`); every draw
  moves each vertex by its bones' moves since, blended by their weights (linear blend
  skinning), and draws the triangles through the node's transform.
- **IKChain** nodes aim a chain of bones at a target (inverse kinematics: an arm reaching for a
  point, a leg planted on the ground): `tip` is the last bone of the chain, `length` how many
  bones up from it move, `target` the node to reach. Two bones are solved exactly (the elbow or
  knee bending the `bendPositive` way); longer chains with cyclic coordinate descent. Chains are
  solved after the scene's nodes and tweens update (the Animator's keys first, then IK), in the
  order they were made.

Scene files (format 13):

	<node kind="Skeleton2D" name="Hero">
		<node kind="Bone2D" name="Hip" boneLength="40">
			<node kind="Bone2D" name="Thigh" rotation="90" boneLength="50"/>
		</node>
		<node kind="SkinnedMesh" name="Body" texture="assets/hero.png">
			<mesh vertices="0,0 10,0 ..." uvs="0,0 10,0 ..." triangles="0,1,2 ..."
			      bones="../Hip,../Hip/Thigh" weights="0:1;0:0.5 1:0.5;..."/>
		</node>
		<node kind="IKChain" name="LegIK" ikTip="../Hip/Thigh" ikLength="2" ikTarget="../Foot"/>
	</node>

DragonBones files are converted into these nodes (dragonbones.odin).
*/

// A bone: a node pointing along its x axis
Bone2D :: struct {
	using node: Node,
	// How long it is, in its own pixels (where its tip is: IK reaches with it; editors draw it)
	length: f32,
}

// The root of a skeleton: bones (and what they carry) are its descendants
Skeleton2D :: struct {
	using node: Node,
}

// One vertex's bones (indices into `MeshData.bones`, -1 unused) and weights (summing to 1)
VertexWeights :: struct {
	bones: [4]i32,
	weights: [4]f32,
}

// A skinned mesh's triangles over its picture and their bones (scene files' `<mesh>`)
MeshData :: struct {
	// Each vertex in the node's space (the rest pose)
	vertices: [dynamic][2]f32,
	// Each vertex's place in the picture, in pixels (of the atlas region, when the texture is one)
	uvs: [dynamic][2]f32,
	// Three vertex indices per triangle
	triangles: [dynamic]i32,
	// The bones, as paths from the mesh node ("../Hip/Thigh")
	bones: [dynamic]string,
	// Each vertex's bones; none (or fewer than the vertices): those vertices don't move
	weights: [dynamic]VertexWeights,
}

// A picture bent over bones
SkinnedMesh :: struct {
	using node: Node,
	// The picture (and its part: an atlas region; zero for the whole)
	texture: ^sdl.Texture,
	region: sdl.FRect,
	mesh: MeshData,
	// Its bones found (`SkinnedMesh_Bind`): their ids, and where each was relative to the mesh then
	// (inverted)
	boneIds: [dynamic]EntityId,
	bind: [dynamic]Transform2D,
	bound: bool,
}

// An IK chain's settings (scene files' `ikLength`, `ikBend`, `ikEnabled`)
IKSettings :: struct {
	// Bones up from the tip that move (1: only the tip turns toward the target)
	length: int,
	// Two bones: which way the middle joint bends (true: clockwise, like a right arm's elbow)
	bendPositive: bool,
	// Whether the chain aims its bones (false leaves them as animated)
	enabled: bool,
}

// An IK chain's settings when none are given (`CreateIKChain`, scene files): two bones, bending
// clockwise, on
DEFAULT_IK_SETTINGS :: IKSettings{length = 2, bendPositive = true, enabled = true}

// Aims a chain of bones at a target
IKChain :: struct {
	using node: Node,
	settings: IKSettings,
	// Paths from the IK node: the chain's last bone, and the node it reaches for (node arena)
	tip: string,
	target: string,
}

// Makes a bone (`length` pixels along its x axis)
CreateBone2D :: proc(scene: ^Scene, length: f32 = 32) -> ^Bone2D {
	b := CreateNode(scene, Bone2D)
	b.length = length
	return b
}

// Makes a skeleton's root
CreateSkeleton2D :: proc(scene: ^Scene) -> ^Skeleton2D {
	return CreateNode(scene, Skeleton2D)
}

/*
Makes a skinned mesh: a picture bent over bones. Its mesh is copied into the node's memory; it
binds to its bones (their rest pose: where they are then) on its first update.

Inputs:
- scene: The scene
- texture: The picture
- mesh: Its triangles, the picture's pixels under them, its bones and weights
- region: The part of the texture (an atlas region; zero: all of it)
*/
CreateSkinnedMesh :: proc(scene: ^Scene, texture: ^sdl.Texture, mesh: MeshData, region := sdl.FRect{}) -> ^SkinnedMesh {
	m := CreateNode(scene, SkinnedMesh)
	m.texture = texture
	m.region = region
	m.mesh = MeshData_Clone(mesh, Node_GetAllocator(m))
	m.boneIds = make([dynamic]EntityId, Node_GetAllocator(m))
	m.bind = make([dynamic]Transform2D, Node_GetAllocator(m))
	m.update = proc(node: ^Node, events: []sdl.Event, dt: f64) {
		m := cast(^SkinnedMesh)node
		if !m.bound do SkinnedMesh_Bind(m)
	}
	m.draw = skinnedMeshDraw
	m.getBounds = proc(node: ^Node) -> (sdl.FRect, bool) {
		m := cast(^SkinnedMesh)node
		if len(m.mesh.vertices) == 0 do return {}, false
		lo, hi := m.mesh.vertices[0], m.mesh.vertices[0]
		for v in m.mesh.vertices do lo, hi = {min(lo.x, v.x), min(lo.y, v.y)}, {max(hi.x, v.x), max(hi.y, v.y)}
		return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, true
	}
	return m
}

/*
Makes an IK chain aiming the bones up from `tip` at `target` (paths from the IK node).
*/
CreateIKChain :: proc(scene: ^Scene, tip, target: string, settings := DEFAULT_IK_SETTINGS) -> ^IKChain {
	c := CreateNode(scene, IKChain)
	c.settings = settings
	c.tip = strings.clone(tip, Node_GetAllocator(c))
	c.target = strings.clone(target, Node_GetAllocator(c))
	if scene.ikChains == nil do scene.ikChains = make([dynamic]^IKChain)
	append(&scene.ikChains, c)
	c.destroy = proc(node: ^Node) {
		c := cast(^IKChain)node
		list := &c.scene.ikChains
		for other, i in list do if other == c {
			ordered_remove(list, i)
			break
		}
		if len(list) == 0 {
			delete(list^)
			list^ = nil
		}
	}
	return c
}

/*
Remembers where a skinned mesh's bones are relative to it now: their rest pose. A vertex moves
with its bones' moves since. Done on its first update; call it again after changing the rest pose
(editors do after moving bones) or the bones.

Returns:
- How many of its bones were found (missing ones leave their vertices in place)
*/
SkinnedMesh_Bind :: proc(mesh: ^SkinnedMesh) -> int {
	clear(&mesh.boneIds)
	clear(&mesh.bind)
	meshWorld := Node_GetWorldTransform(mesh)
	inverse := Transform2D_Inverse(meshWorld)
	found := 0
	for path in mesh.mesh.bones {
		bone := Node_FindPath(mesh, path)
		if bone == nil {
			append(&mesh.boneIds, EntityId{})
			append(&mesh.bind, TRANSFORM2D_IDENTITY)
			continue
		}
		found += 1
		append(&mesh.boneIds, bone.id)
		// The bone in the mesh's space, inverted: a vertex's place relative to the bone at rest
		append(&mesh.bind, Transform2D_Inverse(Transform2D_Multiply(inverse, Node_GetWorldTransform(bone))))
	}
	mesh.bound = true
	return found
}

/*
Where a skinned mesh's vertices are now (its space), its bones' moves blended by their weights.

Returns:
- The vertices (temp allocated)
*/
SkinnedMesh_Deform :: proc(mesh: ^SkinnedMesh) -> [][2]f32 {
	out := make([][2]f32, len(mesh.mesh.vertices), context.temp_allocator)
	copy(out, mesh.mesh.vertices[:])
	if !mesh.bound || len(mesh.boneIds) == 0 do return out
	// Each bone's move since the rest pose, in the mesh's space
	inverse := Transform2D_Inverse(Node_GetRenderWorldTransform(mesh))
	moves := make([]Transform2D, len(mesh.boneIds), context.temp_allocator)
	present := make([]bool, len(mesh.boneIds), context.temp_allocator)
	for id, i in mesh.boneIds {
		bone := id != (EntityId{}) ? Scene_GetNode(mesh.scene, id) : nil
		if bone == nil do continue
		moves[i] = Transform2D_Multiply(Transform2D_Multiply(inverse, Node_GetRenderWorldTransform(bone)), mesh.bind[i])
		present[i] = true
	}
	for v, i in mesh.mesh.vertices {
		if i >= len(mesh.mesh.weights) do break
		w := mesh.mesh.weights[i]
		sum: [2]f32
		total: f32
		for k in 0 ..< 4 {
			b := w.bones[k]
			if b < 0 || int(b) >= len(moves) || !present[b] || w.weights[k] <= 0 do continue
			sum += Transform2D_Apply(moves[b], v) * w.weights[k]
			total += w.weights[k]
		}
		if total > 0 do out[i] = sum / total
	}
	return out
}

/*
Solves a scene's IK chains (Scene_Update, after nodes and tweens): each turns its bones so the
tip's end reaches the target, or points at it when it's out of reach.
*/
Scene_SolveIK :: proc(scene: ^Scene) {
	for c in scene.ikChains do if c.settings.enabled && Node_CanProcess(c) do IKChain_Solve(c)
}

/*
Solves one IK chain now.

Returns:
- false when its tip or target isn't found
*/
IKChain_Solve :: proc(c: ^IKChain) -> bool {
	tipNode := Node_FindPath(c, c.tip)
	target := Node_FindPath(c, c.target)
	if tipNode == nil || target == nil || !Node_Is(tipNode, Bone2D) do return false
	tip := cast(^Bone2D)tipNode
	goal := Node_GetWorldPosition(target)
	// The chain, tip first: the tip and the bones above it, up to `length`
	chain := make([dynamic]^Bone2D, context.temp_allocator)
	for n: ^Node = tip; n != nil && len(chain) < max(c.settings.length, 1); n = n.parent {
		if !Node_Is(n, Bone2D) do break
		append(&chain, cast(^Bone2D)n)
	}
	if len(chain) == 2 {
		ikTwoBones(chain[1], chain[0], goal, c.settings.bendPositive)
		return true
	}
	// Cyclic coordinate descent: from the tip up, each bone turns so the tip points at the goal
	for _ in 0 ..< 12 {
		for bone in chain {
			joint := Node_GetWorldPosition(bone)
			end := boneTip(tip)
			turnToward(bone, joint, end, goal)
		}
		if linalgLength(boneTip(tip) - goal) < 0.5 do break
	}
	return true
}

// A bone's tip in the world
Bone2D_Tip :: proc(bone: ^Bone2D) -> [2]f32 {
	return boneTip(bone)
}

// Copies mesh data into an allocator
MeshData_Clone :: proc(mesh: MeshData, allocator := context.allocator) -> MeshData {
	out := MeshData{
		vertices = make([dynamic][2]f32, 0, len(mesh.vertices), allocator),
		uvs = make([dynamic][2]f32, 0, len(mesh.uvs), allocator),
		triangles = make([dynamic]i32, 0, len(mesh.triangles), allocator),
		bones = make([dynamic]string, 0, len(mesh.bones), allocator),
		weights = make([dynamic]VertexWeights, 0, len(mesh.weights), allocator),
	}
	append(&out.vertices, ..mesh.vertices[:])
	append(&out.uvs, ..mesh.uvs[:])
	append(&out.triangles, ..mesh.triangles[:])
	for b in mesh.bones do append(&out.bones, strings.clone(b, allocator))
	append(&out.weights, ..mesh.weights[:])
	return out
}

// Frees what MeshData_Clone or ParseMesh made
MeshData_Destroy :: proc(mesh: ^MeshData, allocator := context.allocator) {
	delete(mesh.vertices)
	delete(mesh.uvs)
	delete(mesh.triangles)
	for b in mesh.bones do delete(b, allocator)
	delete(mesh.bones)
	delete(mesh.weights)
	mesh^ = {}
}

// Whether two meshes are the same
MeshData_Equal :: proc(a, b: MeshData) -> bool {
	if len(a.vertices) != len(b.vertices) || len(a.uvs) != len(b.uvs) || len(a.triangles) != len(b.triangles) || len(a.bones) != len(b.bones) || len(a.weights) != len(b.weights) do return false
	for v, i in a.vertices do if v != b.vertices[i] do return false
	for v, i in a.uvs do if v != b.uvs[i] do return false
	for v, i in a.triangles do if v != b.triangles[i] do return false
	for v, i in a.bones do if v != b.bones[i] do return false
	for v, i in a.weights do if v != b.weights[i] do return false
	return true
}

/*
A mesh's weights as scene files write them: per vertex `bone:weight` pairs separated by spaces,
vertices by `;` ("0:1;0:0.5 1:0.5").

Returns:
- The text (temp allocated)
*/
FormatWeights :: proc(weights: []VertexWeights) -> string {
	b := strings.builder_make(context.temp_allocator)
	for w, i in weights {
		if i > 0 do strings.write_byte(&b, ';')
		first := true
		for k in 0 ..< 4 do if w.bones[k] >= 0 && w.weights[k] > 0 {
			if !first do strings.write_byte(&b, ' ')
			first = false
			strings.write_int(&b, int(w.bones[k]))
			strings.write_byte(&b, ':')
			strings.write_string(&b, formatShort(w.weights[k]))
		}
	}
	return strings.to_string(b)
}

// Reads `FormatWeights`'s text (temp allocated); false when it doesn't parse
ParseWeights :: proc(text: string) -> ([]VertexWeights, bool) {
	list := make([dynamic]VertexWeights, context.temp_allocator)
	if strings.trim_space(text) == "" do return list[:], true
	for vertex in strings.split(text, ";", context.temp_allocator) {
		w := VertexWeights{bones = {-1, -1, -1, -1}}
		k := 0
		for pair in strings.fields(vertex, context.temp_allocator) {
			if k >= 4 do break
			bone, _, weight := strings.partition(pair, ":")
			bi, ok1 := strconv.parse_int(bone)
			wf, ok2 := strconv.parse_f32(weight)
			if !ok1 || !ok2 do return nil, false
			w.bones[k], w.weights[k] = i32(bi), wf
			k += 1
		}
		append(&list, w)
	}
	return list[:], true
}

// "0,1,2 2,3,0": a mesh's triangles (temp allocated)
FormatTriangles :: proc(triangles: []i32) -> string {
	b := strings.builder_make(context.temp_allocator)
	for t, i in triangles {
		if i > 0 do strings.write_byte(&b, i % 3 == 0 ? ' ' : ',')
		strings.write_int(&b, int(t))
	}
	return strings.to_string(b)
}

// Reads `FormatTriangles`'s text (temp allocated); false when it doesn't parse or isn't whole triangles
ParseTriangles :: proc(text: string) -> ([]i32, bool) {
	list := make([dynamic]i32, context.temp_allocator)
	for field in strings.fields(text, context.temp_allocator) do for part in strings.split(field, ",", context.temp_allocator) {
		n, ok := strconv.parse_int(part)
		if !ok do return nil, false
		append(&list, i32(n))
	}
	return list[:], len(list) % 3 == 0
}

// INTERNAL

@(private="file")
skinnedMeshDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	m := cast(^SkinnedMesh)node
	if m.texture == nil || len(m.mesh.triangles) == 0 do return
	deformed := SkinnedMesh_Deform(m)
	t := GetDrawTransform()
	tint := tinted({255, 255, 255, 255})
	c := sdl.FColor{f32(tint[0]) / 255, f32(tint[1]) / 255, f32(tint[2]) / 255, f32(tint[3]) / 255}
	tw, th := f32(m.texture.w), f32(m.texture.h)
	origin := [2]f32{m.region.x, m.region.y}
	vertices := make([]sdl.Vertex, len(deformed), context.temp_allocator)
	for v, i in deformed {
		p := Transform2D_Apply(t, v)
		uv := i < len(m.mesh.uvs) ? m.mesh.uvs[i] + origin : origin
		vertices[i] = {position = {p.x, p.y}, color = c, tex_coord = {uv.x / tw, uv.y / th}}
	}
	indices := make([dynamic]i32, 0, len(m.mesh.triangles), context.temp_allocator)
	for index in m.mesh.triangles do if int(index) < len(vertices) do append(&indices, index)
	sdl.SetTextureBlendMode(m.texture, GetDrawBlend())
	on := shaderDrawBegin(renderer, {tw, th})
	sdl.RenderGeometry(renderer, m.texture, raw_data(vertices), i32(len(vertices)), raw_data(indices), i32(len(indices)))
	shaderDrawEnd(renderer, on)
}

// A bone's tip: its origin plus `length` along its x axis, in the world
@(private="file")
boneTip :: proc(bone: ^Bone2D) -> [2]f32 {
	return Transform2D_Apply(Node_GetWorldTransform(bone), {bone.length, 0})
}

@(private="file")
linalgLength :: proc(v: [2]f32) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

// Turns a bone about its origin so `from` (a world point it carries) points at `to`
@(private="file")
turnToward :: proc(bone: ^Bone2D, joint, from, to: [2]f32) {
	a := from - joint
	b := to - joint
	if linalgLength(a) < 1e-4 || linalgLength(b) < 1e-4 do return
	delta := math.to_degrees(math.atan2(b.y, b.x) - math.atan2(a.y, a.x))
	// Under a mirrored parent the local rotation turns the other way
	if bone.parent != nil {
		pt := Node_GetWorldTransform(bone.parent)
		if pt.x.x * pt.y.y - pt.x.y * pt.y.x < 0 do delta = -delta
	}
	bone.rotation = normalizeDegrees(bone.rotation + delta)
}

// Two bones reaching a goal exactly (law of cosines), the middle joint bending one way
@(private="file")
ikTwoBones :: proc(upper, lower: ^Bone2D, goal: [2]f32, bendPositive: bool) {
	root := Node_GetWorldPosition(upper)
	a := linalgLength(Node_GetWorldPosition(lower) - root)
	b := linalgLength(boneTip(lower) - Node_GetWorldPosition(lower))
	toGoal := goal - root
	d := clamp(linalgLength(toGoal), abs(a - b) + 1e-3, a + b - 1e-3)
	if a < 1e-4 || b < 1e-4 do return
	// The angle at the root between the goal and the upper bone
	cosA := clamp((a * a + d * d - b * b) / (2 * a * d), -1, 1)
	angleA := math.acos(cosA)
	if !bendPositive do angleA = -angleA
	base := math.atan2(toGoal.y, toGoal.x)
	elbow := root + [2]f32{math.cos(base - angleA), math.sin(base - angleA)} * a
	turnToward(upper, root, Node_GetWorldPosition(lower), elbow)
	turnToward(lower, Node_GetWorldPosition(lower), boneTip(lower), goal)
}

@(private="file")
normalizeDegrees :: proc(d: f32) -> f32 {
	r := math.mod(d, 360)
	if r > 180 do r -= 360
	if r < -180 do r += 360
	return r
}

// A float written short ("0.5", "1")
@(private="file")
formatShort :: proc(v: f32) -> string {
	buf: [32]u8
	s := strconv.write_float(buf[:], f64(v), 'g', 6, 32)
	return strings.clone(strings.trim_prefix(s, "+"), context.temp_allocator)
}
