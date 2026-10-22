#+build !js
package crossfire

import "core:log"
import "core:math"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// Skeletons (skeleton.odin) and DragonBones files (dragonbones.odin): bones from scene files,
// IK reaching targets, skinned meshes bending (pixels), DragonBones converted and played

@(private="file")
near :: proc(a, b: [2]f32, tolerance: f32 = 0.5) -> bool {
	d := a - b
	return math.sqrt(d.x * d.x + d.y * d.y) <= tolerance
}

@(test)
skeletons_ik_and_skinned_meshes :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	data, err := ParseScene(`<scene formatVersion="13">
	<node kind="Skeleton2D" name="Arm" x="100" y="100">
		<node kind="Bone2D" name="Upper" boneLength="50">
			<node kind="Bone2D" name="Lower" x="50" boneLength="50"/>
		</node>
		<node kind="IKChain" name="Reach" ikTip="../Upper/Lower" ikLength="2" ikTarget="../Target" ikBend="negative"/>
		<node kind="Node2D" name="Target" x="60" y="40"/>
	</node>
	<node kind="Skeleton2D" name="Tail" x="300" y="100">
		<node kind="Bone2D" name="A" boneLength="20">
			<node kind="Bone2D" name="B" x="20" boneLength="20">
				<node kind="Bone2D" name="C" x="20" boneLength="20"/>
			</node>
		</node>
		<node kind="IKChain" name="Curl" ikTip="../A/B/C" ikLength="3" ikTarget="../Goal"/>
		<node kind="Node2D" name="Goal" x="30" y="30"/>
	</node>
</scene>`)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, data.nodes[1].boneLength, 50)
	testing.expect(t, data.nodes[3].ikTip == "../Upper/Lower" && data.nodes[3].ik.length == 2 && !data.nodes[3].ik.bendPositive, "IK attributes")
	_ = Scene_Build(scene, &data, "testdata")
	Scene_Update(scene, nil, 0)
	testing.expect_value(t, len(scene.ikChains), 2)
	// Two bones: the tip exactly on the target, the elbow bent the asked way (up: negative)
	lower := cast(^Bone2D)Scene_FindNode(scene, "Arm/Upper/Lower")
	tip := Bone2D_Tip(lower)
	testing.expectf(t, near(tip, {160, 140}), "two bones reach: %v", tip)
	elbow := Node_GetWorldPosition(lower)
	testing.expectf(t, elbow.y < 100 + 40 * elbow.x / 60, "the elbow above the line: %v", elbow)
	// Out of reach: pointing at it, straight
	Scene_FindNode(scene, "Arm/Target").position = {300, 0}
	Scene_Update(scene, nil, 0)
	tip = Bone2D_Tip(lower)
	testing.expectf(t, near(tip, {199.9, 100}, 1), "straight toward it: %v", tip)
	// Three bones (CCD): the tip reaches
	c := cast(^Bone2D)Scene_FindNode(scene, "Tail/A/B/C")
	testing.expectf(t, near(Bone2D_Tip(c), {330, 130}, 1), "three bones reach: %v", Bone2D_Tip(c))
	// Disabled: left alone
	(cast(^IKChain)Scene_FindNode(scene, "Tail/Curl")).settings.enabled = false
	Scene_FindNode(scene, "Tail/A").rotation = 0
	Scene_FindNode(scene, "Tail/A/B").rotation = 0
	Scene_FindNode(scene, "Tail/A/B/C").rotation = 0
	Scene_Update(scene, nil, 0)
	testing.expect(t, near(Bone2D_Tip(c), {360, 100}), "not solved")

	// Weights and triangles' text
	w, ok := ParseWeights("0:1;0:0.5 1:0.5;1:1")
	testing.expect(t, ok && len(w) == 3 && w[1].bones[1] == 1 && w[1].weights[1] == 0.5, "weights read")
	testing.expect_value(t, FormatWeights(w), "0:1;0:0.5 1:0.5;1:1")
	tris, tok := ParseTriangles("0,1,2 2,3,0")
	testing.expect(t, tok && len(tris) == 6, "triangles read")
	testing.expect_value(t, FormatTriangles(tris), "0,1,2 2,3,0")
}

@(test)
skinned_meshes_bend_with_their_bones :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(64, 64, .ARGB8888)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	game.renderer = renderer
	game.resourceManager.renderer = renderer
	scene := game->createScene("S")
	white := sdl.CreateTexture(renderer, .ARGB8888, .STATIC, 4, 4)
	defer sdl.DestroyTexture(white)
	pixels: [16]u32 = 0xffffffff
	_ = sdl.UpdateTexture(white, nil, &pixels, 16)
	// A strip 40 x 8 along x: its left half on bone A, its right half on bone B (at x 20)
	skeleton := CreateSkeleton2D(scene)
	a := CreateBone2D(scene, 20)
	b := CreateBone2D(scene, 20)
	b.position = {20, 0}
	Node_AddChild(skeleton, a)
	Node_AddChild(a, b)
	mesh := MeshData{
		vertices = make([dynamic][2]f32, context.temp_allocator), uvs = make([dynamic][2]f32, context.temp_allocator),
		triangles = make([dynamic]i32, context.temp_allocator), bones = make([dynamic]string, context.temp_allocator),
		weights = make([dynamic]VertexWeights, context.temp_allocator),
	}
	append(&mesh.vertices, [2]f32{0, -4}, [2]f32{20, -4}, [2]f32{40, -4}, [2]f32{0, 4}, [2]f32{20, 4}, [2]f32{40, 4})
	append(&mesh.uvs, [2]f32{0, 0}, [2]f32{2, 0}, [2]f32{4, 0}, [2]f32{0, 4}, [2]f32{2, 4}, [2]f32{4, 4})
	append(&mesh.triangles, 0, 1, 4, 0, 4, 3, 1, 2, 5, 1, 5, 4)
	append(&mesh.bones, "../A", "../A/B")
	only :: proc(bone: i32) -> VertexWeights { return {bones = {bone, -1, -1, -1}, weights = {1, 0, 0, 0}} }
	half := VertexWeights{bones = {0, 1, -1, -1}, weights = {0.5, 0.5, 0, 0}}
	append(&mesh.weights, only(0), half, only(1), only(0), half, only(1))
	a.name = strings.clone("A", Node_GetAllocator(a))
	b.name = strings.clone("B", Node_GetAllocator(b))
	m := CreateSkinnedMesh(scene, white, mesh)
	Node_AddChild(skeleton, m)
	skeleton.position = {8, 20}
	Scene_Update(scene, nil, 0)
	testing.expect(t, m.bound, "bound to its bones")
	// At rest: as made
	rest := SkinnedMesh_Deform(m)
	testing.expect(t, near(rest[2], {40, -4}) && near(rest[5], {40, 4}), "at rest")
	// Bone B turned 90°: its vertices swing down around (20, 0); the shared ones halfway
	b.rotation = 90
	bent := SkinnedMesh_Deform(m)
	testing.expectf(t, near(bent[2], {24, 20}), "the far end swung: %v", bent[2])
	testing.expectf(t, near(bent[1], {22, -2}, 1), "the middle blended: %v", bent[1])
	testing.expect(t, near(bent[0], {0, -4}), "bone A's vertices stay")
	// Drawn: pixels where the swung part is now, none where it was
	_ = sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	_ = sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	_ = sdl.RenderPresent(renderer)
	pixel :: proc(s: ^sdl.Surface, x, y: i32) -> u32 { return (cast([^]u32)s.pixels)[y * (s.pitch / 4) + x] }
	testing.expectf(t, pixel(surface, 8 + 20, 20 + 15) & 0xff > 0x80, "drawn below the joint: %08x", pixel(surface, 8 + 20, 20 + 15))
	testing.expectf(t, pixel(surface, 8 + 35, 20) & 0xff < 0x40, "not where it was: %08x", pixel(surface, 8 + 35, 20))
	testing.expectf(t, pixel(surface, 8 + 5, 20) & 0xff > 0x80, "bone A's part where it was: %08x", pixel(surface, 8 + 5, 20))
}

// A small DragonBones armature: a root bone, an arm with a sprite (trimmed in the atlas), a
// mesh over both weighted, a "wave" animation turning the arm
@(private="file")
DB_SKE :: `{"frameRate": 10, "name": "Robot", "version": "5.5", "armature": [{
	"type": "Armature", "frameRate": 10, "name": "Robot",
	"bone": [
		{"name": "root"},
		{"name": "arm", "parent": "root", "length": 30, "transform": {"x": 10, "y": 0, "skX": 0, "skY": 0}}
	],
	"slot": [{"name": "body", "parent": "root"}, {"name": "hand", "parent": "arm"}],
	"skin": [{"slot": [
		{"name": "hand", "display": [{"name": "hand", "transform": {"x": 30, "y": 0}}]},
		{"name": "body", "display": [{"type": "mesh", "name": "body", "width": 20, "height": 10,
			"vertices": [0, -5, 20, -5, 20, 5, 0, 5], "uvs": [0, 0, 1, 0, 1, 1, 0, 1], "triangles": [0, 1, 2, 0, 2, 3],
			"weights": [1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1], "slotPose": [1, 0, 0, 1, 0, 0], "bonePose": [0, 1, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 10, 0]}]}
	]}],
	"animation": [{"name": "wave", "duration": 10, "playTimes": 0,
		"bone": [{"name": "arm", "rotateFrame": [{"duration": 5, "tweenEasing": 0, "rotate": 0}, {"duration": 5, "tweenEasing": 0, "rotate": 90}, {"duration": 0, "rotate": 0}]}]
	}],
	"defaultActions": [{"gotoAndPlay": "wave"}]
}]}`

@(private="file")
DB_TEX :: `{"name": "Robot", "imagePath": "Robot_tex.png", "width": 64, "height": 32, "SubTexture": [
	{"name": "body", "x": 0, "y": 0, "width": 20, "height": 10},
	{"name": "hand", "x": 24, "y": 0, "width": 8, "height": 8, "frameX": -2, "frameY": -2, "frameWidth": 12, "frameHeight": 12}
]}`

@(test)
dragonbones_files_become_skeletons :: proc(t: ^testing.T) {
	result, ok := DragonBones_Convert(DB_SKE, DB_TEX, "atlases/robot.atlas.xml", "atlases/robot.png")
	defer { SceneData_Destroy(&result.component); AtlasData_Destroy(&result.atlas) }
	testing.expect(t, ok, "converted")
	for w in result.warnings do log.infof("DragonBones: %s", w)
	nodes := result.component.nodes[:]
	find :: proc(nodes: []SceneNodeData, name: string) -> int {
		for n, i in nodes do if n.name == name do return i
		return -1
	}
	testing.expect_value(t, nodes[0].kind, SceneNodeKind.Skeleton2D)
	arm := find(nodes, "arm")
	testing.expect(t, arm >= 0 && nodes[arm].kind == .Bone2D && nodes[arm].boneLength == 30 && nodes[arm].position == {10, 0}, "the arm bone")
	testing.expect_value(t, nodes[nodes[arm].parent].name, "root")
	// Depth-first: every node after its parent
	for n, i in nodes do testing.expect(t, n.parent < i, "parents first")
	hand := find(nodes, "hand")
	testing.expect(t, hand >= 0 && nodes[hand].kind == .Sprite && nodes[nodes[hand].parent].name == "arm", "the hand on the arm")
	testing.expect_value(t, nodes[hand].region, "hand")
	// Trimmed: moved by the trim (8 x 8 of 12 x 12, 2 px in: its middle is the frame's)
	testing.expectf(t, near(nodes[hand].position, {30, 0}), "trim offset: %v", nodes[hand].position)
	body := find(nodes, "body")
	testing.expect(t, body >= 0 && nodes[body].kind == .SkinnedMesh, "the mesh")
	testing.expect(t, len(nodes[body].mesh.vertices) == 4 && nodes[body].mesh.uvs[1] == {20, 0}, "vertices and pixels")
	testing.expect(t, len(nodes[body].mesh.bones) == 2 && nodes[body].mesh.bones[1] == "../root/arm", "bones by path")
	testing.expect(t, nodes[body].zIndex == 0 && nodes[hand].zIndex == 1, "slots' order")
	animator := find(nodes, "Animations")
	testing.expect(t, animator >= 0 && len(nodes[animator].animator.clips) == 1, "an Animator")
	clip := nodes[animator].animator.clips[0]
	testing.expect(t, clip.name == "wave" && clip.loop && clip.length == 1, "the clip")
	testing.expect(t, len(clip.tracks) == 1 && clip.tracks[0].node == "root/arm" && clip.tracks[0].property == "rotation" && len(clip.tracks[0].keys) == 3, "the arm's rotation")
	testing.expect_value(t, nodes[animator].animator.autoplay, "wave")
	testing.expect_value(t, len(result.atlas.regions), 2)

	// Built and played: half way, the arm is at 90°
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	{
		context.logger = log.nil_logger()
		_ = Scene_Build(scene, &result.component, "testdata")
	}
	Scene_Update(scene, nil, 0)
	Scene_Update(scene, nil, 0.5)
	armNode := Scene_FindNode(scene, "Robot/root/arm")
	testing.expect(t, armNode != nil && Node_Is(armNode, Bone2D), "the arm built")
	testing.expectf(t, abs(armNode.rotation - 90) < 0.5, "waving: %v", armNode.rotation)
	mesh := cast(^SkinnedMesh)Scene_FindNode(scene, "Robot/body")
	testing.expect(t, mesh != nil && mesh.bound && len(mesh.boneIds) == 2, "the mesh bound")
	// Its right edge follows the arm: turned 90° about (10, 0)
	deformed := SkinnedMesh_Deform(mesh)
	testing.expectf(t, near(deformed[1], {15, 10}, 1), "bent with the arm: %v", deformed[1])

	_, bad := DragonBones_Convert("{}", DB_TEX, "a", "b")
	testing.expect(t, !bad, "not an armature")
}
