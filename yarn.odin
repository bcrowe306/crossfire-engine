package crossfire

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

/*
Yarn Spinner files (`.yarn`, yarnspinner.dev, the language version 2) converted into a dialogue
(dialogue.odin), which the engine plays and the editor edits:

- each node (`title:` and `position:` headers, a body between `---` and `===`) becomes a node;
- `Speaker: text` lines become lines (`#tags` dropped, `{$x}` kept), `-> option` groups become
  options: each option's indented body becomes a node of its own (`Title.1`, `Title.2`...), and
  what follows the group a continuation node (`Title.after1`) the option bodies jump to;
- `<<if>>` / `<<elseif>>` / `<<else>>` / `<<endif>>` become conditions on the steps inside them,
  `<<if ...>>` after a line or an option that one's own condition;
- `<<jump X>>`, `<<set $x to expr>>`, `<<stop>>` become jump, set and stop steps; `<<declare $x =
  expr>>` a set on the node's first visit; any other command (`<<wait 1>>`, `<<shake 2>>`) a
  command step.

Not converted (reported): `<<once>>`, line groups (`=>`), smart variables, enums, functions
defined by the game other than the built-in ones (they evaluate as unknown), node groups.
`yarnSpeaker` reads `Name: text`; a colon later in the text isn't a speaker.
*/

/*
Converts a Yarn file into a dialogue.

Inputs:
- text: The .yarn file's contents
- allocator: For the dialogue

Returns:
- The dialogue (free with `DialogueData_Destroy`), what wasn't converted (temp allocated), and
  false when it has no nodes
*/
Yarn_Convert :: proc(text: string, allocator := context.allocator) -> (data: DialogueData, warnings: []string, ok: bool) {
	warn := make([dynamic]string, context.temp_allocator)
	data.nodes = make([dynamic]DialogueNode, allocator)
	lines := strings.split_lines(text, context.temp_allocator)
	i := 0
	count := 0
	for i < len(lines) {
		// Headers until ---
		title := ""
		position: Maybe([2]f32)
		for i < len(lines) && strings.trim_space(lines[i]) != "---" {
			l := strings.trim_space(lines[i])
			i += 1
			key, _, value := strings.partition(l, ":")
			switch strings.trim_space(key) {
			case "title": title = strings.trim_space(value)
			case "position":
				x, _, y := strings.partition(strings.trim_space(value), ",")
				position = [2]f32{strconv.parse_f32(strings.trim_space(x)) or_else 0, strconv.parse_f32(strings.trim_space(y)) or_else 0}
			}
		}
		if i >= len(lines) do break
		i += 1
		body := make([dynamic]string, context.temp_allocator)
		for i < len(lines) && strings.trim_space(lines[i]) != "===" {
			append(&body, lines[i])
			i += 1
		}
		i += 1
		if title == "" do continue
		statements := yarnParseBlock(body[:], &warn)
		c := YarnConverter{data = &data, allocator = allocator, title = title, warnings = &warn}
		first := yarnNewNode(&c, title, position.? or_else {f32(count % 4) * 260, f32(count / 4) * 200})
		c.current = first
		yarnEmit(&c, statements, "")
		count += 1
	}
	if len(data.nodes) > 0 do data.start = strings.clone(data.nodes[0].name, allocator)
	return data, warn[:], len(data.nodes) > 0
}

// INTERNAL

@(private="file")
YarnKind :: enum { Line, Option, Command, If, Jump, Set, Declare, Stop }

// A parsed statement (temp allocated)
@(private="file")
YarnStatement :: struct {
	kind: YarnKind,
	speaker, text, condition: string,
	// Option: its body; If: the branches (condition "" for else) and their bodies
	body: []YarnStatement,
	branches: []YarnBranch,
	// Jump target, Set / Declare variable and expression
	target, variable, expression: string,
}

@(private="file")
YarnBranch :: struct {
	condition: string,
	body: []YarnStatement,
}

@(private="file")
indentOf :: proc(line: string) -> int {
	n := 0
	for c in line {
		if c == ' ' do n += 1
		else if c == '\t' do n += 4
		else do break
	}
	return n
}

// Splits "text <<if cond>> #tag" into the text, its condition, dropping tags
@(private="file")
yarnTail :: proc(line: string) -> (text, condition: string) {
	text = line
	if at := strings.index(text, "<<if "); at >= 0 {
		end := strings.index(text[at:], ">>")
		if end > 0 do condition = strings.trim_space(text[at + 5:at + end])
		text = text[:at]
	}
	// Hashtags at the end: #line:abc #lastline
	words := strings.fields(text, context.temp_allocator)
	keep := len(words)
	for keep > 0 && strings.has_prefix(words[keep - 1], "#") do keep -= 1
	if keep < len(words) {
		cut := strings.index(text, words[keep])
		if cut >= 0 do text = text[:cut]
	}
	return strings.trim_space(text), condition
}

// "Name: text" -> Name, text; no speaker when there's no colon before the text
@(private="file")
yarnSpeaker :: proc(line: string) -> (speaker, text: string) {
	colon := strings.index_byte(line, ':')
	if colon <= 0 || strings.contains(line[:colon], "{") || strings.contains(line[:colon], "<<") do return "", line
	return strings.trim_space(line[:colon]), strings.trim_space(line[colon + 1:])
}

// Parses lines (their indentation relative to the first) into statements
@(private="file")
yarnParseBlock :: proc(lines: []string, warn: ^[dynamic]string) -> []YarnStatement {
	out := make([dynamic]YarnStatement, context.temp_allocator)
	i := 0
	for i < len(lines) {
		raw := lines[i]
		l := strings.trim_space(raw)
		if l == "" || strings.has_prefix(l, "//") {
			i += 1
			continue
		}
		indent := indentOf(raw)
		switch {
		case strings.has_prefix(l, "->"):
			// An option: its body is the following lines indented further
			text, cond := yarnTail(strings.trim_space(l[2:]))
			j := i + 1
			for j < len(lines) && (strings.trim_space(lines[j]) == "" || indentOf(lines[j]) > indent) do j += 1
			append(&out, YarnStatement{kind = .Option, text = text, condition = cond, body = yarnParseBlock(lines[i + 1:j], warn)})
			i = j
		case strings.has_prefix(l, "=>"):
			append(warn, fmt.tprintf("line groups (=>) aren't converted: %s", l))
			i += 1
		case strings.has_prefix(l, "<<if "):
			// Branches until the matching <<endif>> (nested ifs counted)
			branches := make([dynamic]YarnBranch, context.temp_allocator)
			condition := strings.trim_space(strings.trim_suffix(l[5:], ">>"))
			start := i + 1
			depth := 0
			j := i + 1
			for ; j < len(lines); j += 1 {
				t := strings.trim_space(lines[j])
				if strings.has_prefix(t, "<<if ") do depth += 1
				if depth > 0 {
					if strings.has_prefix(t, "<<endif") do depth -= 1
					continue
				}
				if strings.has_prefix(t, "<<elseif ") || strings.has_prefix(t, "<<else>>") || strings.has_prefix(t, "<<endif") {
					append(&branches, YarnBranch{condition, yarnParseBlock(lines[start:j], warn)})
					start = j + 1
					if strings.has_prefix(t, "<<elseif ") do condition = strings.trim_space(strings.trim_suffix(t[9:], ">>"))
					else if strings.has_prefix(t, "<<else>>") do condition = ""
					else do break
				}
			}
			append(&out, YarnStatement{kind = .If, branches = branches[:]})
			i = j + 1
		case strings.has_prefix(l, "<<"):
			inner := strings.trim_space(strings.trim_suffix(strings.trim_prefix(l, "<<"), ">>"))
			word, _, rest := strings.partition(inner, " ")
			rest = strings.trim_space(rest)
			switch word {
			case "jump":
				append(&out, YarnStatement{kind = .Jump, target = rest})
			case "stop":
				append(&out, YarnStatement{kind = .Stop})
			case "set", "declare":
				// "$x to 5", "$x = 5"
				name, value := rest, ""
				if at := strings.index(rest, " to "); at >= 0 {
					name, value = rest[:at], rest[at + 4:]
				} else if at := strings.index_byte(rest, '='); at >= 0 {
					name, value = rest[:at], rest[at + 1:]
				}
				// A declare's type ("as Number") isn't needed
				if at := strings.index(value, " as "); at >= 0 do value = value[:at]
				append(&out, YarnStatement{kind = word == "set" ? .Set : .Declare, variable = strings.trim_space(name), expression = strings.trim_space(value)})
			case "once", "endonce", "enum", "endenum", "case":
				append(warn, fmt.tprintf("<<%s>> isn't converted", word))
			case:
				append(&out, YarnStatement{kind = .Command, text = inner})
			}
			i += 1
		case:
			text, cond := yarnTail(l)
			speaker, said := yarnSpeaker(text)
			append(&out, YarnStatement{kind = .Line, speaker = speaker, text = said, condition = cond})
			i += 1
		}
	}
	return out[:]
}

@(private="file")
YarnConverter :: struct {
	data: ^DialogueData,
	allocator: mem.Allocator,
	title: string,
	// The node steps go into now
	current: int,
	// Generated nodes so far for this title
	generated: int,
	warnings: ^[dynamic]string,
}

@(private="file")
yarnNewNode :: proc(c: ^YarnConverter, name: string, position: [2]f32) -> int {
	append(&c.data.nodes, DialogueNode{name = strings.clone(name, c.allocator), position = position, steps = make([dynamic]DialogueStep, c.allocator)})
	return len(c.data.nodes) - 1
}

@(private="file")
yarnAnd :: proc(a, b: string) -> string {
	if a == "" do return b
	if b == "" do return a
	return fmt.tprintf("(%s) and (%s)", a, b)
}

@(private="file")
yarnStep :: proc(c: ^YarnConverter, step: DialogueStep) {
	append(&c.data.nodes[c.current].steps, step)
}

// Emits statements into the current node, each under `condition`
@(private="file")
yarnEmit :: proc(c: ^YarnConverter, statements: []YarnStatement, condition: string) {
	a := c.allocator
	i := 0
	for i < len(statements) {
		s := statements[i]
		switch s.kind {
		case .Line:
			yarnStep(c, {kind = .Line, speaker = strings.clone(s.speaker, a), text = strings.clone(s.text, a), condition = strings.clone(yarnAnd(condition, s.condition), a)})
		case .Option:
			// The group: this option and those right after it
			group := make([dynamic]YarnStatement, context.temp_allocator)
			for i < len(statements) && statements[i].kind == .Option {
				append(&group, statements[i])
				i += 1
			}
			i -= 1
			c.generated += 1
			base := c.data.nodes[c.current].position
			after := fmt.tprintf("%s.after%d", c.title, c.generated)
			options := make([dynamic]DialogueOption, a)
			bodies := make([dynamic]int, context.temp_allocator)
			for o, k in group {
				target := after
				if len(o.body) > 0 {
					target = fmt.tprintf("%s.%d.%d", c.title, c.generated, k + 1)
					append(&bodies, k)
				}
				append(&options, DialogueOption{strings.clone(o.text, a), strings.clone(target, a), strings.clone(o.condition, a)})
			}
			yarnStep(c, {kind = .Options, options = options, condition = strings.clone(condition, a)})
			// Skipped (its condition false): straight on
			yarnStep(c, {kind = .Jump, target = strings.clone(after, a)})
			for k, row in bodies {
				node := yarnNewNode(c, fmt.tprintf("%s.%d.%d", c.title, c.generated, k + 1), base + {f32(row) * 220 - 110, 160})
				c.current = node
				yarnEmit(c, group[k].body, "")
				yarnStep(c, {kind = .Jump, target = strings.clone(after, a)})
			}
			c.current = yarnNewNode(c, after, base + {0, 320})
		case .If:
			// Each branch: its condition, and none of the earlier ones
			earlier := ""
			for b in s.branches {
				own := b.condition != "" ? yarnAnd(earlier == "" ? "" : fmt.tprintf("not (%s)", earlier), b.condition) : (earlier == "" ? "" : fmt.tprintf("not (%s)", earlier))
				yarnEmit(c, b.body, yarnAnd(condition, own))
				if b.condition != "" do earlier = earlier == "" ? b.condition : fmt.tprintf("(%s) or (%s)", earlier, b.condition)
			}
		case .Command:
			yarnStep(c, {kind = .Command, command = strings.clone(s.text, a), condition = strings.clone(condition, a)})
		case .Jump:
			yarnStep(c, {kind = .Jump, target = strings.clone(s.target, a), condition = strings.clone(condition, a)})
		case .Set:
			yarnStep(c, {kind = .Set, variable = strings.clone(s.variable, a), expression = strings.clone(s.expression, a), condition = strings.clone(condition, a)})
		case .Declare:
			// An initial value: set the first time this node runs
			first := fmt.tprintf("visited_count(\"%s\") <= 1", c.title)
			yarnStep(c, {kind = .Set, variable = strings.clone(s.variable, a), expression = strings.clone(s.expression, a), condition = strings.clone(yarnAnd(condition, first), a)})
		case .Stop:
			yarnStep(c, {kind = .Stop, condition = strings.clone(condition, a)})
		}
		i += 1
	}
}
