#+build !js
package crossfire

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"

/*
The engine against Aseprite itself: every file of testdata/aseprite/conformance was written by
Aseprite 1.3.17 (make.lua: every blend mode, groups with z-index, indexed, grayscale, background,
frames and tags of every direction with repeats, tilemaps with every flip, user data, slices, a
noisy image), and every frame exported by it as PNG (its frames and tags as JSON). Each frame must
come out byte for byte (transparent pixels aside), and each duration and tag the same.
tools/aseprite_conformance.sh makes them again.
*/
@(test)
aseprite_matches_aseprite :: proc(t: ^testing.T) {
	dir := "testdata/aseprite/conformance"
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expect(t, err == nil, "the cases")
	checked := 0
	for entry in entries {
		if !strings.has_suffix(entry.name, ".aseprite") do continue
		name := filepath.stem(entry.name)
		data, _ := os.read_entire_file(entry.fullpath, context.temp_allocator)
		ase, parseErr := Aseprite_Parse(data)
		testing.expectf(t, parseErr == .None, "%s: %v", name, parseErr)
		if ase == nil do continue
		defer Aseprite_Destroy(ase)
		for f in 0..<len(ase.frames) {
			loaded := img.Load(strings.clone_to_cstring(JoinPath(dir, strings.concatenate({name, "_", fmtInt(f), ".png"}, context.temp_allocator)), context.temp_allocator))
			testing.expectf(t, loaded != nil, "%s frame %d: Aseprite's export", name, f)
			if loaded == nil do continue
			ref := sdl.ConvertSurface(loaded, .RGBA32)
			sdl.DestroySurface(loaded)
			defer sdl.DestroySurface(ref)
			testing.expectf(t, int(ref.w) == ase.width && int(ref.h) == ase.height, "%s: its size", name)
			ours := Aseprite_FramePixels(ase, f, context.temp_allocator)
			pixels := ([^]u8)(ref.pixels)
			differ := 0
			for y in 0..<ase.height do for x in 0..<ase.width {
				a := ours[(y * ase.width + x) * 4:][:4]
				b := pixels[y * int(ref.pitch) + x * 4:][:4]
				if a[3] == 0 && b[3] == 0 do continue
				if a[0] != b[0] || a[1] != b[1] || a[2] != b[2] || a[3] != b[3] do differ += 1
			}
			testing.expectf(t, differ == 0, "%s frame %d: %d pixels differ from Aseprite's", name, f, differ)
		}
		// Durations and tags, as Aseprite exported them
		text, readErr := os.read_entire_file(JoinPath(dir, strings.concatenate({name, ".json"}, context.temp_allocator)), context.temp_allocator)
		if readErr != nil do continue
		value, jsonErr := json.parse(text, allocator = context.temp_allocator)
		if jsonErr != nil do continue
		root := value.(json.Object)
		frames := root["frames"].(json.Array)
		testing.expectf(t, len(frames) == len(ase.frames), "%s: %d frames, Aseprite %d", name, len(ase.frames), len(frames))
		for fr, i in frames do if i < len(ase.frames) {
			testing.expectf(t, ase.frames[i].duration == int(fr.(json.Object)["duration"].(json.Float)), "%s frame %d's duration", name, i)
		}
		directions := [AsepriteDirection]string{.Forward = "forward", .Reverse = "reverse", .Ping_Pong = "pingpong", .Ping_Pong_Reverse = "pingpong_reverse"}
		tags, _ := root["meta"].(json.Object)["frameTags"].(json.Array)
		testing.expectf(t, len(tags) == len(ase.tags), "%s: %d tags, Aseprite %d", name, len(ase.tags), len(tags))
		for tag, i in tags do if i < len(ase.tags) {
			o := tag.(json.Object)
			repeat := 0
			if r, ok := o["repeat"].(json.String); ok do repeat, _ = strconv.parse_int(r)
			ours := ase.tags[i]
			testing.expectf(t, ours.name == o["name"].(json.String) && ours.from == int(o["from"].(json.Float)) && ours.to == int(o["to"].(json.Float)) &&
				directions[ours.direction] == o["direction"].(json.String) && ours.repeat == repeat, "%s: tag %d (%v)", name, i, o)
		}
		// Slices: the same order, names and keys
		refSlices, _ := root["meta"].(json.Object)["slices"].(json.Array)
		testing.expectf(t, len(refSlices) == len(ase.slices), "%s: %d slices, Aseprite %d", name, len(ase.slices), len(refSlices))
		for rs, i in refSlices do if i < len(ase.slices) {
			o := rs.(json.Object)
			ours := ase.slices[i]
			testing.expectf(t, ours.name == o["name"].(json.String), "%s: slice %d is %s, Aseprite's %v", name, i, ours.name, o["name"])
			keys := o["keys"].(json.Array)
			testing.expectf(t, len(keys) == len(ours.keys), "%s: slice %s's keys", name, ours.name)
			for k, j in keys do if j < len(ours.keys) {
				b := k.(json.Object)["bounds"].(json.Object)
				got := ours.keys[j]
				testing.expectf(t, got.frame == int(k.(json.Object)["frame"].(json.Float)) && got.bounds == {int(b["x"].(json.Float)), int(b["y"].(json.Float)), int(b["w"].(json.Float)), int(b["h"].(json.Float))},
					"%s: slice %s key %d: %v", name, ours.name, j, got)
			}
		}
		checked += 1
	}
	testing.expectf(t, checked >= 27, "%d cases checked", checked)
	free_all(context.temp_allocator)
}

@(private="file")
fmtInt :: proc(n: int) -> string {
	buffer := make([]u8, 24, context.temp_allocator)
	return strconv.write_int(buffer, i64(n), 10)
}

