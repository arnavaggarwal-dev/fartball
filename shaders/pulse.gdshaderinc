// Neon pulses fired by game actions (main.gd arena_pulse). Shared by dome + pitch.
// A pulse is a glowing band that travels from an origin: a ring growing outward
// (dir = 0) or a flat front sweeping along dir (fart thrust direction).
uniform float now = 0.0;  // seconds, same clock main.gd stamps pulses with
uniform vec4 pulse_pos[8];  // xyz origin, w start time
uniform vec4 pulse_dir[8];  // xyz sweep direction (zero = ring), w speed m/s
uniform vec4 pulse_col[8];  // rgb neon colour, a strength
uniform vec3 mood : source_color = vec3(1.0, 0.25, 0.75);  // arena base glow

const float PULSE_LIFE = 2.5;
const float PULSE_WIDTH = 1.6;

vec3 pulses(vec3 wp) {
	vec3 sum = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		float age = now - pulse_pos[i].w;
		if (age < 0.0 || age > PULSE_LIFE) {
			continue;
		}
		vec3 rel = wp - pulse_pos[i].xyz;
		vec3 dir = pulse_dir[i].xyz;
		float d = dot(dir, dir) > 0.5 ? dot(rel, dir) : length(rel);
		float band = exp(-pow((d - age * pulse_dir[i].w) / PULSE_WIDTH, 2.0));
		sum += pulse_col[i].rgb * pulse_col[i].a * band * (1.0 - age / PULSE_LIFE);
	}
	return sum;
}
