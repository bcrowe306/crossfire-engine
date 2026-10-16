package engine

import "core:testing"
import sdl "vendor:sdl3"

// Tests for the project file parser. Run with: odin test .

@(test)
parse_scene_nesting_defaults_and_items :: proc(t: ^testing.T) {
	text := `<?xml version="1.0" encoding="UTF-8"?>
<scene formatVersion="1" name="Test">
	<node kind="Node2D" name="Root">
		<node kind="Sprite" name="Ship" x="10" y="20" texture="assets/ship.png" layer="9"/>
		<node kind="AnimatedSprite" name="Anim" columns="4" playMode="PingPong" loop="false"/>
	</node>
	<node kind="Menu" name="Menu" visible="false">
		<item label="Play &amp; Win" action="scene:Play"/>
		<item label="Quit" action="quit"/>
	</node>
	<node kind="Unknown" name="Fallback"/>
</scene>`
	scene, err := ParseScene(text)
	defer SceneData_Destroy(&scene)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, scene.name, "Test")
	if !testing.expect_value(t, len(scene.nodes), 5) do return

	root, ship, anim, menu, fallback := scene.nodes[0], scene.nodes[1], scene.nodes[2], scene.nodes[3], scene.nodes[4]
	testing.expect_value(t, root.parent, -1)
	testing.expect_value(t, ship.parent, 0)
	testing.expect_value(t, anim.parent, 0)
	testing.expect_value(t, menu.parent, -1)

	testing.expect_value(t, ship.position, [2]f32{10, 20})
	testing.expect_value(t, ship.texture, "assets/ship.png")
	testing.expect_value(t, ship.layer, len(RenderLayer) - 1) // Clamped
	testing.expect_value(t, ship.scale, [2]f32{1, 1})         // Default

	testing.expect_value(t, anim.columns, 4)
	testing.expect_value(t, anim.rows, 1)
	testing.expect_value(t, anim.playMode, AnimationPlayMode.PingPong)
	testing.expect_value(t, anim.loop, false)

	testing.expect_value(t, menu.visible, false)
	if testing.expect_value(t, len(menu.items), 2) {
		testing.expect_value(t, menu.items[0].label, "Play & Win")
		testing.expect_value(t, menu.items[0].action, "scene:Play")
	}

	// Unknown kinds fall back to Node2D rather than failing the whole scene
	testing.expect_value(t, fallback.kind, SceneNodeKind.Node2D)
}

@(test)
parse_project :: proc(t: ^testing.T) {
	text := `<project formatVersion="1" name="Game" width="640" height="360" scaleMode="IntegerScale" background="#102030">
	<scene name="A" path="scenes/A.scene.xml"/>
	<scene name="B" path="scenes/B.scene.xml"/>
	<asset path="assets/a.png" kind="Image"/>
</project>`
	project, err := ParseProject(text)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, project.size, [2]f32{640, 360})
	testing.expect_value(t, project.scaleMode, ScaleMode.IntegerScale)
	testing.expect_value(t, project.background, sdl.Color{0x10, 0x20, 0x30, 0xff})
	testing.expect_value(t, len(project.scenes), 2)
	testing.expect_value(t, len(project.assets), 1)
	// No startScene: the first scene
	testing.expect_value(t, project.startScene, "A")
}

@(test)
parse_errors :: proc(t: ^testing.T) {
	_, err := ParseScene("<scene><node")
	testing.expect_value(t, err, ProjectError.Invalid_XML)

	_, err = ParseScene(`<project name="x"/>`)
	testing.expect_value(t, err, ProjectError.Wrong_Root)

	_, err = ParseProject(`<project formatVersion="99"/>`)
	testing.expect_value(t, err, ProjectError.Unsupported_Version)
}

@(test)
colors_round_trip :: proc(t: ^testing.T) {
	for color in ([]sdl.Color{{255, 128, 0, 255}, {1, 2, 3, 4}}) {
		text := FormatColor(color, context.temp_allocator)
		parsed, ok := ParseColor(text)
		testing.expect(t, ok, text)
		testing.expect_value(t, parsed, color)
	}
	_, ok := ParseColor("orange")
	testing.expect_value(t, ok, false)
	_, ok = ParseColor("#12345")
	testing.expect_value(t, ok, false)
}
