package crossfire

import "base:runtime"
import "core:log"
import "core:mem"
import "core:reflect"
import "core:strings"
import sdl "vendor:sdl3"

// Builds engine scenes from project files (format: project_format.odin)

/*
A texture drawn centered on the node's origin. Created from Sprite nodes in scene files; its
size comes from the texture and the node's scale.
*/
Sprite :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// The image it draws (the resource manager's; nil draws nothing)
	texture: ^sdl.Texture,
	// Its Aseprite file, when the image is one (full path, node arena; "" otherwise): its slices
	source: string,
	// The slice whose pivot is drawn at the origin ("": the middle; aseprite_nodes.odin)
	pivotSlice: string,
	// A 9-patch slice it draws stretched to `nineSize` ("": the whole image)
	nineSlice: string,
	// The 9-patch's size (0: the slice's own)
	nineSize: [2]f32,
}

/*
A sprite sheet animation drawn centered on the node's origin. Created from AnimatedSprite nodes:
its player holds the node's animations (by name; "default" when the scene file has none) and
starts the autoplay one. Scripts switch with `AnimationPlayer_Play(&sprite.animation, "jump")`.
*/
AnimatedSprite :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Its animations and the one playing (updated with the node; allocated in the node's arena)
	animation: AnimationPlayer,
	// Its Aseprite file, when its sheet is one (full path, node arena; "" otherwise): its slices
	source: string,
	// Its cells are the file's frames (an Aseprite file's animations), so slices follow them
	sourceFrames: bool,
	// The slice whose pivot is drawn at the origin, frame by frame ("": the middle)
	pivotSlice: string,
	// The Aseprite layers it draws ("": every visible one; node arena)
	layers: string,
}

/*
Reads and parses a project.xml file.

Inputs:
- path: Path to project.xml
- allocator: Allocator for the result. Free with `ProjectData_Destroy`

Returns:
- The project data, and .None or what went wrong (.File_Not_Found when it can't be read)

Example:
	project, err := e.LoadProjectFile("MyGame/project.xml")
	if err != .None do log.errorf("Can't load the project: %v", err)
	defer e.ProjectData_Destroy(&project)
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
- The scene data, and .None or what went wrong (.File_Not_Found when it can't be read)
*/
LoadSceneFile :: proc(path: string, allocator := context.allocator) -> (SceneData, ProjectError) {
	text, ok := Platform_ReadFile(path)
	if !ok do return {}, .File_Not_Found
	return ParseScene(string(text), allocator)
}

/*
Creates every scene of a project in a game and switches to its start scene. Also sets the game's
background color, physics settings, name (unless code set one), input actions, mix buses,
translations and global scripts from the project. Call from the game's `build` procedure, after
`game.size` and `game.scaleMode` were set from the project (the scenes' cameras and menus are
positioned for that size).

Asset paths are resolved against the project folder, so the game can run from any directory.

Inputs:
- game: The game, during Game_Init
- project: The parsed project.xml
- projectDir: Folder containing project.xml

Returns:
- false if a scene file couldn't be loaded (the others are still created)

Example:
	// In the game's build procedure (game.size and game.scaleMode already set from the project)
	project, err := e.LoadProjectFile("MyGame/project.xml")
	if err != .None do return
	if !e.Game_LoadProject(game, &project, "MyGame") do log.warn("Some scenes didn't load")
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
	// Steam's achievements, stats and cloud files (steam.odin: the stub until Steamworks is in)
	Steam_Setup(game, project.steam, project.achievements[:])
	// Local players: how many, the keyboard, the join action (players.odin)
	Players_Setup(game, project.players)
	// Translations before anything that shows text
	loadProjectTranslations(game, project, projectDir)
	if project.icon != "" && game.window != nil do Game_SetWindowIcon(game, project.icon)
	if project.uiTheme != "" do game.uiTheme = strings.clone(project.uiTheme, Game_GetAllocator(game))
	// Globals exist before the scenes (their nodes' scripts may look them up in `ready`)
	Globals_Start(game, project.globals[:])
	delete(game.projectDir)
	game.projectDir = strings.clone(projectDir)
	ok := true

	// The project's transition and loading scene (scene_flow.odin). With a loading scene, only
	// the start scene and the loading scene are built now; the others when they're entered
	game.flow.transition = project.transition
	delete(game.flow.loadingScene)
	game.flow.loadingScene = strings.clone(project.loadingScene)
	lazy := project.loadingScene != ""
	for ref in project.scenes {
		path := JoinPath(projectDir, ref.path)
		if lazy && ref.name != project.startScene && ref.name != project.loadingScene {
			scene := game->createScene(ref.name)
			if scene != nil {
				scene.unbuilt = true
				if game.sceneFiles == nil do game.sceneFiles = make(map[string]string, Game_GetAllocator(game))
				game.sceneFiles[strings.clone(ref.name, Game_GetAllocator(game))] = strings.clone(path, Game_GetAllocator(game))
			}
			continue
		}
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
	Scene_ApplySettings(scene, data.settings)
	return buildNodes(scene, data.nodes[:], projectDir, allocator, attachScripts, 0)
}

/*
The engine type a scene file's node kind is built as (`Node2D` is a plain `Node`; a Component
instance is its component's root, so it has no type of its own: `Node` here).
*/
SCENE_NODE_TYPES := [SceneNodeKind]typeid{
	.Node2D          = Node,
	.Sprite          = Sprite,
	.AnimatedSprite  = AnimatedSprite,
	.Camera          = Camera2D,
	.Label           = Label,
	.Menu            = Menu,
	.StaticBody      = StaticBody,
	.DynamicBody     = DynamicBody,
	.CharacterMover  = CharacterMover,
	.Area            = Area,
	.CollisionShape  = CollisionShape,
	.RayCast         = RayCast,
	.Joint           = Joint,
	.ParticleEmitter = ParticleEmitter,
	.Component       = Node,
	.AudioPlayer     = AudioPlayer,
	.AudioPlayer2D   = AudioPlayer,
	.MusicPlayer     = AudioPlayer,
	.LDtkLevel       = LDtkLevelNode,
	.TileMap         = TileMapNode,
	.Animator        = Animator,
	.Panel           = Panel,
	.Button          = Button,
	.ProgressBar     = ProgressBar,
	.TextField       = TextField,
	.ScrollBox       = ScrollBox,
	.RichText        = RichText,
	.Light2D         = Light2D,
	.LightOccluder   = LightOccluder,
	.NavRegion       = NavRegion,
	.NavAgent        = NavAgent,
	.StateMachine    = StateMachine,
	.ParallaxLayer   = ParallaxLayer,
	.CameraZone      = CameraZone,
	.CameraView      = CameraView,
	.VirtualJoystick = VirtualJoystick,
	.TouchButton     = TouchButton,
	.ScreenEffect    = ScreenEffect,
}

/*
Whether nodes of a kind can go in a script's node field pointing to `typeName` (a node type's
name without its package, as `ScriptField.hint` gives it): the kind's type is that type, or
embeds it (`DynamicBody` embeds `PhysicsBody`, every node type embeds `Node`). Editors use it to
offer the nodes that fit a field.

Inputs:
- kind: The node kind
- typeName: The type's name ("Node", "Sprite", "PhysicsBody"...)

Returns:
- Whether the field accepts the kind's nodes

Example:
	assert(e.SceneNodeKind_IsType(.DynamicBody, "PhysicsBody"))
*/
SceneNodeKind_IsType :: proc(kind: SceneNodeKind, typeName: string) -> bool {
	id := SCENE_NODE_TYPES[kind]
	for id != nil {
		if named, ok := type_info_of(id).variant.(runtime.Type_Info_Named); ok && named.name == typeName do return true
		if !reflect.is_struct(type_info_of(id)) || len(reflect.struct_field_names(id)) == 0 do return false
		first := reflect.struct_field_at(id, 0)
		if !first.is_using do return false
		id = first.type.id
	}
	return false
}

/*
Applies a scene file's settings to a scene: its screen layers, and its background color and
gravity (none: the project's). `Scene_Build` does it.

Inputs:
- scene: The scene
- settings: The settings
*/
Scene_ApplySettings :: proc(scene: ^Scene, settings: SceneSettings) {
	scene.screenLayers = settings.screenLayers
	scene.background = nil
	if settings.hasBackground do scene.background = settings.background
	Scene_SetLighting(scene, settings.lighting, settings.ambient.a > 0 ? settings.ambient : DEFAULT_AMBIENT, settings.bodyShadows)
	scene.gravity = nil
	if settings.hasGravity {
		scene.gravity = settings.gravity
		// A world made before (by code) changes too
		if scene.physics != nil do Physics_SetGravity(scene, settings.gravity)
	}
}

/*
Adds an instance of a component to a scene: its whole node tree, built like a scene file's, with
its scripts. Like `Scene_AddNode`, the nodes join the scene at the start of its next update
(`onEnter`, then the scripts' `ready`). Call it as often as needed: each call makes another
instance. The component's file is read once per game and cached. `Scene_RemoveComponent`
removes an instance.

Inputs:
- scene: The scene
- component: The component (a `COMPONENT_...` constant, or an exported `e.ComponentAsset` field)
- parent: The node to add it under (nil: the top level)
- position: Where its root goes, relative to the parent

Returns:
- The instance's root node (nil, logged, if the component can't be read). It takes the
  component's name; `Node_GetComponent` tells which component it is

Example:
	// Given: self: ^e.Script, COMPONENT_BULLET: e.ComponentAsset
	bullet := e.Scene_AddComponent(self.scene, COMPONENT_BULLET, position = e.Node_GetWorldPosition(self.node))
*/
Scene_AddComponent :: proc(scene: ^Scene, component: ComponentAsset, parent: ^Node = nil, position: [2]f32 = {}) -> ^Node {
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

// Another name for `Scene_AddComponent` (its first name)
Scene_Instantiate :: Scene_AddComponent

/*
Removes a component instance, its whole tree, like `Scene_RemoveNode`: at the start of the next
update they get `onExit`, then their `destroy` hooks, then their memory is freed. Only an
instance's root is accepted (a node made by `Scene_AddComponent`, or a scene file's Component
node), so a stray id can't remove part of an instance; use `Scene_RemoveNode` for any node.

Inputs:
- scene: The scene
- instanceId: The instance root's `id`

Returns:
- false (logged) when no node of the scene has that id, or it isn't an instance's root

Example:
	// Given: self: ^e.Script, bullet: ^e.Node (from e.Scene_AddComponent)
	e.Scene_RemoveComponent(self.scene, bullet.id)
*/
Scene_RemoveComponent :: proc(scene: ^Scene, instanceId: EntityId) -> bool {
	root := Scene_GetNode(scene, instanceId)
	if root == nil {
		log.warnf("Scene_RemoveComponent: no node with that id in the scene")
		return false
	}
	if root.component == "" {
		log.warnf("Scene_RemoveComponent: %s isn't a component instance's root (Scene_RemoveNode removes any node)", root.name)
		return false
	}
	Scene_RemoveNode(scene, instanceId)
	return true
}

/*
The component a node is the root of an instance of.

Inputs:
- node: The node

Returns:
- The component (its path, like the `COMPONENT_...` constants), and false for nodes that aren't
  an instance's root (nodes inside an instance included)
*/
Node_GetComponent :: proc(node: ^Node) -> (ComponentAsset, bool) {
	if node == nil || node.component == "" do return {}, false
	return ComponentAsset{node.component}, true
}

/*
Every instance of a component in a scene: their roots, in the scene and waiting to join it (in
tree order, then the order they were added). Removed instances are listed until the next update
frees them.

Inputs:
- scene: The scene
- component: The component

Returns:
- The instances' roots (temp allocated)

Example:
	// Given: scene: ^e.Scene, COMPONENT_BULLET: e.ComponentAsset
	for bullet in e.Scene_GetComponentInstances(scene, COMPONENT_BULLET) do e.Scene_RemoveComponent(scene, bullet.id)
*/
Scene_GetComponentInstances :: proc(scene: ^Scene, component: ComponentAsset) -> []^Node {
	found := make([dynamic]^Node, context.temp_allocator)
	for list in ([2][]^Node{scene.nodes[:], scene.addQueue[:]}) {
		for node in list do if node.component != "" && node.component == component.path do append(&found, node)
	}
	return found[:]
}

/*
A component's parsed file, read the first time and kept for the game's life, in the game's arena
(instances share it). A file that can't be read is remembered too: it isn't read again.

Inputs:
- game: The game
- path: The component file, relative to the project folder (`Game.projectDir`)

Returns:
- The component's nodes (don't free them), and false (logged) if it can't be read
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
			initCameraEvents(camera)
			camera.zoom = node.zoom
			camera.follow = DEFAULT_CAMERA_FOLLOW
			camera.offset = scene.game.size * 0.5
			if scene.camera == nil do scene.camera = camera
			n = camera

		case .Sprite:
			sprite := CreateNode(scene, Sprite)
			sprite.draw = Sprite_draw
			sprite.getBounds = Sprite_getBounds
			sprite.texture = loadAsset(rm, projectDir, asepriteLayersKey(node.texture, Aseprite_IsFile(node.texture) ? node.asepriteLayers : ""))
			spriteAllocator := Node_GetAllocator(sprite)
			if Aseprite_IsFile(node.texture) do sprite.source = strings.clone(JoinPath(projectDir, node.texture), spriteAllocator)
			sprite.pivotSlice = strings.clone(node.pivotSlice, spriteAllocator)
			sprite.nineSlice = strings.clone(node.nineSlice, spriteAllocator)
			sprite.nineSize = node.nineSize
			n = sprite

		case .AnimatedSprite:
			sprite := CreateNode(scene, AnimatedSprite)
			sprite.update = AnimatedSprite_update
			sprite.draw = AnimatedSprite_draw
			sprite.getBounds = AnimatedSprite_getBounds
			allocator := Node_GetAllocator(sprite)
			AnimationPlayer_Init(&sprite.animation, allocator)
			sprite.pivotSlice = strings.clone(node.pivotSlice, allocator)
			sprite.layers = strings.clone(node.asepriteLayers, allocator)
			// An animation asset's sheet and animations, else its own
			ownAseprite := node.animationSet == "" && Aseprite_IsFile(node.texture)
			texture := node.animationSet != "" ? nil : loadAsset(rm, projectDir, asepriteLayersKey(node.texture, ownAseprite ? node.asepriteLayers : ""))
			if ownAseprite do sprite.source = strings.clone(JoinPath(projectDir, node.texture), allocator)
			if node.animationSet != "" {
				if set, ok := Game_LoadAnimationSet(scene.game, node.animationSet); ok do AnimatedSprite_SetAnimations(sprite, set, projectDir, node.autoplay)
			} else if texture != nil {
				if len(node.animations) == 0 {
					AnimationPlayer_Add(&sprite.animation, CreateSpriteSheetAnimation("default", texture, node.columns, node.rows,
						node.fps, node.loop, playMode = node.playMode, margin = node.margin, spacing = node.spacing, allocator = allocator))
				}
				for a in node.animations {
					animation := CreateSpriteSheetAnimation(a.name, texture, node.columns, node.rows, a.fps, a.loop, a.start, a.end, a.playMode, node.margin, node.spacing, allocator)
					animation.repeat = a.repeat
					if len(a.durations) > 0 do Animation_SetDurations(animation, a.durations[:])
					if len(a.events) > 0 do Animation_SetEvents(animation, a.events[:])
					AnimationPlayer_Add(&sprite.animation, animation)
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
			shape.oneWay = node.oneWay
			append(&shape.points, ..node.points[:])
			// Following an Aseprite slice of its sprite, frame by frame (aseprite_nodes.odin)
			if node.slice != "" {
				shape.slice = strings.clone(node.slice, Node_GetAllocator(shape))
				shape.shape = .Rectangle
				shape.update = sliceShapeUpdate
			}
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
			// Its layers (music_layers.odin), loaded like its music
			if attachScripts && kind == .Music do for l in node.musicLayers do MusicPlayer_AddLayer(player, l.name, l.sound, l.volume)
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
		case .TileMap:
			n = tileMapBuildNode(scene, &node, projectDir)
		case .ParallaxLayer:
			layer := CreateParallaxLayer(scene, node.texture != "" ? loadAsset(rm, projectDir, node.texture) : nil, node.cameraTools.factor)
			layer.settings = node.cameraTools
			n = layer
		case .CameraZone:
			zone := CreateCameraZone(scene, node.shapeSize)
			zone.settings = node.cameraTools
			n = zone
		case .CameraView:
			view := CreateCameraView(scene, node.shapeSize, "")
			view.cameraPath = strings.clone(node.viewCamera, Node_GetAllocator(view))
			view.settings = node.cameraTools
			n = view
		case .StateMachine:
			n = CreateStateMachine(scene, node.stateMachine)
		case .NavRegion:
			n = CreateNavRegion(scene, node.shapeSize, node.nav)
		case .NavAgent:
			n = CreateNavAgent(scene, node.nav)
		case .VirtualJoystick:
			n = CreateVirtualJoystick(scene, TouchControl_ParseActions(node.touchActions), node.touch)
		case .TouchButton:
			n = CreateTouchButton(scene, TouchControl_ParseActions(node.touchActions)[0], node.text, node.touch)
		case .ScreenEffect:
			fx := CreateScreenEffect(scene, "")
			fx.includeScreenLayers = node.effectScreenLayers
			n = fx
		case .Light2D:
			n = CreateLight2D(scene, node.light)
		case .LightOccluder:
			o := CreateLightOccluder(scene, node.shapeSize)
			o.shape = node.shape
			o.radius = node.radius
			append(&o.points, ..node.points[:])
			n = o
		case .Panel, .Button, .ProgressBar, .TextField, .ScrollBox, .RichText:
			n = uiBuildNode(scene, &node, projectDir, attachScripts)
		case .Animator:
			animator := CreateAnimator(scene)
			Animator_SetClips(animator, node.animator)
			n = animator
		}
		if Node_IsPhysicsBody(n) {
			body := cast(^PhysicsBody)n
			body.collisionLayer = node.collisionLayer
			body.collisionMask = node.collisionMask
			body.friction = node.friction
			body.restitution = node.restitution
			body.density = node.density
			// A shared material replaces the body's own surface and density
			if node.material != "" {
				if material, ok := Game_LoadPhysicsMaterial(scene.game, node.material); ok do PhysicsBody_SetMaterial(body, material)
			}
		}

		n.name = strings.clone(node.name, Node_GetAllocator(n))
		n.position = node.position
		n.rotation = node.rotation
		n.scale = node.scale
		n.layer = RenderLayer(clamp(node.layer, 0, len(RenderLayer) - 1))
		n.visible = node.visible
		// A component instance keeps its root's settings unless the instance sets them
		instance := node.kind == .Component
		if instance do n.component = strings.clone(node.component, Node_GetAllocator(n))
		// A component instance's listeners join its root's own
		for l in node.listeners do Node_AddListener(n, l)
		if !instance || node.processMode != .Inherit do n.processMode = node.processMode
		if !instance || node.blendMode != .Blend do n.blendMode = node.blendMode
		if !instance || node.zIndex != 0 do n.zIndex = node.zIndex
		if !instance || node.ySort do n.ySort = node.ySort
		for g in node.groups do Node_AddToGroup(n, g)
		// Its shader and parameters (shaders.odin)
		if node.shader != "" && Node_SetShader(n, node.shader) {
			for p in node.shaderParams {
				for def, j in n.shader.program.bundle.params do if def.name == p.name {
					if value, ok := ShaderParam_Parse(def.type, p.value); ok do n.shader.values[j] = value
					else do log.warnf("%s: shader parameter %s: can't read %q", node.name, p.name, p.value)
				}
			}
		}
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

@(private)
AnimatedSprite_update :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	AnimationPlayer_Update(&(cast(^AnimatedSprite)node).animation, deltaTime)
}

// Menu buttons from scene files: "scene:<Name>" switches scene, "quit" quits
@(private="file")
runMenuAction :: proc(menu: ^Menu, item: ^MenuItem) {
	if item.userData == nil do return
	action := (cast(^string)item.userData)^
	game := menu.scene.game
	if !Game_RunAction(game, action) do log.warnf("Unknown menu action '%s'", action)
}

@(private)
loadAsset :: proc(rm: ^ResourceManager, projectDir, path: string) -> ^sdl.Texture {
	if path == "" do return nil
	fullPath := JoinPath(projectDir, path)
	return rm->loadTexture(fullPath)
}
