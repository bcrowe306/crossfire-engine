package crossfire

import "core:log"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

/*
State machines: a **StateMachine** node keeps one of a set of **states** (idle, run, jump,
attack, hurt) and moves between them by **transitions** whose conditions read **parameters** your
scripts set (a speed, whether it's on the ground, a "jump" trigger). Each state can play an
animation of an AnimatedSprite, so a character's animation follows what it's doing without code
picking animations.

	<node kind="StateMachine" name="Brain" start="idle">
		<param name="speed" type="Float"/>
		<param name="grounded" type="Bool" value="true"/>
		<param name="jump" type="Trigger"/>
		<state name="idle" animation="idle"/>
		<state name="run" animation="run"/>
		<state name="jump" animation="jump"/>
		<transition from="idle" to="run" when="speed > 10"/>
		<transition from="run" to="idle" when="speed <= 10"/>
		<transition from="*" to="jump" when="jump"/>
		<transition from="jump" to="idle" when="grounded" after="0.2"/>
	</node>

- **Parameters** (`StateMachineParam`): Float (a number), Bool (true or false) and Trigger (set,
  then cleared when a transition uses it). Scripts set them: `StateMachine_SetFloat`,
  `StateMachine_SetBool`, `StateMachine_SetTrigger`.
- **Transitions** (`StateMachineTransition`): from a state (or `*`: from any other state) to
  another, when its condition holds: clauses joined by `and`, each `name` (a Bool that's true,
  a Trigger that's set), `!name`, or `name <op> number` with ==, !=, <, <=, >, >= (Bools compare as
  1 and 0). `after`: not before that many seconds in the state; `onFinished`: only once the
  state's animation ended (a non-looping one). They're checked in order every update; the first
  that holds is taken (at most one per update).
- **Animations:** a state's `animation` plays (from its start) on the `target` AnimatedSprite (a
  path from the StateMachine: "" its parent) when the state is entered.
- **Events:** `onStateEntered` and `onStateExited` (data: the state's name). Listen to them to do
  things on entering a state (a sound when attacking, damage when hurt).
- **Code:** `StateMachine_Current`, `StateMachine_Is`, `StateMachine_TimeInState`,
  `StateMachine_Travel` (go to a state now).
*/

// What a parameter holds
StateMachineParamKind :: enum {
	Float,
	Bool,
	// Set by code, cleared when a transition uses it
	Trigger,
}

// A parameter in a scene file (`StateMachineSettings.params`)
StateMachineParam :: struct {
	name: string,
	kind: StateMachineParamKind,
	// Its starting value as text ("0", "true")
	value: string,
}

// A state in a scene file
StateMachineState :: struct {
	name: string,
	// The target AnimatedSprite's animation it plays ("": none)
	animation: string,
	// Where editors draw it in the graph
	position: [2]f32,
}

// A transition in a scene file
StateMachineTransition :: struct {
	// The state it leaves ("*": any other state) and the one it enters
	from, to: string,
	// Its condition ("": always), e.g. "speed > 10 and grounded"
	condition: string,
	// Seconds in the state before it can be taken (0: at once)
	after: f32,
	// Only once the state's animation ended
	onFinished: bool,
}

/*
A state machine's settings (`SceneNodeData.stateMachine`). Owned: `StateMachineSettings_Destroy`.
*/
StateMachineSettings :: struct {
	// The state it starts in ("": the first)
	start: string,
	// The AnimatedSprite its states animate: a path from it ("": its parent)
	target: string,
	params: [dynamic]StateMachineParam,
	states: [dynamic]StateMachineState,
	transitions: [dynamic]StateMachineTransition,
}

// A condition's clause, parsed
@(private="file")
Clause :: struct {
	param: int,
	op: string,
	value: f32,
}

// A transition ready to run (node arena)
@(private="file")
RuntimeTransition :: struct {
	// States' indices (-1: any)
	from, to: int,
	clauses: []Clause,
	after: f32,
	onFinished: bool,
}

// A node moving between states: see the file's overview
StateMachine :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Its states' names and animations (node arena)
	states: []StateMachineState,
	// Parameters' names, kinds and values (node arena)
	paramNames: []string,
	paramKinds: []StateMachineParamKind,
	values: []f32,
	transitions: []RuntimeTransition,
	// The current state (-1: before the first update)
	current: int,
	// Seconds in it
	timeInState: f32,
	// Its animation ended
	animationFinished: bool,
	// The start state's index, and the target's path (node arena)
	startIndex: int,
	targetPath: string,
	// The target AnimatedSprite, once found
	target: ^AnimatedSprite,
	targetId: EntityId,
	onStateEntered: EventSubject `event:"It entered a state (data: the state's name)" data:"state := data.(string)"`,
	onStateExited: EventSubject `event:"It left a state (data: the state's name)" data:"state := data.(string)"`,
}

/*
Creates a StateMachine with these settings (copied) and adds it to the scene (at the start of the
next update). It enters its start state on its first update.

Inputs:
- scene: The scene
- settings: Its states, transitions and parameters

Returns:
- The state machine
*/
CreateStateMachine :: proc(scene: ^Scene, settings: StateMachineSettings) -> ^StateMachine {
	sm := CreateNode(scene, StateMachine)
	allocator := Node_GetAllocator(sm)
	EventSubject_Init(&sm.onStateEntered, allocator)
	EventSubject_Init(&sm.onStateExited, allocator)
	sm.current = -1
	sm.states = make([]StateMachineState, len(settings.states), allocator)
	for st, i in settings.states do sm.states[i] = {strings.clone(st.name, allocator), strings.clone(st.animation, allocator), st.position}
	sm.paramNames = make([]string, len(settings.params), allocator)
	sm.paramKinds = make([]StateMachineParamKind, len(settings.params), allocator)
	sm.values = make([]f32, len(settings.params), allocator)
	for p, i in settings.params {
		sm.paramNames[i] = strings.clone(p.name, allocator)
		sm.paramKinds[i] = p.kind
		sm.values[i] = parseParamValue(p.value)
	}
	sm.transitions = make([]RuntimeTransition, len(settings.transitions), allocator)
	for t, i in settings.transitions {
		sm.transitions[i] = {
			from = t.from == "*" ? -1 : StateMachine_StateIndex(sm, t.from),
			to = StateMachine_StateIndex(sm, t.to),
			clauses = parseCondition(sm, t.condition, allocator),
			after = t.after,
			onFinished = t.onFinished,
		}
		if sm.transitions[i].to < 0 do log.warnf("StateMachine: a transition goes to '%s', which isn't one of its states", t.to)
	}
	sm.startIndex = settings.start != "" ? StateMachine_StateIndex(sm, settings.start) : 0
	if sm.startIndex < 0 do sm.startIndex = 0
	sm.targetPath = strings.clone(settings.target, allocator)
	sm.update = stateMachineUpdate
	return sm
}

/*
The current state's name ("" before the first update, or without states).
*/
StateMachine_Current :: proc(sm: ^StateMachine) -> string {
	return sm.current >= 0 && sm.current < len(sm.states) ? sm.states[sm.current].name : ""
}

/*
Whether it's in a state.
*/
StateMachine_Is :: proc(sm: ^StateMachine, state: string) -> bool {
	return StateMachine_Current(sm) == state
}

/*
Seconds since it entered its current state.
*/
StateMachine_TimeInState :: proc(sm: ^StateMachine) -> f32 {
	return sm.timeInState
}

/*
A state's index by name (-1: none).
*/
StateMachine_StateIndex :: proc(sm: ^StateMachine, name: string) -> int {
	for st, i in sm.states do if st.name == name do return i
	return -1
}

/*
Goes to a state now, whatever the transitions say (it's entered again if it's the current one).

Returns:
- false when there's no such state

Example:
	// Given: brain: ^e.StateMachine
	e.StateMachine_Travel(brain, "hurt")
*/
StateMachine_Travel :: proc(sm: ^StateMachine, state: string) -> bool {
	i := StateMachine_StateIndex(sm, state)
	if i < 0 do return false
	enterState(sm, i)
	return true
}

/*
Sets a Float parameter.

Example:
	// Given: brain: ^e.StateMachine, velocity: [2]f32
	e.StateMachine_SetFloat(brain, "speed", abs(velocity.x))
*/
StateMachine_SetFloat :: proc(sm: ^StateMachine, name: string, value: f32) {
	if i := paramIndex(sm, name); i >= 0 do sm.values[i] = value
}

/*
Sets a Bool parameter.

Example:
	// Given: brain: ^e.StateMachine, mover: ^e.CharacterMover
	e.StateMachine_SetBool(brain, "grounded", mover.onFloor)
*/
StateMachine_SetBool :: proc(sm: ^StateMachine, name: string, value: bool) {
	if i := paramIndex(sm, name); i >= 0 do sm.values[i] = value ? 1 : 0
}

/*
Sets a Trigger: the next transition its condition is part of is taken, and the trigger cleared.

Example:
	// Given: brain: ^e.StateMachine
	e.StateMachine_SetTrigger(brain, "jump")
*/
StateMachine_SetTrigger :: proc(sm: ^StateMachine, name: string) {
	if i := paramIndex(sm, name); i >= 0 do sm.values[i] = 1
}

/*
A parameter's value (Bools and Triggers: 1 or 0).
*/
StateMachine_GetParam :: proc(sm: ^StateMachine, name: string) -> f32 {
	if i := paramIndex(sm, name); i >= 0 do return sm.values[i]
	return 0
}

/*
Whether a condition is well formed for a set of parameters: "" when it is, else what's wrong
(editors show it).

Inputs:
- settings: The machine's settings (its parameters)
- condition: The condition

Returns:
- The problem, or ""
*/
StateMachine_ConditionProblem :: proc(settings: ^StateMachineSettings, condition: string) -> string {
	for clause in conditionClauses(condition) {
		name, op, value := splitClause(clause)
		if name == "" do return "an empty clause"
		found := false
		for p in settings.params do if p.name == name do found = true
		if !found do return strings.concatenate({"no parameter '", name, "'"}, context.temp_allocator)
		if op != "" {
			if _, ok := strconv.parse_f32(value); !ok && value != "true" && value != "false" do return strings.concatenate({"'", value, "' isn't a number"}, context.temp_allocator)
		}
	}
	return ""
}

/*
A deep copy of state machine settings.
*/
StateMachineSettings_Clone :: proc(s: StateMachineSettings, allocator := context.allocator) -> StateMachineSettings {
	out := StateMachineSettings{start = strings.clone(s.start, allocator), target = strings.clone(s.target, allocator)}
	out.params = make([dynamic]StateMachineParam, 0, len(s.params), allocator)
	for p in s.params do append(&out.params, StateMachineParam{strings.clone(p.name, allocator), p.kind, strings.clone(p.value, allocator)})
	out.states = make([dynamic]StateMachineState, 0, len(s.states), allocator)
	for st in s.states do append(&out.states, StateMachineState{strings.clone(st.name, allocator), strings.clone(st.animation, allocator), st.position})
	out.transitions = make([dynamic]StateMachineTransition, 0, len(s.transitions), allocator)
	for t in s.transitions do append(&out.transitions, StateMachineTransition{strings.clone(t.from, allocator), strings.clone(t.to, allocator), strings.clone(t.condition, allocator), t.after, t.onFinished})
	return out
}

/*
Frees state machine settings (the parser's, `StateMachineSettings_Clone`'s) and empties them.
*/
StateMachineSettings_Destroy :: proc(s: ^StateMachineSettings) {
	for p in s.params {
		delete(p.name)
		delete(p.value)
	}
	for st in s.states {
		delete(st.name)
		delete(st.animation)
	}
	for t in s.transitions {
		delete(t.from)
		delete(t.to)
		delete(t.condition)
	}
	delete(s.params)
	delete(s.states)
	delete(s.transitions)
	delete(s.start)
	delete(s.target)
	s^ = {}
}

/*
Whether two state machine settings are the same.
*/
StateMachineSettings_Equal :: proc(a, b: StateMachineSettings) -> bool {
	if a.start != b.start || a.target != b.target || len(a.params) != len(b.params) || len(a.states) != len(b.states) || len(a.transitions) != len(b.transitions) do return false
	for p, i in a.params do if p.name != b.params[i].name || p.kind != b.params[i].kind || p.value != b.params[i].value do return false
	for st, i in a.states do if st != b.states[i] do return false
	for t, i in a.transitions do if t != b.transitions[i] do return false
	return true
}

// INTERNAL

@(private="file")
paramIndex :: proc(sm: ^StateMachine, name: string) -> int {
	for n, i in sm.paramNames do if n == name do return i
	return -1
}

@(private="file")
parseParamValue :: proc(text: string) -> f32 {
	switch strings.trim_space(text) {
	case "true": return 1
	case "false", "": return 0
	}
	v, _ := strconv.parse_f32(strings.trim_space(text))
	return v
}

// A condition's clauses: split on "and" (and "&&")
@(private="file")
conditionClauses :: proc(condition: string) -> []string {
	text, _ := strings.replace_all(condition, "&&", " and ", context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	for part in strings.split(text, " and ", context.temp_allocator) {
		p := strings.trim_space(part)
		if p != "" do append(&out, p)
	}
	return out[:]
}

// "speed > 10" -> speed, >, 10; "grounded" -> grounded; "!grounded" -> grounded, ==, 0
@(private="file")
splitClause :: proc(clause: string) -> (name, op, value: string) {
	for o in ([6]string{">=", "<=", "==", "!=", ">", "<"}) {
		if i := strings.index(clause, o); i >= 0 {
			return strings.trim_space(clause[:i]), o, strings.trim_space(clause[i + len(o):])
		}
	}
	if strings.has_prefix(clause, "!") do return strings.trim_space(clause[1:]), "==", "0"
	return strings.trim_space(clause), "", ""
}

@(private="file")
parseCondition :: proc(sm: ^StateMachine, condition: string, allocator := context.allocator) -> []Clause {
	clauses := make([dynamic]Clause, allocator)
	for text in conditionClauses(condition) {
		name, op, value := splitClause(text)
		i := paramIndex(sm, name)
		if i < 0 {
			log.warnf("StateMachine: a condition names '%s', which isn't one of its parameters", name)
			// Never true
			append(&clauses, Clause{-1, "", 0})
			continue
		}
		append(&clauses, Clause{i, op, parseParamValue(value)})
	}
	return clauses[:]
}

@(private="file")
holds :: proc(sm: ^StateMachine, clauses: []Clause) -> bool {
	for c in clauses {
		if c.param < 0 do return false
		v := sm.values[c.param]
		ok: bool
		switch c.op {
		case "": ok = v != 0
		case "==": ok = v == c.value
		case "!=": ok = v != c.value
		case "<": ok = v < c.value
		case "<=": ok = v <= c.value
		case ">": ok = v > c.value
		case ">=": ok = v >= c.value
		}
		if !ok do return false
	}
	return true
}

@(private="file")
findTarget :: proc(sm: ^StateMachine) -> ^AnimatedSprite {
	if sm.target != nil && sm.scene != nil && Scene_GetNode(sm.scene, sm.targetId) == sm.target do return sm.target
	sm.target = nil
	n: ^Node = sm.targetPath == "" ? sm.parent : Node_FindPath(sm, sm.targetPath)
	if n == nil || !Node_Is(n, AnimatedSprite) do return nil
	sm.target = cast(^AnimatedSprite)n
	sm.targetId = n.id
	// Its animations' ends finish states waiting for them
	Event_Subscribe(&sm.target.animation.onAnimationEnded, proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) {
		(cast(^StateMachine)user).animationFinished = true
	}, sm)
	return sm.target
}

@(private="file")
enterState :: proc(sm: ^StateMachine, index: int) {
	if sm.current >= 0 do Event_Notify(&sm.onStateExited, sm, sm.states[sm.current].name)
	sm.current = index
	sm.timeInState = 0
	sm.animationFinished = false
	st := sm.states[index]
	if st.animation != "" {
		if target := findTarget(sm); target != nil do AnimationPlayer_Play(&target.animation, st.animation, restart = true)
	}
	Event_Notify(&sm.onStateEntered, sm, st.name)
}

@(private="file")
stateMachineUpdate :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	sm := cast(^StateMachine)node
	if len(sm.states) == 0 do return
	if sm.current < 0 {
		enterState(sm, sm.startIndex)
		return
	}
	sm.timeInState += f32(deltaTime)
	for t in sm.transitions {
		if t.to < 0 || (t.from >= 0 && t.from != sm.current) || (t.from < 0 && t.to == sm.current) do continue
		if t.after > 0 && sm.timeInState < t.after do continue
		if t.onFinished && !sm.animationFinished do continue
		if !holds(sm, t.clauses) do continue
		// The triggers it used are spent
		for c in t.clauses do if c.param >= 0 && sm.paramKinds[c.param] == .Trigger do sm.values[c.param] = 0
		enterState(sm, t.to)
		return
	}
}
