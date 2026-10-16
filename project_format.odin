/*
Project and scene files: the XML format the editor saves and the engine loads.

A project is a folder:

	MyGame/
		project.xml             settings, the scene list and the asset list
		scenes/Menu.scene.xml   one file per scene
		assets/...              images, audio, fonts

project.xml:

	<?xml version="1.0" encoding="UTF-8"?>
	<project formatVersion="2" name="Asteroids" width="1280" height="720"
	         scaleMode="Letterbox" background="#0f121e" startScene="MenuScene">
		<scene name="MenuScene" path="scenes/MenuScene.scene.xml"/>
		<asset path="assets/ship.png" kind="Image"/>
	</project>

A scene file holds a tree of nodes. Nesting is the hierarchy, and a node's `x`, `y`, `rotation`
and scale are relative to its parent:

	<?xml version="1.0" encoding="UTF-8"?>
	<scene formatVersion="2" name="PlayScene">
		<node kind="Node2D" name="World" x="0" y="0">
			<node kind="Camera" name="Camera" x="640" y="360" zoom="1"/>
			<node kind="Sprite" name="Ship" x="640" y="430" texture="assets/ship.png">
				<node kind="AnimatedSprite" name="Flame" x="0" y="40" texture="assets/flame.png"
				      columns="4" rows="1" fps="12"/>
			</node>
		</node>
		<node kind="Label" name="Title" x="640" y="180" text="ASTEROIDS" fontSize="64"
		      color="#ebf0ff" centered="true" layer="7"/>
		<node kind="Menu" name="MainMenu" x="640" y="300" layer="7">
			<item label="Play" action="scene:PlayScene"/>
			<item label="Quit" action="quit"/>
		</node>
	</scene>

Attributes every node may have: `kind`, `name`, `x`, `y`, `rotation` (degrees), `scaleX`,
`scaleY`, `layer` (0-7), `visible`. Kind-specific attributes are listed on `SceneNodeData`.
Missing attributes use the defaults in `DEFAULT_SCENE_NODE`. Paths are relative to the project
folder and use `/`. Colors are `#rrggbb` or `#rrggbbaa`.

Current limits:
- A scene's Camera applies to every node in it, including Labels and Menus (scene files can't
  set `scene.screenLayers` yet).
- Labels and Menus follow their position only; their rotation and scale are ignored.
- Only images are loaded; Audio and Font assets are listed but not used.

Version history:
- 2: positions, rotation and scale are relative to the parent. A Camera's rotation turns the
  view the way a rotated camera would (the world appears to turn the other way).
- 1: positions were world coordinates and parents had no effect; Camera rotation rotated the
  world. Version 1 scenes are converted when parsed.

Parsing (this file) only turns XML into plain data, without SDL, so it can be tested and used
by the editor. `project_loader.odin` builds engine scenes and nodes from that data.
*/

package engine

import "core:encoding/xml"
import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

// Version written by the editor. This loader also reads older versions
PROJECT_FORMAT_VERSION :: 2

/*
Node kinds a scene file can contain.
*/
SceneNodeKind :: enum {
	// Groups other nodes; draws nothing
	Node2D,
	// A texture
	Sprite,
	// A sprite sheet animation
	AnimatedSprite,
	// Configures the scene's camera; not a drawn node
	Camera,
	// Text
	Label,
	// Vertical button menu whose buttons switch scenes or quit
	Menu,
}

/*
What a node kind is, for tools that let users pick one (the editor's Add Node dialog).
*/
SceneNodeKindInfo :: struct {
	// One line describing what the node does
	description: string,
}

/*
Every node kind a scene file can contain, with its description. Tools list node kinds from this
table, so a kind added to `SceneNodeKind` must be described here (the compiler enforces it).

Example:
	for kind in e.SceneNodeKind {
		fmt.printfln("%v: %s", kind, e.SCENE_NODE_KINDS[kind].description)
	}
*/
SCENE_NODE_KINDS := [SceneNodeKind]SceneNodeKindInfo{
	.Node2D         = {"Groups nodes; moving, rotating or scaling it moves its children"},
	.Sprite         = {"Draws an image"},
	.AnimatedSprite = {"Plays a sprite sheet animation"},
	.Camera         = {"Chooses the part of the scene the game shows; can follow a parent node"},
	.Label          = {"Draws a line of text"},
	.Menu           = {"A list of buttons that switch scenes or quit the game"},
}

/*
A button in a Menu node. `action` is `scene:<SceneName>` to switch scene, or `quit`.
*/
MenuItemData :: struct {
	label: string,
	action: string,
}

/*
One node from a scene file. Fields that don't apply to a node's kind are ignored.
*/
SceneNodeData :: struct {
	kind: SceneNodeKind,
	name: string,
	// Index of the parent node, -1 for top-level nodes. Nodes are stored depth-first:
	// every node's children follow it directly
	parent: int,
	// Position relative to the parent. Sprites and labels are centered on it (labels unless
	// `centered` is false)
	position: [2]f32,
	rotation: f32,
	scale: [2]f32,
	layer: int,
	// Hidden nodes, and everything under them, aren't drawn
	visible: bool,

	// Sprite, AnimatedSprite: image path relative to the project folder
	texture: string,
	// Label
	text: string,
	fontSize: f32,
	color: sdl.Color,
	centered: bool,
	// Camera
	zoom: f32,
	// AnimatedSprite: the texture is a columns x rows grid of frames
	columns: int,
	rows: int,
	fps: f32,
	loop: bool,
	playMode: AnimationPlayMode,
	// Menu
	items: [dynamic]MenuItemData,
}

// Values used for attributes a node doesn't specify
DEFAULT_SCENE_NODE :: SceneNodeData{
	parent = -1,
	scale = {1, 1},
	visible = true,
	fontSize = 24,
	color = {255, 255, 255, 255},
	centered = true,
	zoom = 1,
	columns = 1,
	rows = 1,
	fps = 8,
	loop = true,
}

SceneData :: struct {
	name: string,
	nodes: [dynamic]SceneNodeData,
}

SceneRef :: struct {
	name: string,
	// Scene file path relative to the project folder
	path: string,
}

AssetRef :: struct {
	path: string,
	// "Image", "Audio" or "Font"
	kind: string,
}

ProjectData :: struct {
	name: string,
	size: [2]f32,
	scaleMode: ScaleMode,
	background: sdl.Color,
	startScene: string,
	scenes: [dynamic]SceneRef,
	assets: [dynamic]AssetRef,
}

ProjectError :: enum {
	None,
	File_Not_Found,
	Invalid_XML,
	// The root element isn't <project> / <scene>
	Wrong_Root,
	// formatVersion is newer than PROJECT_FORMAT_VERSION
	Unsupported_Version,
}

/*
Parses the text of a project.xml file.

Inputs:
- text: The XML
- allocator: Allocator for the result's strings and lists

Returns:
- The project data, and .None or what went wrong. Free with `ProjectData_Destroy`

Example:
	project, err := e.ParseProject(xmlText)
	defer e.ProjectData_Destroy(&project)
*/
ParseProject :: proc(text: string, allocator := context.allocator) -> (project: ProjectData, err: ProjectError) {
	doc := parseXML(text) or_return
	defer xml.destroy(doc)
	if doc.elements[0].ident != "project" do return {}, .Wrong_Root
	checkVersion(doc, 0) or_return

	context.allocator = allocator
	project = {
		name = cloneAttr(doc, 0, "name", ""),
		size = {attrF32(doc, 0, "width", 1280), attrF32(doc, 0, "height", 720)},
		scaleMode = attrEnum(doc, 0, "scaleMode", ScaleMode.Letterbox),
		background = attrColor(doc, 0, "background", {0, 0, 0, 255}),
		startScene = cloneAttr(doc, 0, "startScene", ""),
		scenes = make([dynamic]SceneRef),
		assets = make([dynamic]AssetRef),
	}
	for child in childElements(doc, 0) {
		switch doc.elements[child].ident {
		case "scene":
			append(&project.scenes, SceneRef{cloneAttr(doc, child, "name", ""), cloneAttr(doc, child, "path", "")})
		case "asset":
			append(&project.assets, AssetRef{cloneAttr(doc, child, "path", ""), cloneAttr(doc, child, "kind", "")})
		}
	}
	if project.startScene == "" && len(project.scenes) > 0 {
		project.startScene = strings.clone(project.scenes[0].name)
	}
	return project, .None
}

/*
Parses the text of a scene file.

Inputs:
- text: The XML
- allocator: Allocator for the result's strings and lists

Returns:
- The scene data with its nodes in depth-first order, and .None or what went wrong.
  Free with `SceneData_Destroy`
*/
ParseScene :: proc(text: string, allocator := context.allocator) -> (scene: SceneData, err: ProjectError) {
	doc := parseXML(text) or_return
	defer xml.destroy(doc)
	if doc.elements[0].ident != "scene" do return {}, .Wrong_Root
	checkVersion(doc, 0) or_return

	context.allocator = allocator
	scene.name = cloneAttr(doc, 0, "name", "")
	scene.nodes = make([dynamic]SceneNodeData)
	for child in childElements(doc, 0) {
		if doc.elements[child].ident == "node" do parseNode(doc, child, -1, &scene)
	}
	if attrInt(doc, 0, "formatVersion", 1) < 2 do migrateSceneFromV1(&scene)
	return scene, .None
}

/*
Frees everything `ParseProject` allocated. Must use the same allocator.
*/
ProjectData_Destroy :: proc(project: ^ProjectData, allocator := context.allocator) {
	context.allocator = allocator
	for s in project.scenes { delete(s.name); delete(s.path) }
	delete(project.scenes)
	for a in project.assets { delete(a.path); delete(a.kind) }
	delete(project.assets)
	delete(project.name)
	delete(project.startScene)
	project^ = {}
}

/*
Frees everything `ParseScene` allocated. Must use the same allocator.
*/
SceneData_Destroy :: proc(scene: ^SceneData, allocator := context.allocator) {
	context.allocator = allocator
	for &node in scene.nodes {
		delete(node.name)
		delete(node.texture)
		delete(node.text)
		for item in node.items { delete(item.label); delete(item.action) }
		delete(node.items)
	}
	delete(scene.nodes)
	delete(scene.name)
	scene^ = {}
}

/*
Formats a color the way the format stores it: `#rrggbb`, or `#rrggbbaa` when not opaque.

Inputs:
- color: The color
- allocator: Allocator for the string

Returns:
- The color text
*/
FormatColor :: proc(color: sdl.Color, allocator := context.allocator) -> string {
	if color.a == 255 do return fmt.aprintf("#%02x%02x%02x", color.r, color.g, color.b, allocator = allocator)
	return fmt.aprintf("#%02x%02x%02x%02x", color.r, color.g, color.b, color.a, allocator = allocator)
}

/*
Parses `#rrggbb` or `#rrggbbaa`.

Inputs:
- text: The color text

Returns:
- The color, and false if the text isn't a valid color
*/
ParseColor :: proc(text: string) -> (sdl.Color, bool) {
	if len(text) != 7 && len(text) != 9 || text[0] != '#' do return {}, false
	value, ok := strconv.parse_u64_of_base(text[1:], 16)
	if !ok do return {}, false
	if len(text) == 7 do value = value << 8 | 0xff
	return {u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value)}, true
}


// INTERNAL

@(private="file")
parseXML :: proc(text: string) -> (^xml.Document, ProjectError) {
	// The default error handler prints to stdout; failures are reported through the return value
	silent :: proc(pos: xml.Pos, msg: string, args: ..any) {}
	doc, err := xml.parse_string(text, {flags = {.Ignore_Unsupported, .Decode_SGML_Entities}}, error_handler = silent)
	if err != .None || doc == nil || len(doc.elements) == 0 {
		xml.destroy(doc)
		return nil, .Invalid_XML
	}
	return doc, .None
}

@(private="file")
checkVersion :: proc(doc: ^xml.Document, element: xml.Element_ID) -> ProjectError {
	if attrInt(doc, element, "formatVersion", 1) > PROJECT_FORMAT_VERSION do return .Unsupported_Version
	return .None
}

@(private="file")
parseNode :: proc(doc: ^xml.Document, element: xml.Element_ID, parent: int, scene: ^SceneData) {
	node := DEFAULT_SCENE_NODE
	node.parent = parent
	node.kind = attrEnum(doc, element, "kind", SceneNodeKind.Node2D)
	node.name = cloneAttr(doc, element, "name", fmt.tprintf("%v", node.kind))
	node.position = {attrF32(doc, element, "x", 0), attrF32(doc, element, "y", 0)}
	node.rotation = attrF32(doc, element, "rotation", 0)
	node.scale = {attrF32(doc, element, "scaleX", 1), attrF32(doc, element, "scaleY", 1)}
	node.layer = clamp(attrInt(doc, element, "layer", 0), 0, len(RenderLayer) - 1)
	node.visible = attrBool(doc, element, "visible", true)
	node.texture = cloneAttr(doc, element, "texture", "")
	node.text = cloneAttr(doc, element, "text", "")
	node.fontSize = attrF32(doc, element, "fontSize", DEFAULT_SCENE_NODE.fontSize)
	node.color = attrColor(doc, element, "color", DEFAULT_SCENE_NODE.color)
	node.centered = attrBool(doc, element, "centered", true)
	node.zoom = attrF32(doc, element, "zoom", 1)
	node.columns = max(attrInt(doc, element, "columns", 1), 1)
	node.rows = max(attrInt(doc, element, "rows", 1), 1)
	node.fps = attrF32(doc, element, "fps", DEFAULT_SCENE_NODE.fps)
	node.loop = attrBool(doc, element, "loop", true)
	node.playMode = attrEnum(doc, element, "playMode", AnimationPlayMode.Forward)
	node.items = make([dynamic]MenuItemData)

	index := len(scene.nodes)
	append(&scene.nodes, node)

	for child in childElements(doc, element) {
		switch doc.elements[child].ident {
		case "node":
			parseNode(doc, child, index, scene)
		case "item":
			append(&scene.nodes[index].items, MenuItemData{
				cloneAttr(doc, child, "label", ""),
				cloneAttr(doc, child, "action", ""),
			})
		}
	}
}

// Version 1 stored world positions (parents had no effect) and rotated the world by a camera's
// rotation. Since parents had no rotation or scale effect, local = world - parent's world
@(private="file")
migrateSceneFromV1 :: proc(scene: ^SceneData) {
	// Children come after their parents, so walking backwards still sees each parent's world value
	#reverse for &node in scene.nodes {
		if node.parent >= 0 do node.position -= scene.nodes[node.parent].position
		if node.kind == .Camera do node.rotation = -node.rotation
	}
}

// Child elements in document order (temp allocated)
@(private="file")
childElements :: proc(doc: ^xml.Document, element: xml.Element_ID) -> []xml.Element_ID {
	children := make([dynamic]xml.Element_ID, context.temp_allocator)
	for value in doc.elements[element].value {
		if id, ok := value.(xml.Element_ID); ok && doc.elements[id].kind == .Element {
			append(&children, id)
		}
	}
	return children[:]
}

@(private="file")
cloneAttr :: proc(doc: ^xml.Document, element: xml.Element_ID, key, default: string) -> string {
	value, found := xml.find_attribute_val_by_key(doc, element, key)
	return strings.clone(found ? value : default)
}

@(private="file")
attrF32 :: proc(doc: ^xml.Document, element: xml.Element_ID, key: string, default: f32) -> f32 {
	value, found := xml.find_attribute_val_by_key(doc, element, key)
	if !found do return default
	result, ok := strconv.parse_f32(value)
	return ok ? result : default
}

@(private="file")
attrInt :: proc(doc: ^xml.Document, element: xml.Element_ID, key: string, default: int) -> int {
	value, found := xml.find_attribute_val_by_key(doc, element, key)
	if !found do return default
	result, ok := strconv.parse_int(value)
	return ok ? result : default
}

@(private="file")
attrBool :: proc(doc: ^xml.Document, element: xml.Element_ID, key: string, default: bool) -> bool {
	value, found := xml.find_attribute_val_by_key(doc, element, key)
	if !found do return default
	return value == "true" || value == "1"
}

@(private="file")
attrColor :: proc(doc: ^xml.Document, element: xml.Element_ID, key: string, default: sdl.Color) -> sdl.Color {
	value, found := xml.find_attribute_val_by_key(doc, element, key)
	if !found do return default
	color, ok := ParseColor(value)
	return ok ? color : default
}

@(private="file")
attrEnum :: proc(doc: ^xml.Document, element: xml.Element_ID, key: string, default: $E) -> E {
	value, found := xml.find_attribute_val_by_key(doc, element, key)
	if !found do return default
	result, ok := reflect.enum_from_name(E, value)
	return ok ? result : default
}
