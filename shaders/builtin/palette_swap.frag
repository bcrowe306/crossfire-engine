#version 450
// Built-in effect (shaders.odin). Compiled by tools/compile_shaders into the .frag.shader beside it
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;
layout(set = 2, binding = 0) uniform sampler2D u_texture;
// Replaces up to four colors (within the tolerance) with others: team colors, skins
layout(set = 3, binding = 0) uniform Params {
	vec4 from1;      // color default=#ff0000 label=Color 1
	vec4 to1;        // color default=#ff0000 label=Becomes 1
	vec4 from2;      // color default=#00ff00 label=Color 2
	vec4 to2;        // color default=#00ff00 label=Becomes 2
	vec4 from3;      // color default=#0000ff label=Color 3
	vec4 to3;        // color default=#0000ff label=Becomes 3
	vec4 from4;      // color default=#ffff00 label=Color 4
	vec4 to4;        // color default=#ffff00 label=Becomes 4
	float tolerance; // default=0.1 min=0 max=1 label=Tolerance
};
vec3 swap(vec3 c, vec4 from, vec4 to) { return distance(c, from.rgb) <= tolerance ? to.rgb : c; }
void main() {
	vec4 c = texture(u_texture, v_uv);
	vec3 rgb = swap(swap(swap(swap(c.rgb, from1, to1), from2, to2), from3, to3), from4, to4);
	o_color = vec4(rgb, c.a) * v_color;
}
