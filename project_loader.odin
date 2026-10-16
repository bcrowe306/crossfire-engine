package engine

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"

// Builds engine scenes from project files (format: project_format.odin)

/*
A texture drawn centered on the node's origin. Created from Sprite nodes in scene files; its
size comes from the texture and the node's scale.
*/
Sprite :: struct {
	using node: Node,
	texture: ^sdl.Texture,
}

/*
A sprite sheet animation drawn centered on the node's origin. Created from AnimatedSprite nodes;
it plays its single animation, "default", from the start.
*/
AnimatedSprite :: struct {
	using node: Node,
	animation: AnimationPlayer,
}

/*
Reads and parses a project.xml file.

Inputs:
- path: Path to project.xml
- allocator: Allocator for the result. Free with `ProjectData_Destroy`

Returns:
- The project data, and .None or what went wrong
*/
LoadProjectFile :: proc(path: string, allocator := context.allocator) -> (ProjectData, ProjectError) {
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, .File_Not_Found
	return ParseProject(string(text), allocator)
}

/*
Reads and parses a scene file.

Inputs:
- path: Path to the .scene.xml file
- allocator: Allocator for the result. Free with `SceneData_Destroy`

Returns:
- The scene data, and .None or what went wrong
*/
LoadSceneFile :: proc(path: string, allocator := context.allocator) -> (SceneData, ProjectError) {
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, .File_Not_Found
	return ParseScene(string(text), allocator)
}

/*
Creates every scene of a project in a game and switches to its start scene. Call from the
game's `build` procedure, after `game.size` and `game.scaleMode` were set from the project
(the scenes' cameras and menus are positioned for that size).

Asset paths are resolved against the project folder, so the game can run from any directory.

Inputs:
- game: The game, during Game_Init
- project: The parsed project.xml
- projectDir: Folder containing project.xml

Returns:
- false if a scene file couldn't be loaded (the others are still created)

Example:
	project, err := e.LoadProjectFile("MyGame/project.xml")
	game.size = project.size
	game.scaleMode = project.scaleMode
	game.build = proc(game: ^e.Game) { e.Game_LoadProject(game, &project, "MyGame") }
*/
Game_LoadProject :: proc(game: ^Game, project: ^ProjectData, projectDir: string) -> bool {
	game.backgroundColor = project.background
	ok := true

	for ref in project.scenes {
		path, _ := filepath.join({projectDir, ref.path}, context.temp_allocator)
		data, err := LoadSceneFile(path)
		if err != .None {
			log.errorf("Couldn't load scene '%s' from %s: %v", ref.name, path, err)
			ok = false
			continue
		}
		scene := game->createScene(ref.name)
		if scene != nil do Scene_Build(scene, &data, projectDir)
		SceneData_Destroy(&data)
	}

	if project.startScene != "" {
		game->switchScene(project.startScene)
	}
	return ok
}

/*
Creates a scene's nodes from parsed scene data, with the same parent/child structure.

A Camera node becomes a Camera2D node; the first one becomes the scene's camera. Hidden nodes
are created hidden, so game code can show them later.

Inputs:
- scene: The scene to fill
- data: The parsed scene
- projectDir: Folder that asset paths are relative to
- allocator: Allocator for the returned list

Returns:
- The created nodes, one per entry in `data.nodes` (same order). Editors use it to keep the
  nodes in sync with their own data; the caller owns the slice
*/
Scene_Build :: proc(scene: ^Scene, data: ^SceneData, projectDir: string, allocator := context.temp_allocator) -> []^Node {
	rm := &scene.game.resourceManager
	created := make([]^Node, len(data.nodes), allocator)

	for &node, i in data.nodes {
		n: ^Node
		switch node.kind {
		case .Node2D:
			n = CreateNode(scene, Node)

		case .Camera:
			camera := CreateNode(scene, Camera2D)
			camera.zoom = node.zoom
			camera.follow = DEFAULT_CAMERA_FOLLOW
			camera.offset = scene.game.size * 0.5
			if scene.camera == nil do scene.camera = camera
			n = camera

		case .Sprite:
			sprite := CreateNode(scene, Sprite)
			sprite.draw = Sprite_draw
			sprite.getBounds = Sprite_getBounds
			sprite.texture = loadAsset(rm, projectDir, node.texture)
			n = sprite

		case .AnimatedSprite:
			sprite := CreateNode(scene, AnimatedSprite)
			sprite.update = AnimatedSprite_update
			sprite.draw = AnimatedSprite_draw
			sprite.getBounds = AnimatedSprite_getBounds
			allocator := Node_GetAllocator(sprite)
			AnimationPlayer_Init(&sprite.animation, allocator)
			texture := loadAsset(rm, projectDir, node.texture)
			if texture != nil {
				AnimationPlayer_Add(&sprite.animation, CreateSpriteSheetAnimation("default", texture,
					node.columns, node.rows, node.fps, node.loop, playMode = node.playMode, allocator = allocator))
				AnimationPlayer_Play(&sprite.animation, "default")
			}
			n = sprite

		case .Label:
			n = CreateLabel(scene, node.text, node.position, node.fontSize, node.color, node.centered)

		case .Menu:
			menu := CreateMenu(scene, node.position)
			allocator := Node_GetAllocator(menu)
			for item in node.items {
				button := Menu_AddButton(menu, item.label, runMenuAction)
				action := new(string, allocator)
				action^ = strings.clone(item.action, allocator)
				button.userData = action
			}
			n = menu
		}

		n.position = node.position
		n.rotation = node.rotation
		n.scale = node.scale
		n.layer = RenderLayer(clamp(node.layer, 0, len(RenderLayer) - 1))
		n.visible = node.visible
		if node.parent >= 0 && created[node.parent] != nil {
			Node_AddChild(created[node.parent], n)
		}
		created[i] = n
	}
	return created
}

Sprite_draw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	sprite := cast(^Sprite)node
	if sprite.texture == nil do return
	size := [2]f32{f32(sprite.texture.w), f32(sprite.texture.h)}
	DrawTexture(renderer, sprite.texture, {-size.x * 0.5, -size.y * 0.5, size.x, size.y})
}

Sprite_getBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	sprite := cast(^Sprite)node
	if sprite.texture == nil do return {}, false
	w, h := f32(sprite.texture.w), f32(sprite.texture.h)
	return {-w * 0.5, -h * 0.5, w, h}, true
}

AnimatedSprite_getBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	size := AnimationPlayer_FrameSize(&(cast(^AnimatedSprite)node).animation)
	if size == {} do return {}, false
	return {-size.x * 0.5, -size.y * 0.5, size.x, size.y}, true
}

AnimatedSprite_update :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	AnimationPlayer_Update(&(cast(^AnimatedSprite)node).animation, deltaTime)
}

AnimatedSprite_draw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	sprite := cast(^AnimatedSprite)node
	size := AnimationPlayer_FrameSize(&sprite.animation)
	AnimationPlayer_Draw(&sprite.animation, renderer, {-size.x * 0.5, -size.y * 0.5, size.x, size.y})
}

// Menu buttons from scene files: "scene:<Name>" switches scene, "quit" quits
@(private="file")
runMenuAction :: proc(menu: ^Menu, item: ^MenuItem) {
	if item.userData == nil do return
	action := (cast(^string)item.userData)^
	game := menu.scene.game
	switch {
	case action == "quit":
		game.shouldQuit = true
	case strings.has_prefix(action, "scene:"):
		game->switchScene(action[len("scene:"):])
	case:
		log.warnf("Unknown menu action '%s'", action)
	}
}

@(private="file")
loadAsset :: proc(rm: ^ResourceManager, projectDir, path: string) -> ^sdl.Texture {
	if path == "" do return nil
	fullPath, _ := filepath.join({projectDir, path}, context.temp_allocator)
	return rm->loadTexture(fullPath)
}
