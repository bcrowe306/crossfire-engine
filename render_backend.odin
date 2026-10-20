package crossfire

import "core:log"
import sdl "vendor:sdl3"

/*
Which SDL renderer a game draws with: a project setting (project.xml's `renderer`, format 11),
overridden by the player's `--renderer <name>`. `Auto` lets SDL choose (OpenGL on Linux,
Direct3D 11 on Windows, Metal on macOS). One that this machine's SDL doesn't have, or that fails
to start, falls back to SDL's choice with a warning. The browser always uses WebGL.

Example:
	// Given: window: ^sdl.Window
	renderer := e.Application_CreateRenderer(window, .Vulkan)
*/
RenderBackend :: enum {
	// SDL's choice for the platform
	Auto,
	OpenGL,
	OpenGLES2,
	Vulkan,
	// SDL's GPU API (Vulkan, Direct3D 12 or Metal underneath)
	GPU,
	Direct3D11,
	Direct3D12,
	Metal,
	// On the CPU: works everywhere, slowest
	Software,
}

// A backend's SDL driver name, how it's shown, and where it exists
RenderBackendInfo :: struct {
	// For SDL_CreateRenderer (nil: SDL's choice)
	driver: cstring,
	// The name shown to people (the editor's Project Settings)
	label: string,
	// The platforms it exists on, as text for people
	platforms: string,
}

// Each backend's SDL driver name, label and platforms
RENDER_BACKENDS := [RenderBackend]RenderBackendInfo{
	.Auto       = {nil, "Auto (SDL's choice)", "Every platform"},
	.OpenGL     = {"opengl", "OpenGL", "Linux, Windows, macOS"},
	.OpenGLES2  = {"opengles2", "OpenGL ES 2", "Linux, Windows, mobile"},
	.Vulkan     = {"vulkan", "Vulkan", "Linux, Windows (macOS through MoltenVK)"},
	.GPU        = {"gpu", "SDL GPU", "Linux, Windows, macOS"},
	.Direct3D11 = {"direct3d11", "Direct3D 11", "Windows"},
	.Direct3D12 = {"direct3d12", "Direct3D 12", "Windows"},
	.Metal      = {"metal", "Metal", "macOS"},
	.Software   = {"software", "Software", "Every platform"},
}

/*
Whether this machine's SDL has the backend's driver (Auto always). It doesn't say the driver
starts: a missing GPU driver only shows when the renderer is created.

Inputs:
- backend: The backend

Returns:
- true if SDL was built with its driver
*/
RenderBackend_Available :: proc(backend: RenderBackend) -> bool {
	driver := RENDER_BACKENDS[backend].driver
	if driver == nil do return true
	for i in 0 ..< sdl.GetNumRenderDrivers() do if sdl.GetRenderDriver(i) == driver do return true
	return false
}

/*
The backend named by `name`: its enum name ("Vulkan") or SDL driver name ("vulkan"), any case.

Inputs:
- name: The name

Returns:
- The backend and true, or .Auto and false for an unknown name

Example:
	if backend, ok := e.RenderBackend_Parse("opengl"); ok do log.infof("using %v", backend)
*/
RenderBackend_Parse :: proc(name: string) -> (RenderBackend, bool) {
	for info, backend in RENDER_BACKENDS {
		if equalFold(name, enumName(backend)) || (info.driver != nil && equalFold(name, string(info.driver))) do return backend, true
	}
	return .Auto, false
}

/*
Creates the window's renderer with a backend, falling back to SDL's choice (with a warning) when
it isn't there or doesn't start. Logs the renderer in use. In the browser the backend is
ignored (WebGL).

Inputs:
- window: The window to draw in
- backend: The backend to try first

Returns:
- The renderer, nil only if none at all could be created (SDL's error is logged)
*/
Application_CreateRenderer :: proc(window: ^sdl.Window, backend: RenderBackend) -> ^sdl.Renderer {
	// The browser has WebGL only
	driver := PLATFORM_WEB ? nil : RENDER_BACKENDS[backend].driver
	renderer := sdl.CreateRenderer(window, driver)
	if renderer == nil && driver != nil {
		log.warnf("Renderer %s isn't available (%s): letting SDL choose", RENDER_BACKENDS[backend].label, sdl.GetError())
		renderer = sdl.CreateRenderer(window, nil)
	}
	if renderer == nil {
		log.error("Error creating renderer:", sdl.GetError())
		return nil
	}
	log.infof("Renderer: %s", sdl.GetRendererName(renderer))
	return renderer
}

@(private="file")
enumName :: proc(backend: RenderBackend) -> string {
	names := [RenderBackend]string{
		.Auto = "Auto", .OpenGL = "OpenGL", .OpenGLES2 = "OpenGLES2", .Vulkan = "Vulkan", .GPU = "GPU",
		.Direct3D11 = "Direct3D11", .Direct3D12 = "Direct3D12", .Metal = "Metal", .Software = "Software",
	}
	return names[backend]
}

@(private="file")
equalFold :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'Z' do x += 32
		if y >= 'A' && y <= 'Z' do y += 32
		if x != y do return false
	}
	return true
}
