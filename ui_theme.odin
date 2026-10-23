package crossfire

import "core:encoding/xml"
import "core:fmt"
import "core:log"
import "core:reflect"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

/*
UI themes: how the UI controls (ui_controls.odin) look. A theme is a font and a `UITheme`: text
sizes, colors and spacing for panels, buttons, progress bars, text fields, scroll boxes and
check boxes (sliders use the progress bars' colors for their track and the buttons' for their
knob).

Themes are assets of kind "Theme" (`.theme.xml` files):

	<theme formatVersion="13" font="assets/fonts/pixel.ttf" textSize="18" buttonColor="#3a5a8c"/>

The root element holds the font and every field of `UITheme` that differs from
`DEFAULT_UI_THEME` (`FormatTheme` writes them, `ParseTheme` reads them). A control uses the
theme its `theme` names, or its nearest control ancestor's, or the project's (`uiTheme` in
project.xml), else the default. Give a whole menu or HUD a theme by setting it on its top
panel.
*/

/*
How UI controls look: sizes in pixels, colors. Tags describe the fields for editors
(`UITheme_Fields`): `label`, `group` (starts a group), `min` / `max`.
*/
UITheme :: struct {
	// Text in controls, in points
	textSize: f32 `label:"Text size" group:"Text" min:"6" max:"96"`,
	// Text
	textColor: sdl.Color `label:"Text color"`,
	// Text of disabled controls
	disabledTextColor: sdl.Color `label:"Disabled text"`,

	// A panel's fill
	panelColor: sdl.Color `label:"Panel color" group:"Panels"`,
	// Borders of panels, buttons and fields
	borderColor: sdl.Color `label:"Border color"`,
	// Border width (0: none)
	borderWidth: f32 `label:"Border width" min:"0" max:"8"`,
	// Rounded corners' radius
	cornerRadius: f32 `label:"Corner radius" min:"0" max:"32"`,
	// Space inside panels, buttons and fields, between their edge and what's in them
	padding: f32 `label:"Padding" min:"0" max:"64"`,
	// Space between a container's children
	spacing: f32 `label:"Spacing" min:"0" max:"64"`,

	// A button's fill
	buttonColor: sdl.Color `label:"Button color" group:"Buttons"`,
	// Under the mouse
	buttonHoverColor: sdl.Color `label:"Hovered"`,
	// Held down
	buttonPressedColor: sdl.Color `label:"Pressed"`,
	// Disabled
	buttonDisabledColor: sdl.Color `label:"Disabled"`,
	// A button's text
	buttonTextColor: sdl.Color `label:"Button text"`,
	// The outline of the control with the keyboard's or gamepad's focus
	focusColor: sdl.Color `label:"Focus outline"`,

	// A text field's fill
	fieldColor: sdl.Color `label:"Field color" group:"Text fields"`,
	// Its placeholder text (shown while it's empty)
	placeholderColor: sdl.Color `label:"Placeholder"`,
	// The text caret
	caretColor: sdl.Color `label:"Caret"`,

	// A progress bar's empty part
	progressBackColor: sdl.Color `label:"Bar background" group:"Progress bars"`,
	// Its filled part
	progressFillColor: sdl.Color `label:"Bar fill"`,

	// A scroll box's bar
	scrollbarColor: sdl.Color `label:"Scrollbar" group:"Scroll boxes"`,

	// A ticked check box's mark (its box is the field color, the button colors under the mouse)
	checkColor: sdl.Color `label:"Check mark" group:"Check boxes"`,
}

// The engine's UI theme: light text on dark blue panels, like `DEFAULT_MENU_STYLE`
DEFAULT_UI_THEME :: UITheme{
	textSize = 20,
	textColor = {235, 240, 255, 255},
	disabledTextColor = {120, 128, 150, 255},
	panelColor = {22, 28, 46, 230},
	borderColor = {70, 86, 130, 255},
	borderWidth = 1,
	cornerRadius = 8,
	padding = 10,
	spacing = 8,
	buttonColor = {44, 62, 104, 255},
	buttonHoverColor = {62, 86, 140, 255},
	buttonPressedColor = {32, 44, 76, 255},
	buttonDisabledColor = {36, 40, 56, 255},
	buttonTextColor = {245, 248, 255, 255},
	focusColor = {255, 210, 90, 255},
	fieldColor = {14, 18, 30, 255},
	placeholderColor = {110, 120, 150, 255},
	caretColor = {255, 210, 90, 255},
	progressBackColor = {14, 18, 30, 255},
	progressFillColor = {90, 200, 120, 255},
	scrollbarColor = {90, 104, 150, 200},
	checkColor = {90, 200, 120, 255},
}

/*
A theme as read from its file: its font and its values. Kept by the game (`Game_LoadTheme`).
*/
ThemeData :: struct {
	// Font path, relative to the project ("" or `DEFAULT_FONT`: the built-in font)
	font: string,
	// The values
	theme: UITheme,
	// The font's full path, found when first used (the game's memory)
	fontPath: string,
}

// A theme field for editors (`UITheme_Fields`)
UIThemeField :: struct {
	// The field's name in the struct and the file
	name: string,
	// What editors show
	label: string,
	// The group it starts ("": it continues the one above)
	group: string,
	// Its Odin type (f32 or sdl.Color)
	type: typeid,
	// Its range, for numbers
	min, max: f32,
}

/*
The theme's fields for editors, in order, with their tags.

Returns:
- The fields (temp allocated)
*/
UITheme_Fields :: proc() -> []UIThemeField {
	fields := reflect.struct_fields_zipped(UITheme)
	infos := make([]UIThemeField, len(fields), context.temp_allocator)
	for field, i in fields {
		info := UIThemeField{name = field.name, type = field.type.id}
		info.label = string(reflect.struct_tag_get(field.tag, "label"))
		if info.label == "" do info.label = field.name
		info.group = string(reflect.struct_tag_get(field.tag, "group"))
		if text, ok := reflect.struct_tag_lookup(field.tag, "min"); ok do info.min, _ = strconv.parse_f32(string(text))
		if text, ok := reflect.struct_tag_lookup(field.tag, "max"); ok do info.max, _ = strconv.parse_f32(string(text))
		infos[i] = info
	}
	return infos
}

/*
A theme field's value as text ("20", "#2c3e68ff").

Inputs:
- theme: The theme
- name: The field

Returns:
- The text (temp allocated), and false when there's no such field
*/
UITheme_Get :: proc(theme: UITheme, name: string) -> (string, bool) {
	theme := theme
	value := reflect.struct_field_value_by_name(theme, name)
	if value.data == nil do return "", false
	switch v in value {
	case f32: return fmt.tprintf("%v", v), true
	case sdl.Color: return FormatColor(v, context.temp_allocator), true
	}
	return "", false
}

/*
Sets a theme field from text.

Inputs:
- theme: The theme
- name: The field
- text: Its value ("20", "#ff8000")

Returns:
- false when there's no such field or the text isn't a value of it (the field is unchanged)
*/
UITheme_Set :: proc(theme: ^UITheme, name, text: string) -> bool {
	field := reflect.struct_field_by_name(UITheme, name)
	if field.type == nil do return false
	at := rawptr(uintptr(theme) + field.offset)
	text := strings.trim_space(text)
	switch field.type.id {
	case f32:
		v := strconv.parse_f32(text) or_return
		(cast(^f32)at)^ = v
	case sdl.Color:
		v := ParseColor(text) or_return
		(cast(^sdl.Color)at)^ = v
	case:
		return false
	}
	return true
}

/*
Reads a theme file's text.

Inputs:
- text: The `.theme.xml` file's text
- allocator: For the font's path

Returns:
- The theme (fields the file lacks are the defaults), and an error
*/
ParseTheme :: proc(text: string, allocator := context.allocator) -> (ThemeData, ProjectError) {
	doc, err := xml.parse_string(text)
	if err != .None do return {}, .Invalid_XML
	defer xml.destroy(doc)
	if doc.element_count == 0 || doc.elements[0].ident != "theme" do return {}, .Invalid_XML
	data := ThemeData{theme = DEFAULT_UI_THEME}
	for a in doc.elements[0].attribs {
		switch a.key {
		case "formatVersion":
			if v, ok := strconv.parse_int(a.val); ok && v > PROJECT_FORMAT_VERSION do return {}, .Unsupported_Version
		case "font":
			data.font = strings.clone(a.val, allocator)
		case:
			// Unknown or bad values keep the default
			UITheme_Set(&data.theme, a.key, a.val)
		}
	}
	return data, .None
}

/*
Writes a theme file: its font and the fields that differ from the default.

Inputs:
- data: The theme
- allocator: For the text

Returns:
- The file's text
*/
FormatTheme :: proc(data: ThemeData, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, `<theme formatVersion="%d"`, PROJECT_FORMAT_VERSION)
	if data.font != "" do fmt.sbprintf(&b, ` font="%s"`, xmlEscape(data.font))
	for field in reflect.struct_fields_zipped(UITheme) {
		value, _ := UITheme_Get(data.theme, field.name)
		defaultValue, _ := UITheme_Get(DEFAULT_UI_THEME, field.name)
		if value != defaultValue do fmt.sbprintf(&b, ` %s="%s"`, field.name, value)
	}
	strings.write_string(&b, "/>\n")
	return strings.to_string(b)
}

@(private="file")
xmlEscape :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in text {
		switch r {
		case '&': strings.write_string(&b, "&amp;")
		case '"': strings.write_string(&b, "&quot;")
		case '<': strings.write_string(&b, "&lt;")
		case '>': strings.write_string(&b, "&gt;")
		case: strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

/*
A theme asset, read once per game (tools put their unsaved themes in `game.themes` first).

Inputs:
- game: The game
- path: The `.theme.xml` file, relative to the project

Returns:
- The theme, and false when it couldn't be read (the default theme then)
*/
Game_LoadTheme :: proc(game: ^Game, path: string) -> (^ThemeData, bool) {
	if game == nil || path == "" do return nil, false
	if data, found := game.themes[path]; found do return data, data != nil
	allocator := Game_GetAllocator(game)
	if game.themes == nil do game.themes = make(map[string]^ThemeData, allocator)
	full := JoinPath(game.projectDir, path)
	text, read := Platform_ReadFile(full)
	data: ^ThemeData
	if !read {
		log.errorf("Couldn't read theme %s", full)
	} else if parsed, err := ParseTheme(string(text), allocator); err != .None {
		log.errorf("Couldn't load theme %s: %v", full, err)
	} else {
		data = new_clone(parsed, allocator)
	}
	game.themes[strings.clone(path, allocator)] = data
	return data, data != nil
}
