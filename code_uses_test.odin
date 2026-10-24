#+build !js
package crossfire

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"
import vmem "core:mem/virtual"

// CODE_USES (code_uses.odin) checked against the package's own source: every procedure a use
// calls exists, and a name goes where the procedure takes that name type. The editor compiles
// every use once more, filled in (its code_drops_test.odin).

// A top-level declaration: a procedure's parameters' types in order, a group's members, a type
@(private="file")
UseDecl :: struct {
	params:  [dynamic]string,
	members: [dynamic]string,
	isType:  bool,
}

@(private="file")
readDecls :: proc(t: ^testing.T) -> map[string]UseDecl {
	decls := make(map[string]UseDecl)
	entries, err := os.read_all_directory_by_path(#directory, context.allocator)
	if !testing.expect(t, err == nil, "the engine's folder reads") do return decls
	for entry in entries {
		if !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") do continue
		data, readErr := os.read_entire_file(entry.fullpath, context.allocator)
		if readErr != nil do continue
		file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
		file.src = string(data)
		file.fullpath = entry.fullpath
		p := parser.default_parser()
		if !parser.parse_file(&p, file) do continue
		for decl in file.decls {
			vd, isValue := decl.derived.(^ast.Value_Decl)
			if !isValue || vd.is_mutable || len(vd.names) != 1 || len(vd.values) != 1 do continue
			ident, isIdent := vd.names[0].derived.(^ast.Ident)
			if !isIdent do continue
			d: UseDecl
			#partial switch v in vd.values[0].derived {
			case ^ast.Proc_Lit:
				if type, ok := v.type.derived.(^ast.Proc_Type); ok && type.params != nil {
					for field in type.params.list {
						typeText := field.type != nil ? file.src[field.type.pos.offset:field.type.end.offset] : ""
						for _ in field.names do append(&d.params, typeText)
					}
				}
			case ^ast.Proc_Group:
				for arg in v.args do if m, ok := arg.derived.(^ast.Ident); ok do append(&d.members, m.name)
			case:
				d.isType = true
			}
			decls[ident.name] = d
		}
	}
	return decls
}

// The arguments of the call starting at `open` (its `(`), split at top-level commas
@(private="file")
callArgs :: proc(code: string, open: int) -> []string {
	args := make([dynamic]string, context.temp_allocator)
	depth, start := 0, open + 1
	for i := open; i < len(code); i += 1 {
		switch code[i] {
		case '(', '{', '[': depth += 1
		case ')', '}', ']':
			depth -= 1
			if depth == 0 {
				append(&args, strings.trim_space(code[start:i]))
				return args[:]
			}
		case ',':
			if depth == 1 {
				append(&args, strings.trim_space(code[start:i]))
				start = i + 1
			}
		}
	}
	return args[:]
}

@(test)
code_uses_call_what_exists :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	decls := readDecls(t)

	firsts := make(map[string]bool)
	for use in CODE_USES {
		testing.expectf(t, use.title != "" && use.code != "", "%s: a use has a title and code", use.on)
		testing.expectf(t, use.kind != .Value || use.var != "", "%s %q: a value has a variable name", use.on, use.title)
		testing.expectf(t, use.node == "" || decls[use.node].isType, "%s %q: its node type %s exists", use.on, use.title, use.node)
		testing.expectf(t, (use.node != "") == strings.contains(use.code, "{node}"), "%s %q: a node type exactly when the code has {node}", use.on, use.title)
		firsts[use.on] = true

		// What it acts on is a type of the package, a field of one, or a dialogue file
		on, _, _ := strings.partition(use.on, ":")
		typeName, _, field := strings.partition(on, ".")
		if on != "Dialogue" {
			testing.expectf(t, decls[typeName].isType, "%s: %s is a type of the engine", use.on, typeName)
		}
		if field != "" {
			id := SCENE_NODE_TYPES[.Node2D]
			if typeName != "Node" do for kind in SceneNodeKind do if SceneNodeKind_IsType(kind, typeName) {
				id = SCENE_NODE_TYPES[kind]
				break
			}
			testing.expectf(t, reflect.struct_field_by_name(id, field).name == field, "%s: the field exists", use.on)
		}

		// Each `e.Procedure(` it calls
		for at := 0; at < len(use.code); {
			i := strings.index(use.code[at:], "e.")
			if i < 0 do break
			start := at + i + 2
			end := start
			for end < len(use.code) && (use.code[end] == '_' || use.code[end] >= 'a' && use.code[end] <= 'z' || use.code[end] >= 'A' && use.code[end] <= 'Z' || use.code[end] >= '0' && use.code[end] <= '9') do end += 1
			at = end
			name := use.code[start:end]
			d, known := decls[name]
			if !testing.expectf(t, known, "%s %q: e.%s exists", use.on, use.title, name) do continue
			if end >= len(use.code) || use.code[end] != '(' do continue
			// The name goes where the procedure takes its name type
			args := callArgs(use.code, end)
			for arg, k in args {
				if !strings.has_prefix(arg, "{name}") || strings.contains(arg, "=") do continue
				candidates := make([dynamic]UseDecl, context.temp_allocator)
				if len(d.members) > 0 {
					for m in d.members do append(&candidates, decls[m])
				} else {
					append(&candidates, d)
				}
				fits := false
				for c in candidates do if k < len(c.params) {
					// A handle's path (`{name}.path`) goes into a path parameter
					fits ||= c.params[k] == on || arg != "{name}" || on == "Dialogue"
				}
				testing.expectf(t, fits, "%s %q: e.%s takes a %s as argument %d", use.on, use.title, name, on, k + 1)
			}
		}
	}
	// Every kind of name has uses (the editor's drops offer them)
	for kind in ([?]string{"AnimationName", "StateName", "StateParamName", "ActionName", "GroupName", "BusName", "SceneName", "ClipName", "DialogueNodeName", "SoundAsset", "MusicAsset", "ComponentAsset", "Node"}) {
		testing.expectf(t, firsts[kind], "%s has uses", kind)
	}
	testing.expect_value(t, len(CodeUses_For("ActionName")), 4)
	testing.expect_value(t, CodeUses_For("ActionName")[0].title, "If it was just pressed")
}
