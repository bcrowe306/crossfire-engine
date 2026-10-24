#+build !js
package crossfire

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

// State machines (state_machine.odin): parameters moving it between states, triggers spent once,
// any-state transitions, waiting for an animation's end or some time, travel, events, the state
// as a property

@(private="file")
SM_SCENE :: `<scene formatVersion="13" name="S">
	<node kind="AnimatedSprite" name="Hero">
		<node kind="StateMachine" name="Brain" start="idle">
			<param name="speed" type="Float"/>
			<param name="grounded" type="Bool" value="true"/>
			<param name="attack" type="Trigger"/>
			<state name="idle" animation="idle" x="10" y="20"/>
			<state name="run" animation="run"/>
			<state name="attack" animation="attack"/>
			<state name="fall"/>
			<transition from="idle" to="run" when="speed > 10 and grounded"/>
			<transition from="run" to="idle" when="speed &lt;= 10"/>
			<transition from="*" to="attack" when="attack"/>
			<transition from="attack" to="idle" onFinished="true"/>
			<transition from="idle" to="fall" when="!grounded" after="0.5"/>
		</node>
	</node>
</scene>`

@(private="file")
SMLog :: struct {
	entered, exited: [dynamic]string,
}

@(test)
state_machines_follow_their_parameters :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	data, err := ParseScene(SM_SCENE)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	settings := data.nodes[1].stateMachine
	testing.expect(t, len(settings.params) == 3 && len(settings.states) == 4 && len(settings.transitions) == 5, "parsed")
	testing.expect_value(t, settings.states[0].position, [2]f32{10, 20})
	testing.expect_value(t, settings.transitions[1].condition, "speed <= 10")
	testing.expect_value(t, StateMachine_ConditionProblem(&settings, "speed > 10 and grounded"), "")
	testing.expect(t, StateMachine_ConditionProblem(&settings, "nothing") != "", "an unknown parameter")
	testing.expect(t, StateMachine_ConditionProblem(&settings, "speed > fast") != "", "not a number")
	clone := StateMachineSettings_Clone(settings)
	testing.expect(t, StateMachineSettings_Equal(clone, settings), "a clone")
	StateMachineSettings_Destroy(&clone)

	created := Scene_Build(scene, &data, "testdata", attachScripts = false)
	hero := cast(^AnimatedSprite)created[0]
	brain := cast(^StateMachine)created[1]
	// Its animations (made here: the test game has no renderer for a sheet's texture)
	AnimationPlayer_Clear(&hero.animation)
	allocator := Node_GetAllocator(hero)
	AnimationPlayer_Add(&hero.animation, CreateSpriteSheetAnimation("idle", nil, 1, 1, 10, true, allocator = allocator))
	AnimationPlayer_Add(&hero.animation, CreateSpriteSheetAnimation("run", nil, 1, 1, 10, true, allocator = allocator))
	AnimationPlayer_Add(&hero.animation, CreateSpriteSheetAnimation("attack", nil, 2, 1, 10, false, allocator = allocator))
	log := SMLog{make([dynamic]string, context.temp_allocator), make([dynamic]string, context.temp_allocator)}
	Event_Subscribe(&brain.onStateEntered, proc(_: ^EventSubject, _: rawptr, d: EventData, user: rawptr) { append(&(cast(^SMLog)user).entered, d.(string)) }, &log)
	Event_Subscribe(&brain.onStateExited, proc(_: ^EventSubject, _: rawptr, d: EventData, user: rawptr) { append(&(cast(^SMLog)user).exited, d.(string)) }, &log)
	step :: proc(scene: ^Scene, dt: f64 = 1.0 / 60) { Scene_Update(scene, nil, dt) }

	// The start state, its animation
	step(scene, 0)
	testing.expect_value(t, StateMachine_Current(brain), "idle")
	testing.expect_value(t, AnimationPlayer_CurrentName(&hero.animation), "idle")
	// Speed: run, and back
	StateMachine_SetFloat(brain, "speed", 50)
	step(scene)
	testing.expect(t, StateMachine_Is(brain, "run"), "running")
	testing.expect_value(t, AnimationPlayer_CurrentName(&hero.animation), "run")
	StateMachine_SetFloat(brain, "speed", 0)
	step(scene)
	testing.expect_value(t, StateMachine_Current(brain), "idle")
	// A trigger: attack from any state, spent; back to idle when the attack's animation ends
	StateMachine_SetTrigger(brain, "attack")
	step(scene)
	testing.expect_value(t, StateMachine_Current(brain), "attack")
	testing.expect_value(t, StateMachine_GetParam(brain, "attack"), f32(0))
	step(scene, 0.1)
	testing.expect_value(t, StateMachine_Current(brain), "attack")
	for _ in 0..<10 do step(scene, 0.1)
	testing.expect_value(t, StateMachine_Current(brain), "idle")
	// After: not off the ground for long enough yet, then falling
	StateMachine_Travel(brain, "idle")
	StateMachine_SetBool(brain, "grounded", false)
	step(scene, 0.1)
	testing.expect_value(t, StateMachine_Current(brain), "idle")
	for _ in 0..<6 do step(scene, 0.1)
	testing.expect_value(t, StateMachine_Current(brain), "fall")
	// Travel; the state as a property (the Animator's and the live view's)
	testing.expect(t, StateMachine_Travel(brain, "run"), "travel")
	text, _ := Animator_ReadProperty(brain, "state", context.temp_allocator)
	testing.expect_value(t, text, "run")
	testing.expect(t, Node_WriteProperty(brain, "state", "idle"), "written")
	testing.expect_value(t, StateMachine_Current(brain), "idle")
	testing.expect(t, !StateMachine_Travel(brain, "nowhere"), "no such state")
	testing.expect(t, len(log.entered) >= 7 && log.entered[0] == "idle" && log.exited[0] == "idle", "events")
	free_all(context.temp_allocator)
}

// Transition logic and guards: priorities, compound conditions, exit guards and interrupts, code
// guards (registered and a machine's own), events, speed and loop, statuses, flat conditions
@(private="file")
SM_GUARD_SCENE :: `<scene formatVersion="14" name="G">
	<node kind="AnimatedSprite" name="Hero">
		<node kind="StateMachine" name="Brain" start="idle">
			<param name="speed" type="Float"/>
			<param name="grounded" type="Bool" value="true"/>
			<param name="attack" type="Trigger"/>
			<param name="hurt" type="Trigger"/>
			<state name="idle" animation="idle"/>
			<state name="run" animation="run" speed="2"/>
			<state name="walk" animation="run"/>
			<state name="attack" animation="attack" loop="Loop" canExit="!busy()" onEnter="swing" onExit="sheathe"/>
			<state name="hurt" animation="idle"/>
			<state name="air"/>
			<transition from="idle" to="walk" when="speed > 0"/>
			<transition from="idle" to="run" when="speed > 50" priority="5"/>
			<transition from="walk" to="idle" when="speed == 0 or (not grounded and speed &lt; 1)"/>
			<transition from="run" to="idle" when="speed &lt;= 50"/>
			<transition from="*" to="attack" when="attack" guard="sm_test_can_attack() and grounded"/>
			<transition from="attack" to="idle" after="0.1"/>
			<transition from="*" to="hurt" when="hurt" interrupts="true" priority="10"/>
			<transition from="hurt" to="idle" after="0.1"/>
			<transition from="idle" to="air" when="!grounded and nowhere_guard()"/>
		</node>
	</node>
</scene>`

@(private="file")
SMEvents :: struct {
	transitions: [dynamic]string,
	stateEvents: [dynamic]string,
	entered, left: int,
	busy: bool,
	allowed: bool,
}

@(test)
state_machines_have_guards_and_priorities :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("G")
	data, err := ParseScene(SM_GUARD_SCENE)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	settings := data.nodes[1].stateMachine
	// Parsed: the new attributes, the old ones' defaults
	testing.expect_value(t, settings.states[0].speed, f32(1))
	testing.expect_value(t, settings.states[1].speed, f32(2))
	testing.expect_value(t, settings.states[3].loop, AnimationLoopRule.Loop)
	testing.expect_value(t, settings.states[3].canExit, "!busy()")
	testing.expect(t, settings.states[3].enterEvent == "swing" && settings.states[3].exitEvent == "sheathe", "state events")
	testing.expect(t, settings.transitions[1].priority == 5 && settings.transitions[6].interrupts, "priority, interrupts")
	testing.expect_value(t, settings.transitions[4].guard, "sm_test_can_attack() and grounded")
	clone := StateMachineSettings_Clone(settings)
	testing.expect(t, StateMachineSettings_Equal(clone, settings), "a clone")
	clone.transitions[1].priority = 4
	testing.expect(t, !StateMachineSettings_Equal(clone, settings), "a priority differs")
	StateMachineSettings_Destroy(&clone)

	// Problems: syntax, parameters, guards (only when asked)
	testing.expect_value(t, StateMachine_ConditionProblem(&settings, "speed == 0 or (not grounded and speed < 1)"), "")
	testing.expect(t, StateMachine_ConditionProblem(&settings, "(speed > 1") != "", "unclosed")
	testing.expect(t, StateMachine_ConditionProblem(&settings, "speed > 1 and") != "", "a dangling and")
	testing.expect(t, StateMachine_ConditionProblem(&settings, "speed # 1") != "", "a stray character")
	testing.expect_value(t, StateMachine_ConditionProblem(&settings, "a_guard()"), "")
	testing.expect(t, StateMachine_ConditionProblem(&settings, "a_guard()", {"other"}, checkGuards = true) != "", "an unknown guard")
	testing.expect_value(t, StateMachine_ConditionProblem(&settings, "!a_guard()", {"a_guard"}, checkGuards = true), "")

	// Flat conditions, both ways
	clauses, any, flat := StateMachine_SplitCondition("speed > 10 and !grounded and can_go()", context.temp_allocator)
	testing.expect(t, flat && !any && len(clauses) == 3, "split")
	if len(clauses) == 3 {
		testing.expect(t, clauses[0].name == "speed" && clauses[0].op == ">" && clauses[0].value == "10", "a comparison")
		testing.expect(t, clauses[1].negated && clauses[1].op == "" && clauses[1].name == "grounded", "a negated bool")
		testing.expect(t, clauses[2].guard && clauses[2].name == "can_go", "a code guard")
		testing.expect_value(t, StateMachine_JoinCondition(clauses, false, context.temp_allocator), "speed > 10 and !grounded and can_go()")
		testing.expect_value(t, StateMachine_JoinCondition(clauses, true, context.temp_allocator), "speed > 10 or !grounded or can_go()")
	}
	_, any, flat = StateMachine_SplitCondition("a || b", context.temp_allocator)
	testing.expect(t, flat && any, "any of")
	_, _, flat = StateMachine_SplitCondition("a and b or c", context.temp_allocator)
	testing.expect(t, !flat, "mixed: not flat")
	_, _, flat = StateMachine_SplitCondition("(a)", context.temp_allocator)
	testing.expect(t, !flat, "parentheses: not flat")
	none: []StateMachineClause
	none, _, flat = StateMachine_SplitCondition("", context.temp_allocator)
	testing.expect(t, flat && len(none) == 0, "empty")

	// A registered code guard (scripts do it in @(init)) and the machine's own
	StateMachine_RegisterGuard("sm_test_can_attack", proc(sm: ^StateMachine) -> bool { return StateMachine_GetParam(sm, "speed") < 100 })
	testing.expect(t, StateMachine_HasGuard(nil, "sm_test_can_attack"), "registered")
	created := Scene_Build(scene, &data, "testdata", attachScripts = false)
	hero := cast(^AnimatedSprite)created[0]
	brain := cast(^StateMachine)created[1]
	AnimationPlayer_Clear(&hero.animation)
	allocator := Node_GetAllocator(hero)
	AnimationPlayer_Add(&hero.animation, CreateSpriteSheetAnimation("idle", nil, 1, 1, 10, true, allocator = allocator))
	AnimationPlayer_Add(&hero.animation, CreateSpriteSheetAnimation("run", nil, 1, 1, 10, true, allocator = allocator))
	AnimationPlayer_Add(&hero.animation, CreateSpriteSheetAnimation("attack", nil, 2, 1, 10, false, allocator = allocator))
	log := SMEvents{transitions = make([dynamic]string, context.temp_allocator), stateEvents = make([dynamic]string, context.temp_allocator), allowed = true}
	StateMachine_SetGuard(brain, "busy", proc(self: ^SMEvents) -> bool { return self.busy }, &log)
	testing.expect(t, StateMachine_HasGuard(brain, "busy") && !StateMachine_HasGuard(nil, "busy"), "its own guard")
	Event_Subscribe(&brain.onTransition, proc(_: ^EventSubject, _: rawptr, d: EventData, user: rawptr) {
		info := (^StateMachineTransitionInfo)(d.(rawptr))
		append(&(cast(^SMEvents)user).transitions, fmt.aprintf("%s>%s#%d", info.from, info.to, info.index, allocator = context.temp_allocator))
	}, &log)
	Event_Subscribe(&brain.onStateEvent, proc(_: ^EventSubject, _: rawptr, d: EventData, user: rawptr) {
		append(&(cast(^SMEvents)user).stateEvents, d.(string))
	}, &log)
	StateMachine_OnEnter(brain, "attack", proc(sm: ^StateMachine, state: string, user: rawptr) { (cast(^SMEvents)user).entered += 1 }, &log)
	StateMachine_OnExit(brain, "attack", proc(sm: ^StateMachine, state: string, user: rawptr) { (cast(^SMEvents)user).left += 1 }, &log)
	step :: proc(scene: ^Scene, dt: f64 = 1.0 / 60) { Scene_Update(scene, nil, dt) }

	step(scene, 0)
	testing.expect_value(t, StateMachine_Current(brain), "idle")
	testing.expect_value(t, StateMachine_Previous(brain), "")
	// Priority: both idle's transitions hold; run's priority wins over walk's order
	StateMachine_SetFloat(brain, "speed", 80)
	step(scene)
	testing.expect_value(t, StateMachine_Current(brain), "run")
	testing.expect_value(t, StateMachine_Previous(brain), "idle")
	testing.expect_value(t, hero.animation.speed, f32(2))
	// Back to 1 when a state of speed 1 plays
	StateMachine_SetFloat(brain, "speed", 10)
	step(scene)
	testing.expect_value(t, StateMachine_Current(brain), "idle")
	testing.expect_value(t, hero.animation.speed, f32(1))
	step(scene)
	testing.expect_value(t, StateMachine_Current(brain), "walk")
	// Compound: "speed == 0 or (not grounded and speed < 1)"
	StateMachine_SetFloat(brain, "speed", 0.5)
	step(scene)
	testing.expect_value(t, StateMachine_Current(brain), "walk")
	StateMachine_SetBool(brain, "grounded", false)
	step(scene)
	testing.expect_value(t, StateMachine_Current(brain), "idle")
	// A missing code guard never holds (logged once): idle doesn't go to air
	StateMachine_SetFloat(brain, "speed", 0)
	step(scene)
	testing.expect_value(t, StateMachine_Current(brain), "idle")
	testing.expect_value(t, StateMachine_TransitionStatus(brain, 8), StateMachineTransitionStatus.Condition_False)

	// The transition guard: "attack" holds, the guard (grounded) doesn't; the trigger waits
	StateMachine_SetTrigger(brain, "attack")
	testing.expect_value(t, StateMachine_TransitionStatus(brain, 4), StateMachineTransitionStatus.Guard_Failed)
	step(scene)
	testing.expect_value(t, StateMachine_Current(brain), "idle")
	testing.expect_value(t, StateMachine_GetParam(brain, "attack"), f32(1))
	StateMachine_SetBool(brain, "grounded", true)
	StateMachine_SetFloat(brain, "speed", 0)
	testing.expect_value(t, StateMachine_TransitionStatus(brain, 4), StateMachineTransitionStatus.Ready)
	step(scene)
	testing.expect_value(t, StateMachine_Current(brain), "attack")
	testing.expect_value(t, StateMachine_GetParam(brain, "attack"), f32(0))
	testing.expect_value(t, hero.animation.loopRule, AnimationLoopRule.Loop)
	testing.expect(t, log.entered == 1 && len(log.stateEvents) == 1 && log.stateEvents[0] == "swing", "entered: its event")

	// The exit guard holds it while busy: its own transition waits
	log.busy = true
	step(scene, 0.2)
	testing.expect_value(t, StateMachine_Current(brain), "attack")
	testing.expect(t, !StateMachine_CanExit(brain), "can't exit")
	testing.expect_value(t, StateMachine_TransitionStatus(brain, 5), StateMachineTransitionStatus.Exit_Blocked)
	testing.expect(t, !StateMachine_TryTravel(brain, "idle"), "try travel refused")
	// An interrupting transition doesn't wait
	StateMachine_SetTrigger(brain, "hurt")
	step(scene)
	testing.expect_value(t, StateMachine_Current(brain), "hurt")
	testing.expect(t, log.left == 1 && log.stateEvents[len(log.stateEvents) - 1] == "sheathe", "left: its event")
	testing.expect_value(t, hero.animation.loopRule, AnimationLoopRule.As_Made)
	// Exit time: hurt waits 0.1 s
	step(scene, 0.05)
	testing.expect_value(t, StateMachine_TransitionStatus(brain, 7), StateMachineTransitionStatus.Waiting)
	step(scene, 0.1)
	testing.expect_value(t, StateMachine_Current(brain), "idle")
	// Travel ignores guards; TryTravel goes when it can
	StateMachine_Travel(brain, "attack")
	testing.expect_value(t, StateMachine_Current(brain), "attack")
	log.busy = false
	testing.expect(t, StateMachine_TryTravel(brain, "idle"), "try travel")
	testing.expect_value(t, StateMachine_TransitionStatus(brain, 0), StateMachineTransitionStatus.Condition_False)
	testing.expect_value(t, StateMachine_TransitionStatus(brain, 3), StateMachineTransitionStatus.Not_From_Here)
	testing.expect(t, len(log.transitions) >= 6 && log.transitions[0] == "idle>run#1", "transition events")
	testing.expect_value(t, log.transitions[len(log.transitions) - 1], "attack>idle#-1")
	StateMachine_SetTrigger(brain, "attack")
	StateMachine_ResetTrigger(brain, "attack")
	testing.expect_value(t, StateMachine_GetParam(brain, "attack"), f32(0))

	// What the live link sends
	b := strings.builder_make(context.temp_allocator)
	StateMachine_LiveJSON(brain, &b)
	value, jerr := json.parse_string(fmt.tprintf("{{%s}}", strings.to_string(b)), allocator = context.temp_allocator)
	testing.expect(t, jerr == nil, "JSON")
	if object, ok := value.(json.Object); ok {
		testing.expect_value(t, object["state"].(json.String), "idle")
		testing.expect_value(t, object["canExit"].(json.Boolean), true)
		transitions := object["transitions"].(json.Array)
		testing.expect_value(t, len(transitions), 9)
		first := transitions[4].(json.Object)
		testing.expect_value(t, first["status"].(json.String), "Condition_False")
		testing.expect_value(t, len(first["guard"].(json.Array)), 2)
		testing.expect_value(t, first["guard"].(json.Array)[0].(json.Boolean), true)
		testing.expect_value(t, len(object["params"].(json.Array)), 4)
	}
	free_all(context.temp_allocator)
}

// A player's loop rule (a state's `loop`): Once ends a looping animation, Loop repeats a one-shot,
// and Play puts it back to As_Made
@(test)
animation_loop_rules_override_the_animation :: proc(t: ^testing.T) {
	player: AnimationPlayer
	AnimationPlayer_Init(&player, context.allocator)
	defer AnimationPlayer_Destroy(&player)
	AnimationPlayer_Add(&player, CreateSpriteSheetAnimation("spin", nil, 2, 1, 10, true))
	AnimationPlayer_Add(&player, CreateSpriteSheetAnimation("hit", nil, 2, 1, 10, false))
	AnimationPlayer_Play(&player, "spin")
	player.loopRule = .Once
	for _ in 0 ..< 5 do AnimationPlayer_Update(&player, 0.1)
	testing.expect(t, player.finished, "a looping animation played once")
	AnimationPlayer_Play(&player, "hit")
	testing.expect_value(t, player.loopRule, AnimationLoopRule.As_Made)
	player.loopRule = .Loop
	for _ in 0 ..< 5 do AnimationPlayer_Update(&player, 0.1)
	testing.expect(t, !player.finished && player.playing, "a one-shot looped")
}
