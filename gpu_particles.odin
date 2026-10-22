package crossfire

import "core:log"
import "core:math"
import sdl "vendor:sdl3"

/*
GPU particles: a ParticleEmitter with `gpu` on simulates `gpuAmount` particles (up to
MAX_GPU_PARTICLES) on the graphics card, when the game draws with SDL's GPU renderer.

**How:** nothing is kept per particle. The vertex shader (shaders/particles) works out each
particle from its index and the time: when it was born in its cycle, where the emitter was then
(the emitter's path, recorded each update and handed over as a storage buffer), random numbers
from a hash of its index and cycle, then the motion in closed form (velocity, acceleration,
gravity, wind; spin), its size and its color (start and end, or the ramp: up to 8 stops). The
particles are drawn into a picture of their own on SDL's GPU device (instanced quads, the
emitter's blend: alpha or additive), which the renderer then draws where the emitter is in the
scene. Measured on an Intel UHD 620 (integrated graphics), a frame's update and draw: 500
particles on the CPU 1.6 ms; on the GPU 500 0.8 ms, 20 000 2.1 ms, 100 000 5.2 ms, 200 000 9.1 ms.

**The same settings**, with these differences: no collisions (the view's edges); the Custom,
Ellipse, Line and Pixel shapes draw as circles; `localSpace` works. Where the GPU renderer isn't
available (other renderers, the web) the emitter simulates on the CPU as usual, with `amount`
particles.
*/

// The most particles an emitter simulates on the GPU
MAX_GPU_PARTICLES :: 200000
// How many samples of the emitter's path the shader reads
GPU_PATH_SAMPLES :: 128
// How many of the emitter's positions are kept (resampled into GPU_PATH_SAMPLES)
@(private="file")
GPU_PATH_RING :: 512

// An emitter's GPU state (`ParticleEmitter.gpu`, the node's arena; SDL objects freed with the node)
GPUParticles :: struct {
	// Seconds since the emitter was made (its own clock), when this run started and stopped
	clock, start, stopped: f64,
	// The emitter's path: (time, x, y, rotation), a ring
	ring: [GPU_PATH_RING][4]f32,
	ringHead, ringCount: int,
	// Drawn with the GPU last time (the CPU simulation is off then)
	active: bool,
	// The picture the particles are drawn into, as SDL's texture too; its renderer and size
	target: ^sdl.GPUTexture,
	targetTexture: ^sdl.Texture,
	renderer: ^sdl.Renderer,
	size: [2]i32,
	// The path's storage buffer and its upload buffer
	path: ^sdl.GPUBuffer,
	upload: ^sdl.GPUTransferBuffer,
	device: ^sdl.GPUDevice,
}

// The pipelines and helpers GPU particles share on a device (`Game.gpuParticles`)
GPUParticleResources :: struct {
	device: ^sdl.GPUDevice,
	// Alpha (premultiplied) and additive
	blend, add: ^sdl.GPUGraphicsPipeline,
	sampler: ^sdl.GPUSampler,
	// A white pixel, for shapes without a texture
	white: ^sdl.GPUTexture,
	failed: bool,
}

@(private="file")
PARTICLES_VERT :: #load("shaders/particles/particles.vert.shader")
@(private="file")
PARTICLES_FRAG :: #load("shaders/particles/particles.frag.shader")

// The vertex shader's uniforms (std140: every member a vec4)
@(private="file")
GPUParticleParams :: struct {
	view0, view1, timing, emission, pathTime, spread, speed, force, sizes, scales, spin, spin2: [4]f32,
	colors: [8][4]f32,
	stops: [2][4]f32,
}

// Whether an emitter is drawing on the GPU now
ParticleEmitter_OnGPU :: proc(emitter: ^ParticleEmitter) -> bool {
	return emitter.gpu != nil && emitter.gpu.active
}

// INTERNAL

// The emitter's clock, path and runs (its update, every frame while `gpu` is on)
@(private)
gpuParticlesUpdate :: proc(emitter: ^ParticleEmitter, deltaTime: f32) {
	g := gpuParticlesState(emitter)
	g.clock += f64(deltaTime)
	s := &emitter.settings
	// Where it is (world space; nothing to record in its own space)
	pos: [2]f32
	rot: f32
	if !s.localSpace {
		world := Node_GetWorldTransform(emitter)
		pos = world.origin
		rot = math.to_radians(Transform2D_Rotation(world))
	}
	g.ring[g.ringHead] = {f32(g.clock), pos.x, pos.y, rot}
	g.ringHead = (g.ringHead + 1) % GPU_PATH_RING
	g.ringCount = min(g.ringCount + 1, GPU_PATH_RING)
	// A one-shot run ends after its cycle; a stopped one when its last particle has lived
	life := f64(max(s.lifetime, 0.0001))
	if emitter.emitting && !s.continuous && g.clock - g.start >= life {
		emitter.emitting = false
		g.stopped = g.start + life
		emitter.finishPending = true
	}
	if !emitter.emitting && emitter.finishPending && g.clock >= g.stopped + life {
		emitter.finishPending = false
		Event_Notify(&emitter.onFinished, emitter, nil)
	}
}

// Starting and stopping a run (ParticleEmitter_Start / Stop)
@(private)
gpuParticlesStart :: proc(emitter: ^ParticleEmitter) {
	if emitter.gpu == nil do return
	emitter.gpu.start = emitter.gpu.clock
	emitter.gpu.stopped = math.F64_MAX
}
@(private)
gpuParticlesStop :: proc(emitter: ^ParticleEmitter) {
	if emitter.gpu == nil do return
	emitter.gpu.stopped = min(emitter.gpu.stopped, emitter.gpu.clock)
}

@(private="file")
gpuParticlesState :: proc(emitter: ^ParticleEmitter) -> ^GPUParticles {
	if emitter.gpu == nil {
		emitter.gpu = new(GPUParticles, Node_GetAllocator(emitter))
		emitter.gpu.stopped = emitter.emitting ? math.F64_MAX : 0
	}
	return emitter.gpu
}

// Frees an emitter's SDL objects (its node's destroy)
@(private)
gpuParticlesDestroy :: proc(emitter: ^ParticleEmitter) {
	g := emitter.gpu
	if g == nil do return
	if g.targetTexture != nil do sdl.DestroyTexture(g.targetTexture)
	if g.device != nil {
		if g.target != nil do sdl.ReleaseGPUTexture(g.device, g.target)
		if g.path != nil do sdl.ReleaseGPUBuffer(g.device, g.path)
		if g.upload != nil do sdl.ReleaseGPUTransferBuffer(g.device, g.upload)
	}
	// Only the SDL objects: the clock, the runs and the path carry on
	g.target, g.targetTexture, g.path, g.upload, g.device, g.renderer, g.size = nil, nil, nil, nil, nil, nil, {}
	g.active = false
}

// Frees the shared pipelines (Game_Destroy, Game_ReleaseShaders: before the renderer goes)
@(private)
gpuParticleResourcesDestroy :: proc(game: ^Game) {
	r := &game.gpuParticles
	if r.device != nil {
		if r.blend != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, r.blend)
		if r.add != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, r.add)
		if r.sampler != nil do sdl.ReleaseGPUSampler(r.device, r.sampler)
		if r.white != nil do sdl.ReleaseGPUTexture(r.device, r.white)
	}
	r^ = {}
}

// The shared pipelines on this device (made the first time; nil when they can't be)
@(private="file")
gpuParticleResources :: proc(game: ^Game, device: ^sdl.GPUDevice) -> ^GPUParticleResources {
	r := &game.gpuParticles
	if r.device == device && !r.failed do return r.blend != nil ? r : nil
	if r.device != nil && r.device != device do gpuParticleResourcesDestroy(game)
	r.device = device
	fail :: proc(r: ^GPUParticleResources, what: string) -> ^GPUParticleResources {
		log.warnf("GPU particles: %s (%s): emitters simulate on the CPU", what, sdl.GetError())
		r.failed = true
		return nil
	}
	vert, okV := Shader_ParseBundle(PARTICLES_VERT, context.temp_allocator)
	frag, okF := Shader_ParseBundle(PARTICLES_FRAG, context.temp_allocator)
	if !okV || !okF do return fail(r, "the shaders can't be read")
	formats := sdl.GetGPUShaderFormats(device)
	make_shader :: proc(device: ^sdl.GPUDevice, b: ShaderBundle, stage: sdl.GPUShaderStage, formats: sdl.GPUShaderFormat) -> ^sdl.GPUShader {
		info := sdl.GPUShaderCreateInfo{stage = stage, num_samplers = u32(b.samplers), num_uniform_buffers = u32(b.uniformBuffers), num_storage_buffers = u32(b.storageBuffers)}
		if .SPIRV in formats {
			info.format, info.code, info.code_size, info.entrypoint = {.SPIRV}, raw_data(b.spirv), len(b.spirv), "main"
		} else if .MSL in formats {
			info.format, info.code, info.code_size, info.entrypoint = {.MSL}, raw_data(b.msl), len(b.msl), "main0"
		} else {
			return nil
		}
		return sdl.CreateGPUShader(device, info)
	}
	vs := make_shader(device, vert, .VERTEX, formats)
	fs := make_shader(device, frag, .FRAGMENT, formats)
	defer {
		if vs != nil do sdl.ReleaseGPUShader(device, vs)
		if fs != nil do sdl.ReleaseGPUShader(device, fs)
	}
	if vs == nil || fs == nil do return fail(r, "the shaders can't be made")
	pipeline :: proc(device: ^sdl.GPUDevice, vs, fs: ^sdl.GPUShader, additive: bool) -> ^sdl.GPUGraphicsPipeline {
		// Premultiplied colors: over (alpha), or added
		target := sdl.GPUColorTargetDescription{
			format = .B8G8R8A8_UNORM,
			blend_state = {
				enable_blend = true,
				src_color_blendfactor = .ONE, dst_color_blendfactor = additive ? .ONE : .ONE_MINUS_SRC_ALPHA, color_blend_op = .ADD,
				src_alpha_blendfactor = .ONE, dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA, alpha_blend_op = .ADD,
			},
		}
		info := sdl.GPUGraphicsPipelineCreateInfo{
			vertex_shader = vs,
			fragment_shader = fs,
			primitive_type = .TRIANGLELIST,
			rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, enable_depth_clip = true},
			target_info = {color_target_descriptions = &target, num_color_targets = 1},
		}
		return sdl.CreateGPUGraphicsPipeline(device, info)
	}
	r.blend = pipeline(device, vs, fs, false)
	r.add = pipeline(device, vs, fs, true)
	if r.blend == nil || r.add == nil do return fail(r, "no pipeline")
	r.sampler = sdl.CreateGPUSampler(device, {min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .NEAREST, address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE})
	r.white = sdl.CreateGPUTexture(device, {type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER}, width = 1, height = 1, layer_count_or_depth = 1, num_levels = 1})
	if r.sampler == nil || r.white == nil do return fail(r, "no sampler")
	// The white pixel
	upload := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = 4})
	defer sdl.ReleaseGPUTransferBuffer(device, upload)
	if mapped := cast(^u32)sdl.MapGPUTransferBuffer(device, upload, false); mapped != nil {
		mapped^ = 0xffffffff
		sdl.UnmapGPUTransferBuffer(device, upload)
	}
	cmd := sdl.AcquireGPUCommandBuffer(device)
	copy := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(copy, {transfer_buffer = upload}, {texture = r.white, w = 1, h = 1, d = 1}, false)
	sdl.EndGPUCopyPass(copy)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	return r
}

/*
Draws an emitter's particles on the GPU (its draw, `gpu` on): returns false when it can't (no
GPU renderer, or the pipelines couldn't be made), and the CPU draws them instead.
*/
@(private)
gpuParticlesDraw :: proc(emitter: ^ParticleEmitter, renderer: ^sdl.Renderer) -> bool {
	g := gpuParticlesState(emitter)
	game := emitter.scene != nil ? emitter.scene.game : nil
	device := renderer != nil ? sdl.GetGPURendererDevice(renderer) : nil
	if game == nil || device == nil {
		g.active = false
		return false
	}
	resources := gpuParticleResources(game, device)
	if resources == nil {
		g.active = false
		return false
	}
	// The picture: the size of what's drawn to
	size := screenEffectsSize(renderer)
	w, h := i32(size.x), i32(size.y)
	if w <= 0 || h <= 0 do return true
	if g.target == nil || g.size != {w, h} || g.renderer != renderer || g.device != device {
		gpuParticlesDestroy(emitter)
		g.device, g.renderer, g.size = device, renderer, {w, h}
		g.target = sdl.CreateGPUTexture(device, {type = .D2, format = .B8G8R8A8_UNORM, usage = {.SAMPLER, .COLOR_TARGET}, width = u32(w), height = u32(h), layer_count_or_depth = 1, num_levels = 1})
		props := sdl.CreateProperties()
		defer sdl.DestroyProperties(props)
		_ = sdl.SetPointerProperty(props, sdl.PROP_TEXTURE_CREATE_GPU_TEXTURE_POINTER, g.target)
		_ = sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_FORMAT_NUMBER, i64(sdl.PixelFormat.BGRA32))
		_ = sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_ACCESS_NUMBER, i64(sdl.TextureAccess.TARGET))
		_ = sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_WIDTH_NUMBER, i64(w))
		_ = sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_HEIGHT_NUMBER, i64(h))
		g.targetTexture = g.target != nil ? sdl.CreateTextureWithProperties(renderer, props) : nil
		g.path = sdl.CreateGPUBuffer(device, {usage = {.GRAPHICS_STORAGE_READ}, size = GPU_PATH_SAMPLES * 16})
		g.upload = sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = GPU_PATH_SAMPLES * 16})
		if g.targetTexture == nil || g.path == nil || g.upload == nil {
			log.warnf("GPU particles: no picture to draw into (%s): simulating on the CPU", sdl.GetError())
			gpuParticlesDestroy(emitter)
			resources.failed = true
			emitter.gpu.active = false
			return false
		}
	}
	s := &emitter.settings
	count := clamp(s.gpuAmount, 1, MAX_GPU_PARTICLES)
	life := max(s.lifetime, 0.0001)

	// The path over the last lifetime, evenly spaced (the newest sample repeats before the first)
	samples: [GPU_PATH_SAMPLES][4]f32
	now := f32(g.clock)
	from := now - life
	step := life / f32(GPU_PATH_SAMPLES - 1)
	for k in 0 ..< GPU_PATH_SAMPLES {
		samples[k] = gpuPathAt(g, from + f32(k) * step)
	}
	if mapped := sdl.MapGPUTransferBuffer(device, g.upload, true); mapped != nil {
		(cast(^[GPU_PATH_SAMPLES][4]f32)mapped)^ = samples
		sdl.UnmapGPUTransferBuffer(device, g.upload)
	}

	// The view: particle space to the picture's pixels
	base := drawState().transform
	view := base
	if !s.localSpace {
		world := Node_GetRenderWorldTransform(emitter)
		if abs(world.x.x * world.y.y - world.y.x * world.x.y) < 1e-12 do return true
		view = Transform2D_Multiply(base, Transform2D_Inverse(world))
	}
	tint := drawState().tint
	tf := [4]f32{f32(tint.r) / 255, f32(tint.g) / 255, f32(tint.b) / 255, f32(tint.a) / 255}
	color :: proc(c: sdl.Color, tint: [4]f32) -> [4]f32 {
		return {f32(c.r) / 255 * tint[0], f32(c.g) / 255 * tint[1], f32(c.b) / 255 * tint[2], f32(c.a) / 255 * tint[3]}
	}
	gravity: [2]f32
	if l := s.gravityDirection.x * s.gravityDirection.x + s.gravityDirection.y * s.gravityDirection.y; l > 0.0001 {
		gravity = s.gravityDirection / math.sqrt(l) * s.gravityVelocity
	}
	shape: f32 = 0
	switch s.shape {
	case .Rectangle: shape = 1
	case .Texture: shape = emitter.texture != nil ? 2 : 1
	case .Circle, .Ellipse, .Line, .Pixel, .Custom: shape = 0
	}
	stoppedAt := g.stopped == math.F64_MAX ? f32(1e30) : f32(g.stopped)
	p := GPUParticleParams{
		view0 = {view.x.x, view.x.y, view.y.x, view.y.y},
		view1 = {view.origin.x, view.origin.y, f32(w), f32(h)},
		timing = {now, f32(g.start), emitter.emitting ? 1e30 : stoppedAt, life},
		emission = {f32(count), life * (1 - clamp(s.burst, 0, 1)), s.continuous ? 1 : 0, GPU_PATH_SAMPLES},
		pathTime = {from, step, s.localSpace ? 1 : 0, 0},
		spread = {s.spread.x, s.spread.y, math.to_radians(s.angle), math.to_radians(s.angleSpread * s.angleVariance)},
		speed = {s.velocity, s.velocitySpread * s.velocityVariance, s.acceleration, s.velocityScale},
		force = {gravity.x, gravity.y, s.wind.x, s.wind.y},
		sizes = {s.size.x, s.size.y, s.sizeSpread * s.sizeVariance, shape},
		scales = {s.scaleStart.x, s.scaleStart.y, s.scaleEnd.x, s.scaleEnd.y},
		spin = {math.to_radians(s.rotation), math.to_radians(s.rotationSpread * s.rotationVariance), math.to_radians(s.torque), math.to_radians(s.torqueSpread * s.torqueVariance)},
		spin2 = {math.to_radians(s.torqueAcceleration), s.colorVariance, 0, 0},
	}
	if s.useColorRamp && s.colorRamp.count > 0 {
		n := min(s.colorRamp.count, 8)
		p.spin2[2] = f32(n)
		for k in 0 ..< n {
			p.colors[k] = color(s.colorRamp.stops[k].color, tf)
			p.stops[k / 4][k % 4] = s.colorRamp.stops[k].position
		}
	} else {
		p.colors[0] = color(s.particleColor, tf)
		p.colors[1] = color(s.colorEnd, tf)
	}
	fragShape := [4]f32{shape, 0, 0, 0}

	// Upload the path, then draw every particle into the picture
	cmd := sdl.AcquireGPUCommandBuffer(device)
	if cmd == nil do return true
	copy := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(copy, {transfer_buffer = g.upload}, {buffer = g.path, size = GPU_PATH_SAMPLES * 16}, true)
	sdl.EndGPUCopyPass(copy)
	target := sdl.GPUColorTargetInfo{texture = g.target, clear_color = {0, 0, 0, 0}, load_op = .CLEAR, store_op = .STORE, cycle = true}
	pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
	additive := drawState().blend == .Add
	sdl.BindGPUGraphicsPipeline(pass, additive ? resources.add : resources.blend)
	buffers := [1]^sdl.GPUBuffer{g.path}
	sdl.BindGPUVertexStorageBuffers(pass, 0, &buffers[0], 1)
	texture := resources.white
	if shape == 2 {
		if t := cast(^sdl.GPUTexture)sdl.GetPointerProperty(sdl.GetTextureProperties(emitter.texture), sdl.PROP_TEXTURE_GPU_TEXTURE_POINTER, nil); t != nil do texture = t
	}
	binding := sdl.GPUTextureSamplerBinding{texture = texture, sampler = resources.sampler}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	sdl.PushGPUVertexUniformData(cmd, 0, &p, size_of(p))
	sdl.PushGPUFragmentUniformData(cmd, 0, &fragShape, size_of(fragShape))
	sdl.DrawGPUPrimitives(pass, u32(count * 6), 1, 0, 0)
	sdl.EndGPURenderPass(pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)

	// The picture where the emitter is in the scene's drawing
	sdl.SetTextureBlendMode(g.targetTexture, additive ? sdl.BLENDMODE_ADD_PREMULTIPLIED : sdl.BLENDMODE_BLEND_PREMULTIPLIED)
	dst := sdl.FRect{0, 0, f32(w), f32(h)}
	sdl.RenderTexture(renderer, g.targetTexture, nil, &dst)
	g.active = true
	return true
}

// Where the emitter was at a time: between its recorded positions (before the first: the first)
@(private="file")
gpuPathAt :: proc(g: ^GPUParticles, t: f32) -> [4]f32 {
	if g.ringCount == 0 do return {}
	newest := (g.ringHead + GPU_PATH_RING - 1) % GPU_PATH_RING
	oldest := (g.ringHead + GPU_PATH_RING - g.ringCount) % GPU_PATH_RING
	if t >= g.ring[newest][0] do return {g.ring[newest][1], g.ring[newest][2], g.ring[newest][3], 0}
	if t <= g.ring[oldest][0] do return {g.ring[oldest][1], g.ring[oldest][2], g.ring[oldest][3], 0}
	// From the newest back (recent times are asked for most)
	for k in 1 ..< g.ringCount {
		a := g.ring[(newest + GPU_PATH_RING - k) % GPU_PATH_RING]
		b := g.ring[(newest + GPU_PATH_RING - k + 1) % GPU_PATH_RING]
		if t >= a[0] {
			f := (t - a[0]) / max(b[0] - a[0], 1e-6)
			return {a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f, 0}
		}
	}
	return {g.ring[oldest][1], g.ring[oldest][2], g.ring[oldest][3], 0}
}
