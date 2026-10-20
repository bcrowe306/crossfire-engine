package crossfire

import "core:encoding/xml"
import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

/*
Project and scene files: the XML format the editor saves and the engine loads.

A project is a folder:

	MyGame/
		project.xml             settings, the scene list and the asset list
		scenes/Menu.scene.xml   one file per scene
		assets/...              images, audio, fonts

project.xml:

	<?xml version="1.0" encoding="UTF-8"?>
	<project formatVersion="5" name="Asteroids" width="1280" height="720"
	         scaleMode="Letterbox" background="#0f121e" startScene="MenuScene"
	         pixelsPerMeter="100" gravityX="0" gravityY="980">
		<scene name="MenuScene" path="scenes/MenuScene.scene.xml"/>
		<asset path="assets/ship.png" kind="Image"/>
		<asset path="data/fast_ship.data.json" kind="Data"/>
		<global script="GameState">
			<prop name="lives" value="3"/>
		</global>
		<action name="jump" deadzone="0.5">
			<key key="Space"/>
			<gamepad button="South"/>
			<axis axis="LeftY" direction="-1"/>
		</action>
	</project>

The optional `renderer` attribute picks the renderer games draw with: a `RenderBackend` name
(`Auto`, the default: SDL's choice; `OpenGL`, `OpenGLES2`, `Vulkan`, `GPU`, `Direct3D11`,
`Direct3D12`, `Metal`, `Software`). See render_backend.odin.

`<action>` elements are the game's input actions (input.odin): a name, a deadzone for sticks, and
its bindings: `<key key="..."/>` (a `Key` name), `<mouse button="..."/>` (`MouseButton`),
`<gamepad button="..." device="0"/>` (`GamepadButton`; no device = any gamepad) and
`<axis axis="..." direction="1|-1" device="0"/>` (`GamepadAxis`).

A scene file holds a tree of nodes. Nesting is the hierarchy, and a node's `x`, `y`, `rotation`
and scale are relative to its parent:

	<?xml version="1.0" encoding="UTF-8"?>
	<scene formatVersion="4" name="PlayScene">
		<node kind="Node2D" name="World" x="0" y="0">
			<node kind="Camera" name="Camera" x="640" y="360" zoom="1"/>
			<node kind="Sprite" name="Ship" x="640" y="430" texture="assets/ship.png">
				<node kind="AnimatedSprite" name="Flame" x="0" y="40" texture="assets/flame.png"
				      columns="4" rows="1" fps="12"/>
			</node>
			<node kind="AnimatedSprite" name="Hero" x="200" y="400" texture="assets/hero.png"
			      columns="4" rows="2" margin="0" spacing="2" autoplay="walk">
				<animation name="walk" start="0" end="3" fps="10" loop="true"/>
				<animation name="jump" start="4" end="7" fps="12" playMode="PingPong"/>
			</node>
		</node>
		<node kind="Label" name="Title" x="640" y="180" text="ASTEROIDS" fontSize="64"
		      color="#ebf0ff" centered="true" layer="7"/>
		<node kind="Menu" name="MainMenu" x="640" y="300" layer="7">
			<item label="Play" action="scene:PlayScene"/>
			<item label="Quit" action="quit"/>
		</node>
		<node kind="Sprite" name="Player" x="640" y="600" texture="assets/ship.png">
			<script name="PlayerController">
				<prop name="speed" value="250"/>
			</script>
		</node>
		<node kind="StaticBody" name="Ground" x="640" y="700" collisionLayer="1">
			<node kind="CollisionShape" shape="Rectangle" width="1280" height="40"/>
		</node>
		<node kind="DynamicBody" name="Crate" x="600" y="100" restitution="0.3">
			<node kind="Sprite" texture="assets/crate.png"/>
			<node kind="CollisionShape" shape="Rectangle" width="48" height="48"/>
		</node>
		<node kind="Area" name="Goal" x="1200" y="640" collisionMask="2">
			<node kind="CollisionShape" shape="Polygon" points="-20,20 20,20 0,-20"/>
		</node>
		<node kind="ParticleEmitter" name="Sparks" x="640" y="500" texture="assets/spark.png">
			<particles amount="80" angle="270" angleSpread="40" angleVariance="1"
			           colorRamp="0:#ffe664 0.5:#e63228 1:#28282800"/>
		</node>
	</scene>

An AnimatedSprite's texture is a sprite sheet of `columns` x `rows` cells (`margin` pixels around
the grid, `spacing` between cells), numbered left to right, top to bottom from 0. Its
`<animation>` elements are named ranges of cells (`start`, `end` inclusive; `end` -1 is the last
cell), each with its `fps`, `loop` and `playMode`; `autoplay` names the one it plays from the start
(else the first). Without `<animation>` elements it plays one animation, "default": every cell, at
the node's `fps`, `loop` and `playMode` (the format before version 7).

ParticleEmitter nodes (particles.odin) keep their settings in a `<particles>` child element: one
attribute per `ParticleSettings` field that differs from `DEFAULT_PARTICLE_SETTINGS`, named like
the field, in `ParticleSettings_Get`'s format. The node's `texture` is the Texture shape's image.

Physics (physics.odin, physics_nodes.odin): body nodes (StaticBody, DynamicBody, CharacterMover,
Area) get their shape from the CollisionShape nodes under them. Collision layers are lists of
layer numbers 1-64 (`collisionLayer="1 3"`), `all`, or empty for none.

Attributes every node may have: `kind`, `name`, `x`, `y`, `rotation` (degrees), `scaleX`,
`scaleY`, `layer` (0-7), `visible`, `processMode` (a `ProcessMode`: Inherit, Pausable,
WhenPaused, Always, Disabled), `blendMode` (a `BlendMode`: Blend, Add, Multiply, Modulate,
None), `zIndex` (draw order in the layer), `ySort` (children drawn by their y), `groups` (names,
separated by commas: `groups="enemies,flying"`). Kind-specific attributes are listed on `SceneNodeData`.
Missing attributes use the defaults in `DEFAULT_SCENE_NODE`. Paths are relative to the project
folder and use `/`. Colors are `#rrggbb` or `#rrggbbaa`. Booleans are `true` or `1`; any other
value is false. A number or color that can't be read keeps the default.

A scene's root element can carry its own settings (`SceneSettings`, format 13): `screenLayers`
(layers drawn without the camera: HUDs, menus), `background` (instead of the project's) and
`gravityX` / `gravityY` (instead of the project's).

Current limits:
- A scene's Camera applies to every node on a layer that isn't one of its `screenLayers`,
  Labels and Menus included.
- Labels and Menus follow their position only; their rotation and scale are ignored.
- Assets aren't preloaded: images load with the nodes that use them, sounds and music with their
  sound nodes (and from code on first use); Font assets are listed but not used.

Version history:
- 13: every node's `processMode`, `blendMode`, `zIndex`, `ySort` and `groups`; CollisionShape
  `oneWay`; the project's window: `fullscreen`, `vsync` (default true), `highDPI`; assets of
  kind "Translation" (CSV tables: localization.odin), the project's `locale` and `icon`, and the
  editor's `<grid width height majorEvery opacity majorOpacity/>` (`GridSettings`; games ignore
  it); scenes' own settings (`SceneSettings`: `screenLayers`, `background`, `gravityX` /
  `gravityY` on the root element). Version 12 files are valid version 13 files.
- 12: `LDtkLevel` nodes (a level, or a whole world, of an LDtk project: ldtk_nodes.odin) and
  assets of kind "LDtk". Version 11 files are valid version 12 files.
- 11: the project's `renderer`. Version 10 files are valid version 11 files.
- 10: sound nodes (AudioPlayer, AudioPlayer2D, MusicPlayer), mix buses (`<bus>` in project.xml),
  assets of kind "Music". Version 9 files are valid version 10 files.
- 9: components (`<component>` files, assets of kind "Component") and `Component` nodes. Version 8
  files are valid version 9 files.
- 8: input actions (`<action>` in project.xml). Version 7 files are valid version 8 files.
- 7: AnimatedSprite `<animation>` elements, `margin`, `spacing` and `autoplay`. Version 6 files are
  valid version 7 files.
- 6: ParticleEmitter nodes and their `<particles>` element. Version 5 files are valid version 6
  files.
- 5: global scripts (`<global script="..."><prop name value/></global>` in project.xml) and
  assets of kind "Data" (data resources, `data/<name>.data.json`: data.odin). Version 4 files are
  valid version 5 files.
- 4: physics: StaticBody, DynamicBody, CharacterMover, Area, CollisionShape, RayCast and Joint
  nodes, and the project's `pixelsPerMeter`, `gravityX`, `gravityY`, `physicsDebug` and
  `physicsSmoothing`. Version 3 files are
  valid version 4 files.
- 3: a node can have a script: a `<script name="...">` child element holding `<prop name="..."
  value="..."/>` values for its exported fields (script.odin). Version 2 files are valid version 3
  files without scripts.
- 2: positions, rotation and scale are relative to the parent. A Camera's rotation turns the
  view the way a rotated camera would (the world appears to turn the other way).
- 1: positions were world coordinates and parents had no effect; Camera rotation rotated the
  world. Version 1 scenes are converted when parsed.

Parsing (this file) only turns XML into plain data, without SDL, so it can be tested and used
by the editor. `project_loader.odin` builds engine scenes and nodes from that data.
*/

// Version written by the editor. This loader also reads older versions
PROJECT_FORMAT_VERSION :: 13

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
	// Physics bodies (physics_nodes.odin); their CollisionShape children give them a shape
	StaticBody,
	DynamicBody,
	CharacterMover,
	Area,
	CollisionShape,
	// Casts a ray every physics step and reports the first hit
	RayCast,
	// Connects two physics bodies: a hinge, rope, spring, slider, weld or wheel
	Joint,
	// Emits particles: sparks, smoke, fire, rain (particles.odin)
	ParticleEmitter,
	// An instance of a component (a saved node tree): its nodes are built in its place
	Component,
	// Sound nodes (audio_nodes.odin): a sound; a sound in the world; streamed music
	AudioPlayer,
	AudioPlayer2D,
	MusicPlayer,
	// A level (or every level of a world) of an LDtk project: tiles, entities, collision
	LDtkLevel,
}

/*
The groups tools list node kinds in (the editor's Add Node dialog), in their display order.
*/
SceneNodeCategory :: enum {
	// Structure: grouping, the camera, component instances, levels
	Scene,
	// What draws: images, animations, particles
	Graphics,
	// Text and menus
	UI,
	// Bodies, shapes, rays and joints
	Physics,
	// Sounds and music
	Audio,
}

// Each category's name as tools show it
SCENE_NODE_CATEGORY_NAMES := [SceneNodeCategory]string{
	.Scene    = "Scene",
	.Graphics = "Graphics",
	.UI       = "User interface",
	.Physics  = "Physics",
	.Audio    = "Sound",
}

/*
What a node kind is, for tools that let users pick one (the editor's Add Node dialog).
*/
SceneNodeKindInfo :: struct {
	// One line describing what the node does
	description: string,
	// The group it's listed in
	category: SceneNodeCategory,
}

/*
Every node kind a scene file can contain, with its description. Tools list node kinds from this
table, so a kind added to `SceneNodeKind` must be described here (the compiler enforces it).

Example:
	for kind in e.SceneNodeKind {
		info := e.SCENE_NODE_KINDS[kind]
		fmt.printfln("%s / %v: %s", e.SCENE_NODE_CATEGORY_NAMES[info.category], kind, info.description)
	}
*/
SCENE_NODE_KINDS := [SceneNodeKind]SceneNodeKindInfo{
	.Node2D         = {"Groups nodes; moving, rotating or scaling it moves its children", .Scene},
	.Sprite         = {"Draws an image", .Graphics},
	.AnimatedSprite = {"Plays a sprite sheet animation", .Graphics},
	.Camera         = {"Chooses the part of the scene the game shows; can follow a parent node", .Scene},
	.Label          = {"Draws a line of text", .UI},
	.Menu           = {"A list of buttons that switch scenes or quit the game", .UI},
	.StaticBody     = {"A physics body that doesn't move by itself: walls, floors, platforms", .Physics},
	.DynamicBody    = {"A physics body moved by gravity, collisions and forces", .Physics},
	.CharacterMover = {"A body moved by code that slides along walls and floors: players, enemies", .Physics},
	.Area           = {"A region that reports bodies entering and leaving it: pickups, triggers", .Physics},
	.CollisionShape = {"The shape of the physics body above it: rectangle, circle, capsule, polygon, segment", .Physics},
	.RayCast        = {"A ray that reports the first physics body in its way: line of sight, ground checks", .Physics},
	.Joint          = {"Connects two physics bodies: a hinge, rope, spring, slider, weld or wheel", .Physics},
	.ParticleEmitter = {"Emits particles that move, spin, grow and change color: sparks, smoke, fire, rain", .Graphics},
	.Component      = {"An instance of a component: a node tree saved in the assets, reused in any scene", .Scene},
	.AudioPlayer    = {"Plays a sound: volume, pitch, pan, looping, through a mix bus", .Audio},
	.AudioPlayer2D  = {"Plays a sound in the world: panned and quieter with distance from the camera", .Audio},
	.MusicPlayer    = {"Streams music: fades, looping, seeking, through a mix bus", .Audio},
	.LDtkLevel      = {"A level made in the LDtk level editor: its tile layers, entities and IntGrid collision", .Scene},
}

/*
A script listening to a node's event, from a scene file:
`<listener event="onFinished" target="../Hero" handler="onBloodFinished"/>` inside the node.
Before the scene's scripts get `ready`, the target node's script's handler (registered with
`Script_Listener`) is subscribed to the event (node_events.odin).
*/
NodeListenerData :: struct {
	// The event: an EventSubject field of the node's type (`NodeType_Events`), "onFinished" or
	// through a field, "animation.onAnimationEnded"
	event: string,
	// The node whose script listens: a path from this node (`Node_FindPath`; "." for itself)
	target: string,
	// The handler's name (`Script_Listener`)
	handler: string,
	// A global's event instead of this node's: the global script's name ("GameState"). The
	// listener is then on the listening node (`target` is "." or empty)
	global: string,
}

/*
A button in a Menu node: `<item label="Play" action="scene:PlayScene"/>`.
*/
MenuItemData :: struct {
	// The button's text
	label: string,
	// `scene:<SceneName>` switches to that scene, `quit` quits the game
	action: string,
}

/*
One node from a scene file. Fields that don't apply to a node's kind are ignored. Each field is
read from the attribute of the same name unless its comment names another one; a missing (or
unreadable) attribute keeps the value in `DEFAULT_SCENE_NODE`.
*/
SceneNodeData :: struct {
	// `kind`: what node it becomes (unknown or missing: Node2D)
	kind: SceneNodeKind,
	// `name` (missing: the kind's name, "Sprite")
	name: string,
	// Index of the parent node, -1 for top-level nodes. Nodes are stored depth-first:
	// every node's children follow it directly
	parent: int,
	// `x`, `y`: position relative to the parent, in pixels. Sprites and labels are centered on it
	// (labels unless `centered` is false)
	position: [2]f32,
	// Degrees clockwise, relative to the parent
	rotation: f32,
	// `scaleX`, `scaleY`: scale relative to the parent (1: unscaled)
	scale: [2]f32,
	// The render layer, 0-7 (out-of-range values are clamped)
	layer: int,
	// Hidden nodes, and everything under them, aren't drawn
	visible: bool,
	// Whether it updates while its scene is paused (Node.processMode)
	processMode: ProcessMode,
	// How its drawing combines with what's under it (Node.blendMode)
	blendMode: BlendMode,
	// Draw order within its layer (Node.zIndex)
	zIndex: i32,
	// Its children draw sorted by their y (Node.ySort)
	ySort: bool,
	// Groups it belongs to (Node.groups): `groups="enemies,flying"`
	groups: [dynamic]string,

	// Sprite, AnimatedSprite, ParticleEmitter (its Texture shape): image path relative to the project folder
	texture: string,
	// Label: its text
	text: string,
	// Label: font size (default 24)
	fontSize: f32,
	// Label: text color (`#rrggbb` or `#rrggbbaa`; default white)
	color: sdl.Color,
	// Label: centered on its position (false: its top-left corner is there)
	centered: bool,
	// Camera: zoom (1: none, 2: twice as big)
	zoom: f32,
	// AnimatedSprite: the texture is a columns x rows grid of cells (at least 1 each)
	columns: int,
	// AnimatedSprite: rows of the sheet's grid (see `columns`)
	rows: int,
	// AnimatedSprite without `<animation>` elements: frames per second of its "default" animation
	fps: f32,
	// AnimatedSprite without `<animation>` elements: the "default" animation loops (default true).
	// Sound nodes read `loop` too, into `audio` (default false there)
	loop: bool,
	// AnimatedSprite without `<animation>` elements: the "default" animation's play mode
	playMode: AnimationPlayMode,
	// AnimatedSprite: the sheet's grid margin and spacing (pixels), its animations (none: one
	// "default" animation of every cell, from fps/loop/playMode above), and the one played first.
	// `margin`: pixels around the grid
	margin: f32,
	// AnimatedSprite: pixels between cells
	spacing: f32,
	// AnimatedSprite: its `<animation>` child elements, in order
	animations: [dynamic]AnimationData,
	// AnimatedSprite: the animation it plays from the start ("" or unknown: the first)
	autoplay: string,
	// Menu: its `<item>` child elements, top to bottom
	items: [dynamic]MenuItemData,
	// Any kind: the script attached to the node (`<script name="...">`; "" for none)
	script: string,
	// Any kind: the script's exported field values (its `<prop>` elements)
	props: [dynamic]ScriptPropData,
	// Any kind: scripts listening to its events (`<listener event target handler/>`, format 13)
	listeners: [dynamic]NodeListenerData,

	// StaticBody, DynamicBody, CharacterMover, Area: the layers it's on and collides with
	// (`collisionLayer="1 3"`, `collisionMask="all"`), and its surface.
	// `collisionLayer`: the layers it's on, as bits (layer n is bit n-1; default layer 1)
	collisionLayer: u64,
	// Bodies: the layers it collides with (default all). RayCast: the layers it hits
	collisionMask: u64,
	// Bodies: surface friction (default 0.6)
	friction: f32,
	// Bodies: bounciness, 0 to 1 (default 0)
	restitution: f32,
	// Bodies: density, for the mass of dynamic bodies (default 1)
	density: f32,
	// DynamicBody: multiplies the project's gravity (default 1)
	gravityScale: f32,
	// DynamicBody: slows its movement over time (0: none)
	linearDamping: f32,
	// DynamicBody: slows its spin over time (0: none)
	angularDamping: f32,
	// DynamicBody: it doesn't rotate
	fixedRotation: bool,
	// DynamicBody: continuous collision for fast bodies (doesn't pass through thin walls)
	bullet: bool,
	// CharacterMover: the steepest floor, degrees
	floorMaxAngle: f32,
	// CollisionShape: `shape`; Rectangle `width` and `height`; Circle `radius`; Capsule `radius`
	// and `height` (overall); Polygon and Segment `points="x,y x,y ..."`; `disabled`; `oneWay`
	// (format 13: only its top stops what comes down on it).
	// `shape`: Rectangle (default), Circle, Capsule, Polygon or Segment
	shape: CollisionShapeKind,
	// CollisionShape: `width`, `height` in pixels (Rectangle; a Capsule's overall height is `.y`)
	shapeSize: [2]f32,
	// CollisionShape: Circle and Capsule radius, in pixels
	radius: f32,
	// CollisionShape: Polygon and Segment points, in the node's space (`points="x,y x,y ..."`)
	points: [dynamic][2]f32,
	// CollisionShape: left out of its body
	disabled: bool,
	// CollisionShape (format 13): a one-way platform, only its top stops what comes down on it
	oneWay: bool,
	// RayCast: `targetX`, `targetY` (relative to the node), `enabled`, `excludeParent`
	// (collisionMask is the layers it hits).
	// `targetX`, `targetY`: the ray's end, relative to the node
	target: [2]f32,
	// RayCast: casting (default true)
	enabled: bool,
	// RayCast: ignore the body it's under (default true)
	excludeParent: bool,
	// Joint (physics_joints.odin): `joint` (the kind), `bodyA` / `bodyB` (names or paths; bodyA
	// "" = the body it's under, or the world), `offsetX`/`offsetY` (Distance: body B's anchor),
	// `limit`, `lower`, `upper`, `motor`, `motorSpeed`, `maxMotor`, `spring`, `hertz`, `damping`,
	// `collideConnected`.
	// `joint`: the joint's kind (default Revolute)
	jointKind: JointKind,
	// Joint: name or path of body A ("" = the body the joint is under, or the world)
	bodyA: string,
	// Joint: name or path of body B
	bodyB: string,
	// Joint: `offsetX`, `offsetY`: Distance joints' anchor on body B, relative to the joint
	jointOffset: [2]f32,
	// Joint: `limit`: `lower` and `upper` apply
	enableLimit: bool,
	// Joint: the lower limit (Revolute: degrees; Distance: length in px; Prismatic, Wheel: px)
	lower: f32,
	// Joint: the upper limit, in `lower`'s units
	upper: f32,
	// Joint: `motor`: the motor runs
	enableMotor: bool,
	// Joint: motor speed (Revolute, Wheel: degrees per second; Distance, Prismatic: px/s)
	motorSpeed: f32,
	// Joint: the motor's maximum torque (Revolute, Wheel) or force (Distance, Prismatic)
	maxMotor: f32,
	// Joint: `spring`: the joint is springy
	enableSpring: bool,
	// Joint: the spring's frequency, in hertz
	hertz: f32,
	// Joint: `damping`: the spring's damping ratio (default 0.5)
	dampingRatio: f32,
	// Joint: the two bodies still collide with each other
	collideConnected: bool,
	// ParticleEmitter: its `<particles>` element (particles.odin)
	particles: ParticleSettings,
	// Component: the component file it's an instance of (relative to the project folder)
	component: string,
	// AudioPlayer, AudioPlayer2D, MusicPlayer: the sound (or music) file, the bus ("" Master),
	// and `volume`, `pitch`, `pan`, `loop`, `autostart`, `maxDistance`, `attenuation`, `fadeIn`, `fadeOut`.
	// `sound`: the sound (or music) file, relative to the project folder
	sound: string,
	// Sound nodes: the mix bus it plays through ("" for Master)
	bus: string,
	// Sound nodes: `volume`, `pitch`, `pan`, `loop`, `autostart`, `maxDistance`, `attenuation`,
	// `fadeIn`, `fadeOut` (missing ones from DEFAULT_AUDIO_SETTINGS)
	audio: AudioSettings,
	// LDtkLevel: `ldtk` (the .ldtk file), `level`, `allLevels`, `intGridCollision`,
	// `collisionValues`, `spawnEntities`, `background`, `smoothTiles`, and `<entity name="..."
	// component="..."/>` children; the generated collision uses `collisionLayer`, `collisionMask`,
	// `friction`, `restitution` (ldtk_nodes.odin)
	ldtk: LDtkLevelSettings,
}

/*
An AnimatedSprite's animation: a named range of its sheet's cells.

	<animation name="walk" start="0" end="3" fps="10" loop="true" playMode="Forward"/>
*/
AnimationData :: struct {
	// The name scripts play it by (missing: "default")
	name: string,
	// First and last cell played, inclusive; end -1 is the sheet's last cell
	start: int,
	// The last cell played (inclusive; -1, the default: the sheet's last cell)
	end: int,
	// Frames per second (default 8)
	fps: f32,
	// Plays again from the start when it ends (default false, unlike the node's `loop`)
	loop: bool,
	// Forward (default), or another `AnimationPlayMode`
	playMode: AnimationPlayMode,
}

// A script field's value in a scene file: `<prop name="speed" value="250"/>`
ScriptPropData :: struct {
	// The exported field's name
	name: string,
	// The value in its text form (see `Script_SetField`)
	value: string,
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
	collisionLayer = 1,
	collisionMask = PHYSICS_ALL_LAYERS,
	friction = 0.6,
	density = 1,
	gravityScale = 1,
	floorMaxAngle = 45,
	shapeSize = {32, 32},
	radius = 16,
	target = {0, 50},
	enabled = true,
	excludeParent = true,
	jointOffset = {0, 100},
	dampingRatio = 0.5,
	particles = DEFAULT_PARTICLE_SETTINGS,
	audio = DEFAULT_AUDIO_SETTINGS,
	ldtk = DEFAULT_LDTK_LEVEL_SETTINGS,
}

/*
A parsed scene (or component) file: `ParseScene`, `ParseComponent`. Free with `SceneData_Destroy`.
*/
SceneData :: struct {
	// The root element's `name`
	name: string,
	// Every node, depth-first: a node's children follow it directly (`SceneNodeData.parent`)
	nodes: [dynamic]SceneNodeData,
	// The root element's scene-wide settings (format 13)
	settings: SceneSettings,
}

/*
A scene's own settings, from its file's root element (format 13):
`<scene name="Level" screenLayers="8" background="#203040" gravityX="0" gravityY="490">`.
`Scene_Build` applies them to the scene. The zero value is a scene without any.
*/
SceneSettings :: struct {
	// Layers drawn in screen space, ignoring the camera (`Scene.screenLayers`): HUDs and menus.
	// `screenLayers="7 8"` (layer numbers 1-8)
	screenLayers: bit_set[RenderLayer],
	// Clear the screen with `background` instead of the project's color (`background="#rrggbb"`)
	hasBackground: bool,
	// The scene's background color, when `hasBackground`
	background: sdl.Color,
	// Use `gravity` instead of the project's (`gravityX`, `gravityY`)
	hasGravity: bool,
	// The scene's gravity in px/s², y down, when `hasGravity`
	gravity: [2]f32,
}

/*
Formats screen layers as scene files store them: layer numbers 1-8 separated by spaces ("" for
none).

Inputs:
- layers: The layers
- allocator: For the text

Returns:
- The text, e.g. "7 8"
*/
FormatScreenLayers :: proc(layers: bit_set[RenderLayer], allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for layer in RenderLayer do if layer in layers {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
		strings.write_int(&b, int(layer) + 1)
	}
	return strings.to_string(b)
}

/*
Parses screen layers: layer numbers 1-8 separated by spaces or commas ("" = none).

Inputs:
- text: The text

Returns:
- The layers, and false if a part wasn't a layer number (the valid ones are kept)
*/
ParseScreenLayers :: proc(text: string) -> (bit_set[RenderLayer], bool) {
	layers: bit_set[RenderLayer]
	ok := true
	for part in strings.split_multi(strings.trim_space(text), {" ", ","}, context.temp_allocator) {
		if part == "" do continue
		n, valid := strconv.parse_int(part)
		if !valid || n < 1 || n > len(RenderLayer) {
			ok = false
			continue
		}
		layers += {RenderLayer(n - 1)}
	}
	return layers, ok
}

// A scene of a project: `<scene name="MenuScene" path="scenes/MenuScene.scene.xml"/>`
SceneRef :: struct {
	// The scene's name (what `game->switchScene` and menu actions use)
	name: string,
	// Scene file path relative to the project folder
	path: string,
}

// An asset a project lists: `<asset path="assets/ship.png" kind="Image"/>`
AssetRef :: struct {
	// The file, relative to the project folder
	path: string,
	// "Image", "Audio", "Music", "Font", "Data", "Component", "LDtk" or "Translation"
	kind: string,
}

/*
A parsed project.xml (`ParseProject`, `LoadProjectFile`). Free with `ProjectData_Destroy`.
*/
ProjectData :: struct {
	// The game's name (`name`)
	name: string,
	// `width`, `height`: the game's size in pixels (default 1280 x 720)
	size: [2]f32,
	// How the game fits its window (`scaleMode`; default Letterbox)
	scaleMode: ScaleMode,
	// The color behind everything (`background`; default black)
	background: sdl.Color,
	// The scene the game starts in (`startScene`; missing: the first scene listed)
	startScene: string,
	// Its scenes, in file order (`<scene>` elements)
	scenes: [dynamic]SceneRef,
	// Its assets, in file order (`<asset>` elements)
	assets: [dynamic]AssetRef,
	// pixelsPerMeter, gravityX / gravityY (px/s²), physicsDebug, physicsSmoothing
	physics: PhysicsSettings,
	// Global scripts, in start order: `<global script="GameState"><prop .../></global>` (globals.odin)
	globals: [dynamic]GlobalData,
	// Input actions, in order: `<action name="jump"><key key="Space"/></action>` (input.odin)
	actions: [dynamic]InputActionData,
	// Mix buses (Master's settings too, if listed): `<bus name="Music" volume="0.8"/>` (audio_nodes.odin)
	buses: [dynamic]AudioBusData,
	// The renderer games draw with (`renderer="Vulkan"`, format 11; Auto: SDL's choice)
	renderer: RenderBackend,
	// The game's window (`fullscreen`, `vsync`, `highDPI`, format 13)
	window: WindowSettings,
	// The game window's icon: an image path relative to the project (`icon="assets/icon.png"`,
	// format 13); "" for the engine's (the Crossfire logo)
	icon: string,
	// The language to start in (`locale="fr"`, format 13); "" for the player's system language.
	// The translation tables are the assets of kind "Translation" (localization.odin)
	locale: string,
	// The editor's grid for this project (`<grid width="16" height="16"/>`, format 13); games
	// don't use it
	grid: GridSettings,
}

/*
A project's grid, as tools show it and snap to it (the editor's viewport). Games don't use it.
*/
GridSettings :: struct {
	// A cell's width and height, world units (GRID_SIZE_RANGE)
	size: [2]int,
	// A major (more opaque) line every this many cells; 0 = none (GRID_MAJOR_RANGE)
	majorEvery: int,
	// The lines' opacity, percent
	opacity: int,
	// The major lines' opacity, percent
	majorOpacity: int,
}

// A project's grid without a `<grid>` element: 32 px cells, a major line every 4
DEFAULT_GRID_SETTINGS :: GridSettings{size = {32, 32}, majorEvery = 4, opacity = 8, majorOpacity = 20}

// The values a grid's cell size may take (parsing clamps to it)
GRID_SIZE_RANGE :: [2]int{2, 1024}
// The values a grid's major line spacing may take, in cells
GRID_MAJOR_RANGE :: [2]int{0, 64}

/*
How a game's window starts. Games change fullscreen and vsync while running with
`Game_SetFullscreen` / `Game_SetVSync` (an options menu).
*/
WindowSettings :: struct {
	// Start fullscreen (the desktop's resolution; the game scales into it)
	fullscreen: bool,
	// Wait for the display's refresh (no tearing; the frame rate follows the display)
	vsync: bool,
	// Use the display's full pixel density (sharper on high-DPI and Retina screens; more pixels to draw)
	highDPI: bool,
}

// A window as games had it before these settings: windowed, vsync, not high-DPI
DEFAULT_WINDOW_SETTINGS :: WindowSettings{vsync = true}

// What went wrong reading a project, scene or component file
ProjectError :: enum {
	None,
	// The file couldn't be read (`LoadProjectFile`, `LoadSceneFile`)
	File_Not_Found,
	// The text isn't well-formed XML, or is empty
	Invalid_XML,
	// The root element isn't <project> / <scene> / <component>, as the parser expected
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
	// Given: xmlText: string
	project, err := e.ParseProject(xmlText)
	if err != .None do log.errorf("Can't read the project: %v", err)
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
		renderer = attrEnum(doc, 0, "renderer", RenderBackend.Auto),
		window = {
			fullscreen = attrBool(doc, 0, "fullscreen", DEFAULT_WINDOW_SETTINGS.fullscreen),
			vsync = attrBool(doc, 0, "vsync", DEFAULT_WINDOW_SETTINGS.vsync),
			highDPI = attrBool(doc, 0, "highDPI", DEFAULT_WINDOW_SETTINGS.highDPI),
		},
		background = attrColor(doc, 0, "background", {0, 0, 0, 255}),
		startScene = cloneAttr(doc, 0, "startScene", ""),
		locale = cloneAttr(doc, 0, "locale", ""),
		icon = cloneAttr(doc, 0, "icon", ""),
		grid = DEFAULT_GRID_SETTINGS,
		scenes = make([dynamic]SceneRef),
		assets = make([dynamic]AssetRef),
		globals = make([dynamic]GlobalData),
		actions = make([dynamic]InputActionData),
		buses = make([dynamic]AudioBusData),
		physics = {
			pixelsPerMeter = max(attrF32(doc, 0, "pixelsPerMeter", DEFAULT_PHYSICS.pixelsPerMeter), 1),
			gravity = {attrF32(doc, 0, "gravityX", DEFAULT_PHYSICS.gravity.x), attrF32(doc, 0, "gravityY", DEFAULT_PHYSICS.gravity.y)},
			debugDraw = attrBool(doc, 0, "physicsDebug", false),
			smoothing = attrBool(doc, 0, "physicsSmoothing", true),
		},
	}
	for child in childElements(doc, 0) {
		switch doc.elements[child].ident {
		case "scene":
			append(&project.scenes, SceneRef{cloneAttr(doc, child, "name", ""), cloneAttr(doc, child, "path", "")})
		case "asset":
			append(&project.assets, AssetRef{cloneAttr(doc, child, "path", ""), cloneAttr(doc, child, "kind", "")})
		case "global":
			global := GlobalData{script = cloneAttr(doc, child, "script", ""), props = make([dynamic]ScriptPropData)}
			for prop in childElements(doc, child) {
				if doc.elements[prop].ident != "prop" do continue
				append(&global.props, ScriptPropData{cloneAttr(doc, prop, "name", ""), cloneAttr(doc, prop, "value", "")})
			}
			append(&project.globals, global)
		case "grid":
			d := DEFAULT_GRID_SETTINGS
			project.grid = {
				size = {
					clamp(attrInt(doc, child, "width", d.size.x), GRID_SIZE_RANGE[0], GRID_SIZE_RANGE[1]),
					clamp(attrInt(doc, child, "height", d.size.y), GRID_SIZE_RANGE[0], GRID_SIZE_RANGE[1]),
				},
				majorEvery = clamp(attrInt(doc, child, "majorEvery", d.majorEvery), GRID_MAJOR_RANGE[0], GRID_MAJOR_RANGE[1]),
				opacity = clamp(attrInt(doc, child, "opacity", d.opacity), 0, 100),
				majorOpacity = clamp(attrInt(doc, child, "majorOpacity", d.majorOpacity), 0, 100),
			}
		case "bus":
			append(&project.buses, AudioBusData{
				name = cloneAttr(doc, child, "name", MASTER_BUS),
				volume = max(attrF32(doc, child, "volume", 1), 0),
				pan = clamp(attrF32(doc, child, "pan", 0), -1, 1),
				mute = attrBool(doc, child, "mute", false),
			})
		case "action":
			action := InputActionData{
				name = cloneAttr(doc, child, "name", ""),
				deadzone = clamp(attrF32(doc, child, "deadzone", DEFAULT_ACTION_DEADZONE), 0, 0.99),
				bindings = make([dynamic]InputBinding),
			}
			for b in childElements(doc, child) {
				Lookup :: struct { doc: ^xml.Document, element: xml.Element_ID }
				lookup := Lookup{doc, b}
				get :: proc(user: rawptr, key: string) -> (string, bool) {
					l := cast(^Lookup)user
					return xml.find_attribute_val_by_key(l.doc, l.element, key)
				}
				// Unknown bindings (a newer engine's) are skipped
				if binding, ok := ParseInputBinding(doc.elements[b].ident, get, &lookup); ok do append(&action.bindings, binding)
			}
			append(&project.actions, action)
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

Example:
	// Given: xmlText: string
	data, err := e.ParseScene(xmlText)
	if err != .None do log.errorf("Can't read the scene: %v", err)
	defer e.SceneData_Destroy(&data)
	for n in data.nodes do fmt.println(n.kind, n.name)
*/
ParseScene :: proc(text: string, allocator := context.allocator) -> (scene: SceneData, err: ProjectError) {
	doc := parseXML(text) or_return
	defer xml.destroy(doc)
	if doc.elements[0].ident != "scene" do return {}, .Wrong_Root
	checkVersion(doc, 0) or_return

	context.allocator = allocator
	scene.name = cloneAttr(doc, 0, "name", "")
	scene.nodes = make([dynamic]SceneNodeData)
	if text, found := xml.find_attribute_val_by_key(doc, 0, "screenLayers"); found do scene.settings.screenLayers, _ = ParseScreenLayers(text)
	if _, found := xml.find_attribute_val_by_key(doc, 0, "background"); found {
		scene.settings.hasBackground = true
		scene.settings.background = attrColor(doc, 0, "background", {0, 0, 0, 255})
	}
	_, hasX := xml.find_attribute_val_by_key(doc, 0, "gravityX")
	_, hasY := xml.find_attribute_val_by_key(doc, 0, "gravityY")
	if hasX || hasY {
		scene.settings.hasGravity = true
		scene.settings.gravity = {attrF32(doc, 0, "gravityX", DEFAULT_PHYSICS.gravity.x), attrF32(doc, 0, "gravityY", DEFAULT_PHYSICS.gravity.y)}
	}
	for child in childElements(doc, 0) {
		if doc.elements[child].ident == "node" do parseNode(doc, child, -1, &scene)
	}
	if attrInt(doc, 0, "formatVersion", 1) < 2 do migrateSceneFromV1(&scene)
	return scene, .None
}

/*
Parses the text of a component file: one node tree saved to be reused in any scene.

	<?xml version="1.0" encoding="UTF-8"?>
	<component formatVersion="9" name="Ship">
		<node kind="Sprite" name="Ship" texture="assets/ship.png">
			<node kind="ParticleEmitter" name="Exhaust" y="30"/>
		</node>
	</component>

Its first top-level node is the root (others are ignored). Scenes use it through a `Component`
node, `<node kind="Component" name="Ship2" x="100" y="50" component="components/ship.component.xml"/>`:
the component's nodes are built in its place, the root taking the instance's name, transform,
layer and visibility (Scene_Build); `Scene_AddComponent` adds one from code.

Inputs:
- text: The XML
- allocator: Allocator for the result's strings and lists

Returns:
- The nodes (depth-first, the root first), and .None or what went wrong. Free with `SceneData_Destroy`
*/
ParseComponent :: proc(text: string, allocator := context.allocator) -> (component: SceneData, err: ProjectError) {
	doc := parseXML(text) or_return
	defer xml.destroy(doc)
	if doc.elements[0].ident != "component" do return {}, .Wrong_Root
	checkVersion(doc, 0) or_return

	context.allocator = allocator
	component.name = cloneAttr(doc, 0, "name", "")
	component.nodes = make([dynamic]SceneNodeData)
	for child in childElements(doc, 0) {
		if doc.elements[child].ident == "node" {
			parseNode(doc, child, -1, &component)
			break
		}
	}
	return component, .None
}

/*
Frees everything `ParseProject` allocated and zeroes the project. Must use the same allocator.

Inputs:
- project: The project data
- allocator: The allocator it was parsed with
*/
ProjectData_Destroy :: proc(project: ^ProjectData, allocator := context.allocator) {
	context.allocator = allocator
	for s in project.scenes { delete(s.name); delete(s.path) }
	delete(project.scenes)
	for a in project.assets { delete(a.path); delete(a.kind) }
	delete(project.assets)
	for &g in project.globals {
		delete(g.script)
		for p in g.props { delete(p.name); delete(p.value) }
		delete(g.props)
	}
	delete(project.globals)
	for &a in project.actions {
		delete(a.name)
		delete(a.bindings)
	}
	delete(project.actions)
	for b in project.buses do delete(b.name)
	delete(project.buses)
	delete(project.locale)
	delete(project.icon)
	delete(project.name)
	delete(project.startScene)
	project^ = {}
}

/*
Frees everything `ParseScene` (or `ParseComponent`) allocated and zeroes the scene. Must use the
same allocator.

Inputs:
- scene: The scene data
- allocator: The allocator it was parsed with
*/
SceneData_Destroy :: proc(scene: ^SceneData, allocator := context.allocator) {
	context.allocator = allocator
	for &node in scene.nodes {
		delete(node.name)
		for g in node.groups do delete(g)
		delete(node.groups)
		delete(node.texture)
		delete(node.text)
		for item in node.items { delete(item.label); delete(item.action) }
		delete(node.items)
		delete(node.script)
		for prop in node.props { delete(prop.name); delete(prop.value) }
		delete(node.props)
		for l in node.listeners { delete(l.event); delete(l.target); delete(l.handler); delete(l.global) }
		delete(node.listeners)
		delete(node.points)
		delete(node.bodyA)
		delete(node.bodyB)
		for a in node.animations do delete(a.name)
		delete(node.animations)
		delete(node.autoplay)
		delete(node.component)
		delete(node.sound)
		delete(node.bus)
		LDtkLevelSettings_Destroy(&node.ldtk)
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


/*
Formats collision layers the way the format stores them: `all`, the layer numbers ("1 3"), or ""
for none.

Inputs:
- layers: The layer bits (layer n is bit n-1)
- allocator: Allocator for the string

Returns:
- The text
*/
FormatPhysicsLayers :: proc(layers: u64, allocator := context.allocator) -> string {
	if layers == PHYSICS_ALL_LAYERS do return strings.clone("all", allocator)
	b := strings.builder_make(allocator)
	for bit in 0 ..< 64 {
		if layers & (1 << u64(bit)) == 0 do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
		strings.write_int(&b, bit + 1)
	}
	return strings.to_string(b)
}

/*
Parses collision layers: `all`, or layer numbers 1-64 separated by spaces or commas ("" = none).

Inputs:
- text: The layers' text

Returns:
- The layer bits (layer n is bit n-1), and false if a part isn't a layer number 1-64 (it's
  skipped; the others are still in the bits)
*/
ParsePhysicsLayers :: proc(text: string) -> (u64, bool) {
	text := strings.trim_space(text)
	if text == "all" do return PHYSICS_ALL_LAYERS, true
	bits: u64
	ok := true
	for part in strings.split_multi(text, {" ", ","}, context.temp_allocator) {
		if part == "" do continue
		n, valid := strconv.parse_int(part)
		if !valid || n < 1 || n > 64 {
			ok = false
			continue
		}
		bits |= 1 << u64(n - 1)
	}
	return bits, ok
}

/*
Formats points the way the format stores them: "x,y x,y".

Inputs:
- points: The points
- allocator: Allocator for the string

Returns:
- The text
*/
FormatPoints :: proc(points: [][2]f32, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for p, i in points {
		if i > 0 do strings.write_byte(&b, ' ')
		fmt.sbprintf(&b, "%v,%v", p.x, p.y)
	}
	return strings.to_string(b)
}

/*
Parses points: "x,y x,y ...".

Inputs:
- text: The points' text

Returns:
- The points (temp allocated), and false if one couldn't be read (it's skipped)
*/
ParsePoints :: proc(text: string) -> ([][2]f32, bool) {
	points := make([dynamic][2]f32, context.temp_allocator)
	ok := true
	for part in strings.fields(text, context.temp_allocator) {
		xs, _, ys := strings.partition(part, ",")
		x, okX := strconv.parse_f32(xs)
		y, okY := strconv.parse_f32(ys)
		if !okX || !okY {
			ok = false
			continue
		}
		append(&points, [2]f32{x, y})
	}
	return points[:], ok
}

// INTERNAL

@(private="file")
attrLayers :: proc(doc: ^xml.Document, element: xml.Element_ID, key: string, default: u64) -> u64 {
	value, found := xml.find_attribute_val_by_key(doc, element, key)
	if !found do return default
	layers, _ := ParsePhysicsLayers(value)
	return layers
}

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
	node.processMode = attrEnum(doc, element, "processMode", ProcessMode.Inherit)
	node.blendMode = attrEnum(doc, element, "blendMode", BlendMode.Blend)
	node.zIndex = i32(attrInt(doc, element, "zIndex", 0))
	node.ySort = attrBool(doc, element, "ySort", false)
	if groups, found := xml.find_attribute_val_by_key(doc, element, "groups"); found && groups != "" {
		for name in strings.split(groups, ",", context.temp_allocator) {
			if trimmed := strings.trim_space(name); trimmed != "" do append(&node.groups, strings.clone(trimmed))
		}
	}
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
	node.margin = attrF32(doc, element, "margin", 0)
	node.spacing = attrF32(doc, element, "spacing", 0)
	node.animations = make([dynamic]AnimationData)
	node.autoplay = cloneAttr(doc, element, "autoplay", "")
	node.component = cloneAttr(doc, element, "component", "")
	node.sound = cloneAttr(doc, element, "sound", "")
	node.bus = cloneAttr(doc, element, "bus", "")
	d := DEFAULT_AUDIO_SETTINGS
	node.audio = {
		volume = max(attrF32(doc, element, "volume", d.volume), 0),
		pitch = clamp(attrF32(doc, element, "pitch", d.pitch), 0.01, 100),
		pan = clamp(attrF32(doc, element, "pan", d.pan), -1, 1),
		// Not AnimatedSprite's `loop` (its default is on)
		loop = node.kind == .AudioPlayer || node.kind == .AudioPlayer2D || node.kind == .MusicPlayer ? attrBool(doc, element, "loop", false) : false,
		autostart = attrBool(doc, element, "autostart", false),
		maxDistance = max(attrF32(doc, element, "maxDistance", d.maxDistance), 1),
		attenuation = max(attrF32(doc, element, "attenuation", d.attenuation), 0.01),
		fadeIn = max(attrF32(doc, element, "fadeIn", 0), 0),
		fadeOut = max(attrF32(doc, element, "fadeOut", 0), 0),
	}
	node.items = make([dynamic]MenuItemData)
	node.props = make([dynamic]ScriptPropData)
	node.collisionLayer = attrLayers(doc, element, "collisionLayer", DEFAULT_SCENE_NODE.collisionLayer)
	node.collisionMask = attrLayers(doc, element, "collisionMask", DEFAULT_SCENE_NODE.collisionMask)
	node.friction = attrF32(doc, element, "friction", DEFAULT_SCENE_NODE.friction)
	node.restitution = attrF32(doc, element, "restitution", DEFAULT_SCENE_NODE.restitution)
	node.density = attrF32(doc, element, "density", DEFAULT_SCENE_NODE.density)
	node.gravityScale = attrF32(doc, element, "gravityScale", DEFAULT_SCENE_NODE.gravityScale)
	node.linearDamping = attrF32(doc, element, "linearDamping", 0)
	node.angularDamping = attrF32(doc, element, "angularDamping", 0)
	node.fixedRotation = attrBool(doc, element, "fixedRotation", false)
	node.bullet = attrBool(doc, element, "bullet", false)
	node.floorMaxAngle = attrF32(doc, element, "floorMaxAngle", DEFAULT_SCENE_NODE.floorMaxAngle)
	node.shape = attrEnum(doc, element, "shape", CollisionShapeKind.Rectangle)
	node.shapeSize = {attrF32(doc, element, "width", DEFAULT_SCENE_NODE.shapeSize.x), attrF32(doc, element, "height", DEFAULT_SCENE_NODE.shapeSize.y)}
	node.radius = attrF32(doc, element, "radius", DEFAULT_SCENE_NODE.radius)
	node.points = make([dynamic][2]f32)
	if value, found := xml.find_attribute_val_by_key(doc, element, "points"); found {
		points, _ := ParsePoints(value)
		append(&node.points, ..points)
	}
	node.disabled = attrBool(doc, element, "disabled", false)
	node.oneWay = attrBool(doc, element, "oneWay", false)
	node.target = {attrF32(doc, element, "targetX", DEFAULT_SCENE_NODE.target.x), attrF32(doc, element, "targetY", DEFAULT_SCENE_NODE.target.y)}
	node.enabled = attrBool(doc, element, "enabled", true)
	node.excludeParent = attrBool(doc, element, "excludeParent", true)
	node.jointKind = attrEnum(doc, element, "joint", JointKind.Revolute)
	node.bodyA = cloneAttr(doc, element, "bodyA", "")
	node.bodyB = cloneAttr(doc, element, "bodyB", "")
	node.jointOffset = {attrF32(doc, element, "offsetX", DEFAULT_SCENE_NODE.jointOffset.x), attrF32(doc, element, "offsetY", DEFAULT_SCENE_NODE.jointOffset.y)}
	node.enableLimit = attrBool(doc, element, "limit", false)
	node.lower = attrF32(doc, element, "lower", 0)
	node.upper = attrF32(doc, element, "upper", 0)
	node.enableMotor = attrBool(doc, element, "motor", false)
	node.motorSpeed = attrF32(doc, element, "motorSpeed", 0)
	node.maxMotor = attrF32(doc, element, "maxMotor", 0)
	node.enableSpring = attrBool(doc, element, "spring", false)
	node.hertz = attrF32(doc, element, "hertz", 0)
	node.dampingRatio = attrF32(doc, element, "damping", DEFAULT_SCENE_NODE.dampingRatio)
	node.collideConnected = attrBool(doc, element, "collideConnected", false)
	dl := DEFAULT_LDTK_LEVEL_SETTINGS
	node.ldtk = {
		file = cloneAttr(doc, element, "ldtk", ""),
		level = cloneAttr(doc, element, "level", ""),
		allLevels = attrBool(doc, element, "allLevels", dl.allLevels),
		collisionLayer = cloneAttr(doc, element, "intGridCollision", ""),
		collisionValues = make([dynamic]int),
		spawnEntities = attrBool(doc, element, "spawnEntities", dl.spawnEntities),
		background = attrBool(doc, element, "background", dl.background),
		smoothTiles = attrBool(doc, element, "smoothTiles", dl.smoothTiles),
		entityComponents = make([dynamic]LDtkEntityComponent),
	}
	if value, found := xml.find_attribute_val_by_key(doc, element, "collisionValues"); found {
		for part in strings.fields(value, context.temp_allocator) {
			if v, ok := strconv.parse_int(part); ok do append(&node.ldtk.collisionValues, v)
		}
	}

	index := len(scene.nodes)
	append(&scene.nodes, node)

	for child in childElements(doc, element) {
		switch doc.elements[child].ident {
		case "node":
			parseNode(doc, child, index, scene)
		case "animation":
			append(&scene.nodes[index].animations, AnimationData{
				name = cloneAttr(doc, child, "name", "default"),
				start = max(attrInt(doc, child, "start", 0), 0),
				end = attrInt(doc, child, "end", -1),
				fps = attrF32(doc, child, "fps", DEFAULT_SCENE_NODE.fps),
				loop = attrBool(doc, child, "loop", false),
				playMode = attrEnum(doc, child, "playMode", AnimationPlayMode.Forward),
			})
		case "particles":
			// Unknown or bad attributes keep the default
			for a in doc.elements[child].attribs do ParticleSettings_Set(&scene.nodes[index].particles, a.key, a.val)
		case "entity":
			append(&scene.nodes[index].ldtk.entityComponents, LDtkEntityComponent{
				cloneAttr(doc, child, "name", ""),
				cloneAttr(doc, child, "component", ""),
			})
		case "item":
			append(&scene.nodes[index].items, MenuItemData{
				cloneAttr(doc, child, "label", ""),
				cloneAttr(doc, child, "action", ""),
			})
		case "listener":
			append(&scene.nodes[index].listeners, NodeListenerData{
				cloneAttr(doc, child, "event", ""),
				cloneAttr(doc, child, "target", ""),
				cloneAttr(doc, child, "handler", ""),
				cloneAttr(doc, child, "global", ""),
			})
		case "script":
			// One per node; a second one is ignored
			if scene.nodes[index].script != "" do continue
			scene.nodes[index].script = cloneAttr(doc, child, "name", "")
			for prop in childElements(doc, child) {
				if doc.elements[prop].ident != "prop" do continue
				append(&scene.nodes[index].props, ScriptPropData{
					cloneAttr(doc, prop, "name", ""),
					cloneAttr(doc, prop, "value", ""),
				})
			}
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
