package crossfire

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import sdl "vendor:sdl3"

/*
State machines: a **StateMachine** node keeps one of a set of **states** (idle, run, jump,
attack, hurt) and moves between them by **transitions** whose conditions read **parameters** your
scripts set (a speed, whether it's on the ground, a "jump" trigger) and **guards** your code
provides. Each state can play an animation of an AnimatedSprite, so a character's animation
follows what it's doing without code picking animations.

	<node kind="StateMachine" name="Brain" start="idle">
		<param name="speed" type="Float"/>
		<param name="grounded" type="Bool" value="true"/>
		<param name="jump" type="Trigger"/>
		<param name="hurt" type="Trigger"/>
		<state name="idle" animation="idle"/>
		<state name="run" animation="run" speed="1.5"/>
		<state name="jump" animation="jump"/>
		<state name="attack" animation="attack" loop="Once" canExit="!busy()" onEnter="swing"/>
		<state name="hurt" animation="hurt"/>
		<transition from="idle" to="run" when="speed > 10 and grounded"/>
		<transition from="run" to="idle" when="speed <= 10"/>
		<transition from="*" to="jump" when="jump" guard="grounded"/>
		<transition from="*" to="hurt" when="hurt" priority="10" interrupts="true"/>
		<transition from="jump" to="idle" when="grounded" after="0.2"/>
		<transition from="attack" to="idle" onFinished="true"/>
	</node>

- **Parameters** (`StateMachineParam`): Float (a number), Bool (true or false) and Trigger (set,
  then cleared when a transition reading it is taken). Scripts set them:
  `StateMachine_SetFloat`, `StateMachine_SetBool`, `StateMachine_SetTrigger`.
- **Conditions** (a transition's `when`, its `guard`, a state's `canExit`): clauses joined by
  `and` (`&&`) and `or` (`||`), `not` (`!`) and parentheses (`and` binds tighter than `or`). A
  clause is `name` (a Bool that's true, a Trigger that's set, a Float that isn't 0),
  `name <op> number` with ==, !=, <, <=, >, >= (Bools compare as 1 and 0, `true` and `false`
  too), or `guard()`: a **code guard**, an Odin procedure a script registers by name
  (`StateMachine_RegisterGuard`, or `StateMachine_SetGuard` for one machine with the script's
  `self`). An empty condition always holds. `StateMachine_SplitCondition` and
  `StateMachine_JoinCondition` read and write the flat ones (all of, any of) editors build.
- **Transitions** (`StateMachineTransition`): from a state (or `*`: from any other state) to
  another, when its `when` and its `guard` both hold (the guard: extra conditions, shown apart
  in editors: which one blocks). **Exit time:** `after` (not before that many seconds in the
  state), `onFinished` (only once the state's animation ended). **Priority:** every update the
  transitions out of the current state are tried highest `priority` first (equal ones in their
  order); the first that can be taken is (at most one per update). **Interrupts:** a state's
  `canExit` (its **exit guard**) keeps it while it doesn't hold: no transition leaves, except
  one that `interrupts` (a hurt or a death cutting an attack short).
- **States:** a state's `animation` plays (from its start) on the `target` AnimatedSprite (a path
  from the StateMachine: "" its parent) when it's entered, at its `speed`, looping or once as its
  `loop` says (`AnimationPlayer.loopRule`). Its `onEnter` and `onExit` name events the machine
  sends through `onStateEvent`.
- **Events:** `onStateEntered` and `onStateExited` (data: the state's name), `onTransition`
  (data: a `^StateMachineTransitionInfo`), `onStateEvent` (data: a state's `onEnter` / `onExit`
  name). `StateMachine_OnEnter` and `StateMachine_OnExit` listen to one state.
- **Code:** `StateMachine_Current`, `StateMachine_Previous`, `StateMachine_Is`,
  `StateMachine_TimeInState`, `StateMachine_CanExit`, `StateMachine_Travel` (go to a state now,
  whatever the guards say), `StateMachine_TryTravel` (only when the state can be left),
  `StateMachine_TransitionStatus` (why a transition is or isn't taken: editors show it live).
- **Crossfades:** none. A state's animation starts at once: an AnimatedSprite shows one frame of
  one animation at a time, so there's nothing to blend between.
*/

// What a parameter holds
StateMachineParamKind :: enum {
	Float,
	Bool,
	// Set by code, cleared when a transition reading it is taken
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
	// Its exit guard: a condition; while it doesn't hold, only transitions that interrupt leave
	// ("": it can always be left)
	canExit: string,
	// Its animation's playback speed (1 as made, 2 double; 0 counts as 1)
	speed: f32,
	// Whether its animation loops: as made, or overridden
	loop: AnimationLoopRule,
	// Events `onStateEvent` sends when it's entered and when it's left ("": none)
	enterEvent, exitEvent: string,
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
	// Its guard: more conditions that must hold too ("": none), e.g. "can_attack() and !stunned"
	guard: string,
	// Tried before the ones with a lower priority (0 by default; equal ones in their order)
	priority: int,
	// Taken even while the state's exit guard (`canExit`) keeps it
	interrupts: bool,
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

/*
A code guard: whether a transition may be taken, or a state left (a condition's `name()`).
Keep it quick and without side effects: it's called every update while its transition is tried,
and by editors showing the machine live.
*/
StateMachineGuard :: proc(sm: ^StateMachine) -> bool

// What `onTransition` carries (valid during the notification)
StateMachineTransitionInfo :: struct {
	// The states it left and entered
	from, to: string,
	// The transition's index in the settings (-1: `StateMachine_Travel`)
	index: int,
}

// A state's listener (`StateMachine_OnEnter`, `StateMachine_OnExit`): the machine and the state
StateMachineStateHandler :: proc(sm: ^StateMachine, state: string, user: rawptr)

// Why a transition is or isn't taken now (`StateMachine_TransitionStatus`)
StateMachineTransitionStatus :: enum {
	// It doesn't leave the current state (or the machine hasn't started)
	Not_From_Here,
	// Its exit time hasn't come: `after` seconds, or the animation's end
	Waiting,
	// Its condition (`when`) doesn't hold
	Condition_False,
	// Its condition holds, its guard doesn't
	Guard_Failed,
	// Both hold, but the state's exit guard keeps it (and it doesn't interrupt)
	Exit_Blocked,
	// It would be taken (unless one tried before it is)
	Ready,
}

/*
One clause of a flat condition (`StateMachine_SplitCondition`): what editors show as a row.
*/
StateMachineClause :: struct {
	// The parameter, or the code guard's name (`guard`)
	name: string,
	guard: bool,
	// `!name`, `!guard()`: it holds when the clause doesn't
	negated: bool,
	// "" (the parameter is true, set, not 0), or ==, !=, <, <=, >, >=
	op: string,
	// What it's compared with ("10", "true")
	value: string,
}

// A condition's piece, compiled (a node arena's flat tree)
@(private="file")
CondNode :: struct {
	kind: enum u8 { Never, Param, Guard, Not, And, Or },
	op: CompareOp,
	param: int,
	value: f32,
	guard: string,
	// Children: Not's `a`, And's and Or's `a` and `b`
	a, b: int,
	// A missing guard was logged
	warned: bool,
}

// A clause's comparison (Truthy: the parameter isn't 0)
@(private="file")
CompareOp :: enum u8 { Truthy, Eq, Ne, Lt, Le, Gt, Ge }

// A compiled condition (root -1: always holds)
@(private="file")
Condition :: struct {
	nodes: []CondNode,
	root: int,
}

// A transition ready to run (node arena)
@(private="file")
RuntimeTransition :: struct {
	// States' indices (-1: any)
	from, to: int,
	condition, guard: Condition,
	// The Trigger parameters its condition and guard read (spent when it's taken)
	triggers: []int,
	after: f32,
	onFinished, interrupts: bool,
	priority: int,
	// Its index in the settings
	index: int,
	// Its condition and guard as written (node arena: editors' rows, live)
	conditionText, guardText: string,
}

// A guard one machine has (`StateMachine_SetGuard`)
@(private="file")
OwnGuard :: struct {
	name: string,
	call: proc(self: rawptr) -> bool,
	self: rawptr,
}

// A node moving between states: see the file's overview
StateMachine :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Its states' names and animations (node arena)
	states: []StateMachineState,
	// Each state's exit guard, compiled
	exits: []Condition,
	// Parameters' names, kinds and values (node arena)
	paramNames: []string,
	paramKinds: []StateMachineParamKind,
	values: []f32,
	// Highest priority first
	transitions: []RuntimeTransition,
	// The current state (-1: before the first update) and the one before it (-1: none)
	current, previous: int,
	// Seconds in it
	timeInState: f32,
	// Its animation ended
	animationFinished: bool,
	// A state's speed other than 1 was given to the target's player (one of 1 then puts it back)
	speedSet: bool,
	// The start state's index, and the target's path (node arena)
	startIndex: int,
	targetPath: string,
	// The target AnimatedSprite, once found
	target: ^AnimatedSprite,
	targetId: EntityId,
	// Guards set on this machine (`StateMachine_SetGuard`)
	guards: [dynamic]OwnGuard,
	onStateEntered: EventSubject `event:"It entered a state (data: the state's name)" data:"state := data.(string)"`,
	onStateExited: EventSubject `event:"It left a state (data: the state's name)" data:"state := data.(string)"`,
	onTransition: EventSubject `event:"It moved from a state to another (data: the states and the transition)" data:"info := (^e.StateMachineTransitionInfo)(data.(rawptr))"`,
	onStateEvent: EventSubject `event:"A state's enter or exit event (data: its name)" data:"name := data.(string)"`,
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
	EventSubject_Init(&sm.onTransition, allocator)
	EventSubject_Init(&sm.onStateEvent, allocator)
	sm.guards = make([dynamic]OwnGuard, allocator)
	sm.current, sm.previous = -1, -1
	sm.paramNames = make([]string, len(settings.params), allocator)
	sm.paramKinds = make([]StateMachineParamKind, len(settings.params), allocator)
	sm.values = make([]f32, len(settings.params), allocator)
	for p, i in settings.params {
		sm.paramNames[i] = strings.clone(p.name, allocator)
		sm.paramKinds[i] = p.kind
		sm.values[i] = parseParamValue(p.value)
	}
	sm.states = make([]StateMachineState, len(settings.states), allocator)
	sm.exits = make([]Condition, len(settings.states), allocator)
	for st, i in settings.states {
		sm.states[i] = StateMachineState_Clone(st, allocator)
		sm.exits[i] = compileCondition(sm, st.canExit, allocator)
	}
	sm.transitions = make([]RuntimeTransition, len(settings.transitions), allocator)
	for t, i in settings.transitions {
		rt := RuntimeTransition{
			from = t.from == "*" ? -1 : StateMachine_StateIndex(sm, t.from),
			to = StateMachine_StateIndex(sm, t.to),
			condition = compileCondition(sm, t.condition, allocator),
			guard = compileCondition(sm, t.guard, allocator),
			after = t.after,
			onFinished = t.onFinished,
			interrupts = t.interrupts,
			priority = t.priority,
			index = i,
			conditionText = strings.clone(t.condition, allocator),
			guardText = strings.clone(t.guard, allocator),
		}
		triggers := make([dynamic]int, allocator)
		for c in ([2]Condition{rt.condition, rt.guard}) {
			for n in c.nodes do if n.kind == .Param && sm.paramKinds[n.param] == .Trigger && !slice.contains(triggers[:], n.param) do append(&triggers, n.param)
		}
		rt.triggers = triggers[:]
		sm.transitions[i] = rt
		if rt.to < 0 do log.warnf("StateMachine: a transition goes to '%s', which isn't one of its states", t.to)
	}
	// Highest priority first; equal ones keep their order
	slice.stable_sort_by(sm.transitions, proc(a, b: RuntimeTransition) -> bool { return a.priority > b.priority })
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
The state it was in before the current one ("": none yet).

Example:
	// Given: brain: ^e.StateMachine
	if e.StateMachine_Is(brain, "idle") && e.StateMachine_Previous(brain) == "attack" do e.Log_Info("the attack ended")
*/
StateMachine_Previous :: proc(sm: ^StateMachine) -> string {
	return sm.previous >= 0 && sm.previous < len(sm.states) ? sm.states[sm.previous].name : ""
}

/*
Whether it's in a state.
*/
StateMachine_Is :: proc(sm: ^StateMachine, state: StateName) -> bool {
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
StateMachine_StateIndex :: proc(sm: ^StateMachine, state: StateName) -> int {
	for st, i in sm.states do if st.name == state do return i
	return -1
}

/*
Whether its current state can be left now: its exit guard (`canExit`) holds, or it has none.
Transitions that interrupt leave it either way, and so does `StateMachine_Travel`.

Example:
	// Given: brain: ^e.StateMachine
	if e.StateMachine_CanExit(brain) do e.StateMachine_SetTrigger(brain, "attack")
*/
StateMachine_CanExit :: proc(sm: ^StateMachine) -> bool {
	if sm.current < 0 || sm.current >= len(sm.exits) do return true
	return evaluate(sm, sm.exits[sm.current])
}

/*
Goes to a state now, whatever the transitions and guards say (it's entered again if it's the
current one).

Returns:
- false when there's no such state

Example:
	// Given: brain: ^e.StateMachine
	e.StateMachine_Travel(brain, "hurt")
*/
StateMachine_Travel :: proc(sm: ^StateMachine, state: StateName) -> bool {
	i := StateMachine_StateIndex(sm, state)
	if i < 0 do return false
	enterState(sm, i, -1)
	return true
}

/*
Goes to a state now if the current one can be left (`StateMachine_CanExit`), whatever the
transitions say.

Returns:
- false when there's no such state, or the current state's exit guard keeps it

Example:
	// Given: brain: ^e.StateMachine
	if !e.StateMachine_TryTravel(brain, "dodge") do e.Log_Info("busy")
*/
StateMachine_TryTravel :: proc(sm: ^StateMachine, state: StateName) -> bool {
	i := StateMachine_StateIndex(sm, state)
	if i < 0 || !StateMachine_CanExit(sm) do return false
	enterState(sm, i, -1)
	return true
}

/*
Sets a Float parameter.

Example:
	// Given: brain: ^e.StateMachine, velocity: [2]f32
	e.StateMachine_SetFloat(brain, "speed", abs(velocity.x))
*/
StateMachine_SetFloat :: proc(sm: ^StateMachine, name: StateParamName, value: f32) {
	if i := paramIndex(sm, name); i >= 0 do sm.values[i] = value
}

/*
Sets a Bool parameter.

Example:
	// Given: brain: ^e.StateMachine, mover: ^e.CharacterMover
	e.StateMachine_SetBool(brain, "grounded", mover.onFloor)
*/
StateMachine_SetBool :: proc(sm: ^StateMachine, name: StateParamName, value: bool) {
	if i := paramIndex(sm, name); i >= 0 do sm.values[i] = value ? 1 : 0
}

/*
Sets a Trigger: the next transition reading it that's taken clears it.

Example:
	// Given: brain: ^e.StateMachine
	e.StateMachine_SetTrigger(brain, "jump")
*/
StateMachine_SetTrigger :: proc(sm: ^StateMachine, name: StateParamName) {
	if i := paramIndex(sm, name); i >= 0 do sm.values[i] = 1
}

/*
Clears a Trigger that no transition used (a jump pressed too early to count).

Example:
	// Given: brain: ^e.StateMachine
	e.StateMachine_ResetTrigger(brain, "jump")
*/
StateMachine_ResetTrigger :: proc(sm: ^StateMachine, name: StateParamName) {
	if i := paramIndex(sm, name); i >= 0 && sm.paramKinds[i] == .Trigger do sm.values[i] = 0
}

/*
A parameter's value (Bools and Triggers: 1 or 0).
*/
StateMachine_GetParam :: proc(sm: ^StateMachine, name: StateParamName) -> f32 {
	if i := paramIndex(sm, name); i >= 0 do return sm.values[i]
	return 0
}

/*
Registers a code guard under a name, for every state machine: conditions call it as `name()`.
Call it from an `@(init)` procedure in a script's file, as scripts register (it's
`proc "contextless"`). Registering a name again replaces it. A machine's own guard of the same
name (`StateMachine_SetGuard`) comes first.

Inputs:
- name: Its name in conditions (letters, digits, `_`)
- guard: The procedure

Example:
	package scripts

	import e "engine:."

	@(init)
	register_guards :: proc "contextless" () {
		// "can_attack()" in a transition's guard: not while the cooldown runs
		e.StateMachine_RegisterGuard("can_attack", proc(sm: ^e.StateMachine) -> bool {
			return e.StateMachine_TimeInState(sm) > 0.25
		})
	}
*/
StateMachine_RegisterGuard :: proc "contextless" (name: string, guard: StateMachineGuard) {
	context = Platform_DefaultContext()
	sync.mutex_lock(&guardRegistryLock)
	defer sync.mutex_unlock(&guardRegistryLock)
	if guardRegistry == nil do guardRegistry = make(map[string]StateMachineGuard)
	if _, had := guardRegistry[name]; !had do guardRegistry[strings.clone(name)] = guard
	else do guardRegistry[name] = guard
}

/*
Gives one machine a code guard that reads a script's state: `guard` is called with `self`. It
comes before a registered guard of the same name. Set it in the script's `ready`; setting a name
again replaces it.

Inputs:
- sm: The machine
- name: Its name in conditions
- guard: The procedure, called with `self`
- self: What it gets (the script)

Example:
	// Given: brain: ^e.StateMachine
	Hero :: struct {
		using script: e.Script,
		stamina: f32,
	}
	hero: ^Hero
	e.StateMachine_SetGuard(brain, "has_stamina", proc(self: ^Hero) -> bool { return self.stamina > 10 }, hero)
*/
StateMachine_SetGuard :: proc(sm: ^StateMachine, name: string, guard: proc(self: ^$T) -> bool, self: ^T) {
	// ^T and rawptr are passed the same way, so the typed procedure can be stored untyped
	call := transmute(proc(self: rawptr) -> bool)guard
	for &g in sm.guards do if g.name == name {
		g.call, g.self = call, self
		return
	}
	append(&sm.guards, OwnGuard{strings.clone(name, Node_GetAllocator(sm)), call, self})
}

/*
Whether a code guard of that name is registered (`StateMachine_RegisterGuard`) or set on the
machine (`StateMachine_SetGuard`; sm nil: registered ones only).
*/
StateMachine_HasGuard :: proc(sm: ^StateMachine, name: string) -> bool {
	if sm != nil do for g in sm.guards do if g.name == name do return true
	sync.mutex_lock(&guardRegistryLock)
	defer sync.mutex_unlock(&guardRegistryLock)
	_, ok := guardRegistry[name]
	return ok
}

/*
Listens to one state being entered: `handler` is called with the machine and the state's name
(the machine's `onStateEntered`, filtered).

Returns:
- The listener's handle, for `Event_Unsubscribe(&sm.onStateEntered, handle)`

Example:
	// Given: brain: ^e.StateMachine
	e.StateMachine_OnEnter(brain, "attack", proc(sm: ^e.StateMachine, state: string, user: rawptr) {
		e.Log_Info("swing")
	}, nil)
*/
StateMachine_OnEnter :: proc(sm: ^StateMachine, state: StateName, handler: StateMachineStateHandler, user: rawptr) -> ListenerHandle {
	return listenToState(sm, &sm.onStateEntered, state, handler, user)
}

/*
Listens to one state being left: `handler` is called with the machine and the state's name (the
machine's `onStateExited`, filtered).

Returns:
- The listener's handle, for `Event_Unsubscribe(&sm.onStateExited, handle)`

Example:
	// Given: brain: ^e.StateMachine
	e.StateMachine_OnExit(brain, "hurt", proc(sm: ^e.StateMachine, state: string, user: rawptr) {
		e.Log_Info("recovered")
	}, nil)
*/
StateMachine_OnExit :: proc(sm: ^StateMachine, state: StateName, handler: StateMachineStateHandler, user: rawptr) -> ListenerHandle {
	return listenToState(sm, &sm.onStateExited, state, handler, user)
}

/*
Why a transition is or isn't taken now, as the next update tries it (code guards are called).
Editors show it live; transitions tried before it may still be taken first.

Inputs:
- sm: The machine
- index: The transition's index in the settings

Returns:
- Its status
*/
StateMachine_TransitionStatus :: proc(sm: ^StateMachine, index: int) -> StateMachineTransitionStatus {
	for &t in sm.transitions do if t.index == index do return transitionStatus(sm, &t, -1)
	return .Not_From_Here
}

/*
Whether a condition is well formed for a set of parameters: "" when it is, else what's wrong
(editors show it).

Inputs:
- settings: The machine's settings (its parameters)
- condition: The condition
- guards: The code guards there are (with `checkGuards`)
- checkGuards: Report a `name()` not in `guards`

Returns:
- The problem, or ""
*/
StateMachine_ConditionProblem :: proc(settings: ^StateMachineSettings, condition: string, guards: []string = nil, checkGuards := false) -> string {
	names := make([]string, len(settings.params), context.temp_allocator)
	for p, i in settings.params do names[i] = p.name
	nodes, _, problem := parseCondition(condition, names, context.temp_allocator)
	if problem != "" do return problem
	for n in nodes {
		if n.kind == .Never do return fmt.tprintf("no parameter '%s'", n.guard)
		if n.kind == .Guard && checkGuards && !slice.contains(guards, n.guard) do return fmt.tprintf("no code guard '%s' (scripts register them: e.StateMachine_RegisterGuard)", n.guard)
	}
	return ""
}

/*
A condition's clauses when it's flat (clauses all joined by `and`, or all by `or`; no
parentheses), as editors show it in rows.

Inputs:
- condition: The condition ("": no clauses)
- allocator: For the clauses and their strings

Returns:
- clauses: Its clauses in order
- any: They're joined by `or` (else `and`)
- ok: It's flat (else editors show it as text only)
*/
StateMachine_SplitCondition :: proc(condition: string, allocator := context.allocator) -> (clauses: []StateMachineClause, any: bool, ok: bool) {
	tokens, problem := tokenize(condition, context.temp_allocator)
	if problem != "" do return nil, false, false
	out := make([dynamic]StateMachineClause, allocator)
	joiner := ""
	i := 0
	for i < len(tokens) {
		c := StateMachineClause{}
		for i < len(tokens) && (tokens[i] == "!" || tokens[i] == "not") {
			c.negated = !c.negated
			i += 1
		}
		if i >= len(tokens) || !isName(tokens[i]) || isKeyword(tokens[i]) do return clausesFail(out)
		c.name = tokens[i]
		i += 1
		if i + 1 < len(tokens) && tokens[i] == "(" && tokens[i + 1] == ")" {
			c.guard = true
			i += 2
		} else if i < len(tokens) && isCompare(tokens[i]) {
			if i + 1 >= len(tokens) || isOperator(tokens[i + 1]) do return clausesFail(out)
			c.op, c.value = tokens[i], tokens[i + 1]
			i += 2
		}
		c.name = strings.clone(c.name, allocator)
		c.op = strings.clone(c.op, allocator)
		c.value = strings.clone(c.value, allocator)
		append(&out, c)
		if i >= len(tokens) do break
		j := joinWord(tokens[i])
		if j == "" || (joiner != "" && j != joiner) do return clausesFail(out)
		joiner = j
		i += 1
		if i >= len(tokens) do return clausesFail(out)
	}
	return out[:], joiner == "or", true
}

/*
Writes clauses as a condition (`StateMachine_SplitCondition`'s other way): joined by `and`, or
`or` when `any`.

Returns:
- The condition (allocated)
*/
StateMachine_JoinCondition :: proc(clauses: []StateMachineClause, any: bool, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for c, i in clauses {
		if i > 0 do strings.write_string(&b, any ? " or " : " and ")
		if c.negated do strings.write_byte(&b, '!')
		strings.write_string(&b, c.name)
		if c.guard do strings.write_string(&b, "()")
		else if c.op != "" do fmt.sbprintf(&b, " %s %s", c.op, c.value == "" ? "0" : c.value)
	}
	return strings.to_string(b)
}

/*
Whether one clause holds on a running machine now (a code guard is called). Editors show each
row's result live.
*/
StateMachine_ClauseHolds :: proc(sm: ^StateMachine, clause: StateMachineClause) -> bool {
	ok: bool
	if clause.guard {
		ok = callGuard(sm, clause.name, nil)
	} else {
		i := paramIndex(sm, clause.name)
		if i < 0 do return false
		ok = compare(sm.values[i], compareOp(clause.op), parseParamValue(clause.value))
	}
	return clause.negated ? !ok : ok
}

/*
Frees a state's strings (settings' states; `StateMachineSettings_Destroy` does it for all).
*/
StateMachineState_Destroy :: proc(st: ^StateMachineState) {
	delete(st.name)
	delete(st.animation)
	delete(st.canExit)
	delete(st.enterEvent)
	delete(st.exitEvent)
	st^ = {}
}

/*
A copy of a state, its strings cloned.
*/
StateMachineState_Clone :: proc(st: StateMachineState, allocator := context.allocator) -> StateMachineState {
	out := st
	out.name = strings.clone(st.name, allocator)
	out.animation = strings.clone(st.animation, allocator)
	out.canExit = strings.clone(st.canExit, allocator)
	out.enterEvent = strings.clone(st.enterEvent, allocator)
	out.exitEvent = strings.clone(st.exitEvent, allocator)
	return out
}

/*
Frees a transition's strings (settings' transitions).
*/
StateMachineTransition_Destroy :: proc(t: ^StateMachineTransition) {
	delete(t.from)
	delete(t.to)
	delete(t.condition)
	delete(t.guard)
	t^ = {}
}

/*
A copy of a transition, its strings cloned.
*/
StateMachineTransition_Clone :: proc(t: StateMachineTransition, allocator := context.allocator) -> StateMachineTransition {
	out := t
	out.from = strings.clone(t.from, allocator)
	out.to = strings.clone(t.to, allocator)
	out.condition = strings.clone(t.condition, allocator)
	out.guard = strings.clone(t.guard, allocator)
	return out
}

/*
A deep copy of state machine settings.
*/
StateMachineSettings_Clone :: proc(s: StateMachineSettings, allocator := context.allocator) -> StateMachineSettings {
	out := StateMachineSettings{start = strings.clone(s.start, allocator), target = strings.clone(s.target, allocator)}
	out.params = make([dynamic]StateMachineParam, 0, len(s.params), allocator)
	for p in s.params do append(&out.params, StateMachineParam{strings.clone(p.name, allocator), p.kind, strings.clone(p.value, allocator)})
	out.states = make([dynamic]StateMachineState, 0, len(s.states), allocator)
	for st in s.states do append(&out.states, StateMachineState_Clone(st, allocator))
	out.transitions = make([dynamic]StateMachineTransition, 0, len(s.transitions), allocator)
	for t in s.transitions do append(&out.transitions, StateMachineTransition_Clone(t, allocator))
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
	for &st in s.states do StateMachineState_Destroy(&st)
	for &t in s.transitions do StateMachineTransition_Destroy(&t)
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

// The code guards scripts registered (StateMachine_RegisterGuard; heap, for the program's run)
@(private="file")
guardRegistry: map[string]StateMachineGuard
@(private="file")
guardRegistryLock: sync.Mutex

@(private="file")
StateListener :: struct {
	sm: ^StateMachine,
	state: string,
	handler: StateMachineStateHandler,
	user: rawptr,
}

@(private="file")
listenToState :: proc(sm: ^StateMachine, subject: ^EventSubject, state: string, handler: StateMachineStateHandler, user: rawptr) -> ListenerHandle {
	allocator := Node_GetAllocator(sm)
	l := new(StateListener, allocator)
	l^ = {sm, strings.clone(state, allocator), handler, user}
	return Event_Subscribe(subject, proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
		l := cast(^StateListener)user
		if name, ok := data.(string); ok && name == l.state do l.handler(l.sm, name, l.user)
	}, l)
}

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

@(private="file")
isNameByte :: proc(c: u8) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' }

@(private="file")
isName :: proc(t: string) -> bool { return len(t) > 0 && isNameByte(t[0]) }

@(private="file")
isKeyword :: proc(t: string) -> bool { return t == "and" || t == "or" || t == "not" }

@(private="file")
isCompare :: proc(t: string) -> bool { return t == "==" || t == "!=" || t == "<" || t == "<=" || t == ">" || t == ">=" }

@(private="file")
isOperator :: proc(t: string) -> bool { return !isName(t) || isKeyword(t) }

// "and" / "&&" -> "and", "or" / "||" -> "or", else ""
@(private="file")
joinWord :: proc(t: string) -> string {
	switch t {
	case "and", "&&": return "and"
	case "or", "||": return "or"
	}
	return ""
}

@(private="file")
clausesFail :: proc(out: [dynamic]StateMachineClause) -> ([]StateMachineClause, bool, bool) {
	for c in out {
		delete(c.name, out.allocator)
		delete(c.op, out.allocator)
		delete(c.value, out.allocator)
	}
	delete(out)
	return nil, false, false
}

// A condition's tokens: names and numbers, comparisons, !, (, ), &&, ||
@(private="file")
tokenize :: proc(text: string, allocator := context.temp_allocator) -> (tokens: []string, problem: string) {
	out := make([dynamic]string, allocator)
	i := 0
	for i < len(text) {
		c := text[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			i += 1
		case isNameByte(c):
			j := i
			for j < len(text) && isNameByte(text[j]) do j += 1
			append(&out, text[i:j])
			i = j
		case c == '(' || c == ')':
			append(&out, text[i:i + 1])
			i += 1
		case i + 1 < len(text) && (text[i:i + 2] == ">=" || text[i:i + 2] == "<=" || text[i:i + 2] == "==" || text[i:i + 2] == "!=" || text[i:i + 2] == "&&" || text[i:i + 2] == "||"):
			append(&out, text[i:i + 2])
			i += 2
		case c == '<' || c == '>' || c == '!':
			append(&out, text[i:i + 1])
			i += 1
		case:
			return nil, fmt.tprintf("'%c' isn't part of a condition", rune(c))
		}
	}
	return out[:], ""
}

// The parser's state: the tokens, where it is, the tree it builds
@(private="file")
Parser :: struct {
	tokens: []string,
	at: int,
	nodes: [dynamic]CondNode,
	params: []string,
	problem: string,
}

/*
Parses a condition into a flat tree. Unknown parameters become `.Never` nodes holding the name in
`guard` (so callers can report them); a syntax problem is returned.
*/
@(private="file")
parseCondition :: proc(text: string, params: []string, allocator := context.allocator) -> (nodes: [dynamic]CondNode, root: int, problem: string) {
	tokens, tokenProblem := tokenize(text, context.temp_allocator)
	nodes = make([dynamic]CondNode, allocator)
	if tokenProblem != "" do return nodes, -1, tokenProblem
	if len(tokens) == 0 do return nodes, -1, ""
	p := Parser{tokens = tokens, nodes = nodes, params = params}
	root = parseOr(&p)
	if p.problem == "" && p.at < len(p.tokens) do p.problem = fmt.tprintf("'%s' isn't expected here", p.tokens[p.at])
	return p.nodes, root, p.problem
}

@(private="file")
peek :: proc(p: ^Parser) -> string { return p.at < len(p.tokens) ? p.tokens[p.at] : "" }

@(private="file")
addNode :: proc(p: ^Parser, n: CondNode) -> int {
	append(&p.nodes, n)
	return len(p.nodes) - 1
}

@(private="file")
parseOr :: proc(p: ^Parser) -> int {
	left := parseAnd(p)
	for p.problem == "" && joinWord(peek(p)) == "or" {
		p.at += 1
		right := parseAnd(p)
		left = addNode(p, {kind = .Or, a = left, b = right})
	}
	return left
}

@(private="file")
parseAnd :: proc(p: ^Parser) -> int {
	left := parseUnary(p)
	for p.problem == "" && joinWord(peek(p)) == "and" {
		p.at += 1
		right := parseUnary(p)
		left = addNode(p, {kind = .And, a = left, b = right})
	}
	return left
}

@(private="file")
parseUnary :: proc(p: ^Parser) -> int {
	if p.problem != "" do return -1
	t := peek(p)
	switch {
	case t == "":
		p.problem = len(p.tokens) == 0 ? "" : "a condition can't end there"
		return -1
	case t == "!" || t == "not":
		p.at += 1
		inner := parseUnary(p)
		return addNode(p, {kind = .Not, a = inner})
	case t == "(":
		p.at += 1
		inner := parseOr(p)
		if p.problem == "" && peek(p) != ")" do p.problem = "a '(' isn't closed"
		p.at += 1
		return inner
	case !isName(t) || isKeyword(t):
		p.problem = fmt.tprintf("'%s' isn't expected here", t)
		return -1
	}
	p.at += 1
	if peek(p) == "(" {
		p.at += 1
		if peek(p) != ")" {
			p.problem = fmt.tprintf("a code guard takes nothing: %s()", t)
			return -1
		}
		p.at += 1
		return addNode(p, {kind = .Guard, guard = t})
	}
	n := CondNode{kind = .Param, param = -1}
	for name, i in p.params do if name == t do n.param = i
	if isCompare(peek(p)) {
		opText := p.tokens[p.at]
		n.op = compareOp(opText)
		p.at += 1
		value := peek(p)
		if value == "" || isOperator(value) {
			p.problem = fmt.tprintf("'%s %s' compares with nothing", t, opText)
			return -1
		}
		if _, isNumber := strconv.parse_f32(value); !isNumber && value != "true" && value != "false" {
			p.problem = fmt.tprintf("'%s' isn't a number", value)
			return -1
		}
		n.value = parseParamValue(value)
		p.at += 1
	}
	if n.param < 0 {
		// Never holds; the name kept for problems
		n.kind = .Never
		n.guard = t
	}
	return addNode(p, n)
}

// A condition compiled for a machine (node arena); problems are logged and it never holds
@(private="file")
compileCondition :: proc(sm: ^StateMachine, text: string, allocator := context.allocator) -> Condition {
	nodes, root, problem := parseCondition(text, sm.paramNames, allocator)
	if problem != "" {
		log.warnf("StateMachine: the condition '%s' can't be read (%s): it never holds", text, problem)
		clear(&nodes)
		append(&nodes, CondNode{kind = .Never})
		return {nodes[:], 0}
	}
	for &n in nodes {
		if n.kind == .Never do log.warnf("StateMachine: a condition names '%s', which isn't one of its parameters", n.guard)
		if n.kind == .Guard do n.guard = strings.clone(n.guard, allocator)
	}
	return {nodes[:], root}
}

@(private="file")
compareOp :: proc(text: string) -> CompareOp {
	switch text {
	case "==": return .Eq
	case "!=": return .Ne
	case "<":  return .Lt
	case "<=": return .Le
	case ">":  return .Gt
	case ">=": return .Ge
	}
	return .Truthy
}

@(private="file")
compare :: proc(v: f32, op: CompareOp, value: f32) -> bool {
	switch op {
	case .Truthy: return v != 0
	case .Eq: return v == value
	case .Ne: return v != value
	case .Lt: return v < value
	case .Le: return v <= value
	case .Gt: return v > value
	case .Ge: return v >= value
	}
	return false
}

// Calls a code guard: the machine's own, else a registered one (missing: false, logged once
// through `warned` when it's given)
@(private="file")
callGuard :: proc(sm: ^StateMachine, name: string, warned: ^bool) -> bool {
	for g in sm.guards do if g.name == name do return g.call(g.self)
	guard: StateMachineGuard
	{
		sync.mutex_lock(&guardRegistryLock)
		defer sync.mutex_unlock(&guardRegistryLock)
		guard = guardRegistry[name]
	}
	if guard != nil do return guard(sm)
	if warned != nil && !warned^ {
		warned^ = true
		log.warnf("StateMachine: no code guard '%s' (scripts register them with e.StateMachine_RegisterGuard): it never holds", name)
	}
	return false
}

@(private="file")
evaluate :: proc(sm: ^StateMachine, c: Condition) -> bool {
	if c.root < 0 do return true
	return evalNode(sm, c.nodes, c.root)
}

@(private="file")
evalNode :: proc(sm: ^StateMachine, nodes: []CondNode, i: int) -> bool {
	if i < 0 || i >= len(nodes) do return false
	n := &nodes[i]
	switch n.kind {
	case .Never: return false
	case .Param: return compare(sm.values[n.param], n.op, n.value)
	case .Guard: return callGuard(sm, n.guard, &n.warned)
	case .Not:   return !evalNode(sm, nodes, n.a)
	case .And:   return evalNode(sm, nodes, n.a) && evalNode(sm, nodes, n.b)
	case .Or:    return evalNode(sm, nodes, n.a) || evalNode(sm, nodes, n.b)
	}
	return false
}

// A transition's status for the current state; `canExit` -1: not worked out yet (else 0 / 1)
@(private="file")
transitionStatus :: proc(sm: ^StateMachine, t: ^RuntimeTransition, canExit: int) -> StateMachineTransitionStatus {
	if sm.current < 0 || t.to < 0 || (t.from >= 0 && t.from != sm.current) || (t.from < 0 && t.to == sm.current) do return .Not_From_Here
	if t.after > 0 && sm.timeInState < t.after do return .Waiting
	if t.onFinished && !sm.animationFinished do return .Waiting
	if !evaluate(sm, t.condition) do return .Condition_False
	if !evaluate(sm, t.guard) do return .Guard_Failed
	if !t.interrupts {
		exits := canExit >= 0 ? canExit == 1 : StateMachine_CanExit(sm)
		if !exits do return .Exit_Blocked
	}
	return .Ready
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

// Leaves the current state for another (`via`: the transition's index in the settings, -1 none)
@(private="file")
enterState :: proc(sm: ^StateMachine, index: int, via: int) {
	from := sm.current
	if from >= 0 {
		if sm.states[from].exitEvent != "" do Event_Notify(&sm.onStateEvent, sm, sm.states[from].exitEvent)
		Event_Notify(&sm.onStateExited, sm, sm.states[from].name)
	}
	sm.previous = from
	sm.current = index
	sm.timeInState = 0
	sm.animationFinished = false
	st := sm.states[index]
	if st.animation != "" {
		if target := findTarget(sm); target != nil {
			player := &target.animation
			AnimationPlayer_Play(player, st.animation, restart = true)
			player.loopRule = st.loop
			speed := st.speed > 0 ? st.speed : 1
			if speed != 1 || sm.speedSet {
				player.speed = speed
				sm.speedSet = speed != 1
			}
		}
	}
	if from >= 0 {
		info := StateMachineTransitionInfo{sm.states[from].name, st.name, via}
		Event_Notify(&sm.onTransition, sm, rawptr(&info))
	}
	if st.enterEvent != "" do Event_Notify(&sm.onStateEvent, sm, st.enterEvent)
	Event_Notify(&sm.onStateEntered, sm, st.name)
}

/*
The live link's view of a machine (live.odin's `machine` reply, after `"type":"machine","id":..,`):
its state, time, whether it can exit (and each of the exit guard's clauses), its parameters, each
transition's status and its condition's and guard's clauses (flat ones; `[]` otherwise).
*/
@(private)
StateMachine_LiveJSON :: proc(sm: ^StateMachine, b: ^strings.Builder) {
	clauses :: proc(sm: ^StateMachine, b: ^strings.Builder, text: string) {
		strings.write_byte(b, '[')
		list, _, ok := StateMachine_SplitCondition(text, context.temp_allocator)
		if ok do for c, i in list {
			if i > 0 do strings.write_byte(b, ',')
			fmt.sbprint(b, StateMachine_ClauseHolds(sm, c))
		}
		strings.write_byte(b, ']')
	}
	fmt.sbprintf(b, `"state":%q,"previous":%q,"time":%.2f,"canExit":%v,"exit":`, StateMachine_Current(sm), StateMachine_Previous(sm), sm.timeInState, StateMachine_CanExit(sm))
	clauses(sm, b, sm.current >= 0 ? sm.states[sm.current].canExit : "")
	strings.write_string(b, `,"params":[`)
	for name, i in sm.paramNames {
		if i > 0 do strings.write_byte(b, ',')
		value := sm.paramKinds[i] == .Float ? fmt.tprintf("%g", sm.values[i]) : (sm.values[i] != 0 ? "true" : "false")
		fmt.sbprintf(b, `{{"name":%q,"value":%q}}`, name, value)
	}
	strings.write_string(b, `],"transitions":[`)
	for i in 0 ..< len(sm.transitions) {
		if i > 0 do strings.write_byte(b, ',')
		for &t in sm.transitions do if t.index == i {
			fmt.sbprintf(b, `{{"status":%q,"when":`, fmt.tprint(transitionStatus(sm, &t, -1)))
			clauses(sm, b, t.conditionText)
			strings.write_string(b, `,"guard":`)
			clauses(sm, b, t.guardText)
			strings.write_byte(b, '}')
		}
	}
	strings.write_byte(b, ']')
}

@(private="file")
stateMachineUpdate :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	sm := cast(^StateMachine)node
	if len(sm.states) == 0 do return
	if sm.current < 0 {
		enterState(sm, sm.startIndex, -1)
		return
	}
	sm.timeInState += f32(deltaTime)
	// The exit guard is asked once per update, and only when a transition needs it
	canExit := -1
	for &t in sm.transitions {
		status := transitionStatus(sm, &t, canExit)
		if status == .Exit_Blocked do canExit = 0
		if status != .Ready do continue
		// The triggers it read are spent
		for p in t.triggers do sm.values[p] = 0
		enterState(sm, t.to, t.index)
		return
	}
}
