#version 450
// GPU particles' pixels (gpu_particles.odin): a soft circle, a rectangle, or the texture, in the
// particle's color; premultiplied, for the emitter's picture
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;
layout(set = 2, binding = 0) uniform sampler2D u_texture;
layout(set = 3, binding = 0) uniform Shape {
	vec4 shape; // 0 circle, 1 rectangle, 2 texture; unused
};
void main() {
	vec4 c = v_color;
	if (shape.x > 1.5) {
		c *= texture(u_texture, v_uv);
	} else if (shape.x < 0.5) {
		float d = length(v_uv - 0.5) * 2.0;
		c.a *= 1.0 - smoothstep(0.85, 1.0, d);
	}
	o_color = vec4(c.rgb * c.a, c.a);
}
