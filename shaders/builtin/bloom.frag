#version 450
// Built-in effect (shaders.odin). Compiled by tools/compile_shaders into the .frag.shader beside it
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;
layout(set = 2, binding = 0) uniform sampler2D u_texture;
// Bright parts glow into their surroundings: what's over the threshold, blurred and added
layout(set = 3, binding = 0) uniform Params {
	float threshold;  // default=0.7 min=0 max=1 label=Threshold
	float intensity;  // default=1 min=0 max=4 label=Intensity
	float radius;     // default=6 min=0 max=32 label=Radius (pixels)
	vec2 texelSize;   // filled by the engine
};
vec3 bright(vec2 uv) {
	vec3 c = texture(u_texture, uv).rgb;
	float l = max(c.r, max(c.g, c.b));
	return c * smoothstep(threshold, min(threshold + 0.25, 1.0), l);
}
void main() {
	vec4 base = texture(u_texture, v_uv);
	vec3 glow = bright(v_uv) * 0.2;
	float total = 0.2;
	for (int ring = 1; ring <= 3; ring++) {
		float r = radius * float(ring) / 3.0;
		float w = 0.25 / float(ring);
		for (int i = 0; i < 8; i++) {
			float a = float(i) * 0.785398 + float(ring) * 0.4;
			glow += bright(v_uv + vec2(cos(a), sin(a)) * texelSize * r) * w;
			total += w;
		}
	}
	glow /= total;
	o_color = vec4(base.rgb + glow * intensity, base.a) * v_color;
}
