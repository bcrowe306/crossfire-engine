package engine

import "core:strings"
import sdl "vendor:sdl3"

// Static text. When centered, the node's position is the center of the text, otherwise its
// top-left corner. Labels are .Position_Only nodes: they follow their position but don't rotate or scale
Label :: struct {
	using node: Node,
	text: string,
	size: f32,
	color: sdl.Color,
	centered: bool,
	font: string,
}

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
	label.font = font
	return label
}

Label_draw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	label := cast(^Label)node
	rm := &label.scene.game.resourceManager
	if label.centered {
		DrawTextCentered(rm, {0, 0}, label.text, label.font, label.size, label.color)
	} else {
		DrawText(rm, {0, 0}, label.text, label.font, label.size, label.color)
	}
}

Label_getBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	label := cast(^Label)node
	if label.scene == nil || label.scene.game == nil do return {}, false
	size := MeasureText(&label.scene.game.resourceManager, label.text, label.font, label.size)
	if label.centered do return {-size.x * 0.5, -size.y * 0.5, size.x, size.y}, true
	return {0, 0, size.x, size.y}, true
}
