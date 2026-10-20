package engine

import "core:c"
import "core:math"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// TEXT PRIMITIVE HELPERS
//
// font is a font file path, or DEFAULT_FONT for the embedded Open Sans.
// Fonts are loaded through the resource manager on first use and cached per size.
// pos is the top-left corner of the text.
// While a scene draws a node, text is positioned and scaled by its transform but not rotated.

DrawText :: proc(rm: ^ResourceManager, pos: sdl.FPoint, text: string, font: string, size: f32, color: sdl.Color) {
	DrawTextWrapped(rm, pos, text, font, size, color, 0)
}

// Wraps lines to fit within wrapWidth pixels. A wrapWidth of 0 only breaks on newlines
DrawTextWrapped :: proc(rm: ^ResourceManager, pos: sdl.FPoint, text: string, font: string, size: f32, color: sdl.Color, wrapWidth: f32) {
	if len(text) == 0 || rm.textEngine == nil do return

	pos, size, wrapWidth := pos, size, wrapWidth
	// Text follows the draw transform's position and scale, but stays upright: SDL_ttf can't
	// rotate. Scaled sizes are rounded to whole points so changing scales don't cache endless sizes
	if drawState().transform != TRANSFORM2D_IDENTITY {
		pos = sdl.FPoint(toScreen(cast([2]f32)pos))
		size = max(math.round(toScreenLength(size)), 1)
		wrapWidth = toScreenLength(wrapWidth)
	}
	color := tinted(color)

	ttfFont := rm->loadFont(font, size)
	if ttfFont == nil do return

	// Text objects are cheap; the glyph atlas lives in the text engine and persists across frames
	ttfText := ttf.CreateText(rm.textEngine, ttfFont, raw_data(text), len(text))
	if ttfText == nil do return
	defer ttf.DestroyText(ttfText)

	ttf.SetTextColor(ttfText, color[0], color[1], color[2], color[3])
	if wrapWidth > 0 {
		ttf.SetTextWrapWidth(ttfText, c.int(wrapWidth))
	}
	ttf.DrawRendererText(ttfText, pos.x, pos.y)
}

// Draws text centered on pos, useful for titles and buttons
DrawTextCentered :: proc(rm: ^ResourceManager, pos: sdl.FPoint, text: string, font: string, size: f32, color: sdl.Color) {
	textSize := MeasureText(rm, text, font, size)
	DrawText(rm, pos - textSize * 0.5, text, font, size, color)
}

// Returns the width and height in pixels that the text would take up when drawn
MeasureText :: proc(rm: ^ResourceManager, text: string, font: string, size: f32, wrapWidth: f32 = 0) -> sdl.FPoint {
	if len(text) == 0 do return {}

	ttfFont := rm->loadFont(font, size)
	if ttfFont == nil do return {}

	w, h: c.int
	ttf.GetStringSizeWrapped(ttfFont, raw_data(text), len(text), c.int(wrapWidth), &w, &h)
	return {f32(w), f32(h)}
}
