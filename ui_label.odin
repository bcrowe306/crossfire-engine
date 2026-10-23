package crossfire

import "core:strings"
import sdl "vendor:sdl3"

/*
A node that draws one line of static text.

When `centered` is true the node's position is the center of the text, otherwise its top-left
corner. Labels are `.Position_Only` nodes: they follow their world position but don't rotate or
scale. Text starting with "@" is a translation key, looked up with `Tr_Text` each frame.
*/
Label :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// The text to draw, or "@key" for a translated string. `CreateLabel` copies it into the node's
	// arena; if you assign a new string yourself, it must outlive the label
	text: string,
	// Font size in points
	size: f32,
	// Text color
	color: sdl.Color,
	// true: the position is the center of the text; false: its top-left corner
	centered: bool,
	// Font path, or `DEFAULT_FONT`. Not copied: use a string that outlives the label
	font: string,
}

/*
Creates a `Label` node and adds it to the scene (at the start of the next update).

The text and the font's path are copied into the label node's arena, so temporary strings are
fine.

Inputs:
- scene: The scene that owns the label
- text: The text to draw, or "@key" for a translated string (see `Tr_Text`)
- pos: Position in pixels, relative to the label's parent (the scene root until you reparent it)
- size: Font size in points
- color: Text color
- centered: true to center the text on `pos`, false to put its top-left corner there
- font: Font path, or `DEFAULT_FONT`

Returns:
- The new label, owned by the scene

Example:
	title := e.CreateLabel(scene, "@menu.title", {640, 120}, 48, {255, 255, 255, 255})
	title.color = {255, 220, 120, 255}
*/
CreateLabel :: proc(scene: ^Scene, text: string, pos: [2]f32, size: f32, color: sdl.Color, centered := true, font := DEFAULT_FONT) -> ^Label {
	label := CreateNode(scene, Label)
	label.draw = Label_draw
	label.getBounds = Label_getBounds
	// Copied into the label node so callers can pass temporary strings
	label.text = strings.clone(text, Node_GetAllocator(label))
	label.position = pos
	label.transformMode = .Position_Only
	label.size = size
	label.color = color
	label.centered = centered
	label.font = strings.clone(font, Node_GetAllocator(label))
	return label
}

@(private)
Label_draw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	label := cast(^Label)node
	rm := &label.scene.game.resourceManager
	// "@key" is translated (localization.odin)
	text := Tr_Text(label.text, label.scene.game)
	if label.centered {
		DrawTextCentered(rm, {0, 0}, text, label.font, label.size, label.color)
	} else {
		DrawText(rm, {0, 0}, text, label.font, label.size, label.color)
	}
}

@(private)
Label_getBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	label := cast(^Label)node
	if label.scene == nil || label.scene.game == nil do return {}, false
	size := MeasureText(&label.scene.game.resourceManager, Tr_Text(label.text, label.scene.game), label.font, label.size)
	if label.centered do return {-size.x * 0.5, -size.y * 0.5, size.x, size.y}, true
	return {0, 0, size.x, size.y}, true
}
