shader_type spatial;
// Striped pitch with neon markings: lines glow in the arena mood colour and flare
// as action pulses cross them; the grass picks up a faint wash of each pulse.
#include "res://shaders/pulse.gdshaderinc"

uniform vec2 size = vec2(40.0, 24.0);
uniform sampler2D grass_tex : source_color, filter_linear_mipmap, repeat_enable;

varying vec3 wp;

float ln(float d) {
	return 1.0 - step(0.115, abs(d));
}

// soft falloff around a line: fakes bloom on the neon markings
float halo(float d) {
	return exp(-pow(abs(d) / 0.45, 2.0));
}

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = (UV - 0.5) * size;
	vec2 a = abs(p);
	vec3 c = mix(vec3(0.263, 0.631, 0.212), vec3(0.298, 0.686, 0.247), mod(floor(UV.x * 10.0), 2.0));
	float bx = size.x * 0.5 - 0.16;
	float bz = size.y * 0.5 - 0.16;
	float l = max(ln(a.x - bx) * step(a.y, bz + 0.12), ln(a.y - bz) * step(a.x, bx + 0.12));
	l = max(l, ln(p.x));
	l = max(l, ln(length(p) - 3.2));
	l = max(l, ln(a.x - (bx - 5.0)) * step(a.y, 8.0));
	l = max(l, ln(a.y - 8.0) * step(bx - 5.0, a.x) * step(a.x, bx));
	float h = max(halo(a.x - bx) * step(a.y, bz), halo(a.y - bz) * step(a.x, bx));
	h = max(h, halo(p.x));
	h = max(h, halo(length(p) - 3.2));
	h = max(h, halo(a.x - (bx - 5.0)) * step(a.y, 8.0));
	h = max(h, halo(a.y - 8.0) * step(bx - 5.0, a.x) * step(a.x, bx));
	h *= 1.0 - l;
	vec3 pulse = pulses(wp);
	// real grass texture (4 m tiles) tinted by the mowing stripes
	vec3 grass = texture(grass_tex, p / 4.0).rgb;
	vec3 stripe = pow(c, vec3(2.2)) / 0.25;
	ALBEDO = mix(grass * stripe * 0.9, vec3(1.0), l * 0.8);
	ROUGHNESS = 0.95;
	EMISSION = l * (mood * 0.9 + pulse * 2.5) + h * (mood * 0.25 + pulse * 0.9) + pulse * 0.12;
}
