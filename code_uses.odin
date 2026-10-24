package crossfire

/*
Code uses: what game code typically does with each kind of thing the editor knows, so editors
can write it. The Crossfire Editor's code tabs take drops of scene nodes, animations, states,
input actions, sounds and the rest: dropped in a procedure, the thing becomes one of these uses
(its first is the plain drop, the others its menu). The editor reads `CODE_USES` directly, and
code_uses_test.odin checks that every procedure a use calls exists and takes its name where the
name type says.

A use acts on (`on`):
- a name type of names.odin ("AnimationName", "ActionName"...), optionally narrowed by a word
  after a colon ("StateParamName:Trigger": a Trigger parameter)
- an asset handle type of assets.odin ("SoundAsset", "ComponentAsset"...)
- a node type ("AudioPlayer"; "Node" for any node), whose embedding types share its uses
- a node type's field ("Node.position"), for a property in the editor's inspector
- "Dialogue": a dialogue file (its DIALOGUE_ constant)

Its code names what the editor fills in:
- `{name}`: the name or handle (the project's typed constant: ANIM_HERO_RUN, SOUND_JUMP)
- `{node}`: a pointer to the node of type `node` (the thing's owner: an animation's sprite)
- `{self}`: the script (the procedure's script parameter), `{game}` and `{scene}` its game and scene
- `{value}`: a value of the field's type; `{type}`: a data resource's type
- `{caret}`: where the caret goes (else after the code)

`e.` stands for the engine package (the editor writes the file's own import name).
*/

// How a use's code is written where it's dropped
CodeUseKind :: enum {
	// A statement on its own line
	Statement,
	// A condition: an `if` block in a procedure, the expression in a call's argument
	Condition,
	// A value: `<var> := <code>` in a procedure, the expression in a call's argument
	Value,
}

// One thing code does with a kind of thing (see CODE_USES)
CodeUse :: struct {
	// What it acts on: a name type, a handle type, a node type, "Type.field" (see the file's doc)
	on:    string,
	// What it does, in a menu's words ("Play it")
	title: string,
	kind:  CodeUseKind,
	// The node type `{node}` stands for ("" when the code has none)
	node:  string,
	// The code, with placeholders (see the file's doc)
	code:  string,
	// A Value's variable name ("strength")
	var:   string,
}

/*
What editors offer to write for each kind of thing. For each `on`, the first is the common one
(a plain drop); keep the others few and useful. New node kinds get drops by adding their uses
here.
*/
CODE_USES := [?]CodeUse{
	// Names
	{on = "AnimationName", title = "Play it", kind = .Statement, node = "AnimatedSprite", code = "e.AnimationPlayer_Play(&{node}.animation, {name})"},
	{on = "AnimationName", title = "Play it from the start", kind = .Statement, node = "AnimatedSprite", code = "e.AnimationPlayer_Play(&{node}.animation, {name}, restart = true)"},
	{on = "AnimationName", title = "If it's playing", kind = .Condition, node = "AnimatedSprite", code = "e.AnimationPlayer_IsPlaying(&{node}.animation, {name})"},
	{on = "StateName", title = "Travel to it", kind = .Statement, node = "StateMachine", code = "e.StateMachine_Travel({node}, {name})"},
	{on = "StateName", title = "If it's the current state", kind = .Condition, node = "StateMachine", code = "e.StateMachine_Is({node}, {name})"},
	{on = "StateParamName:Float", title = "Set it", kind = .Statement, node = "StateMachine", code = "e.StateMachine_SetFloat({node}, {name}, {caret}0)"},
	{on = "StateParamName:Bool", title = "Set it", kind = .Statement, node = "StateMachine", code = "e.StateMachine_SetBool({node}, {name}, {caret}true)"},
	{on = "StateParamName:Trigger", title = "Fire it", kind = .Statement, node = "StateMachine", code = "e.StateMachine_SetTrigger({node}, {name})"},
	{on = "StateParamName", title = "Read it", kind = .Value, node = "StateMachine", code = "e.StateMachine_GetParam({node}, {name})", var = "value"},
	{on = "ActionName", title = "If it was just pressed", kind = .Condition, code = "e.Input_IsActionJustPressed({name})"},
	{on = "ActionName", title = "If it's held", kind = .Condition, code = "e.Input_IsActionPressed({name})"},
	{on = "ActionName", title = "If it was just released", kind = .Condition, code = "e.Input_IsActionJustReleased({name})"},
	{on = "ActionName", title = "Its strength (0 to 1)", kind = .Value, code = "e.Input_GetActionStrength({name})", var = "strength"},
	{on = "GroupName", title = "For each node in it", kind = .Statement, code = "for node in e.Scene_GetGroup({scene}, {name}) {\n\t{caret}\n}"},
	{on = "GroupName", title = "Add this node to it", kind = .Statement, code = "e.Node_AddToGroup({self}.node, {name})"},
	{on = "GroupName", title = "If this node is in it", kind = .Condition, code = "e.Node_IsInGroup({self}.node, {name})"},
	{on = "BusName", title = "Set its volume", kind = .Statement, code = "e.Audio_SetBusVolume({name}, {caret}1)"},
	{on = "BusName", title = "Mute it", kind = .Statement, code = "e.Audio_SetBusMute({name}, true)"},
	{on = "SceneName", title = "Change to it", kind = .Statement, code = "e.Game_ChangeScene({game}, {name})"},
	{on = "SceneName", title = "Push it over this one", kind = .Statement, code = "e.Game_PushScene({game}, {name})"},
	{on = "ClipName", title = "Play it", kind = .Statement, node = "Animator", code = "e.Animator_Play({node}, {name})"},
	{on = "ClipName", title = "Play it from the start", kind = .Statement, node = "Animator", code = "e.Animator_Play({node}, {name}, restart = true)"},
	{on = "DialogueNodeName", title = "Start the dialogue here", kind = .Statement, node = "DialogueBox", code = "e.DialogueBox_Start({node}, {name})"},
	{on = "Dialogue", title = "Show it in a new dialogue box", kind = .Value, code = "e.CreateDialogueBox({scene}, {name})", var = "box"},

	// Asset handles
	{on = "SoundAsset", title = "Play it", kind = .Statement, code = "e.Game_PlaySound({game}, {name})"},
	{on = "SoundAsset", title = "Play it on a bus", kind = .Statement, code = "e.Game_PlaySound({game}, {name}, bus = {caret}\"SFX\")"},
	{on = "MusicAsset", title = "Crossfade to it", kind = .Statement, node = "AudioPlayer", code = "e.MusicPlayer_CrossfadeTo({node}, {name}.path, 1)"},
	{on = "MusicAsset", title = "Play it", kind = .Statement, node = "AudioPlayer", code = "e.AudioPlayer_SetSound({node}, {name}.path)\ne.AudioPlayer_Play({node})"},
	{on = "TextureAsset", title = "Load it", kind = .Value, code = "e.Asset_Texture({game}, {name})", var = "texture"},
	{on = "FontAsset", title = "Load it", kind = .Value, code = "e.Asset_Font({game}, {name}, 24)", var = "font"},
	{on = "ComponentAsset", title = "Add one here", kind = .Value, code = "e.Scene_AddComponent({scene}, {name}, position = e.Node_GetWorldPosition({self}.node))", var = "instance"},
	{on = "ComponentAsset", title = "Add one under this node", kind = .Value, code = "e.Scene_AddComponent({scene}, {name}, parent = {self}.node)", var = "instance"},
	{on = "AnimationAsset", title = "Use it on a sprite", kind = .Statement, node = "AnimatedSprite", code = "e.AnimatedSprite_UseAnimations({node}, {name})"},
	{on = "DataAsset", title = "Read its values", kind = .Value, code = "e.Data({type}, {name})", var = "values"},

	// Node types (embedding types share them: an AudioPlayer2D's are AudioPlayer's too)
	{on = "AudioPlayer", title = "Play it", kind = .Statement, node = "AudioPlayer", code = "e.AudioPlayer_Play({node})"},
	{on = "AudioPlayer", title = "Stop it", kind = .Statement, node = "AudioPlayer", code = "e.AudioPlayer_Stop({node})"},
	{on = "AudioPlayer", title = "If it's playing", kind = .Condition, node = "AudioPlayer", code = "e.AudioPlayer_IsPlaying({node})"},
	{on = "ParticleEmitter", title = "Start it", kind = .Statement, node = "ParticleEmitter", code = "e.ParticleEmitter_Start({node})"},
	{on = "ParticleEmitter", title = "Stop it", kind = .Statement, node = "ParticleEmitter", code = "e.ParticleEmitter_Stop({node})"},
	{on = "Animator", title = "Stop it", kind = .Statement, node = "Animator", code = "e.Animator_Stop({node})"},
	{on = "Animator", title = "If it's playing", kind = .Condition, node = "Animator", code = "e.Animator_IsPlaying({node})"},
	{on = "Camera2D", title = "Shake it", kind = .Statement, node = "Camera2D", code = "e.Camera2D_Shake({node}, 4, 0.3)"},
	{on = "DialogueBox", title = "Start it", kind = .Statement, node = "DialogueBox", code = "e.DialogueBox_Start({node})"},
	{on = "DialogueBox", title = "If it's playing", kind = .Condition, node = "DialogueBox", code = "e.DialogueBox_IsPlaying({node})"},
	{on = "Control", title = "Set its text", kind = .Statement, node = "Control", code = "e.Control_SetText({node}, \"{caret}\")"},
	{on = "Node", title = "Its world position", kind = .Value, node = "Node", code = "e.Node_GetWorldPosition({node})", var = "position"},
	{on = "Node", title = "Hide it", kind = .Statement, node = "Node", code = "{node}.visible = false"},
	{on = "Node", title = "Remove it", kind = .Statement, node = "Node", code = "e.Scene_RemoveNode({scene}, {node}.id)"},

	// Fields shown in the inspector, beyond reading and setting them
	{on = "Node.position", title = "Its world position", kind = .Value, node = "Node", code = "e.Node_GetWorldPosition({node})", var = "position"},
	{on = "Node.position", title = "Move it in the world", kind = .Statement, node = "Node", code = "e.Node_SetWorldPosition({node}, {caret}{value})"},
}

/*
The uses of a kind of thing, the common one first.

Inputs:
- on: What they act on (see CODE_USES)
- allocator: For the list

Returns:
- The uses, in the table's order
*/
CodeUses_For :: proc(on: string, allocator := context.temp_allocator) -> []CodeUse {
	out := make([dynamic]CodeUse, allocator)
	for use in CODE_USES do if use.on == on do append(&out, use)
	return out[:]
}
