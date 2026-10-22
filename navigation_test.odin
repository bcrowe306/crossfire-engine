#+build !js
package crossfire

import "core:math"
import "core:testing"

// Navigation (navigation.odin): A* around walls, straightened paths, no path, regions blocked by
// static bodies, agents walking to their target and arriving

@(test)
paths_go_around_walls :: proc(t: ^testing.T) {
	// 10 x 10 cells of 10 px; a wall down column 5 with a gap at the bottom row
	grid := NavGrid{cellSize = 10, columns = 10, rows = 10, diagonal = true}
	grid.blocked = make([]bool, 100, context.temp_allocator)
	for row in 0..<9 do grid.blocked[row * 10 + 5] = true
	path, ok := NavGrid_FindPath(&grid, {5, 5}, {95, 5}, context.temp_allocator)
	testing.expect(t, ok, "a path")
	if !ok do return
	testing.expect_value(t, path[len(path) - 1], [2]f32{95, 5})
	// Through the gap, every leg in the clear
	low := false
	for p in path do if p.y > 90 do low = true
	testing.expect(t, low, "through the gap at the bottom")
	from := [2]f32{5, 5}
	length: f32
	for p in path {
		testing.expectf(t, NavGrid_LineClear(&grid, from, p), "%v to %v is clear", from, p)
		d := p - from
		length += math.sqrt(d.x * d.x + d.y * d.y)
		from = p
	}
	// Straightened: not cell by cell
	testing.expectf(t, len(path) <= 4, "few points: %v", path)
	testing.expectf(t, length > 195 && length < 230, "around, not much longer: %v", length)
	// A target in the wall: to the nearest open cell
	path, ok = NavGrid_FindPath(&grid, {5, 5}, {55, 15}, context.temp_allocator)
	testing.expect(t, ok, "near the wall")
	// The gap closed: no way through
	grid.blocked[9 * 10 + 5] = true
	_, ok = NavGrid_FindPath(&grid, {5, 5}, {95, 5}, context.temp_allocator)
	testing.expect(t, !ok, "walled off")
	// Without diagonals, steps are straight; never across a blocked corner either way
	open := NavGrid{cellSize = 10, columns = 3, rows = 3}
	open.blocked = make([]bool, 9, context.temp_allocator)
	open.blocked[1] = true
	open.blocked[3] = true
	_, ok = NavGrid_FindPath(&open, {5, 5}, {15, 15}, context.temp_allocator)
	testing.expect(t, !ok, "not between two blocked corners")
	free_all(context.temp_allocator)
}

@(private="file")
NAV_SCENE :: `<scene formatVersion="13" name="S">
	<node kind="NavRegion" name="Floor" width="200" height="200" cellSize="10" agentRadius="5"/>
	<node kind="StaticBody" name="Box" x="100" y="100">
		<node kind="CollisionShape" shape="Rectangle" width="40" height="40"/>
	</node>
	<node kind="Node2D" name="Walker" x="20" y="100">
		<node kind="NavAgent" name="Nav" speed="200" arriveDistance="2"/>
	</node>
</scene>`

@(test)
agents_walk_around_static_bodies :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	data, err := ParseScene(NAV_SCENE)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect(t, data.nodes[0].nav.cellSize == 10 && data.nodes[4].nav.speed == 200, "parsed")
	created := Scene_Build(scene, &data, "testdata", attachScripts = false)
	Scene_Update(scene, nil, 0)
	region := cast(^NavRegion)created[0]
	testing.expect(t, region.built, "built on its first update")
	// The box covers 80..120; grown by 5, cells whose middles are within 75..125
	testing.expect(t, NavGrid_IsBlocked(&region.grid, {10, 10}), "the box's middle")
	testing.expect(t, NavGrid_IsBlocked(&region.grid, {7, 10}), "its grown edge (75..85)")
	testing.expect(t, !NavGrid_IsBlocked(&region.grid, {6, 10}), "open beyond it")
	testing.expect_value(t, Scene_FindNavRegion(scene, {50, 50}), region)

	// The walker goes to the other side, around the box
	walker := created[3]
	agent := cast(^NavAgent)created[4]
	arrived := 0
	Event_Subscribe(&agent.onArrived, proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) { (cast(^int)user)^ += 1 }, &arrived)
	testing.expect(t, NavAgent_SetTarget(agent, {180, 100}), "a path")
	for _ in 0..<200 {
		Scene_Update(scene, nil, 1.0 / 60)
		p := Node_GetWorldPosition(walker)
		testing.expectf(t, !NavGrid_IsBlocked(&region.grid, NavGrid_CellAt(&region.grid, p) or_else {}), "never in a blocked cell: %v", p)
		if arrived > 0 do break
	}
	testing.expect_value(t, arrived, 1)
	p := Node_GetWorldPosition(walker)
	testing.expectf(t, abs(p.x - 180) < 3 && abs(p.y - 100) < 3, "there: %v", p)
	// Nowhere to go: the box's middle moves to an open cell; outside the region fails
	failed := 0
	Event_Subscribe(&agent.onPathFailed, proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) { (cast(^int)user)^ += 1 }, &failed)
	testing.expect(t, !NavAgent_SetTarget(agent, {500, 500}), "outside")
	testing.expect_value(t, failed, 1)
	free_all(context.temp_allocator)
}
