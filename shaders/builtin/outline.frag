#version 450
// Built-in effect (shaders.odin). Compiled by tools/compile_shaders into the .frag.shader beside it
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;
layout(set = 2, binding = 0) uniform sampler2D u_texture;
// A line around the opaque pixels, drawn over the transparent pixels next to them (the picture
// needs transparent room around it: a sheet's frames need a gap)
layout(set = 3, binding = 0) uniform Params {
	vec4 outlineColor; // color default=#ffffff label=Outline color
	float width;       // default=1 min=0 max=8 label=Width (pixels)
	vec2 texelSize;    // filled by the engine
};
void main() {
	vec4 c = texture(u_texture, v_uv);
	float edge = 0.0;
	vec2 d = texelSize * width;
	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.785398;
		edge = max(edge, texture(u_texture, v_uv + vec2(cos(a), sin(a)) * d).a);
	}
	// Inside: the picture; outside, next to it: the outline
	vec4 line = vec4(outlineColor.rgb, outlineColor.a * edge * (1.0 - c.a));
	vec4 mixed = vec4(mix(line.rgb, c.rgb, c.a), max(c.a, line.a));
	o_color = mixed * v_color;
}
