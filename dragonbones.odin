package crossfire

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

/*
DragonBones files (dragonbones.github.io, DragonBones Pro's JSON export, format 5.x) converted into
the engine's own nodes (skeleton.odin), so a character made there plays like one made in the
editor:

- the armature (`<name>_ske.json`'s first one) becomes a **Skeleton2D**, its bones **Bone2D**
  nodes (position, rotation, scale and length as set up);
- each slot's display becomes a **Sprite** on its bone (an image) or a **SkinnedMesh** (a mesh:
  its vertices, picture coordinates, triangles and bone weights), drawn in the slots' order
  (`zIndex`);
- the texture atlas (`<name>_tex.json` and its picture) becomes an **atlas** (atlas.odin) the
  sprites and meshes draw regions of;
- the animations become an **Animator**'s clips: each bone's translate, rotate and scale frames
  as position, rotation and scale tracks (the setup pose plus the frame's offset), looping when
  they play forever.

`DragonBones_Convert` does it in memory; editors write the result as a component and an atlas
asset (the Crossfire Editor's import of a `_ske.json`).

Not converted (each reported in the warnings): slots switching displays or colors over time,
FFD (mesh vertex) animations, skins other than the first, nested armatures, bounding boxes,
IK constraints (add IKChain nodes), skewed bones (only rotation), rotated atlas regions, and
curve easings (they play linearly; `tweenEasing` null steps).
*/

// What DragonBones_Convert makes
DragonBonesResult :: struct {
	// A component: the Skeleton2D root and everything under it (free with SceneData_Destroy)
	component: SceneData,
	// The atlas its sprites and meshes draw from (free with AtlasData_Destroy)
	atlas: AtlasData,
	// What wasn't converted (temp allocated)
	warnings: []string,
}

/*
Converts a DragonBones armature and its texture atlas into a component and an atlas.

Inputs:
- ske: The `_ske.json` file's text
- tex: The `_tex.json` file's text
- atlasPath: Where the atlas will be (the sprites' `texture`; "atlases/hero.atlas.xml")
- imagePath: Where the atlas's picture will be ("atlases/hero.png")

Returns:
- The component and atlas, what wasn't converted, and false when the texts aren't DragonBones
  files (the reason is the first warning)
*/
DragonBones_Convert :: proc(ske, tex: string, atlasPath, imagePath: string) -> (result: DragonBonesResult, ok: bool) {
	warnings := make([dynamic]string, context.temp_allocator)
	file: dbFile
	if err := json.unmarshal(transmute([]byte)ske, &file, allocator = context.temp_allocator); err != nil || len(file.armature) == 0 {
		append(&warnings, "not a DragonBones skeleton (_ske.json) with an armature")
		result.warnings = warnings[:]
		return result, false
	}
	atlasFile: dbAtlas
	if err := json.unmarshal(transmute([]byte)tex, &atlasFile, allocator = context.temp_allocator); err != nil {
		append(&warnings, "not a DragonBones texture atlas (_tex.json)")
		result.warnings = warnings[:]
		return result, false
	}
	if len(file.armature) > 1 do append(&warnings, fmt.tprintf("%d armatures: only %s is converted", len(file.armature), file.armature[0].name))
	arm := &file.armature[0]
	frameRate := f32(arm.frameRate > 0 ? arm.frameRate : file.frameRate > 0 ? file.frameRate : 24)

	// The atlas: each SubTexture a region
	result.atlas = AtlasData{image = strings.clone(imagePath), regions = make([dynamic]AtlasRegion)}
	trims := make(map[string][2]f32, context.temp_allocator)
	for sub in atlasFile.SubTexture {
		if sub.rotated do append(&warnings, fmt.tprintf("%s is rotated in the atlas: drawn wrong (export without rotation)", sub.name))
		append(&result.atlas.regions, AtlasRegion{name = strings.clone(sub.name), source = strings.clone(sub.name), rect = {sub.x, sub.y, sub.width, sub.height}})
		// A trimmed picture's middle against the untrimmed one's
		if fw, hasW := sub.frameWidth.?; hasW {
			fh := sub.frameHeight.? or_else sub.height
			fx := sub.frameX.? or_else 0
			fy := sub.frameY.? or_else 0
			trims[sub.name] = {f32(-fx) + f32(sub.width) * 0.5 - f32(fw) * 0.5, f32(-fy) + f32(sub.height) * 0.5 - f32(fh) * 0.5}
		}
	}
	regionSize :: proc(atlas: ^AtlasData, name: string) -> [2]f32 {
		r, found := Atlas_Find(atlas, name)
		return found ? {f32(r.rect[2]), f32(r.rect[3])} : {}
	}

	// The tree: the root, bones under it (DragonBones lists parents before children), slots'
	// displays under their bones, weighted meshes under the root
	Item :: struct {
		data: SceneNodeData,
		parent: int,
		children: [dynamic]int,
	}
	items := make([dynamic]Item, context.temp_allocator)
	newItem :: proc(items: ^[dynamic]Item, kind: SceneNodeKind, name: string, parent: int) -> int {
		n := DEFAULT_SCENE_NODE
		n.kind, n.name = kind, strings.clone(name)
		append(items, Item{data = n, parent = parent, children = make([dynamic]int, context.temp_allocator)})
		index := len(items) - 1
		if parent >= 0 do append(&items[parent].children, index)
		return index
	}
	root := newItem(&items, .Skeleton2D, arm.name != "" ? arm.name : "Skeleton", -1)
	boneItem := make(map[string]int, context.temp_allocator)
	bonePath := make(map[string]string, context.temp_allocator)
	setup := make(map[string]dbTransform, context.temp_allocator)
	for bone in arm.bone {
		parent := root
		path := bone.name
		if p, found := boneItem[bone.parent]; found && bone.parent != "" {
			parent = p
			path = fmt.tprintf("%s/%s", bonePath[bone.parent], bone.name)
		}
		i := newItem(&items, .Bone2D, bone.name, parent)
		t := bone.transform
		items[i].data.position = {t.x, t.y}
		items[i].data.rotation = t.skY
		items[i].data.scale = {t.scX.? or_else 1, t.scY.? or_else 1}
		items[i].data.boneLength = bone.length
		if abs(t.skX - t.skY) > 0.01 do append(&warnings, fmt.tprintf("bone %s is skewed: only its rotation is used", bone.name))
		boneItem[bone.name] = i
		bonePath[bone.name] = path
		setup[bone.name] = t
	}

	// Displays: the first skin, each slot's shown display
	if len(arm.skin) > 1 do append(&warnings, fmt.tprintf("%d skins: only the first is converted", len(arm.skin)))
	skinSlots := make(map[string]^dbSkinSlot, context.temp_allocator)
	if len(arm.skin) > 0 do for &ss in arm.skin[0].slot do skinSlots[ss.name] = &ss
	for slot, order in arm.slot {
		ss, hasSkin := skinSlots[slot.name]
		if !hasSkin || len(ss.display) == 0 do continue
		shown := slot.displayIndex.? or_else 0
		if shown < 0 || shown >= len(ss.display) do continue
		if len(ss.display) > 1 do append(&warnings, fmt.tprintf("slot %s has %d displays: only the one it shows at first is converted", slot.name, len(ss.display)))
		d := &ss.display[shown]
		region := d.path != "" ? d.path : d.name
		bone, onBone := boneItem[slot.parent]
		if !onBone do bone = root
		switch d.type {
		case "", "image":
			i := newItem(&items, .Sprite, slot.name, bone)
			t := d.transform
			offset := trims[region]
			scale := [2]f32{t.scX.? or_else 1, t.scY.? or_else 1}
			angle := math.to_radians(t.skY)
			offset = {offset.x * scale.x, offset.y * scale.y}
			offset = {offset.x * math.cos(angle) - offset.y * math.sin(angle), offset.x * math.sin(angle) + offset.y * math.cos(angle)}
			items[i].data.position = {t.x, t.y} + offset
			items[i].data.rotation = t.skY
			items[i].data.scale = scale
			items[i].data.texture = strings.clone(atlasPath)
			items[i].data.region = strings.clone(region)
			items[i].data.zIndex = i32(order)
		case "mesh":
			weighted := len(d.weights) > 0
			i := newItem(&items, .SkinnedMesh, slot.name, weighted ? root : bone)
			items[i].data.texture = strings.clone(atlasPath)
			items[i].data.region = strings.clone(region)
			items[i].data.zIndex = i32(order)
			m := MeshData{vertices = make([dynamic][2]f32), uvs = make([dynamic][2]f32), triangles = make([dynamic]i32), bones = make([dynamic]string), weights = make([dynamic]VertexWeights)}
			size := regionSize(&result.atlas, region)
			pose := [6]f32{1, 0, 0, 1, 0, 0}
			if len(d.slotPose) == 6 do for v, k in d.slotPose do pose[k] = v
			for k := 0; k + 1 < len(d.vertices); k += 2 {
				x, y := d.vertices[k], d.vertices[k + 1]
				// Weighted vertices are placed in the armature by the slot's pose
				if weighted do x, y = pose[0] * x + pose[2] * y + pose[4], pose[1] * x + pose[3] * y + pose[5]
				append(&m.vertices, [2]f32{x, y})
			}
			for k := 0; k + 1 < len(d.uvs); k += 2 do append(&m.uvs, [2]f32{d.uvs[k] * size.x, d.uvs[k + 1] * size.y})
			for v in d.triangles do append(&m.triangles, i32(v))
			if weighted {
				// [count, bone, weight, bone, weight...] per vertex; bones are the armature's indices
				local := make(map[int]i32, context.temp_allocator)
				at := 0
				for _ in 0 ..< len(m.vertices) {
					if at >= len(d.weights) do break
					count := int(d.weights[at])
					at += 1
					influences := make([dynamic]struct { bone: int, weight: f32 }, context.temp_allocator)
					for _ in 0 ..< count {
						if at + 1 >= len(d.weights) do break
						append(&influences, struct { bone: int, weight: f32 }{int(d.weights[at]), d.weights[at + 1]})
						at += 2
					}
					if len(influences) > 4 {
						slice.sort_by(influences[:], proc(a, b: struct { bone: int, weight: f32 }) -> bool { return a.weight > b.weight })
						resize(&influences, 4)
					}
					w := VertexWeights{bones = {-1, -1, -1, -1}}
					total: f32
					for inf in influences do total += inf.weight
					for inf, k in influences {
						if inf.bone < 0 || inf.bone >= len(arm.bone) do continue
						index, known := local[inf.bone]
						if !known {
							index = i32(len(m.bones))
							local[inf.bone] = index
							append(&m.bones, strings.clone(fmt.tprintf("../%s", bonePath[arm.bone[inf.bone].name])))
						}
						w.bones[k], w.weights[k] = index, total > 0 ? inf.weight / total : 0
					}
					append(&m.weights, w)
				}
			}
			items[i].data.mesh = m
		case:
			append(&warnings, fmt.tprintf("slot %s shows a %s display: not converted", slot.name, d.type))
		}
	}

	// Animations: an Animator under the root (track paths from it: the root)
	if len(arm.animation) > 0 {
		a := newItem(&items, .Animator, "Animations", root)
		settings := AnimatorSettings{speed = 1, clips = make([dynamic]AnimatorClipData)}
		for anim in arm.animation {
			clip := AnimatorClipData{name = strings.clone(anim.name), length = f32(anim.duration) / frameRate, loop = anim.playTimes == 0, tracks = make([dynamic]AnimatorTrackData)}
			for timeline in anim.bone {
				t, known := setup[timeline.name]
				if !known do continue
				path := bonePath[timeline.name]
				track :: proc(clip: ^AnimatorClipData, node, property: string) -> ^AnimatorTrackData {
					append(&clip.tracks, AnimatorTrackData{node = strings.clone(node), property = strings.clone(property), keys = make([dynamic]AnimatorKeyData)})
					return &clip.tracks[len(clip.tracks) - 1]
				}
				key :: proc(tr: ^AnimatorTrackData, time: f32, value: string, easing: Maybe(f32)) {
					append(&tr.keys, AnimatorKeyData{time = time, value = strings.clone(value), ease = dbEase(easing)})
				}
				steps :: proc(easings: []Maybe(f32)) -> bool {
					for e in easings do if _, tween := e.?; tween do return false
					return len(easings) > 1
				}
				easings :: proc(frames: $T) -> []Maybe(f32) {
					list := make([]Maybe(f32), len(frames), context.temp_allocator)
					for f, i in frames do list[i] = f.tweenEasing
					return list
				}
				if len(timeline.translateFrame) > 0 {
					tr := track(&clip, path, "position")
					tr.step = steps(easings(timeline.translateFrame))
					time: f32
					for f in timeline.translateFrame {
						key(tr, time / frameRate, fmt.tprintf("%v, %v", t.x + f.x, t.y + f.y), f.tweenEasing)
						time += f32(f.duration)
					}
				}
				if len(timeline.rotateFrame) > 0 {
					tr := track(&clip, path, "rotation")
					tr.step = steps(easings(timeline.rotateFrame))
					time: f32
					for f in timeline.rotateFrame {
						key(tr, time / frameRate, fmt.tprintf("%v", t.skY + f.rotate), f.tweenEasing)
						time += f32(f.duration)
					}
				}
				if len(timeline.scaleFrame) > 0 {
					tr := track(&clip, path, "scale")
					tr.step = steps(easings(timeline.scaleFrame))
					time: f32
					for f in timeline.scaleFrame {
						sx, sy := (t.scX.? or_else 1) * (f.x.? or_else 1), (t.scY.? or_else 1) * (f.y.? or_else 1)
						key(tr, time / frameRate, fmt.tprintf("%v, %v", sx, sy), f.tweenEasing)
						time += f32(f.duration)
					}
				}
				// DragonBones 5.0's single "frame" timeline: transforms as offsets
				if len(timeline.frame) > 0 {
					pos := track(&clip, path, "position")
					rot := track(&clip, path, "rotation")
					scl := track(&clip, path, "scale")
					time: f32
					for f in timeline.frame {
						ft := f.transform
						key(pos, time / frameRate, fmt.tprintf("%v, %v", t.x + ft.x, t.y + ft.y), f.tweenEasing)
						key(rot, time / frameRate, fmt.tprintf("%v", t.skY + ft.skY), f.tweenEasing)
						key(scl, time / frameRate, fmt.tprintf("%v, %v", (t.scX.? or_else 1) * (ft.scX.? or_else 1), (t.scY.? or_else 1) * (ft.scY.? or_else 1)), f.tweenEasing)
						time += f32(f.duration)
					}
				}
			}
			if len(anim.slot) > 0 do append(&warnings, fmt.tprintf("animation %s changes slots (displays, colors): not converted", anim.name))
			if len(anim.ffd) > 0 || len(anim.deform) > 0 do append(&warnings, fmt.tprintf("animation %s moves mesh vertices: not converted", anim.name))
			append(&settings.clips, clip)
		}
		// It starts with the armature's default animation, else the first
		if len(arm.defaultActions) > 0 && arm.defaultActions[0].gotoAndPlay != "" {
			settings.autoplay = strings.clone(arm.defaultActions[0].gotoAndPlay)
		} else {
			settings.autoplay = strings.clone(arm.animation[0].name)
		}
		items[a].data.animator = settings
	}
	if len(arm.ik) > 0 do append(&warnings, fmt.tprintf("%d IK constraints: not converted (add IKChain nodes)", len(arm.ik)))

	// Depth-first, as scene data is stored
	result.component = SceneData{name = strings.clone(items[root].data.name), nodes = make([dynamic]SceneNodeData)}
	emit :: proc(items: []Item, i, parent: int, out: ^[dynamic]SceneNodeData) {
		n := items[i].data
		n.parent = parent
		append(out, n)
		here := len(out) - 1
		for c in items[i].children do emit(items, c, here, out)
	}
	emit(items[:], root, -1, &result.component.nodes)
	result.warnings = warnings[:]
	return result, true
}

// INTERNAL

@(private="file")
dbEase :: proc(easing: Maybe(f32)) -> EaseType {
	e, tween := easing.?
	if !tween || e == 0 do return .Linear
	// Flash's easing: -1..0 eases in, 0..1 out, 2 both
	if e >= 2 do return .InOutQuad
	return e < 0 ? .InQuad : .OutQuad
}

@(private="file")
dbTransform :: struct {
	x, y, skX, skY: f32,
	scX, scY: Maybe(f32),
}

@(private="file")
dbFrame :: struct {
	duration: int,
	tweenEasing: Maybe(f32),
	x, y, rotate: f32,
	transform: dbTransform,
}

// A scale frame: x and y multiply (absent: 1)
@(private="file")
dbScaleFrame :: struct {
	duration: int,
	tweenEasing: Maybe(f32),
	x, y: Maybe(f32),
}

@(private="file")
dbDisplay :: struct {
	name, path, type: string,
	transform: dbTransform,
	vertices, uvs, weights, slotPose, bonePose: []f32,
	triangles: []int,
	width, height: f32,
}

@(private="file")
dbSkinSlot :: struct {
	name: string,
	display: []dbDisplay,
}

@(private="file")
dbFile :: struct {
	name, version: string,
	frameRate: int,
	armature: []struct {
		name: string,
		frameRate: int,
		bone: []struct { name, parent: string, length: f32, transform: dbTransform },
		slot: []struct { name, parent: string, displayIndex: Maybe(int) },
		skin: []struct { name: string, slot: []dbSkinSlot },
		animation: []struct {
			name: string,
			duration, playTimes: int,
			bone: []struct {
				name: string,
				translateFrame, rotateFrame, frame: []dbFrame,
				scaleFrame: []dbScaleFrame,
			},
			slot, ffd, deform: []json.Value,
		},
		ik: []json.Value,
		defaultActions: []struct { gotoAndPlay: string },
	},
}

@(private="file")
dbAtlas :: struct {
	name, imagePath: string,
	width, height: int,
	SubTexture: []struct {
		name: string,
		x, y, width, height: int,
		frameX, frameY, frameWidth, frameHeight: Maybe(int),
		rotated: bool,
	},
}
