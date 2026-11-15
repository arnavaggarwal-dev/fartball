shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
// Translucent neon shell: faint face-on, stronger at grazing angles, a 2 m grid
// that flares as action pulses roll across it.
#include "res://shaders/pulse.gdshaderinc"

uniform float base_alpha = 0.06;
uniform float rim_alpha = 0.45;
uniform float grid_alpha = 0.18;

varying vec3 wp;
varying vec3 wn;

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wn = abs(NORMAL);
}

void fragment() {
	float rim = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.0);
	// grid lines along the two axes that run across this face, with a soft halo that
	// fakes bloom (engine glow costs ~10 ms on GL Compatibility, this costs nothing)
	vec3 g = abs(fract(wp * 0.5) - 0.5) * 2.0;  // 1 on a line, 0 mid-cell
	vec3 mask = 1.0 - step(vec3(0.7), wn);
	vec3 core3 = smoothstep(vec3(0.88), vec3(0.97), g) * mask;
	vec3 halo3 = pow(g, vec3(12.0)) * mask;
	float grid = max(max(core3.x, core3.y), core3.z);
	float halo = max(max(halo3.x, halo3.y), halo3.z);
	vec3 p = pulses(wp);
	float pl = clamp(max(max(p.r, p.g), p.b), 0.0, 1.0);
	ALBEDO = mood * (0.7 + grid + 0.5 * halo) + p * (1.2 + 2.0 * grid + 1.5 * halo);
	ALPHA = clamp(base_alpha + rim_alpha * rim + grid_alpha * grid + 0.12 * halo + pl * (0.35 + 0.5 * grid + 0.4 * halo), 0.0, 1.0);
}
