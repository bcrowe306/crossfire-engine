#version 450
// Built-in effect (shaders.odin). Compiled by tools/compile_shaders into the .frag.shader beside it
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;
layout(set = 2, binding = 0) uniform sampler2D u_texture;
// An old TV over the screen: scanlines, curved glass, an aperture grille, a dark border
// (adapted from the "Lightweight CRT Effect" SDL's GPU renderer test uses)
layout(set = 3, binding = 0) uniform Params {
	float scanlines;   // default=0.5 min=0 max=1 label=Scanlines
	float warp;        // default=0.05 min=0 max=0.3 label=Curve
	float vignette;    // default=0.5 min=0 max=1 label=Dark border
	float grille;      // default=0.05 min=0 max=1 label=Grille
	float brightness;  // default=1.2 min=0.5 max=2 label=Brightness
	vec2 textureSize;  // filled by the engine
};
void main() {
	vec2 uv = v_uv;
	vec2 delta = uv - 0.5;
	uv += delta * dot(delta, delta) * warp;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) { o_color = vec4(0.0, 0.0, 0.0, 1.0); return; }
	float line = sin(uv.y * textureSize.y * 3.14159265) * 0.5 + 0.5;
	line = mix(1.0, line, scanlines * 0.5);
	float g = mod(uv.x * textureSize.x, 3.0) < 1.5 ? 0.95 : 1.05;
	g = mix(1.0, g, grille * 0.5);
	vec4 c = texture(u_texture, uv) * v_color;
	vec2 v = uv * (1.0 - uv);
	float border = mix(1.0, v.x * v.y * 15.0, vignette * 0.7);
	o_color = vec4(c.rgb * line * g * border * brightness, c.a);
}
