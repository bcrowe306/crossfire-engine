#+build !js
package crossfire

import "core:strings"
import "core:sync"
import "core:testing"

// Script node fields (pointers to nodes, set from paths before ready) and Node_FindPath

LinkScript :: struct {
	using script: Script,
	hand: ^Node `export:"default=Arm/Hand"`,
	picture: ^Sprite `export:"default=../Pic"`,
	world: ^Node `export:"default=/World"`,
	// DynamicBody embeds PhysicsBody: accepted
	body: ^PhysicsBody `export:"default=../Ball"`,
	// Arm is a plain Node: not a Sprite, stays nil
	wrong: ^Sprite `export:"default=Arm"`,
	missing: ^Node `export:"default=Nope"`,
	empty: ^Node `export:""`,
	// Seen by ready: the fields were set before it ran
	handAtReady: ^Node,
}

@(private="file")
linkOnce: sync.Once

@(private="file")
registerLinkScript :: proc() {
	sync.once_do(&linkOnce, proc() {
		Script_Register(LinkScript, {ready = proc(self: ^LinkScript) { self.handAtReady = self.hand }})
	})
}

@(private="file")
named :: proc(scene: ^Scene, $T: typeid, name: string, parent: ^Node = nil) -> ^T {
	node := CreateNode(scene, T)
	node.name = name
	if parent != nil do Node_AddChild(parent, node)
	return node
}

@(test)
node_paths_find_children_parents_and_the_top_level :: proc(t: ^testing.T) {
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	world := named(scene, Node, "World")
	hero := named(scene, Node, "Hero")
	arm := named(scene, Node, "Arm", hero)
	hand := named(scene, Node, "Hand", arm)
	Scene_ProcessQueues(scene)

	testing.expect(t, Node_FindPath(hero, "Arm/Hand") == hand, "children")
	testing.expect(t, Node_FindPath(hand, "..") == arm, "the parent")
	testing.expect(t, Node_FindPath(hand, "../../Arm/./Hand") == hand, ". and ..")
	testing.expect(t, Node_FindPath(hero, "../World") == world, "a top-level sibling")
	testing.expect(t, Node_FindPath(hand, "/World") == world && Node_FindPath(world, "/Hero/Arm") == arm, "from the top level")
	testing.expect(t, Node_FindPath(hero, ".") == hero, "itself")
	testing.expect(t, Node_FindPath(hero, "") == nil && Node_FindPath(hero, "Nope") == nil, "nothing")
	testing.expect(t, Node_FindPath(hero, "..") == nil && Node_FindPath(hero, "../..") == nil, "not above the top level")
	// Scene_FindNode takes the same paths from the top level ("/", the editor's PATH_ constants)
	testing.expect(t, Scene_FindNode(scene, "/Hero/Arm/Hand") == hand && Scene_FindNode(scene, "/World") == world, "/ paths")
	testing.expect(t, Scene_FindNode(scene, "/Arm") == nil && Scene_FindNode(scene, "Arm") == arm, "/Arm is a top-level Arm only")
	testing.expect(t, Scene_FindNode(scene, "Hero/Arm/Hand") == hand, "a path without / as before")
}

@(test)
script_node_fields_are_set_before_ready :: proc(t: ^testing.T) {
	registerLinkScript()
	info := Script_Find("LinkScript")
	if !testing.expect(t, info != nil) do return
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	world := named(scene, Node, "World")
	hero := named(scene, Node, "Hero")
	arm := named(scene, Node, "Arm", hero)
	hand := named(scene, Node, "Hand", arm)
	picture := named(scene, Sprite, "Pic")
	ball := named(scene, DynamicBody, "Ball")
	other := named(scene, Sprite, "Other")

	// The catalog tells the editor the pointed type
	for field in info.fields do if field.name == "picture" {
		testing.expect_value(t, field.type, ScriptFieldType.Node)
		testing.expect_value(t, field.hint, "Sprite")
	}
	testing.expect(t, strings.contains(Script_DescribeJSON(context.temp_allocator), `"name": "body", "type": "Node", "default": "../Ball", "hint": "PhysicsBody"`), "described")

	self := cast(^LinkScript)Node_AttachScript(hero, info, nil)
	// A scene file's value replaces the default
	second := named(scene, Node, "Second")
	self2 := cast(^LinkScript)Node_AttachScript(second, info, {{"picture", "../Other"}, {"hand", ""}})
	testing.expect(t, self.hand == nil, "not before ready")
	Scene_ProcessQueues(scene)
	Scene_ReadyScripts(scene)

	testing.expect(t, self.hand == hand && self.handAtReady == hand, "set before ready")
	testing.expect(t, self.picture == picture, "a sibling, of its type")
	testing.expect(t, self.world == world, "from the top level")
	testing.expect(t, self.body == &ball.body, "a type that embeds the field's")
	testing.expect(t, self.wrong == nil && self.missing == nil && self.empty == nil, "wrong type, missing, empty: nil")
	testing.expect(t, self2.picture == other && self2.hand == nil, "the scene file's paths")
	free_all(context.temp_allocator)
}

@(test)
node_kinds_fit_node_fields :: proc(t: ^testing.T) {
	testing.expect(t, SceneNodeKind_IsType(.Sprite, "Sprite"), "its own type")
	testing.expect(t, SceneNodeKind_IsType(.DynamicBody, "PhysicsBody"), "an embedded type")
	for kind in SceneNodeKind do testing.expectf(t, SceneNodeKind_IsType(kind, "Node"), "%v is a Node", kind)
	testing.expect(t, !SceneNodeKind_IsType(.Sprite, "Area"), "another type")
	testing.expect(t, !SceneNodeKind_IsType(.Node2D, "Sprite"), "not the other way")
}
