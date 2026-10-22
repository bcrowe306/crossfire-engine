#version 450
// Text drawn from an MSDF atlas (fonts.odin): each texel holds three distances to the glyph's
// edge; their median, scaled to screen pixels, gives a sharp edge at any size.
// Compiled by tools/compile_shaders into the .frag.shader beside it
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;
layout(set = 2, binding = 0) uniform sampler2D u_texture;
layout(set = 3, binding = 0) uniform Params {
	float pxRange;  // default=4 min=1 max=32 label=Distance range
};
float median(float r, float g, float b) {
	return max(min(r, g), min(max(r, g), b));
}
void main() {
	vec3 msd = texture(u_texture, v_uv).rgb;
	// The atlas's distance range in screen pixels at this size
	vec2 unitRange = vec2(pxRange) / vec2(textureSize(u_texture, 0));
	vec2 screenTexSize = vec2(1.0) / fwidth(v_uv);
	float screenPxRange = max(0.5 * dot(unitRange, screenTexSize), 1.0);
	float distance = screenPxRange * (median(msd.r, msd.g, msd.b) - 0.5);
	float opacity = clamp(distance + 0.5, 0.0, 1.0);
	o_color = vec4(v_color.rgb, v_color.a * opacity);
}
