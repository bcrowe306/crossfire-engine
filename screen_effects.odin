package crossfire

import sdl "vendor:sdl3"

/*
Screen effects: a ScreenEffect node runs its shader (shaders.odin) over the whole scene as drawn:
the scene goes into a picture the screen's size first, then that picture is drawn through each
ScreenEffect in turn (in the order they were added), the last one onto the screen.

- `includeScreenLayers` (on by default): the effect covers the scene's screen layers too (a HUD
  on an old TV); off, it covers the world only and screen layers draw over it untouched.
- A ScreenEffect that's hidden, or whose shader can't run (not the GPU renderer), is skipped.
- Its parameters are its shader's (`Node_SetShaderParam` on the effect node).

Example:
	tv := e.CreateScreenEffect(scene, "builtin:crt")
	e.Node_SetShaderParam(tv, "scanlines", 0.8)
*/

// A shader over the whole scene (its `shader` is the effect)
ScreenEffect :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// The effect covers the scene's screen layers too
	includeScreenLayers: bool,
}

/*
Creates a ScreenEffect and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- shader: The effect ("builtin:crt", a project shader's path)

Returns:
- The effect node (its shader set; a shader that can't load leaves it without one, logged)
*/
CreateScreenEffect :: proc(scene: ^Scene, shader: string) -> ^ScreenEffect {
	fx := CreateNode(scene, ScreenEffect)
	fx.includeScreenLayers = true
	Node_SetShader(fx, shader)
	fx.destroy = proc(node: ^Node) {
		scene := node.scene
		if scene == nil do return
		for other, i in scene.screenEffects do if other == cast(^ScreenEffect)node {
			ordered_remove(&scene.screenEffects, i)
			break
		}
		if len(scene.screenEffects) == 0 {
			delete(scene.screenEffects)
			scene.screenEffects = nil
		}
	}
	if scene.screenEffects == nil do scene.screenEffects = make([dynamic]^ScreenEffect)
	append(&scene.screenEffects, fx)
	return fx
}

// INTERNAL

// The effects that run this frame (in the scene, visible, with a shader this renderer runs)
@(private)
screenEffectsActive :: proc(scene: ^Scene, renderer: ^sdl.Renderer) -> []^ScreenEffect {
	if len(scene.screenEffects) == 0 || renderer == nil || !Renderer_SupportsShaders(renderer) do return nil
	list := make([dynamic]^ScreenEffect, 0, len(scene.screenEffects), context.temp_allocator)
	for fx in scene.screenEffects do if fx.inScene && fx.shader != nil && !fx.shader.program.failed && Node_IsVisibleInTree(fx) do append(&list, fx)
	return list[:]
}

// The size of what's drawn to: the logical presentation's, else the current target's
@(private)
screenEffectsSize :: proc(renderer: ^sdl.Renderer) -> [2]f32 {
	w, h: i32
	mode: sdl.RendererLogicalPresentation
	if sdl.GetRenderLogicalPresentation(renderer, &w, &h, &mode) && mode != .DISABLED && w > 0 && h > 0 do return {f32(w), f32(h)}
	if sdl.GetCurrentRenderOutputSize(renderer, &w, &h) && w > 0 && h > 0 do return {f32(w), f32(h)}
	return {}
}

// Starts drawing the scene into the first effect picture (cleared to the scene's background)
@(private)
screenEffectsBegin :: proc(scene: ^Scene, renderer: ^sdl.Renderer, size: [2]f32) -> bool {
	fx := &scene.effects
	for &t in fx.targets {
		if t != nil && (t.size != size || fx.renderer != renderer) {
			RenderTarget_Destroy(t)
			t = nil
		}
	}
	fx.renderer = renderer
	for &t in fx.targets {
		if t != nil do continue
		texture := sdl.CreateTexture(renderer, RENDER_TARGET_FORMAT, .TARGET, i32(size.x), i32(size.y))
		if texture == nil do return false
		sdl.SetTextureScaleMode(texture, .NEAREST)
		sdl.SetTextureBlendMode(texture, sdl.BLENDMODE_BLEND)
		t = new(RenderTarget)
		t.texture, t.size = texture, size
	}
	// A game's background (opaque): the picture starts from it and replaces the screen; without one
	// (editors' previews draw their own backdrop first) it starts transparent and blends over
	background := sdl.Color{}
	if scene.game != nil do background = scene.game.backgroundColor
	if color, set := scene.background.?; set do background = color
	fx.opaque = background.a == 255
	RenderTarget_Begin(renderer, fx.targets[0], clear = true, clearColor = fx.opaque ? background : {})
	return true
}

// Ends the scene's picture and draws it through each effect, the last onto what was drawn to
@(private)
screenEffectsEnd :: proc(scene: ^Scene, renderer: ^sdl.Renderer, effects: []^ScreenEffect, time: f32) {
	fx := &scene.effects
	RenderTarget_End(renderer, fx.targets[0])
	source := 0
	ds := drawState()
	for effect, i in effects {
		last := i == len(effects) - 1
		into := fx.targets[1 - source]
		if !last do RenderTarget_Begin(renderer, into, clear = true)
		SetDrawState(TRANSFORM2D_IDENTITY)
		ds.material, ds.time = effect.shader, time
		texture := fx.targets[source].texture
		size := fx.targets[source].size
		dst := sdl.FRect{0, 0, size.x, size.y}
		sdl.SetTextureColorMod(texture, 255, 255, 255)
		sdl.SetTextureAlphaMod(texture, 255)
		// Opaque: the scene picture replaces what's under it (the background is in it); else the
		// last pass blends over what's under it (between passes: copied as it is)
		sdl.SetTextureBlendMode(texture, fx.opaque || !last ? sdl.BLENDMODE_NONE : sdl.BLENDMODE_BLEND)
		on := shaderDrawBegin(renderer, size)
		sdl.RenderTexture(renderer, texture, nil, &dst)
		shaderDrawEnd(renderer, on)
		sdl.SetTextureBlendMode(texture, sdl.BLENDMODE_BLEND)
		ds.material = nil
		if !last {
			RenderTarget_End(renderer, into)
			source = 1 - source
		}
	}
}

// Frees the effect pictures (Scene_Destroy)
@(private)
screenEffectsDestroy :: proc(scene: ^Scene) {
	for &t in scene.effects.targets {
		RenderTarget_Destroy(t)
		t = nil
	}
	delete(scene.screenEffects)
	scene.screenEffects = nil
}

// A scene's screen effect pictures (two, drawn back and forth)
@(private)
ScreenEffectTargets :: struct {
	targets: [2]^RenderTarget,
	renderer: ^sdl.Renderer,
	// This frame's picture started from an opaque background
	opaque: bool,
}
