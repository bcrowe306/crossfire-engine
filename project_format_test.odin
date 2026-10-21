#+build !js
package crossfire

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

@(test)
parse_animated_sprite_animations :: proc(t: ^testing.T) {
	text := `<scene formatVersion="7" name="S">
		<node kind="AnimatedSprite" name="Hero" texture="hero.png" columns="4" rows="2" margin="1" spacing="2" autoplay="jump">
			<animation name="walk" start="0" end="3" fps="10" loop="true"/>
			<animation name="jump" start="4" fps="12" playMode="PingPong"/>
		</node>
		<node kind="AnimatedSprite" name="Old" texture="old.png" columns="4" fps="6"/>
	</scene>`
	scene, err := ParseScene(text)
	defer SceneData_Destroy(&scene)
	testing.expect_value(t, err, ProjectError.None)
	hero := scene.nodes[0]
	testing.expect_value(t, hero.margin, 1)
	testing.expect_value(t, hero.spacing, 2)
	testing.expect_value(t, hero.autoplay, "jump")
	testing.expect_value(t, len(hero.animations), 2)
	walk := hero.animations[0]
	testing.expect(t, walk.name == "walk" && walk.start == 0 && walk.end == 3 && walk.fps == 10 && walk.loop && walk.playMode == .Forward && len(walk.durations) == 0, "walk")
	testing.expect_value(t, hero.animations[1].end, -1) // Missing: to the last cell
	testing.expect_value(t, hero.animations[1].playMode, AnimationPlayMode.PingPong)
	testing.expect(t, !hero.animations[1].loop, "loop defaults to off")
	// Before version 7: no animations, the node's fps
	testing.expect_value(t, len(scene.nodes[1].animations), 0)
	testing.expect_value(t, scene.nodes[1].fps, 6)

	// Cells of a 4x2 sheet of 44x22 px with a 1 px margin and 2 px spacing: 9 x 9 px each
	cell := SpriteSheet_CellRect({44, 22}, 4, 2, 1, 2, 5)
	testing.expect_value(t, cell, sdl.FRect{12, 12, 9, 9})
}

@(test)
project_renderer_setting :: proc(t: ^testing.T) {
	project, err := ParseProject(`<project formatVersion="11" name="R" renderer="Vulkan"/>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, project.renderer, RenderBackend.Vulkan)
	old, _ := ParseProject(`<project formatVersion="10" name="R"/>`)
	defer ProjectData_Destroy(&old)
	testing.expect_value(t, old.renderer, RenderBackend.Auto)

	backend, ok := RenderBackend_Parse("software")
	testing.expect(t, ok && backend == .Software, "by driver name")
	backend, ok = RenderBackend_Parse("direct3d11")
	testing.expect(t, ok && backend == .Direct3D11, "by driver name")
	backend, ok = RenderBackend_Parse("OpenGLES2")
	testing.expect(t, ok && backend == .OpenGLES2, "by enum name")
	_, ok = RenderBackend_Parse("glide")
	testing.expect(t, !ok, "unknown")
	testing.expect(t, RenderBackend_Available(.Auto), "Auto is always there")

	options, valid := Player_ParseArgs({"player", "game", "--renderer", "vulkan"})
	testing.expect(t, valid && options.renderer == "vulkan" && options.projectDir == "game", "--renderer")
}

@(test)
parse_project_grid :: proc(t: ^testing.T) {
	project, err := ParseProject(`<project formatVersion="13" name="G"><grid width="16" height="24" majorEvery="0" opacity="150"/></project>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, err, ProjectError.None)
	// Missing attributes keep the defaults; values are kept in range
	testing.expect_value(t, project.grid, GridSettings{size = {16, 24}, majorEvery = 0, opacity = 100, majorOpacity = DEFAULT_GRID_SETTINGS.majorOpacity})
	// No <grid>: the defaults
	plain, _ := ParseProject(`<project formatVersion="13" name="P"/>`)
	defer ProjectData_Destroy(&plain)
	testing.expect_value(t, plain.grid, DEFAULT_GRID_SETTINGS)
}

@(test)
scene_settings_are_parsed_and_applied :: proc(t: ^testing.T) {
	data, err := ParseScene(`<scene formatVersion="13" name="Level" screenLayers="7, 8" background="#203040" gravityY="490"/>`)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, data.settings, SceneSettings{
		screenLayers = {.Layer7, .Layer8},
		hasBackground = true, background = {0x20, 0x30, 0x40, 255},
		hasGravity = true, gravity = {DEFAULT_PHYSICS.gravity.x, 490},
	})
	testing.expect_value(t, FormatScreenLayers({.Layer1, .Layer8}, context.temp_allocator), "1 8")
	layers, ok := ParseScreenLayers("2 nine 3")
	testing.expect(t, !ok && layers == {.Layer2, .Layer3}, "bad parts are reported, good ones kept")

	// Applied by Scene_Build: screen layers, background, gravity for the world made later
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	_ = Scene_Build(scene, &data, "")
	testing.expect_value(t, scene.screenLayers, bit_set[RenderLayer]{.Layer7, .Layer8})
	testing.expect_value(t, scene.background.?, sdl.Color{0x20, 0x30, 0x40, 255})
	testing.expect_value(t, Scene_GetPhysics(scene).settings.gravity, [2]f32{0, 490})

	// Without settings: none (the project's)
	plain, _ := ParseScene(`<scene formatVersion="13" name="Plain"/>`)
	defer SceneData_Destroy(&plain)
	testing.expect_value(t, plain.settings, SceneSettings{})
	Scene_ApplySettings(scene, plain.settings)
	_, hasBackground := scene.background.?
	testing.expect(t, !hasBackground && scene.screenLayers == {}, "cleared")
	free_all(context.temp_allocator)
}
