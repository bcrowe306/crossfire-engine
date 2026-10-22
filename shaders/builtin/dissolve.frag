#version 450
// Built-in effect (shaders.odin). Compiled by tools/compile_shaders into the .frag.shader beside it
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;
layout(set = 2, binding = 0) uniform sampler2D u_texture;
// Eats the picture away in a noisy pattern (amount 0: whole, 1: gone) with a glowing edge
layout(set = 3, binding = 0) uniform Params {
	float amount;     // default=0 min=0 max=1 label=Amount
	vec4 edgeColor;   // color default=#ff9a3c label=Edge color
	float edgeWidth;  // default=0.06 min=0 max=0.3 label=Edge width
	float scale;      // default=24 min=1 max=200 label=Noise scale
};
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
void main() {
	vec4 c = texture(u_texture, v_uv) * v_color;
	float n = noise(v_uv * scale) * 0.75 + noise(v_uv * scale * 2.7) * 0.25;
	float cut = amount * (1.0 + edgeWidth);
	if (n < cut - edgeWidth) { o_color = vec4(0.0); return; }
	float glow = 1.0 - smoothstep(0.0, max(edgeWidth, 0.0001), n - (cut - edgeWidth));
	o_color = vec4(mix(c.rgb, edgeColor.rgb, glow * step(0.001, amount)), c.a);
}
