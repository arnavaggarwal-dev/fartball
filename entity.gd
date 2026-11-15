class_name Entity
extends RigidBody3D
## Ball or blob. Jolt does collisions; this adds ground friction, walking, and for
## blobs a self-righting controller that switches off while stunned (ragdoll tumble).

@export var r := 0.85
@export var is_ball := false
@export var air_fric := 0.15
@export var color := Color.WHITE
## Gas vents through a choked orifice: flow is proportional to the gas left, so thrust
## decays exponentially with this fixed time constant (seconds), whatever the charge.
@export var vent_tau := 0.18
## Thrust acts this far (m) above the centre of mass, so a hard burn pitches you forward.
@export var nozzle_arm := 0.1

var ground_fric := 2.5
var in_cloud := false
var grounded := false
var prev_vel := Vector3.ZERO  # velocity before the latest physics step, for impact speeds
# last 6 physics steps (50 ms) of velocity: Jolt's speculative contacts start braking a
# body before body_entered fires, so impact speed is read from this short history
var vel_hist: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var vel_i := 0
var stun := 0.0  # seconds left of limp ragdoll tumbling
var gas := 100.0
var cd := 0.0
var aim := Vector3(1, 0, 0)
var squash := 0.0
var walk := Vector3.ZERO
var burn_j := 0.0  # impulse still in the chamber (N*s)
var burn_dir := Vector3.ZERO  # thrust direction in body space, fixed at release
var thrust := Vector3.ZERO  # current thrust force (world), drives the Exhaust gas particles
# ball-only touch tracking
var last_toucher: Entity
var touch_pos := Vector3.ZERO
var wall_since_touch := false

@onready var inner: Node3D = get_node_or_null("Inner")


func _ready() -> void:
	if inner:
		# BodyMat is local_to_scene: each player gets its own team tint over the shared texture
		$Inner/Body.material_override.albedo_color = color.lerp(Color.WHITE, 0.45)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var dt := state.step
	prev_vel = state.linear_velocity
	vel_hist[vel_i % vel_hist.size()] = prev_vel
	vel_i += 1
	grounded = false
	for i in state.get_contact_count():
		if state.get_contact_local_normal(i).y > 0.5:
			grounded = true
			break
	var v := state.linear_velocity
	var f := exp(-(ground_fric if grounded else air_fric) * dt)
	if in_cloud:
		f *= exp(-2.5 * dt)
	v.x *= f
	v.z *= f
	if not is_ball and grounded and walk != Vector3.ZERO and Vector2(v.x, v.z).length() < 3.6:
		v += walk * 22 * dt
	state.linear_velocity = v
	thrust = Vector3.ZERO
	if burn_j > 0.3:  # below this the dribble isn't worth simulating
		var dj := burn_j * (1 - exp(-dt / vent_tau))  # exact exponential vent over this step
		burn_j -= dj
		var b := state.transform.basis
		thrust = (b * burn_dir).normalized() * dj / dt  # thrust turns with the body
		state.apply_force(thrust, b * (center_of_mass + Vector3(0, nozzle_arm, 0)))
	else:
		burn_j = 0.0
	if is_ball:
		if grounded:
			state.angular_velocity *= f
		return

	stun = maxf(0, stun - dt)
	if stun > 0:
		return
	# PD on angular velocity (inertia-independent): stand up, then turn to face aim
	var b := state.transform.basis
	var err := b.y.cross(Vector3.UP)
	var face := Vector3(b.x.x, 0, b.x.z)
	if face.length_squared() > 0.01 and grounded:
		err += Vector3.UP * face.normalized().signed_angle_to(Vector3(aim.x, 0, aim.z), Vector3.UP) * 0.4
	var kp := 100.0 if grounded else 15.0
	var kd := 14.0 if grounded else 2.0
	var w := state.angular_velocity
	state.angular_velocity = w + (err * kp - w * kd) * dt


## Load the chamber: `impulse` N*s vents along world `dir` (locked to the body from now on).
func vent(dir: Vector3, impulse: float) -> void:
	burn_j += impulse
	burn_dir = global_basis.inverse() * dir


## Fastest this body was moving along `dir` in the last 50 ms.
func peak_speed_along(dir: Vector3) -> float:
	var best := -INF
	for v in vel_hist:
		best = maxf(best, v.dot(dir))
	return best


func knock(impact: float) -> void:
	if not is_ball and impact > 0:
		stun = maxf(stun, clampf(impact * 0.09, 0.3, 1.6))


func _on_body_entered(body: Node) -> void:
	var other_v: Vector3 = body.prev_vel if body is Entity else Vector3.ZERO
	var impact := (prev_vel - other_v).length()
	if impact > 6:
		knock(impact)


func play_fart(charge: float, burst: bool) -> void:
	var s := "Burst" if burst else ("Small" if charge < 0.33 else ("Mid" if charge < 0.7 else "Big"))
	get_node("Sfx/" + s).play()
