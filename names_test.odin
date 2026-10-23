#+build !js
package crossfire

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"
import "core:testing"
import vmem "core:mem/virtual"

// The name types (names.odin) checked against this package's own source, as the editor reads
// them: every type is an alias of string, the procedures taking names use them, and no public
// procedure takes such a name as a plain string.

// The name types, as names.odin declares them
@(private="file")
NAME_TYPES := [?]string{
	"NodePath", "ChildPath", "ScenePath", "AnimationName", "ActionName", "GroupName", "BusName",
	"SceneName", "StateName", "StateParamName", "ClipName", "DialogueNodeName", "AchievementName",
	"SoundPath",
}

// A procedure's parameter as written: its type ("" when only a default gives it) and default
@(private="file")
SourceParam :: struct {
	procName, name, type, value: string,
	private: bool,
}

// Every top-level procedure parameter and type alias of the package's files (not tests)
@(private="file")
readSource :: proc(t: ^testing.T, allocator := context.allocator) -> (params: [dynamic]SourceParam, aliases: map[string]string) {
	context.allocator = allocator
	params = make([dynamic]SourceParam)
	aliases = make(map[string]string)
	entries, err := os.read_all_directory_by_path(#directory, context.allocator)
	if !testing.expect(t, err == nil, "the engine's folder reads") do return
	for entry in entries {
		if !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") do continue
		data, readErr := os.read_entire_file(entry.fullpath, context.allocator)
		if readErr != nil do continue
		file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
		file.src = string(data)
		file.fullpath = entry.fullpath
		p := parser.default_parser()
		testing.expectf(t, parser.parse_file(&p, file), "%s parses", entry.name)
		filePrivate := strings.contains(string(data), "#+private")
		for decl in file.decls {
			vd, isValue := decl.derived.(^ast.Value_Decl)
			if !isValue || vd.is_mutable || len(vd.names) != 1 || len(vd.values) != 1 do continue
			ident, isIdent := vd.names[0].derived.(^ast.Ident)
			if !isIdent do continue
			private := filePrivate
			for attr in vd.attributes do for elem in attr.elems {
				text := file.src[elem.pos.offset:elem.end.offset]
				if strings.has_prefix(text, "private") do private = true
			}
			#partial switch v in vd.values[0].derived {
			case ^ast.Ident:
				aliases[ident.name] = v.name
			case ^ast.Proc_Lit:
				type, ok := v.type.derived.(^ast.Proc_Type)
				if !ok || type.params == nil do continue
				for field in type.params.list {
					typeText := field.type != nil ? file.src[field.type.pos.offset:field.type.end.offset] : ""
					value := field.default_value != nil ? file.src[field.default_value.pos.offset:field.default_value.end.offset] : ""
					for name in field.names {
						if n, isName := name.derived.(^ast.Ident); isName {
							append(&params, SourceParam{ident.name, n.name, typeText, value, private || strings.has_prefix(ident.name, "_")})
						}
					}
				}
			}
		}
	}
	return
}

@(test)
name_types_are_string_aliases_and_procedures_use_them :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	params, aliases := readSource(t, vmem.arena_allocator(&arena))

	for name in NAME_TYPES {
		testing.expectf(t, aliases[name] == "string", "%s is an alias of string (got %q)", name, aliases[name])
	}

	// What the editor completes and checks, a few per name type (it reads them all)
	Expected :: struct { procName, param, type: string }
	expected := [?]Expected{
		{"Node_FindPath", "path", "NodePath"},
		{"Camera2D_SetFollowTargetPath", "path", "NodePath"},
		{"Node_FindChild", "path", "ChildPath"},
		{"Scene_FindNode", "path", "ScenePath"},
		{"AnimationPlayer_PlayByName", "name", "AnimationName"},
		{"AnimatedSprite_UseAnimations", "autoplay", "AnimationName"},
		{"Input_IsActionJustPressed", "name", "ActionName"},
		{"Input_GetVector", "positiveY", "ActionName"},
		{"Player_GetAxis", "negative", "ActionName"},
		{"Input_AddAction", "name", "ActionName"},
		{"Scene_GetGroup", "group", "GroupName"},
		{"Node_AddToGroup", "group", "GroupName"},
		{"Audio_SetBusVolume", "name", "BusName"},
		{"Game_PlaySoundFile", "bus", "BusName"},
		{"Game_PlaySoundAsset", "bus", "BusName"},
		{"Game_PlaySoundFile", "path", "SoundPath"},
		{"Game_ChangeScene", "name", "SceneName"},
		{"Game_PushScene", "name", "SceneName"},
		{"StateMachine_Is", "state", "StateName"},
		{"StateMachine_Travel", "state", "StateName"},
		{"StateMachine_SetTrigger", "name", "StateParamName"},
		{"Animator_Play", "name", "ClipName"},
		{"Dialogue_Start", "node", "DialogueNodeName"},
		{"DialogueBox_Start", "node", "DialogueNodeName"},
		{"Steam_UnlockAchievement", "name", "AchievementName"},
	}
	for want in expected {
		found := false
		for p in params do if p.procName == want.procName && p.name == want.param {
			found = true
			testing.expectf(t, p.type == want.type, "%s's %s is a %s (got %q)", want.procName, want.param, want.type, p.type)
		}
		testing.expectf(t, found, "%s has a parameter %s", want.procName, want.param)
	}

	// Names that always mean one of the kinds: a public procedure taking one as a plain string
	// (or by a default alone) has to use the name type
	Means :: struct { param, type: string }
	MEANS :: [?]Means{
		{"action", "ActionName"}, {"bus", "BusName"}, {"group", "GroupName"}, {"state", "StateName"},
		{"startNode", "DialogueNodeName"}, {"autoplay", "AnimationName"},
	}
	// Where the parameter isn't such a name
	EXCEPTIONS :: [?]string{
		// "scene:Name", "push:Name", "pop", "quit": a menu action, not an input action
		"Game_RunAction.action",
		"CreateButton.action",
	}
	for p in params {
		if p.private do continue
		want := ""
		for m in MEANS do if m.param == p.name do want = m.type
		if want == "" do continue
		key := fmt.tprintf("%s.%s", p.procName, p.name)
		excepted := false
		for x in EXCEPTIONS do if x == key do excepted = true
		if excepted do continue
		plain := p.type == "string" || p.type == "" && strings.has_prefix(p.value, "\"")
		testing.expectf(t, !plain, "%s takes a %s: give it that type (names.odin)", key, want)
	}
}
