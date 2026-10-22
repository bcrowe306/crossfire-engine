#version 450
// Built-in effect (shaders.odin). Compiled by tools/compile_shaders into the .frag.shader beside it
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;
layout(set = 2, binding = 0) uniform sampler2D u_texture;
// Flashes the picture toward a color (white by default): set amount to 1, then fade it to 0
layout(set = 3, binding = 0) uniform Params {
	vec4 flashColor;  // color default=#ffffff label=Flash color
	float amount;     // default=0 min=0 max=1 label=Amount
};
void main() {
	vec4 c = texture(u_texture, v_uv) * v_color;
	o_color = vec4(mix(c.rgb, flashColor.rgb, clamp(amount * flashColor.a, 0.0, 1.0)), c.a);
}
