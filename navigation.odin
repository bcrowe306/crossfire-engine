package crossfire

import "core:math"
import "core:slice"
import sdl "vendor:sdl3"

/*
Pathfinding and navigation: **NavRegion** nodes say where characters can walk (a grid of cells
over an area, blocked where static bodies are), and **NavAgent** nodes find paths through it
(A*, then straightened) and steer their parent along them, keeping apart from each other.

	<node kind="NavRegion" name="Floor" width="1280" height="720" cellSize="16" agentRadius="10"/>
	<node kind="CharacterMover" name="Guard" x="100" y="100">
		<node kind="CollisionShape" shape="Circle" radius="10"/>
		<node kind="NavAgent" name="Nav" speed="120"/>
	</node>

- **The grid** (`NavGrid`): a NavRegion covers `size` from its position (its top-left corner),
  in cells of `cellSize`. A cell is blocked when a static body's collision shape covers it, grown
  by `agentRadius` so characters that wide fit through what's left: the walls of TileMaps and LDtk
  levels, StaticBody nodes. It's built when the scene starts (`NavRegion_Rebuild` after walls
  change); `NavGrid_SetBlocked` blocks cells by hand (a closed door).
- **Paths** (`NavRegion_FindPath`, `NavGrid_FindPath`): A* over the cells, 8 ways (`diagonal`;
  never cutting a blocked corner), then straightened where the way is clear. A target in a
  blocked cell goes to the nearest open one.
- **Agents** (`NavAgent`): `NavAgent_SetTarget` finds a path in the region it's in, and each
  update the agent works out `velocity` (toward the next point at `speed`, slowing near the end,
  pushed apart from other agents within `avoidRadius`). With `autoMove` it moves its parent: a
  CharacterMover by its velocity (`CharacterMover_Move`), a DynamicBody by its velocity, anything
  else by its position. Events: `onArrived`, `onPathFailed`.
- Movement is in the plane (top-down games, or flying); a platformer's walking needs jumps the
  grid doesn't know about.
*/

// A grid of walkable cells (a NavRegion's): see the file's overview
NavGrid :: struct {
	// The world position of cell (0, 0)'s top-left corner
	origin: [2]f32,
	// A cell's width and height
	cellSize: f32,
	// Cells across and down
	columns, rows: int,
	// Blocked cells, row by row
	blocked: []bool,
	// Paths may go diagonally (never across a blocked corner)
	diagonal: bool,
}

/*
A navigation area's settings (`SceneNodeData.nav`): a NavRegion's and a NavAgent's.
*/
NavSettings :: struct {
	// NavRegion: a cell's size in pixels
	cellSize: f32,
	// NavRegion: how far walls are grown (half the characters' width), in pixels
	agentRadius: f32,
	// NavRegion: paths may go diagonally
	diagonal: bool,
	// NavAgent: pixels per second
	speed: f32,
	// NavAgent: how close counts as arrived, in pixels
	arriveDistance: f32,
	// NavAgent: keeps this far from other agents (0: doesn't avoid them)
	avoidRadius: f32,
	// NavAgent: moves its parent itself (else scripts read `velocity`)
	autoMove: bool,
}

// Navigation settings when the scene file sets none
DEFAULT_NAV_SETTINGS :: NavSettings{cellSize = 16, agentRadius = 8, diagonal = true, speed = 100, arriveDistance = 4, avoidRadius = 12, autoMove = true}

// An area characters can walk in: see the file's overview
NavRegion :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Its size in pixels, from its position (its top-left corner)
	size: [2]f32,
	// Its settings (cellSize, agentRadius, diagonal)
	settings: NavSettings,
	// Its grid (node arena; built when the scene starts, `NavRegion_Rebuild`)
	grid: NavGrid,
	// The grid has been built
	built: bool,
}

// A character's path finder and steering: see the file's overview
NavAgent :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Its settings (speed, arriveDistance, avoidRadius, autoMove)
	settings: NavSettings,
	// The path being followed, in world positions (node arena)
	path: [dynamic][2]f32,
	// The next point of `path`
	next: int,
	// Where it's going, and whether it has somewhere to go
	target: [2]f32,
	moving: bool,
	// What it would move by this update, in pixels per second (also when not `autoMove`)
	velocity: [2]f32,
	// It reached the end of its path
	onArrived: EventSubject `event:"It reached its target"`,
	// No path leads to its target (or it's in no NavRegion)
	onPathFailed: EventSubject `event:"No path leads to its target"`,
}

/*
Creates a NavRegion and adds it to the scene (at the start of the next update). Its grid is
built on its first update.

Inputs:
- scene: The scene
- size: Its width and height in pixels, from its position (its top-left corner)
- settings: Its cell size, agent radius, diagonal moves

Returns:
- The region

Example:
	floor := e.CreateNavRegion(scene, {1280, 720})
	floor.settings.cellSize = 32
*/
CreateNavRegion :: proc(scene: ^Scene, size: [2]f32, settings := DEFAULT_NAV_SETTINGS) -> ^NavRegion {
	r := CreateNode(scene, NavRegion)
	r.size = size
	r.settings = settings
	r.update = proc(node: ^Node, events: []sdl.Event, dt: f64) {
		r := cast(^NavRegion)node
		if !r.built do NavRegion_Rebuild(r)
	}
	r.getBounds = proc(node: ^Node) -> (sdl.FRect, bool) {
		r := cast(^NavRegion)node
		return {0, 0, r.size.x, r.size.y}, r.size.x > 0 && r.size.y > 0
	}
	return r
}

/*
Creates a NavAgent and adds it to the scene (at the start of the next update). Make it a child of
the node it moves.

Inputs:
- scene: The scene
- settings: Its speed, arrive distance, avoidance, auto move

Returns:
- The agent

Example:
	// Given: guard: ^e.CharacterMover
	nav := e.CreateNavAgent(scene)
	e.Node_AddChild(guard, nav)
	e.NavAgent_SetTarget(nav, {600, 300})
*/
CreateNavAgent :: proc(scene: ^Scene, settings := DEFAULT_NAV_SETTINGS) -> ^NavAgent {
	a := CreateNode(scene, NavAgent)
	a.settings = settings
	allocator := Node_GetAllocator(a)
	a.path = make([dynamic][2]f32, allocator)
	EventSubject_Init(&a.onArrived, allocator)
	EventSubject_Init(&a.onPathFailed, allocator)
	a.update = navAgentUpdate
	return a
}

/*
Builds a region's grid again from the static bodies in its area (after walls were added, moved
or removed). Cells blocked by hand are open again.

Inputs:
- region: The region
*/
NavRegion_Rebuild :: proc(region: ^NavRegion) {
	cell := max(region.settings.cellSize, 1)
	columns := max(int(math.ceil(region.size.x / cell)), 1)
	rows := max(int(math.ceil(region.size.y / cell)), 1)
	grid := &region.grid
	if len(grid.blocked) != columns * rows do grid.blocked = make([]bool, columns * rows, Node_GetAllocator(region))
	grid.origin = Node_GetWorldPosition(region)
	grid.cellSize = cell
	grid.columns, grid.rows = columns, rows
	grid.diagonal = region.settings.diagonal
	slice.fill(grid.blocked, false)
	if region.scene != nil do NavGrid_BlockStaticBodies(grid, region.scene, region.settings.agentRadius)
	region.built = true
}

/*
Blocks the cells a scene's static bodies' collision shapes cover, grown by a radius.

Inputs:
- grid: The grid
- scene: The scene
- radius: How far shapes are grown (the characters' half width)
*/
NavGrid_BlockStaticBodies :: proc(grid: ^NavGrid, scene: ^Scene, radius: f32) {
	for node in scene.nodes {
		if !Node_Is(node, CollisionShape) do continue
		shape := cast(^CollisionShape)node
		if shape.disabled || shape.oneWay do continue
		body := shape.parent
		for body != nil && !Node_IsPhysicsBody(body) do body = body.parent
		if body == nil || !Node_Is(body, StaticBody) do continue
		world := Node_GetWorldTransform(shape)
		// The shape's outline in the world (a circle: its center and radius)
		outline := make([dynamic][2]f32, context.temp_allocator)
		circle := false
		r: f32
		switch shape.shape {
		case .Rectangle:
			h := shape.size * 0.5
			for p in ([4][2]f32{{-h.x, -h.y}, {h.x, -h.y}, {h.x, h.y}, {-h.x, h.y}}) do append(&outline, Transform2D_Apply(world, p))
		case .Capsule:
			h := [2]f32{shape.radius, shape.height * 0.5}
			for p in ([4][2]f32{{-h.x, -h.y}, {h.x, -h.y}, {h.x, h.y}, {-h.x, h.y}}) do append(&outline, Transform2D_Apply(world, p))
		case .Circle:
			circle = true
			r = shape.radius * Transform2D_Scale(world).x
			append(&outline, world.origin)
		case .Polygon, .Segment:
			for p in shape.points do append(&outline, Transform2D_Apply(world, p))
		}
		if len(outline) == 0 do continue
		// The cells near it: blocked when their center is within the shape grown by the radius
		lo, hi := outline[0], outline[0]
		for p in outline do lo, hi = {min(lo.x, p.x), min(lo.y, p.y)}, {max(hi.x, p.x), max(hi.y, p.y)}
		grow := radius + (circle ? r : 0)
		c0 := max(int(math.floor((lo.x - grow - grid.origin.x) / grid.cellSize)), 0)
		r0 := max(int(math.floor((lo.y - grow - grid.origin.y) / grid.cellSize)), 0)
		c1 := min(int(math.floor((hi.x + grow - grid.origin.x) / grid.cellSize)), grid.columns - 1)
		r1 := min(int(math.floor((hi.y + grow - grid.origin.y) / grid.cellSize)), grid.rows - 1)
		for row in r0..=r1 do for column in c0..=c1 {
			center := grid.origin + ([2]f32{f32(column), f32(row)} + 0.5) * grid.cellSize
			inside: bool
			if circle {
				d := center - outline[0]
				inside = d.x * d.x + d.y * d.y <= grow * grow
			} else {
				inside = distanceToOutline(center, outline[:], shape.shape != .Segment) <= radius
			}
			if inside do grid.blocked[row * grid.columns + column] = true
		}
	}
}

/*
Blocks or opens the cell under a world point (a door closing or opening).

Inputs:
- grid: The grid (a NavRegion's `grid`)
- at: A world position
- blocked: Blocked (true) or open
*/
NavGrid_SetBlocked :: proc(grid: ^NavGrid, at: [2]f32, blocked: bool) {
	if c, ok := NavGrid_CellAt(grid, at); ok do grid.blocked[c.y * grid.columns + c.x] = blocked
}

/*
The cell under a world point.

Inputs:
- grid: The grid
- at: A world position

Returns:
- Its column and row, and false when it's outside the grid
*/
NavGrid_CellAt :: proc(grid: ^NavGrid, at: [2]f32) -> ([2]int, bool) {
	if grid.cellSize <= 0 do return {}, false
	c := [2]int{int(math.floor((at.x - grid.origin.x) / grid.cellSize)), int(math.floor((at.y - grid.origin.y) / grid.cellSize))}
	return c, c.x >= 0 && c.y >= 0 && c.x < grid.columns && c.y < grid.rows
}

/*
Whether a cell is blocked (outside the grid counts as blocked).
*/
NavGrid_IsBlocked :: proc(grid: ^NavGrid, cell: [2]int) -> bool {
	if cell.x < 0 || cell.y < 0 || cell.x >= grid.columns || cell.y >= grid.rows do return true
	return grid.blocked[cell.y * grid.columns + cell.x]
}

/*
Finds a path over a grid: A* over its cells, then straightened where the way is clear. A target
in a blocked cell is moved to the nearest open cell.

Inputs:
- grid: The grid
- from, to: World positions
- allocator: For the points

Returns:
- The points from the start (excluded) to the target (included), and false when there's no
  path (the start or target outside the grid, or walled off)
*/
NavGrid_FindPath :: proc(grid: ^NavGrid, from, to: [2]f32, allocator := context.allocator) -> ([][2]f32, bool) {
	start, inStart := NavGrid_CellAt(grid, from)
	goal, inGoal := NavGrid_CellAt(grid, to)
	if !inStart || !inGoal do return nil, false
	if NavGrid_IsBlocked(grid, goal) {
		open, found := nearestOpen(grid, goal)
		if !found do return nil, false
		goal = open
	}
	if NavGrid_IsBlocked(grid, start) {
		// A character pushed into a wall's grown edge: from the nearest open cell
		open, found := nearestOpen(grid, start)
		if !found do return nil, false
		start = open
	}
	n := grid.columns * grid.rows
	index :: proc(grid: ^NavGrid, c: [2]int) -> int { return c.y * grid.columns + c.x }
	cost := make([]f32, n, context.temp_allocator)
	came := make([]i32, n, context.temp_allocator)
	closed := make([]bool, n, context.temp_allocator)
	for i in 0..<n do cost[i], came[i] = max(f32), -1
	Open :: struct { cell: int, score: f32 }
	heap := make([dynamic]Open, context.temp_allocator)
	push :: proc(heap: ^[dynamic]Open, item: Open) {
		append(heap, item)
		i := len(heap) - 1
		for i > 0 {
			parent := (i - 1) / 2
			if heap[parent].score <= heap[i].score do break
			heap[parent], heap[i] = heap[i], heap[parent]
			i = parent
		}
	}
	heapPop :: proc(heap: ^[dynamic]Open) -> Open {
		top := heap[0]
		last := pop(heap)
		if len(heap) == 0 do return top
		heap[0] = last
		i := 0
		for {
			l, r := i * 2 + 1, i * 2 + 2
			small := i
			if l < len(heap) && heap[l].score < heap[small].score do small = l
			if r < len(heap) && heap[r].score < heap[small].score do small = r
			if small == i do break
			heap[small], heap[i] = heap[i], heap[small]
			i = small
		}
		return top
	}
	heuristic :: proc(a, b: [2]int, diagonal: bool) -> f32 {
		dx, dy := f32(abs(a.x - b.x)), f32(abs(a.y - b.y))
		if !diagonal do return dx + dy
		return max(dx, dy) + (math.SQRT_TWO - 1) * min(dx, dy)
	}
	s := index(grid, start)
	cost[s] = 0
	push(&heap, {s, heuristic(start, goal, grid.diagonal)})
	g := index(grid, goal)
	found := false
	for len(heap) > 0 {
		current := heapPop(&heap).cell
		if closed[current] do continue
		closed[current] = true
		if current == g {
			found = true
			break
		}
		c := [2]int{current % grid.columns, current / grid.columns}
		for d in ([8][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) {
			diag := d.x != 0 && d.y != 0
			if diag && !grid.diagonal do continue
			next := c + d
			if NavGrid_IsBlocked(grid, next) do continue
			// Never across a blocked corner
			if diag && (NavGrid_IsBlocked(grid, {c.x + d.x, c.y}) || NavGrid_IsBlocked(grid, {c.x, c.y + d.y})) do continue
			ni := index(grid, next)
			step: f32 = diag ? math.SQRT_TWO : 1
			if cost[current] + step < cost[ni] {
				cost[ni] = cost[current] + step
				came[ni] = i32(current)
				push(&heap, {ni, cost[ni] + heuristic(next, goal, grid.diagonal)})
			}
		}
	}
	if !found do return nil, false
	// The cells back from the goal, then straightened: from each kept point, the farthest one
	// in clear sight
	cells := make([dynamic][2]f32, context.temp_allocator)
	for at := g; at != -1; at = int(came[at]) {
		append(&cells, grid.origin + ([2]f32{f32(at % grid.columns), f32(at / grid.columns)} + 0.5) * grid.cellSize)
		if at == s do break
	}
	slice.reverse(cells[:])
	// The real start and end, not their cells' middles (the end when it was open)
	cells[0] = from
	if !NavGrid_IsBlocked(grid, NavGrid_CellAt(grid, to) or_else goal) do cells[len(cells) - 1] = to
	points := make([dynamic][2]f32, allocator)
	at := 0
	for at < len(cells) - 1 {
		far := at + 1
		for k := len(cells) - 1; k > at + 1; k -= 1 {
			if NavGrid_LineClear(grid, cells[at], cells[k]) {
				far = k
				break
			}
		}
		append(&points, cells[far])
		at = far
	}
	return points[:], true
}

/*
Whether a straight line between two world points crosses only open cells.
*/
NavGrid_LineClear :: proc(grid: ^NavGrid, a, b: [2]f32) -> bool {
	d := b - a
	length := math.sqrt(d.x * d.x + d.y * d.y)
	steps := max(int(math.ceil(length / (grid.cellSize * 0.25))), 1)
	for i in 0..=steps {
		p := a + d * (f32(i) / f32(steps))
		c, inside := NavGrid_CellAt(grid, p)
		if !inside || grid.blocked[c.y * grid.columns + c.x] do return false
	}
	return true
}

/*
A path in a region (see `NavGrid_FindPath`); its grid is built first if it isn't yet.

Inputs:
- region: The region
- from, to: World positions
- allocator: For the points

Returns:
- The points, and whether there's a path
*/
NavRegion_FindPath :: proc(region: ^NavRegion, from, to: [2]f32, allocator := context.allocator) -> ([][2]f32, bool) {
	if !region.built do NavRegion_Rebuild(region)
	return NavGrid_FindPath(&region.grid, from, to, allocator)
}

/*
The region a world point is in (the first that has it).

Inputs:
- scene: The scene
- at: A world position

Returns:
- The region, or nil
*/
Scene_FindNavRegion :: proc(scene: ^Scene, at: [2]f32) -> ^NavRegion {
	for node in scene.nodes {
		if !Node_Is(node, NavRegion) do continue
		r := cast(^NavRegion)node
		p := Node_GetWorldPosition(r)
		if at.x >= p.x && at.y >= p.y && at.x < p.x + r.size.x && at.y < p.y + r.size.y do return r
	}
	return nil
}

/*
Sends an agent somewhere: a path is found in the region it's in, and it follows it.

Inputs:
- agent: The agent
- target: A world position

Returns:
- false when there's no path (onPathFailed fires too)
*/
NavAgent_SetTarget :: proc(agent: ^NavAgent, target: [2]f32) -> bool {
	agent.target = target
	clear(&agent.path)
	agent.next = 0
	agent.moving = false
	here := Node_GetWorldPosition(agent)
	region := agent.scene != nil ? Scene_FindNavRegion(agent.scene, here) : nil
	if region == nil {
		Event_Notify(&agent.onPathFailed, agent, nil)
		return false
	}
	points, ok := NavRegion_FindPath(region, here, target, context.temp_allocator)
	if !ok {
		Event_Notify(&agent.onPathFailed, agent, nil)
		return false
	}
	append(&agent.path, ..points)
	agent.moving = len(agent.path) > 0
	return true
}

/*
Stops an agent where it is.
*/
NavAgent_Stop :: proc(agent: ^NavAgent) {
	clear(&agent.path)
	agent.moving = false
	agent.velocity = {}
}

// INTERNAL

@(private="file")
nearestOpen :: proc(grid: ^NavGrid, from: [2]int) -> ([2]int, bool) {
	for radius in 1..=max(grid.columns, grid.rows) {
		best: [2]int
		bestD := max(int)
		for dy in -radius..=radius do for dx in -radius..=radius {
			if max(abs(dx), abs(dy)) != radius do continue
			c := from + {dx, dy}
			if NavGrid_IsBlocked(grid, c) do continue
			d := dx * dx + dy * dy
			if d < bestD do best, bestD = c, d
		}
		if bestD != max(int) do return best, true
	}
	return {}, false
}

// The distance from a point to a polygon (0 inside a closed one) or a polyline
@(private="file")
distanceToOutline :: proc(p: [2]f32, outline: [][2]f32, closed: bool) -> f32 {
	n := len(outline)
	if n == 1 {
		d := p - outline[0]
		return math.sqrt(d.x * d.x + d.y * d.y)
	}
	inside := false
	best := max(f32)
	for i in 0..<n {
		if !closed && i == n - 1 do break
		a, b := outline[i], outline[(i + 1) % n]
		// Even-odd crossing test
		if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x do inside = !inside
		ab := b - a
		t := clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / max(ab.x * ab.x + ab.y * ab.y, 1e-9), 0, 1)
		q := a + ab * t
		d := p - q
		best = min(best, math.sqrt(d.x * d.x + d.y * d.y))
	}
	if closed && inside do return 0
	return best
}

@(private="file")
navAgentUpdate :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	agent := cast(^NavAgent)node
	agent.velocity = {}
	if !agent.moving || agent.next >= len(agent.path) do return
	here := Node_GetWorldPosition(agent)
	s := agent.settings
	// Past points close enough go by
	for agent.next < len(agent.path) - 1 {
		d := agent.path[agent.next] - here
		if d.x * d.x + d.y * d.y > s.arriveDistance * s.arriveDistance do break
		agent.next += 1
	}
	goal := agent.path[agent.next]
	d := goal - here
	distance := math.sqrt(d.x * d.x + d.y * d.y)
	last := agent.next == len(agent.path) - 1
	if last && distance <= max(s.arriveDistance, 0.5) {
		agent.moving = false
		Event_Notify(&agent.onArrived, agent, nil)
		return
	}
	speed := s.speed
	// Slowing down over the last stretch, and not past the goal in one step
	if last do speed = min(speed, distance * 4)
	if deltaTime > 0 do speed = min(speed, distance / f32(deltaTime))
	v := distance > 0 ? d / distance * speed : [2]f32{}
	// Apart from other agents
	if s.avoidRadius > 0 && agent.scene != nil {
		push: [2]f32
		for other in agent.scene.nodes {
			if other == agent || !Node_Is(other, NavAgent) do continue
			o := cast(^NavAgent)other
			away := here - Node_GetWorldPosition(o)
			gap := math.sqrt(away.x * away.x + away.y * away.y)
			reach := s.avoidRadius + o.settings.avoidRadius
			if gap <= 0.001 || gap >= reach do continue
			push += away / gap * (reach - gap) / reach
		}
		v += push * s.speed
		if l := math.sqrt(v.x * v.x + v.y * v.y); l > s.speed do v = v / l * s.speed
	}
	agent.velocity = v
	if !s.autoMove do return
	// Its parent moves (or itself, at the top level)
	mover: ^Node = agent.parent != nil ? agent.parent : agent
	switch {
	case Node_Is(mover, CharacterMover):
		cm := cast(^CharacterMover)mover
		cm.velocity = v
		if mover.scene != nil && mover.scene.physics != nil {
			CharacterMover_Move(cm, deltaTime)
		} else {
			Node_SetWorldPosition(mover, Node_GetWorldPosition(mover) + v * f32(deltaTime))
		}
	case Node_Is(mover, DynamicBody):
		DynamicBody_SetVelocity(cast(^DynamicBody)mover, v)
	case:
		Node_SetWorldPosition(mover, Node_GetWorldPosition(mover) + v * f32(deltaTime))
	}
}
