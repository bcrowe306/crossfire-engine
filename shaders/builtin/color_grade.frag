#version 450
// Built-in effect (shaders.odin). Compiled by tools/compile_shaders into the .frag.shader beside it
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;
layout(set = 2, binding = 0) uniform sampler2D u_texture;
// Color grading over the scene (or a node): brightness, contrast, saturation, a tint, a vignette
layout(set = 3, binding = 0) uniform Params {
	float brightness; // default=0 min=-1 max=1 label=Brightness
	float contrast;   // default=1 min=0 max=3 label=Contrast
	float saturation; // default=1 min=0 max=3 label=Saturation
	vec4 tint;        // color default=#ffffff label=Tint
	float vignette;   // default=0 min=0 max=1 label=Vignette
};
void main() {
	vec4 c = texture(u_texture, v_uv) * v_color;
	vec3 rgb = c.rgb + brightness;
	rgb = (rgb - 0.5) * contrast + 0.5;
	float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
	rgb = mix(vec3(l), rgb, saturation) * tint.rgb;
	vec2 d = v_uv - 0.5;
	rgb *= 1.0 - vignette * smoothstep(0.2, 0.75, length(d) * 1.2);
	o_color = vec4(clamp(rgb, 0.0, 1.0), c.a);
}
