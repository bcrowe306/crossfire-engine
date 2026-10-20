#+build !js
package crossfire

import "core:os"
import "core:path/filepath"
import "core:testing"

// Component tests: component files in a temp folder, instanced by scene data and from code

@(private="file")
writeFile :: proc(dir, name, text: string) {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	_ = os.make_directory_all(filepath.dir(path))
	_ = os.write_entire_file(path, text)
}

@(private="file")
SHIP :: `<?xml version="1.0" encoding="UTF-8"?>
<component formatVersion="9" name="Ship">
	<node kind="Node2D" name="Ship" x="5" y="5">
		<node kind="ParticleEmitter" name="Exhaust" y="30"/>
		<node kind="Node2D" name="Gun" x="10"/>
	</node>
	<node kind="Node2D" name="Ignored"/>
</component>`

@(private="file")
FLEET :: `<component formatVersion="9" name="Fleet">
	<node kind="Node2D" name="Fleet">
		<node kind="Component" name="Lead" x="100" component="components/ship.component.xml"/>
		<node kind="Component" name="Wing" x="200" component="components/ship.component.xml"/>
	</node>
</component>`

@(test)
components_are_instanced :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, "engine_test_components"}, context.temp_allocator)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	writeFile(dir, "components/ship.component.xml", SHIP)
	writeFile(dir, "components/fleet.component.xml", FLEET)

	parsed, err := ParseComponent(SHIP)
	defer SceneData_Destroy(&parsed)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, parsed.name, "Ship")
	testing.expect_value(t, len(parsed.nodes), 3) // The root and its children; a second root is ignored
	_, wrong := ParseComponent(`<scene name="S"/>`)
	testing.expect_value(t, wrong, ProjectError.Wrong_Root)

	game: Game
	game.projectDir = dir
	defer if game.arenaReady do MemoryArena_Destroy(&game.arena)
	scene := new(Scene)
	Scene_Init(scene)
	scene.game = &game
	defer { Scene_Destroy(scene); free(scene) }

	// Two instances in a scene file, one under a node; and a component holding components
	text := `<scene formatVersion="9" name="S">
		<node kind="Component" name="Player" x="40" y="50" rotation="90" component="components/ship.component.xml"/>
		<node kind="Node2D" name="Enemies" x="500">
			<node kind="Component" name="Enemy" component="components/ship.component.xml" visible="false"/>
		</node>
		<node kind="Component" name="Fleet" component="components/fleet.component.xml"/>
	</scene>`
	data, _ := ParseScene(text)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, data.nodes[0].component, "components/ship.component.xml")
	created := Scene_Build(scene, &data, dir)
	Scene_ProcessQueues(scene)

	player := created[0]
	testing.expect_value(t, player.name, "Player") // The instance's name and transform
	testing.expect_value(t, player.position, [2]f32{40, 50})
	testing.expect_value(t, player.rotation, 90)
	testing.expect(t, Node_Is(Scene_FindNode(scene, "Player/Exhaust"), ParticleEmitter), "its children came along")
	enemy := Scene_FindNode(scene, "Enemies/Enemy")
	testing.expect(t, enemy != nil && !enemy.visible, "under its parent, hidden")
	testing.expect(t, Scene_FindNode(scene, "Enemies/Enemy/Gun") != nil, "a second instance")
	testing.expect(t, Scene_FindNode(scene, "Fleet/Wing/Exhaust") != nil, "components in components")
	testing.expect_value(t, Scene_FindNode(scene, "Fleet/Wing").position, [2]f32{200, 0})
	testing.expect_value(t, len(game.components), 2) // Each file read once

	// From code, as often as needed
	a := Scene_Instantiate(scene, ComponentAsset{"components/ship.component.xml"}, position = {1, 2})
	b := Scene_Instantiate(scene, ComponentAsset{"components/ship.component.xml"}, parent = player)
	Scene_ProcessQueues(scene)
	testing.expect(t, a != nil && b != nil && a != b, "two more")
	testing.expect_value(t, a.position, [2]f32{1, 2})
	testing.expect(t, b.parent == player, "under the given parent")
	testing.expect_value(t, len(a.children), 2)
}
