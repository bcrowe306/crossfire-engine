#version 450
// GPU particles (gpu_particles.odin): every particle worked out from its index and the time,
// with no state kept between frames. Compiled by tools/compile_shaders into the .shader beside it.
// Six vertices a particle (two triangles); gl_VertexIndex / 6 is the particle.

// Where the emitter was: samples evenly spaced in time (x, y, rotation in radians, unused)
layout(set = 0, binding = 0) readonly buffer Path { vec4 path[]; };

layout(set = 1, binding = 0) uniform Params {
	vec4 view0;     // the view: its x axis (x.x, x.y) and y axis (y.x, y.y)
	vec4 view1;     // its origin (x, y), the target's width and height in pixels
	vec4 timing;    // now, when it started, when it stopped (huge while emitting), lifetime
	vec4 emission;  // particles, emission time per cycle, continuous (1 or 0), path samples
	vec4 pathTime;  // the first sample's time, seconds between samples, local space (1 or 0), unused
	vec4 spread;    // spread x, y, angle (radians), angle spread (radians)
	vec4 speed;     // velocity, velocity spread, acceleration, speed scale
	vec4 force;     // gravity x, y, wind x, y
	vec4 sizes;     // size x, y, size spread, shape (0 circle, 1 rectangle, 2 texture)
	vec4 scales;    // scale start x, y, scale end x, y
	vec4 spin;      // rotation (radians), rotation spread, torque (radians/s), torque spread
	vec4 spin2;     // torque acceleration, color variance, ramp stops (0: start and end colors), unused
	vec4 colors[8]; // the ramp's colors (or start, end)
	vec4 stops[2];  // the ramp's positions, 4 a vec4
};

layout(location = 0) out vec4 v_color;
layout(location = 1) out vec2 v_uv;

uint hash(uint x) {
	x ^= x >> 16; x *= 0x7feb352du;
	x ^= x >> 15; x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}
// A random number from -1 to 1 for this particle's life (`k`: which cycle), the `j`th
float rnd(uint i, uint k, uint j) {
	return float(hash(i * 2654435761u ^ hash(k * 40503u + j * 977u))) / 4294967295.0 * 2.0 - 1.0;
}

vec3 pathAt(float t) {
	float n = emission.w;
	float f = clamp((t - pathTime.x) / max(pathTime.y, 1e-6), 0.0, n - 1.0);
	int a = int(floor(f));
	int b = min(a + 1, int(n) - 1);
	return mix(path[a].xyz, path[b].xyz, fract(f));
}

float stopAt(int s) { return stops[s / 4][s % 4]; }

vec4 colorAt(float t) {
	int count = int(spin2.z);
	if (count <= 0) return mix(colors[0], colors[1], t);
	if (t <= stopAt(0)) return colors[0];
	for (int s = 1; s < count; s++) {
		if (t <= stopAt(s)) {
			float a = stopAt(s - 1), b = stopAt(s);
			return mix(colors[s - 1], colors[s], (t - a) / max(b - a, 1e-6));
		}
	}
	return colors[count - 1];
}

void main() {
	uint i = uint(gl_VertexIndex / 6);
	int corner = gl_VertexIndex % 6;
	float now = timing.x, start = timing.y, stopped = timing.z, life = max(timing.w, 1e-4);
	float count = emission.x;
	float offset = float(i) / max(count, 1.0) * emission.y;
	float since = now - start - offset;
	float k = emission.z > 0.5 ? floor(since / life) : 0.0;
	float born = start + k * life + offset;
	float age = now - born;
	// Not born yet, past its life, or born after emitting stopped: nothing to draw
	if (since < 0.0 || age < 0.0 || age >= life || born > stopped) {
		gl_Position = vec4(2.0, 2.0, 0.0, 1.0);
		v_color = vec4(0.0);
		v_uv = vec2(0.0);
		return;
	}
	uint cycle = uint(max(k, 0.0));
	float t = age / life;
	vec3 at = pathAt(born);
	// Where it starts: the emitter then, plus the spread (turned with the emitter)
	vec2 off = vec2(rnd(i, cycle, 0u) * spread.x, rnd(i, cycle, 1u) * spread.y);
	float c = cos(at.z), s = sin(at.z);
	vec2 p0 = at.xy + vec2(c * off.x - s * off.y, s * off.x + c * off.y);
	float angle = spread.z + rnd(i, cycle, 2u) * spread.w + at.z;
	vec2 dir = vec2(cos(angle), sin(angle));
	vec2 v0 = dir * (speed.x + rnd(i, cycle, 3u) * speed.y);
	vec2 accel = force.xy + force.zw + dir * speed.z;
	vec2 p = p0 + (v0 * age + 0.5 * accel * age * age) * speed.w;
	float rotation = spin.x + rnd(i, cycle, 4u) * spin.y + (spin.z + rnd(i, cycle, 5u) * spin.w) * age + 0.5 * spin2.x * age * age;
	vec2 size = (sizes.xy + rnd(i, cycle, 6u) * sizes.z) * mix(scales.xy, scales.zw, t);
	// A circle's size is its radius
	if (sizes.w < 0.5) size = vec2(size.x * 2.0);
	vec4 color = colorAt(t);
	color.rgb = clamp(color.rgb + vec3(rnd(i, cycle, 7u), rnd(i, cycle, 8u), rnd(i, cycle, 9u)) * spin2.y, 0.0, 1.0);

	const vec2 corners[6] = vec2[6](vec2(-0.5, -0.5), vec2(0.5, -0.5), vec2(0.5, 0.5), vec2(-0.5, -0.5), vec2(0.5, 0.5), vec2(-0.5, 0.5));
	vec2 q = corners[corner] * size;
	float rc = cos(rotation), rs = sin(rotation);
	vec2 world = p + vec2(rc * q.x - rs * q.y, rs * q.x + rc * q.y);
	vec2 screen = view1.xy + view0.xy * world.x + view0.zw * world.y;
	gl_Position = vec4(screen.x / view1.z * 2.0 - 1.0, 1.0 - screen.y / view1.w * 2.0, 0.0, 1.0);
	v_color = color;
	v_uv = corners[corner] + 0.5;
}
