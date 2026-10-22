package crossfire

import "core:log"
import sdl "vendor:sdl3"

/*
The pixel format of the engine's render targets (RenderTarget_Create, tile caches): BGRA32,
`B8G8R8A8_UNORM` on Vulkan, the format SDL's Vulkan swapchains use on nearly every platform.

SDL 3.4's Vulkan renderer picks its pipelines by the swapchain's format, not the render target's
(`VULKAN_SetDrawState` uses `surfaceFormat.format`), so drawing into a target of another format
used pipelines made for an incompatible render pass (Vulkan validation:
`VUID-vkCmdDraw-renderPass-02684`; it drew right on the GPUs tried, but it's undefined). Other
renderers take any format alike. Readers convert (`sdl.ConvertSurface`): don't assume RGBA order.
*/
RENDER_TARGET_FORMAT :: sdl.PixelFormat.BGRA32

/*
Render targets: textures to draw into instead of the screen. Draw a scene into one (a minimap, a
picture-in-picture, a split-screen half, a transition snapshot) or draw anything with the Draw*
helpers between `RenderTarget_Begin` and `RenderTarget_End`; then draw its `texture` like any other
(`DrawTexture`, a Sprite's texture).

Example:
	// Given: level: ^e.Scene
	// A minimap: the level, drawn small every frame, shown in a corner by a HUD global
	minimap := e.RenderTarget_Create(game, {320, 180})
	// In the HUD's draw:
	e.Scene_DrawToTarget(level, minimap, e.Transform2D{x = {0.1, 0}, y = {0, 0.1}})
	e.DrawTexture(renderer, minimap.texture, {960, 20, 320, 180})
*/
RenderTarget :: struct {
	// What was drawn into it: draw it like any texture
	texture: ^sdl.Texture,
	// Its size in pixels
	size: [2]f32,
	// The renderer target RenderTarget_Begin replaced, put back by RenderTarget_End
	previous: ^sdl.Texture,
	// The renderer viewport before RenderTarget_Begin, put back by RenderTarget_End
	previousViewport: sdl.Rect,
	// The logical presentation size before RenderTarget_Begin, put back by RenderTarget_End
	previousLogical: [2]i32,
	// The logical presentation mode before RenderTarget_Begin, put back by RenderTarget_End
	previousMode: sdl.RendererLogicalPresentation,
}

/*
Makes a render target of `size` pixels, cleared to transparent.

Inputs:
- game: The game (its renderer)
- size: Width and height in pixels
- smooth: Linear filtering when it's drawn scaled (otherwise nearest, for pixel art)

Returns:
- The target (`RenderTarget_Destroy` frees it), or nil (logged) when the renderer can't make one

Example:
	minimap := e.RenderTarget_Create(game, {320, 180})
	defer e.RenderTarget_Destroy(minimap)
*/
RenderTarget_Create :: proc(game: ^Game, size: [2]f32, smooth := false) -> ^RenderTarget {
	texture := sdl.CreateTexture(game.renderer, RENDER_TARGET_FORMAT, .TARGET, i32(max(size.x, 1)), i32(max(size.y, 1)))
	if texture == nil {
		log.errorf("RenderTarget_Create: %s", sdl.GetError())
		return nil
	}
	sdl.SetTextureScaleMode(texture, smooth ? .LINEAR : .NEAREST)
	sdl.SetTextureBlendMode(texture, sdl.BLENDMODE_BLEND)
	target := new(RenderTarget)
	target.texture = texture
	target.size = {max(size.x, 1), max(size.y, 1)}
	RenderTarget_Begin(game.renderer, target)
	sdl.SetRenderDrawColor(game.renderer, 0, 0, 0, 0)
	sdl.RenderClear(game.renderer)
	RenderTarget_End(game.renderer, target)
	return target
}

/*
Frees a render target and its texture.

Inputs:
- target: The target (nil does nothing)
*/
RenderTarget_Destroy :: proc(target: ^RenderTarget) {
	if target == nil do return
	sdl.DestroyTexture(target.texture)
	free(target)
}

/*
Draws into a target from now on (until `RenderTarget_End`): the Draw* helpers and SDL calls land in
its texture, in its own pixels (the game's logical presentation is off meanwhile). Calls can
nest across different targets; don't begin the same target twice before ending it.

Inputs:
- renderer: The renderer that made it
- target: The target
- clear: Clear it to `clearColor` first
- clearColor: The color to clear to (transparent by default)

Example:
	// Given: target: ^e.RenderTarget
	e.RenderTarget_Begin(renderer, target, clear = true)
	e.DrawCircle(renderer, {160, 90}, 40, sdl.Color{255, 200, 0, 255})
	e.RenderTarget_End(renderer, target)
*/
RenderTarget_Begin :: proc(renderer: ^sdl.Renderer, target: ^RenderTarget, clear := false, clearColor := sdl.Color{0, 0, 0, 0}) {
	target.previous = sdl.GetRenderTarget(renderer).? or_else nil
	sdl.GetRenderViewport(renderer, &target.previousViewport)
	w, h: i32
	sdl.GetRenderLogicalPresentation(renderer, &w, &h, &target.previousMode)
	target.previousLogical = {w, h}
	sdl.SetRenderTarget(renderer, target.texture)
	sdl.SetRenderLogicalPresentation(renderer, 0, 0, .DISABLED)
	sdl.SetRenderViewport(renderer, nil)
	if clear {
		sdl.SetRenderDrawColor(renderer, clearColor.r, clearColor.g, clearColor.b, clearColor.a)
		sdl.RenderClear(renderer)
	}
}

/*
Goes back to drawing where it was before `RenderTarget_Begin` (the screen, or another target),
with the renderer's viewport and logical presentation as they were.

Inputs:
- renderer: The renderer
- target: The target given to `RenderTarget_Begin`
*/
RenderTarget_End :: proc(renderer: ^sdl.Renderer, target: ^RenderTarget) {
	sdl.SetRenderTarget(renderer, target.previous)
	sdl.SetRenderLogicalPresentation(renderer, target.previousLogical.x, target.previousLogical.y, target.previousMode)
	viewport := target.previousViewport
	sdl.SetRenderViewport(renderer, viewport.w > 0 ? &viewport : nil)
}

/*
Draws a scene into a render target (cleared first): through `view` when given, else through its
camera scaled from the game's size to the target's (the whole game view, stretched when the
aspect ratios differ). Its nodes don't
update; the scene that's playing can draw another one this way, or itself.

Inputs:
- scene: The scene to draw
- target: Where
- view: World to target pixels; nil for the camera's view, scaled to the target
- clearColor: What's under the scene (transparent by default)

Example:
	// Given: level: ^e.Scene, minimap: ^e.RenderTarget
	e.Scene_DrawToTarget(level, minimap)
*/
Scene_DrawToTarget :: proc(scene: ^Scene, target: ^RenderTarget, view: Maybe(Transform2D) = nil, clearColor := sdl.Color{0, 0, 0, 0}) {
	renderer := scene.game != nil ? scene.game.renderer : nil
	if renderer == nil || target == nil do return
	transform, given := view.?
	if !given {
		gameSize := scene.game.size
		scale := gameSize.x > 0 && gameSize.y > 0 ? target.size / gameSize : [2]f32{1, 1}
		camera := scene.camera != nil ? Camera2D_ViewTransform(scene.camera) : TRANSFORM2D_IDENTITY
		transform = Transform2D_Multiply(Transform2D{x = {scale.x, 0}, y = {0, scale.y}}, camera)
	}
	RenderTarget_Begin(renderer, target, clear = true, clearColor = clearColor)
	Scene_DrawWithView(scene, renderer, transform)
	RenderTarget_End(renderer, target)
}
