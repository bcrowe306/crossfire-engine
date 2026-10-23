package crossfire

/*
Name types: what kind of name a procedure's string parameter takes. Each is an alias of `string`
(`NodePath :: string`), not a distinct type: any string still goes in, a variable or a
`fmt.tprintf` as well as a literal, so no code has to change, and the editor's typed constants
(`SCENE_FOREST`, `PATH_HERO_SPRITE`) fit them. What they add is meaning:
- signatures and their docs say which names go where (`Game_ChangeScene(game, name: SceneName)`)
- the editor reads them from this package's source (`core:odin/parser`): its code editor completes
  those names inside a call's string argument (the project's scenes, the sprite's animations, the
  nodes around the script's node), offers the typed constants there first, and warns about a name
  the project doesn't have.

**Rules for the engine's own procedures** (names_test.odin checks them):
- a parameter that takes one of these names has its type, also with a default
  (`node: DialogueNodeName = ""`, not `node := ""`)
- a procedure whose name has `_Add` or `_Create` in it declares the name it's given
  (`Node_AddToGroup`, `Audio_AddBus`, `Input_AddAction`, `Game_CreateScene`): editors complete
  existing names there but don't report new ones, and count them as known elsewhere
- other procedures only use names that exist (made in the editor or declared in code)
*/

/*
A path from a node to another, as `Node_FindPath` reads it: child names separated by "/"
("Gun", "Arm/Hand"), ".." for the parent, "." for the node itself, and a leading "/" for the
scene's top level ("/HUD/BossBar").

Example:
	// Given: self: ^e.Script
	camera := e.Node_FindPath(self.node, "../Camera")
*/
NodePath :: string

/*
A path of child names below a node, as `Node_FindChild` reads it ("Sprite", "Arm/Hand"): no
".." and no leading "/".

Example:
	// Given: self: ^e.Script
	sprite := e.Node_FindChild(self.node, "Sprite")
*/
ChildPath :: string

/*
A node of a scene, as `Scene_FindNode` reads it: a name ("Level": the first node of that name
anywhere), a path from a top-level node ("HUD/BossBar"), or a path from the top level with a
leading "/" ("/HUD/BossBar": the top-level HUD only).

Example:
	hud := e.Scene_FindNode(scene, "/HUD")
*/
ScenePath :: string

/*
An animation of an AnimatedSprite (its own, its animation asset's, or an Aseprite file's tags).

Example:
	// Given: sprite: ^e.AnimatedSprite
	e.AnimationPlayer_Play(&sprite.animation, "run")
*/
AnimationName :: string

/*
An input action (Project Settings > Input, or `Input_AddAction`).

Example:
	if e.Input_IsActionJustPressed("jump") do e.Log_Info("jump")
*/
ActionName :: string

/*
A node group (a node's groups in the editor, or `Node_AddToGroup`).

Example:
	for enemy in e.Scene_GetGroup(scene, "enemies") do enemy.visible = false
*/
GroupName :: string

/*
A mix bus (the editor's Mixer, project.xml's `<bus>`, or `Audio_AddBus`). "" is Master where a
procedure says so.

Example:
	e.Audio_SetBusVolume("Music", 0.5)
*/
BusName :: string

/*
A scene of the project, by name (or one made with `Game_CreateScene`).

Example:
	e.Game_ChangeScene(game, "TitleScene")
*/
SceneName :: string

/*
A state of a StateMachine node.

Example:
	// Given: brain: ^e.StateMachine
	if e.StateMachine_Is(brain, "attack") do e.Log_Info("attacking")
*/
StateName :: string

/*
A parameter of a StateMachine node (Float, Bool or Trigger).

Example:
	// Given: brain: ^e.StateMachine
	e.StateMachine_SetFloat(brain, "speed", 120)
*/
StateParamName :: string

/*
A clip of an Animator node (the Timeline's clips).

Example:
	// Given: animator: ^e.Animator
	e.Animator_Play(animator, "intro")
*/
ClipName :: string

/*
A node of a dialogue (a `.dialogue.xml` file's nodes).

Example:
	// Given: box: ^e.DialogueBox
	e.DialogueBox_Start(box, "Start")
*/
DialogueNodeName :: string

/*
A Steam achievement's API name (Project Settings > Steam).

Example:
	e.Steam_UnlockAchievement("first_blood")
*/
AchievementName :: string

/*
A sound or music file, relative to the project folder ("assets/sfx/jump.wav"). Code that names
a project asset can use its typed handle instead (`SoundAsset`, `MusicAsset`).

Example:
	e.Game_PlaySound(game, "assets/sfx/jump.wav")
*/
SoundPath :: string
