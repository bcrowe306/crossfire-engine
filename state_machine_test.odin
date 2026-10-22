#+build !js
package crossfire

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
