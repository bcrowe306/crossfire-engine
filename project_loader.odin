package engine

import "core:log"
import "core:mem"
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
A sprite sheet animation drawn centered on the node's origin. Created from AnimatedSprite nodes:
its player holds the node's animations (by name; "default" when the scene file has none) and
starts the autoplay one. Scripts switch with `AnimationPlayer_Play(&sprite.animation, "jump")`.
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
	text, ok := Platform_ReadFile(path)
	if !ok do return {}, .File_Not_Found
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
	text, ok := Platform_ReadFile(path)
	if !ok do return {}, .File_Not_Found
	return ParseScene(string(text), allocator)
}

/*
Creates every scene of a project in a game and switches to its start scene. Also sets the game's
physics settings from the project. Call from the
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
	game.physics = project.physics
	// In the game's arena: freed with the game (a name set by code is the code's)
	if game.name == "" do game.name = strings.clone(project.name, Game_GetAllocator(game))
	// Data, Global and Save_Game use the game that's playing
	currentGame = game
	// The project's input actions (input.odin) and mix buses (audio_nodes.odin)
	Input_SetActions(game, project.actions[:])
	Audio_SetBuses(game, project.buses[:])
	// Globals exist before the scenes (their nodes' scripts may look them up in `ready`)
	Globals_Start(game, project.globals[:])
	delete(game.projectDir)
	game.projectDir = strings.clone(projectDir)
	ok := true

	for ref in project.scenes {
		path := JoinPath(projectDir, ref.path)
		data, err := LoadSceneFile(path)
		if err != .None {
			log.errorf("Couldn't load scene '%s' from %s: %v", ref.name, path, err)
			ok = false
			continue
		}
		scene := game->createScene(ref.name)
		if scene != nil {
			Scene_Build(scene, &data, projectDir)
			// Kept to build it again when it's entered again (Game_RebuildScene)
			if game.sceneFiles == nil do game.sceneFiles = make(map[string]string, Game_GetAllocator(game))
			game.sceneFiles[strings.clone(ref.name, Game_GetAllocator(game))] = strings.clone(path, Game_GetAllocator(game))
		}
		SceneData_Destroy(&data)
	}

	if project.startScene != "" {
		game->switchScene(project.startScene)
	}
	Globals_Ready(game)
	return ok
}

/*
Creates a scene's nodes from parsed scene data, with the same parent/child structure.

A Camera node becomes a Camera2D node; the first one becomes the scene's camera. Hidden nodes
are created hidden, so game code can show them later. Nodes keep their names (`Scene_FindNode`),
and nodes with a script get it attached (it must be registered: see script.odin); its `ready`
runs on the scene's next update.

Inputs:
- scene: The scene to fill
- data: The parsed scene
- projectDir: Folder that asset paths are relative to
- allocator: Allocator for the returned list
- attachScripts: Attach scripts. The editor's viewport passes false: scripts don't run there

Returns:
- The created nodes, one per entry in `data.nodes` (same order). Editors use it to keep the
  nodes in sync with their own data; the caller owns the slice
*/
Scene_Build :: proc(scene: ^Scene, data: ^SceneData, projectDir: string, allocator := context.temp_allocator, attachScripts := true) -> []^Node {
	return buildNodes(scene, data.nodes[:], projectDir, allocator, attachScripts, 0)
}

/*
Adds an instance of a component to a scene: its whole node tree, built like a scene file's, with
its scripts (their `ready` runs on the scene's next update). Call it as often as needed: each
call makes another instance. The component's file is read once per game and cached.

Inputs:
- scene: The scene
- component: The component (a `COMPONENT_...` constant, or an exported `e.ComponentAsset` field)
- parent: The node to add it under (nil: the top level)
- position: Where its root goes, relative to the parent

Returns:
- The instance's root node (nil, logged, if the component can't be read)

Example:
	bullet := e.Scene_Instantiate(self.scene, COMPONENT_BULLET, position = e.Node_GetWorldPosition(self.node))
*/
Scene_Instantiate :: proc(scene: ^Scene, component: ComponentAsset, parent: ^Node = nil, position: [2]f32 = {}) -> ^Node {
	if scene == nil || scene.game == nil do return nil
	instance := DEFAULT_SCENE_NODE
	instance.kind = .Component
	instance.component = component.path
	instance.position = position
	data, ok := Game_LoadComponent(scene.game, component.path)
	if !ok do return nil
	instance.name = data.name
	created := buildNodes(scene, {instance}, scene.game.projectDir, context.temp_allocator, true, 0)
	root := created[0]
	if root != nil && parent != nil do Node_AddChild(parent, root)
	return root
}

/*
A component's parsed file, read the first time and kept for the game's life (instances share it).

Returns:
- The component's nodes, and false (logged) if it can't be read
*/
Game_LoadComponent :: proc(game: ^Game, path: string) -> (^SceneData, bool) {
	if data, found := game.components[path]; found do return data, data != nil
	allocator := Game_GetAllocator(game)
	if game.components == nil do game.components = make(map[string]^SceneData, allocator)
	full := JoinPath(game.projectDir, path)
	text, read := Platform_ReadFile(full)
	data: ^SceneData
	if !read {
		log.errorf("Couldn't read component %s", full)
	} else if parsed, err := ParseComponent(string(text), allocator); err != .None {
		log.errorf("Couldn't load component %s: %v", full, err)
	} else if len(parsed.nodes) == 0 {
		log.errorf("Component %s has no nodes", full)
	} else {
		data = new_clone(parsed, allocator)
	}
	game.components[strings.clone(path, allocator)] = data
	return data, data != nil
}

// Components can hold instances of other components, this many deep (a component that holds
// itself would never end)
@(private="file")
MAX_COMPONENT_DEPTH :: 16

// Builds nodes (a scene's or a component's), components' instances included
@(private)
buildNodes :: proc(scene: ^Scene, nodes: []SceneNodeData, projectDir: string, allocator: mem.Allocator, attachScripts: bool, depth: int) -> []^Node {
	rm := &scene.game.resourceManager
	created := make([]^Node, len(nodes), allocator)

	for &node, i in nodes {
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
				if len(node.animations) == 0 {
					AnimationPlayer_Add(&sprite.animation, CreateSpriteSheetAnimation("default", texture, node.columns, node.rows,
						node.fps, node.loop, playMode = node.playMode, margin = node.margin, spacing = node.spacing, allocator = allocator))
				}
				for a in node.animations {
					AnimationPlayer_Add(&sprite.animation, CreateSpriteSheetAnimation(a.name, texture, node.columns, node.rows,
						a.fps, a.loop, a.start, a.end, a.playMode, node.margin, node.spacing, allocator))
				}
				// The autoplay animation, else the first
				if node.autoplay == "" || !AnimationPlayer_Play(&sprite.animation, node.autoplay) do AnimationPlayer_Play(&sprite.animation, 0)
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

		case .StaticBody:
			n = CreateStaticBody(scene)
		case .DynamicBody:
			body := CreateDynamicBody(scene)
			body.gravityScale = node.gravityScale
			body.linearDamping = node.linearDamping
			body.angularDamping = node.angularDamping
			body.fixedRotation = node.fixedRotation
			body.bullet = node.bullet
			n = body
		case .CharacterMover:
			mover := CreateCharacterMover(scene)
			mover.floorMaxAngle = node.floorMaxAngle
			n = mover
		case .Area:
			n = CreateArea(scene)
		case .CollisionShape:
			shape := CreateCollisionShape(scene, node.shape)
			shape.size = node.shapeSize
			shape.radius = node.radius
			shape.height = node.shapeSize.y
			shape.disabled = node.disabled
			append(&shape.points, ..node.points[:])
			n = shape
		case .RayCast:
			ray := CreateRayCast(scene, node.target)
			ray.collisionMask = node.collisionMask
			ray.enabled = node.enabled
			ray.excludeParent = node.excludeParent
			n = ray
		case .Joint:
			joint := CreateJoint(scene, node.jointKind)
			allocator := Node_GetAllocator(joint)
			joint.bodyA = strings.clone(node.bodyA, allocator)
			joint.bodyB = strings.clone(node.bodyB, allocator)
			joint.offset = node.jointOffset
			joint.enableLimit, joint.lower, joint.upper = node.enableLimit, node.lower, node.upper
			joint.enableMotor, joint.motorSpeed, joint.maxMotor = node.enableMotor, node.motorSpeed, node.maxMotor
			joint.enableSpring, joint.hertz, joint.dampingRatio = node.enableSpring, node.hertz, node.dampingRatio
			joint.collideConnected = node.collideConnected
			n = joint
		case .ParticleEmitter:
			emitter := CreateParticleEmitter(scene, node.particles)
			emitter.texture = loadAsset(rm, projectDir, node.texture)
			n = emitter
		case .AudioPlayer, .AudioPlayer2D, .MusicPlayer:
			kind := node.kind == .MusicPlayer ? AudioPlayerKind.Music : node.kind == .AudioPlayer2D ? AudioPlayerKind.Positional : AudioPlayerKind.Sound
			player := CreateAudioPlayer(scene, kind, node.audio)
			player.bus = strings.clone(node.bus, Node_GetAllocator(player))
			// Sounds don't play in tools that build scenes without scripts (the editor's viewport)
			if attachScripts do AudioPlayer_SetSound(player, node.sound)
			else do player.sound = strings.clone(node.sound, Node_GetAllocator(player))
			n = player
		case .Component:
			// The component's tree in its place; its root takes this node's name, transform,
			// layer and visibility (below). A missing component leaves an empty node
			data: ^SceneData
			ok: bool
			if node.component != "" && depth < MAX_COMPONENT_DEPTH {
				data, ok = Game_LoadComponent(scene.game, node.component)
			} else if depth >= MAX_COMPONENT_DEPTH {
				log.errorf("%s: components nested more than %d deep (does %s hold itself?)", node.name, MAX_COMPONENT_DEPTH, node.component)
			}
			if ok {
				n = buildNodes(scene, data.nodes[:], projectDir, context.temp_allocator, attachScripts, depth + 1)[0]
			} else {
				n = CreateNode(scene, Node)
			}
		case .LDtkLevel:
			n = ldtkBuildNode(scene, &node, projectDir, attachScripts, depth)
		}
		if Node_IsPhysicsBody(n) {
			body := cast(^PhysicsBody)n
			body.collisionLayer = node.collisionLayer
			body.collisionMask = node.collisionMask
			body.friction = node.friction
			body.restitution = node.restitution
			body.density = node.density
		}

		n.name = strings.clone(node.name, Node_GetAllocator(n))
		n.position = node.position
		n.rotation = node.rotation
		n.scale = node.scale
		n.layer = RenderLayer(clamp(node.layer, 0, len(RenderLayer) - 1))
		n.visible = node.visible
		if node.parent >= 0 && created[node.parent] != nil {
			Node_AddChild(created[node.parent], n)
		}
		if node.script != "" && attachScripts {
			if n.script.info != nil {
				log.warnf("%s: its component's root has a script already; '%s' isn't attached", node.name, node.script)
			} else if info := Script_Find(node.script); info != nil {
				Node_AttachScript(n, info, node.props[:])
			} else {
				log.warnf("%s: no script named '%s' (is the project's scripts package built into this player?)", node.name, node.script)
			}
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
	fullPath := JoinPath(projectDir, path)
	return rm->loadTexture(fullPath)
}
