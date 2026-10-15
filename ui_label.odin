package engine

import "core:strings"
import sdl "vendor:sdl3"

// Static text. When centered, pos is the center of the text, otherwise its top-left corner
Label :: struct {
	using node: Node,
	text: string,
	pos: [2]f32,
	size: f32,
	color: sdl.Color,
	centered: bool,
	font: string,
}

CreateLabel :: proc(scene: ^Scene, text: string, pos: [2]f32, size: f32, color: sdl.Color, centered := true, font := DEFAULT_FONT) -> ^Label {
	label := CreateNode(scene, Label)
	label.draw = Label_draw
	// Copied into the label node so callers can pass temporary strings
	label.text = strings.clone(text, Node_GetAllocator(label))
	label.pos = pos
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
		DrawTextCentered(rm, sdl.FPoint(label.pos), label.text, label.font, label.size, label.color)
	} else {
		DrawText(rm, sdl.FPoint(label.pos), label.text, label.font, label.size, label.color)
	}
}
