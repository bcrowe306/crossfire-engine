package crossfire

import "core:encoding/xml"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:strconv"
import "core:strings"

/*
Dialogue: conversations as data, played by a runner and shown by a DialogueBox node
(dialogue_box.odin).

A **dialogue** (an asset of kind "Dialogue", a `.dialogue.xml` file; Yarn Spinner's `.yarn` files
convert into one: yarn.odin) is a set of named **nodes**, each a list of **steps**:

| Step | Does |
|---|---|
| Line | someone says something: `speaker`, `text` (`{$gold}` puts a variable in) |
| Options | the player chooses: each option's `text` and the node it goes `next` to |
| Jump | goes on in another node |
| Set | sets a variable: `var="$gold" value="$gold - 5"` |
| Command | tells the game something (`<<shake 2>>`): the box's `onCommand` event; `wait 1` pauses |
| Stop | ends the conversation |

Every step (and option) can have a condition (`if="$gold >= 5 and not visited(\"Shop\")"`): it
runs (or shows) only when true. A node that runs out of steps ends the conversation.

	<dialogue formatVersion="13" start="Start">
		<node name="Start" x="0" y="0">
			<line speaker="Guide" text="Welcome! You have {$gold} gold."/>
			<options>
				<option text="Buy a sword" next="Buy" if="$gold >= 5"/>
				<option text="Goodbye" next="End"/>
			</options>
		</node>
		<node name="Buy" x="240" y="0">
			<set var="$gold" value="$gold - 5"/>
			<command text="give sword"/>
			<line speaker="Guide" text="Here you go."/>
		</node>
	</dialogue>

**Expressions** are Yarn's: numbers, "strings", true / false, `$variables` (unset: 0), `+ - * / %`,
`== != < <= > >=` (also `is eq neq lt lte gt gte`), `and or not` (also `&& || !`), parentheses,
and the functions `visited("Node")`, `visited_count("Node")`, `random()`, `random_range(a, b)`,
`dice(sides)`.

A **DialogueRunner** plays one: `Dialogue_Start`, then `Dialogue_Continue` after each line and
`Dialogue_Choose` at options; its `state` says what to show. Variables (`DialogueVariables`) are a game's
(`Game.dialogueVariables`: every DialogueBox shares them, so `$met_guide` set in one conversation
is true in the next) or a runner's own; `Dialogue_SetVariable` / `GetVariable`, or
`DialogueVariables_Set` / `Get` from scripts.
*/

// A dialogue file's extension
DIALOGUE_EXTENSION :: ".dialogue.xml"

// What a step does
DialogueStepKind :: enum {
	Line,
	Options,
	Jump,
	Set,
	Command,
	Stop,
}

// A choice of an Options step
DialogueOption :: struct {
	text: string,
	// The node it goes to ("": the conversation ends)
	target: string,
	// Shown only when true ("": always)
	condition: string,
}

// One step of a node (the fields its kind uses)
DialogueStep :: struct {
	kind: DialogueStepKind,
	// Runs only when true ("": always)
	condition: string,
	// Line: who says it ("": nobody: narration) and what
	speaker, text: string,
	// Options: the choices
	options: [dynamic]DialogueOption,
	// Jump: the node to go on in
	target: string,
	// Set: the variable ("$gold") and the expression it's set to
	variable, expression: string,
	// Command: its text ("shake 2")
	command: string,
}

// A node: its steps, run in order
DialogueNode :: struct {
	name: string,
	// Where editors draw it in the graph
	position: [2]f32,
	steps: [dynamic]DialogueStep,
}

// A dialogue (`ParseDialogue`; free with `DialogueData_Destroy`)
DialogueData :: struct {
	// The node conversations start in ("": the first)
	start: string,
	nodes: [dynamic]DialogueNode,
}

// A value of an expression or variable
DialogueValue :: union {
	f64,
	bool,
	string,
}

// What a runner is waiting for
DialogueState :: enum {
	// Not started, or finished
	Idle,
	// A line shows: `Dialogue_Continue` after it
	Line,
	// Options show: `Dialogue_Choose`
	Options,
	// A command came: the game does it, then `Dialogue_Continue`
	Command,
	// It ended (a Stop, a node out of steps, an option to nowhere)
	Finished,
}

// An option as shown (its condition held)
DialogueShownOption :: struct {
	text: string,
	// Its index in the step (Dialogue_Choose takes the shown index)
	index: int,
}

// Dialogue variables ("$gold") and how often each node was entered (by name)
DialogueVariables :: struct {
	values: map[string]DialogueValue,
	visits: map[string]int,
	allocator: mem.Allocator,
}

// Plays a dialogue
DialogueRunner :: struct {
	data: ^DialogueData,
	state: DialogueState,
	// Where it is: a node's index and the next step in it
	node, step: int,
	// What shows now (its strings live until the next Continue or Choose)
	speaker, text: string,
	options: [dynamic]DialogueShownOption,
	// The command waiting (State Command)
	command: string,
	// Its variables and node visits: shared (a game's, `Game.dialogueVariables`, which every
	// DialogueBox uses), or nil for its own (`own`)
	shared: ^DialogueVariables,
	own: DialogueVariables,
	// The Options step showing (for Choose)
	optionsStep: int,
	allocator: mem.Allocator,
}

/*
Reads a dialogue file.

Inputs:
- text: The file's contents
- allocator: For the dialogue's strings and lists

Returns:
- The dialogue (free with `DialogueData_Destroy`), or an error
*/
ParseDialogue :: proc(text: string, allocator := context.allocator) -> (DialogueData, ProjectError) {
	doc, err := xml.parse_string(text)
	if err != .None do return {}, .Invalid_XML
	defer xml.destroy(doc)
	if doc.element_count == 0 || doc.elements[0].ident != "dialogue" do return {}, .Wrong_Root
	data := DialogueData{nodes = make([dynamic]DialogueNode, allocator)}
	get :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string, allocator: mem.Allocator) -> string {
		v, _ := xml.find_attribute_val_by_key(doc, id, key)
		return strings.clone(v, allocator)
	}
	num :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string) -> f32 {
		v, _ := xml.find_attribute_val_by_key(doc, id, key)
		return strconv.parse_f32(v) or_else 0
	}
	if version, found := xml.find_attribute_val_by_key(doc, 0, "formatVersion"); found {
		if v, ok := strconv.parse_int(version); ok && v > PROJECT_FORMAT_VERSION do return {}, .Unsupported_Version
	}
	data.start = get(doc, 0, "start", allocator)
	for child in doc.elements[0].value {
		nodeId, isElement := child.(xml.Element_ID)
		if !isElement || doc.elements[nodeId].ident != "node" do continue
		node := DialogueNode{name = get(doc, nodeId, "name", allocator), position = {num(doc, nodeId, "x"), num(doc, nodeId, "y")}, steps = make([dynamic]DialogueStep, allocator)}
		for s in doc.elements[nodeId].value {
			id, isStep := s.(xml.Element_ID)
			if !isStep do continue
			step := DialogueStep{condition = get(doc, id, "if", allocator)}
			switch doc.elements[id].ident {
			case "line":
				step.kind = .Line
				step.speaker, step.text = get(doc, id, "speaker", allocator), get(doc, id, "text", allocator)
			case "options":
				step.kind = .Options
				step.options = make([dynamic]DialogueOption, allocator)
				for o in doc.elements[id].value {
					oid, isOption := o.(xml.Element_ID)
					if !isOption || doc.elements[oid].ident != "option" do continue
					append(&step.options, DialogueOption{get(doc, oid, "text", allocator), get(doc, oid, "next", allocator), get(doc, oid, "if", allocator)})
				}
			case "jump":
				step.kind = .Jump
				step.target = get(doc, id, "next", allocator)
			case "set":
				step.kind = .Set
				step.variable, step.expression = get(doc, id, "var", allocator), get(doc, id, "value", allocator)
			case "command":
				step.kind = .Command
				step.command = get(doc, id, "text", allocator)
			case "stop":
				step.kind = .Stop
			case:
				delete(step.condition, allocator)
				continue
			}
			append(&node.steps, step)
		}
		append(&data.nodes, node)
	}
	return data, .None
}

/*
Writes a dialogue file.

Returns:
- The text (in `allocator`)
*/
FormatDialogue :: proc(data: DialogueData, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "<dialogue formatVersion=\"%d\"", PROJECT_FORMAT_VERSION)
	if data.start != "" do fmt.sbprintf(&b, " start=\"%s\"", dialogueEscape(data.start))
	strings.write_string(&b, ">\n")
	cond :: proc(b: ^strings.Builder, condition: string) {
		if condition != "" do fmt.sbprintf(b, " if=\"%s\"", dialogueEscape(condition))
	}
	for n in data.nodes {
		fmt.sbprintf(&b, "\t<node name=\"%s\" x=\"%v\" y=\"%v\">\n", dialogueEscape(n.name), n.position.x, n.position.y)
		for s in n.steps {
			strings.write_string(&b, "\t\t")
			switch s.kind {
			case .Line:
				strings.write_string(&b, "<line")
				if s.speaker != "" do fmt.sbprintf(&b, " speaker=\"%s\"", dialogueEscape(s.speaker))
				fmt.sbprintf(&b, " text=\"%s\"", dialogueEscape(s.text))
				cond(&b, s.condition)
				strings.write_string(&b, "/>\n")
			case .Options:
				strings.write_string(&b, "<options")
				cond(&b, s.condition)
				strings.write_string(&b, ">\n")
				for o in s.options {
					fmt.sbprintf(&b, "\t\t\t<option text=\"%s\" next=\"%s\"", dialogueEscape(o.text), dialogueEscape(o.target))
					cond(&b, o.condition)
					strings.write_string(&b, "/>\n")
				}
				strings.write_string(&b, "\t\t</options>\n")
			case .Jump:
				fmt.sbprintf(&b, "<jump next=\"%s\"", dialogueEscape(s.target))
				cond(&b, s.condition)
				strings.write_string(&b, "/>\n")
			case .Set:
				fmt.sbprintf(&b, "<set var=\"%s\" value=\"%s\"", dialogueEscape(s.variable), dialogueEscape(s.expression))
				cond(&b, s.condition)
				strings.write_string(&b, "/>\n")
			case .Command:
				fmt.sbprintf(&b, "<command text=\"%s\"", dialogueEscape(s.command))
				cond(&b, s.condition)
				strings.write_string(&b, "/>\n")
			case .Stop:
				strings.write_string(&b, "<stop")
				cond(&b, s.condition)
				strings.write_string(&b, "/>\n")
			}
		}
		strings.write_string(&b, "\t</node>\n")
	}
	strings.write_string(&b, "</dialogue>\n")
	return strings.to_string(b)
}

// A copy of a dialogue (in `allocator`)
DialogueData_Clone :: proc(data: DialogueData, allocator := context.allocator) -> DialogueData {
	out := DialogueData{start = strings.clone(data.start, allocator), nodes = make([dynamic]DialogueNode, 0, len(data.nodes), allocator)}
	for n in data.nodes {
		node := DialogueNode{name = strings.clone(n.name, allocator), position = n.position, steps = make([dynamic]DialogueStep, 0, len(n.steps), allocator)}
		for s in n.steps do append(&node.steps, DialogueStep_Clone(s, allocator))
		append(&out.nodes, node)
	}
	return out
}

// A copy of a step (in `allocator`)
DialogueStep_Clone :: proc(s: DialogueStep, allocator := context.allocator) -> DialogueStep {
	c := s
	c.condition = strings.clone(s.condition, allocator)
	c.speaker, c.text = strings.clone(s.speaker, allocator), strings.clone(s.text, allocator)
	c.target = strings.clone(s.target, allocator)
	c.variable, c.expression = strings.clone(s.variable, allocator), strings.clone(s.expression, allocator)
	c.command = strings.clone(s.command, allocator)
	c.options = {}
	if s.kind == .Options {
		c.options = make([dynamic]DialogueOption, 0, len(s.options), allocator)
		for o in s.options do append(&c.options, DialogueOption{strings.clone(o.text, allocator), strings.clone(o.target, allocator), strings.clone(o.condition, allocator)})
	}
	return c
}

// Frees a step's strings
DialogueStep_Destroy :: proc(s: ^DialogueStep, allocator := context.allocator) {
	delete(s.condition, allocator)
	delete(s.speaker, allocator)
	delete(s.text, allocator)
	delete(s.target, allocator)
	delete(s.variable, allocator)
	delete(s.expression, allocator)
	delete(s.command, allocator)
	for o in s.options {
		delete(o.text, allocator)
		delete(o.target, allocator)
		delete(o.condition, allocator)
	}
	delete(s.options)
	s^ = {}
}

// Frees what ParseDialogue or DialogueData_Clone made
DialogueData_Destroy :: proc(data: ^DialogueData, allocator := context.allocator) {
	delete(data.start, allocator)
	for &n in data.nodes {
		delete(n.name, allocator)
		for &s in n.steps do DialogueStep_Destroy(&s, allocator)
		delete(n.steps)
	}
	delete(data.nodes)
	data^ = {}
}

// Whether two dialogues are the same
DialogueData_Equal :: proc(a, b: DialogueData) -> bool {
	if a.start != b.start || len(a.nodes) != len(b.nodes) do return false
	for n, i in a.nodes {
		m := b.nodes[i]
		if n.name != m.name || n.position != m.position || len(n.steps) != len(m.steps) do return false
		for s, k in n.steps {
			t := m.steps[k]
			if s.kind != t.kind || s.condition != t.condition || s.speaker != t.speaker || s.text != t.text || s.target != t.target {
				return false
			}
			if s.variable != t.variable || s.expression != t.expression || s.command != t.command || len(s.options) != len(t.options) {
				return false
			}
			for o, j in s.options do if o != t.options[j] do return false
		}
	}
	return true
}

// A node's index by name (-1 when there's none)
Dialogue_FindNode :: proc(data: ^DialogueData, name: string) -> int {
	if data == nil do return -1
	for n, i in data.nodes do if n.name == name do return i
	return -1
}

/*
Starts a conversation: in `node` (the dialogue's start node when ""), running until the first
line, options, command or its end.

Inputs:
- runner: The runner (its variables kept)
- data: The dialogue (kept by pointer: keep it alive while it plays)
- node: The node to start in

Returns:
- false when there's no such node (the runner is Finished)
*/
Dialogue_Start :: proc(runner: ^DialogueRunner, data: ^DialogueData, node := "") -> bool {
	if runner.allocator.procedure == nil do runner.allocator = context.allocator
	runner.data = data
	name := node != "" ? node : data.start
	index := name != "" ? Dialogue_FindNode(data, name) : (len(data.nodes) > 0 ? 0 : -1)
	if index < 0 {
		runner.state = .Finished
		return false
	}
	dialogueEnter(runner, index)
	return dialogueRun(runner)
}

/*
Goes on after a line or a command, until the next line, options, command or the end.

Returns:
- false when the conversation is over (the runner is Finished)
*/
Dialogue_Continue :: proc(runner: ^DialogueRunner) -> bool {
	if runner.state != .Line && runner.state != .Command do return runner.state != .Finished && runner.state != .Idle
	return dialogueRun(runner)
}

/*
Chooses one of the options showing (its index among `runner.options`) and goes on in its node.

Returns:
- false when it ended there (an option to nowhere), or there are no options showing
*/
Dialogue_Choose :: proc(runner: ^DialogueRunner, shown: int) -> bool {
	if runner.state != .Options || shown < 0 || shown >= len(runner.options) do return false
	step := &runner.data.nodes[runner.node].steps[runner.optionsStep]
	option := step.options[runner.options[shown].index]
	target := Dialogue_FindNode(runner.data, option.target)
	if target < 0 {
		runner.state = .Finished
		return false
	}
	dialogueEnter(runner, target)
	return dialogueRun(runner)
}

// Ends a conversation now
Dialogue_Stop :: proc(runner: ^DialogueRunner) {
	runner.state = .Finished
	clearOptions(runner)
}

// Sets a runner's dialogue variable ("$gold"; a string is copied)
Dialogue_SetVariable :: proc(runner: ^DialogueRunner, name: string, value: DialogueValue) {
	DialogueVariables_Set(dialogueVars(runner), name, value)
}

// A runner's dialogue variable (nil when unset)
Dialogue_GetVariable :: proc(runner: ^DialogueRunner, name: string) -> DialogueValue {
	return dialogueVars(runner).values[name]
}

/*
Sets a dialogue variable ("$gold"; a string is copied).

Example:
	// Given: game: ^e.Game
	e.DialogueVariables_Set(&game.dialogueVariables, "$gold", f64(12))
*/
DialogueVariables_Set :: proc(vars: ^DialogueVariables, name: string, value: DialogueValue) {
	if vars.allocator.procedure == nil do vars.allocator = context.allocator
	if vars.values == nil do vars.values = make(map[string]DialogueValue, vars.allocator)
	key := name
	if old, found := vars.values[name]; found {
		if s, isString := old.(string); isString do delete(s, vars.allocator)
	} else {
		key = strings.clone(name, vars.allocator)
	}
	v := value
	if s, isString := value.(string); isString do v = strings.clone(s, vars.allocator)
	vars.values[key] = v
}

// A dialogue variable (nil when unset)
DialogueVariables_Get :: proc(vars: ^DialogueVariables, name: string) -> DialogueValue {
	return vars.values[name]
}

// Frees dialogue variables
DialogueVariables_Destroy :: proc(vars: ^DialogueVariables) {
	for k, v in vars.values {
		delete(k, vars.allocator)
		if s, isString := v.(string); isString do delete(s, vars.allocator)
	}
	delete(vars.values)
	for k in vars.visits do delete(k, vars.allocator)
	delete(vars.visits)
	vars^ = {}
}

// Frees a runner's variables and lists (not its dialogue)
DialogueRunner_Destroy :: proc(runner: ^DialogueRunner) {
	DialogueVariables_Destroy(&runner.own)
	clearOptions(runner)
	delete(runner.options)
	delete(runner.speaker, runner.allocator)
	delete(runner.text, runner.allocator)
	delete(runner.command, runner.allocator)
	runner^ = {}
}

/*
Evaluates an expression with a runner's variables (nil runner: no variables).

Returns:
- The value, and false (with value nil) when it doesn't parse
*/
Dialogue_Evaluate :: proc(runner: ^DialogueRunner, expression: string) -> (DialogueValue, bool) {
	p := ExprParser{runner = runner, text = expression}
	exprNext(&p)
	v := exprOr(&p)
	if p.failed || p.kind != .End do return nil, false
	return v, true
}

// Whether a value counts as true (nonzero numbers, non-empty strings)
DialogueValue_Truthy :: proc(v: DialogueValue) -> bool {
	switch x in v {
	case f64: return x != 0
	case bool: return x
	case string: return x != ""
	}
	return false
}

// A value as text ("5", "true", "hello"; temp allocated)
DialogueValue_Text :: proc(v: DialogueValue) -> string {
	switch x in v {
	case f64:
		if x == math.trunc(x) && abs(x) < 1e15 do return fmt.tprintf("%d", i64(x))
		return fmt.tprintf("%v", x)
	case bool: return x ? "true" : "false"
	case string: return x
	}
	return "0"
}

/*
A line's text with `{expression}` parts replaced by their values ("You have {$gold} gold").

Returns:
- The text (temp allocated)
*/
Dialogue_Interpolate :: proc(runner: ^DialogueRunner, text: string) -> string {
	if strings.index_byte(text, '{') < 0 do return text
	b := strings.builder_make(context.temp_allocator)
	rest := text
	for len(rest) > 0 {
		open := strings.index_byte(rest, '{')
		if open < 0 {
			strings.write_string(&b, rest)
			break
		}
		close := strings.index_byte(rest[open:], '}')
		if close < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:open])
		v, ok := Dialogue_Evaluate(runner, rest[open + 1:open + close])
		strings.write_string(&b, ok ? DialogueValue_Text(v) : rest[open:open + close + 1])
		rest = rest[open + close + 1:]
	}
	return strings.to_string(b)
}

// INTERNAL

// The variables a runner uses: the shared ones, else its own
@(private="file")
dialogueVars :: proc(runner: ^DialogueRunner) -> ^DialogueVariables {
	return runner.shared != nil ? runner.shared : &runner.own
}

@(private="file")
dialogueEnter :: proc(runner: ^DialogueRunner, node: int) {
	runner.node, runner.step = node, 0
	vars := dialogueVars(runner)
	if vars.allocator.procedure == nil do vars.allocator = runner.allocator
	if vars.visits == nil do vars.visits = make(map[string]int, vars.allocator)
	name := runner.data.nodes[node].name
	if name in vars.visits {
		vars.visits[name] += 1
	} else {
		vars.visits[strings.clone(name, vars.allocator)] = 1
	}
}

// Runs steps until one shows something or the conversation ends
@(private="file")
dialogueRun :: proc(runner: ^DialogueRunner) -> bool {
	clearOptions(runner)
	// A loop of jumps that shows nothing can't hang the game
	for _ in 0 ..< 10000 {
		node := &runner.data.nodes[runner.node]
		if runner.step >= len(node.steps) {
			runner.state = .Finished
			return false
		}
		step := &node.steps[runner.step]
		runner.step += 1
		if step.condition != "" {
			v, ok := Dialogue_Evaluate(runner, step.condition)
			if !ok || !DialogueValue_Truthy(v) do continue
		}
		switch step.kind {
		case .Line:
			setText(runner, &runner.speaker, Dialogue_Interpolate(runner, step.speaker))
			setText(runner, &runner.text, Dialogue_Interpolate(runner, step.text))
			runner.state = .Line
			return true
		case .Options:
			for o, i in step.options {
				if o.condition != "" {
					v, ok := Dialogue_Evaluate(runner, o.condition)
					if !ok || !DialogueValue_Truthy(v) do continue
				}
				// In the runner's memory until the next run
				append(&runner.options, DialogueShownOption{text = strings.clone(Dialogue_Interpolate(runner, o.text), runner.allocator), index = i})
			}
			if len(runner.options) == 0 do continue
			runner.optionsStep = runner.step - 1
			runner.state = .Options
			return true
		case .Jump:
			target := Dialogue_FindNode(runner.data, step.target)
			if target < 0 {
				runner.state = .Finished
				return false
			}
			dialogueEnter(runner, target)
		case .Set:
			if v, ok := Dialogue_Evaluate(runner, step.expression); ok do Dialogue_SetVariable(runner, step.variable, v)
		case .Command:
			setText(runner, &runner.command, Dialogue_Interpolate(runner, step.command))
			runner.state = .Command
			return true
		case .Stop:
			runner.state = .Finished
			return false
		}
	}
	runner.state = .Finished
	return false
}

@(private="file")
clearOptions :: proc(runner: ^DialogueRunner) {
	for o in runner.options do delete(o.text, runner.allocator)
	clear(&runner.options)
}

@(private="file")
setText :: proc(runner: ^DialogueRunner, field: ^string, text: string) {
	delete(field^, runner.allocator)
	field^ = strings.clone(text, runner.allocator)
}

// The expression parser: a token at a time, evaluating as it parses
@(private="file")
ExprTokenKind :: enum { End, Number, String, Variable, Name, Operator, Open, Close, Comma, Bad }

@(private="file")
ExprParser :: struct {
	runner: ^DialogueRunner,
	text: string,
	at: int,
	kind: ExprTokenKind,
	token: string,
	number: f64,
	failed: bool,
}

@(private="file")
exprNext :: proc(p: ^ExprParser) {
	for p.at < len(p.text) && (p.text[p.at] == ' ' || p.text[p.at] == '\t') do p.at += 1
	if p.at >= len(p.text) {
		p.kind, p.token = .End, ""
		return
	}
	c := p.text[p.at]
	start := p.at
	switch {
	case c >= '0' && c <= '9' || c == '.':
		for p.at < len(p.text) && (p.text[p.at] >= '0' && p.text[p.at] <= '9' || p.text[p.at] == '.') do p.at += 1
		p.kind, p.token = .Number, p.text[start:p.at]
		p.number = strconv.parse_f64(p.token) or_else 0
	case c == '"':
		p.at += 1
		for p.at < len(p.text) && p.text[p.at] != '"' do p.at += 1
		p.kind, p.token = .String, p.text[start + 1:min(p.at, len(p.text))]
		p.at = min(p.at + 1, len(p.text))
	case c == '$' || c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'):
		p.at += 1
		for p.at < len(p.text) {
			d := p.text[p.at]
			if !(d == '_' || d == '.' || (d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') || (d >= '0' && d <= '9')) do break
			p.at += 1
		}
		p.kind, p.token = c == '$' ? .Variable : .Name, p.text[start:p.at]
	case c == '(':
		p.at += 1
		p.kind, p.token = .Open, "("
	case c == ')':
		p.at += 1
		p.kind, p.token = .Close, ")"
	case c == ',':
		p.at += 1
		p.kind, p.token = .Comma, ","
	case:
		// Two-character operators first
		if p.at + 1 < len(p.text) {
			two := p.text[p.at:p.at + 2]
			switch two {
			case "==", "!=", "<=", ">=", "&&", "||":
				p.at += 2
				p.kind, p.token = .Operator, two
				return
			}
		}
		switch c {
		case '+', '-', '*', '/', '%', '<', '>', '!', '=':
			p.at += 1
			p.kind, p.token = .Operator, p.text[start:p.at]
		case:
			p.at += 1
			p.kind, p.failed = .Bad, true
		}
	}
}

// Whether the current token is an operator (or a word one) of these
@(private="file")
exprIs :: proc(p: ^ExprParser, ops: ..string) -> bool {
	if p.kind != .Operator && p.kind != .Name do return false
	for op in ops do if p.token == op do return true
	return false
}

@(private="file")
exprOr :: proc(p: ^ExprParser) -> DialogueValue {
	left := exprAnd(p)
	for exprIs(p, "or", "||") {
		exprNext(p)
		right := exprAnd(p)
		left = DialogueValue_Truthy(left) || DialogueValue_Truthy(right)
	}
	return left
}

@(private="file")
exprAnd :: proc(p: ^ExprParser) -> DialogueValue {
	left := exprCompare(p)
	for exprIs(p, "and", "&&") {
		exprNext(p)
		right := exprCompare(p)
		left = DialogueValue_Truthy(left) && DialogueValue_Truthy(right)
	}
	return left
}

@(private="file")
exprCompare :: proc(p: ^ExprParser) -> DialogueValue {
	left := exprSum(p)
	for exprIs(p, "==", "!=", "<", "<=", ">", ">=", "=", "is", "eq", "neq", "lt", "lte", "gt", "gte") {
		op := p.token
		exprNext(p)
		right := exprSum(p)
		switch op {
		case "==", "=", "is", "eq": left = valuesEqual(left, right)
		case "!=", "neq":           left = !valuesEqual(left, right)
		case "<", "lt":             left = asNumber(left) < asNumber(right)
		case "<=", "lte":           left = asNumber(left) <= asNumber(right)
		case ">", "gt":             left = asNumber(left) > asNumber(right)
		case ">=", "gte":           left = asNumber(left) >= asNumber(right)
		}
	}
	return left
}

@(private="file")
exprSum :: proc(p: ^ExprParser) -> DialogueValue {
	left := exprProduct(p)
	for exprIs(p, "+", "-") {
		op := p.token
		exprNext(p)
		right := exprProduct(p)
		if op == "+" {
			// Strings join
			ls, lIsString := left.(string)
			rs, rIsString := right.(string)
			if lIsString || rIsString {
				left = strings.concatenate({lIsString ? ls : DialogueValue_Text(left), rIsString ? rs : DialogueValue_Text(right)}, context.temp_allocator)
			} else {
				left = asNumber(left) + asNumber(right)
			}
		} else {
			left = asNumber(left) - asNumber(right)
		}
	}
	return left
}

@(private="file")
exprProduct :: proc(p: ^ExprParser) -> DialogueValue {
	left := exprUnary(p)
	for exprIs(p, "*", "/", "%") {
		op := p.token
		exprNext(p)
		right := asNumber(exprUnary(p))
		switch op {
		case "*": left = asNumber(left) * right
		case "/": left = right == 0 ? 0 : asNumber(left) / right
		case "%": left = right == 0 ? 0 : math.mod(asNumber(left), right)
		}
	}
	return left
}

@(private="file")
exprUnary :: proc(p: ^ExprParser) -> DialogueValue {
	if exprIs(p, "not", "!") {
		exprNext(p)
		return !DialogueValue_Truthy(exprUnary(p))
	}
	if exprIs(p, "-") {
		exprNext(p)
		return -asNumber(exprUnary(p))
	}
	return exprPrimary(p)
}

@(private="file")
exprPrimary :: proc(p: ^ExprParser) -> DialogueValue {
	switch p.kind {
	case .Number:
		v := p.number
		exprNext(p)
		return v
	case .String:
		v := p.token
		exprNext(p)
		return v
	case .Variable:
		name := p.token
		exprNext(p)
		if p.runner != nil {
			if v, found := dialogueVars(p.runner).values[name]; found do return v
		}
		return f64(0)
	case .Open:
		exprNext(p)
		v := exprOr(p)
		if p.kind != .Close do p.failed = true
		exprNext(p)
		return v
	case .Name:
		name := p.token
		exprNext(p)
		switch name {
		case "true": return true
		case "false": return false
		}
		// A function call
		if p.kind != .Open {
			p.failed = true
			return nil
		}
		exprNext(p)
		args := make([dynamic]DialogueValue, context.temp_allocator)
		for p.kind != .Close && p.kind != .End && !p.failed {
			append(&args, exprOr(p))
			if p.kind == .Comma do exprNext(p)
		}
		if p.kind != .Close do p.failed = true
		exprNext(p)
		arg :: proc(args: []DialogueValue, i: int) -> DialogueValue { return i < len(args) ? args[i] : nil }
		switch name {
		case "visited":
			s, _ := arg(args[:], 0).(string)
			return p.runner != nil && dialogueVars(p.runner).visits[s] > 0
		case "visited_count":
			s, _ := arg(args[:], 0).(string)
			return p.runner != nil ? f64(dialogueVars(p.runner).visits[s]) : 0
		case "random":
			return rand.float64()
		case "random_range":
			lo, hi := asNumber(arg(args[:], 0)), asNumber(arg(args[:], 1))
			return math.floor(lo + rand.float64() * (hi - lo + 1))
		case "dice":
			sides := max(asNumber(arg(args[:], 0)), 1)
			return math.floor(rand.float64() * sides) + 1
		}
		p.failed = true
		return nil
	case .End, .Operator, .Close, .Comma, .Bad:
	}
	p.failed = true
	return nil
}

@(private="file")
asNumber :: proc(v: DialogueValue) -> f64 {
	switch x in v {
	case f64: return x
	case bool: return x ? 1 : 0
	case string: return strconv.parse_f64(x) or_else 0
	}
	return 0
}

@(private="file")
valuesEqual :: proc(a, b: DialogueValue) -> bool {
	as, aIsString := a.(string)
	bs, bIsString := b.(string)
	if aIsString && bIsString do return as == bs
	ab, aIsBool := a.(bool)
	bb, bIsBool := b.(bool)
	if aIsBool && bIsBool do return ab == bb
	return asNumber(a) == asNumber(b)
}

@(private="file")
dialogueEscape :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in text {
		switch r {
		case '&': strings.write_string(&b, "&amp;")
		case '"': strings.write_string(&b, "&quot;")
		case '<': strings.write_string(&b, "&lt;")
		case '>': strings.write_string(&b, "&gt;")
		case '\n': strings.write_string(&b, "&#10;")
		case: strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}
