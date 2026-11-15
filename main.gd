extends Node3D
## Fartball: Godot port of proto2.html. All nodes live in main.tscn / character.tscn;
## this script only drives them. Ball and blobs are Jolt RigidBody3Ds (see entity.gd).

const W := 20.0
const D := 12.0
const GOAL_HW := 4.0
const GOAL_H := 4.5
const POCKET := 3.0
const SENS := 0.0025
const TRAJ_N := 70
const STAND_Y := 0.95  # blob origin height when standing on the floor
const GAS_DV := 0.52  # m/s of delta-v per unit of gas vented
const MODS := ["LOW GRAVITY", "GIANT BALL", "SLIPPERY PITCH"]
const YELLOW := Color("ffe14a")
const GREEN := Color("9be03a")
const RECORD_PATH := "user://record.txt"  # "wins losses"
# neon pulse colours (shaders/pulse.gdshaderinc)
const NEON_PINK := Color(1.0, 0.25, 0.75)  # idle arena mood
const NEON_YOU := Color(1.0, 0.45, 0.05)
const NEON_BOT := Color(0.6, 0.2, 1.0)
const NEON_TOUCH_YOU := Color(0.0, 0.95, 1.0)
const NEON_TOUCH_BOT := Color(1.0, 0.1, 0.85)
const NEON_WALL := Color(0.9, 0.95, 1.0)
const NEON_SLAM := Color(1.0, 0.1, 0.2)
const NEON_TOXIC := Color(0.25, 1.0, 0.1)
const NEON_GOAL := Color(0.75, 1.0, 0.0)
const PULSE_N := 8
const MY_FART_PATH := "user://my_fart.wav"
## your recorded fart replaces your stock farts, pitched so bigger farts still sound bigger
const MY_FART_PITCH := {"Burst": 1.35, "Small": 1.12, "Mid": 1.0, "Big": 0.8}
const MIC_GATE := 1500  # 16-bit sample level (about -27 dBFS) that counts as "fart started"
const MY_FART_MAX := 2.0  # seconds kept after the fart starts
const MY_FART_MAX_GAIN := 8.0  # cap on the volume boost (+18 dB) so quiet recordings don't blow up the hiss
const MIC_MAX_SEC := 10.0  # longest raw recording kept before trimming
const FAN_SLICES := 3
const MOAN_SPEED := 7.0  # m/s closing speed between you and the opponent that earns a moan

var web := OS.has_feature("web")  # browser build: CPU particles, lighter profile
var state := "menu"
var goals_you := 0
var goals_bot := 0
var overtime := false
var diff := 0.25
var modifier := ""
var wins := 0
var losses := 0
var yaw := 0.0
var pitch := 0.35
var first_person := false
var charging := false
var charge_start := 0
var cam_shake := 0.0
var cam_pos := Vector3(-15, 5, 0)
var cam_look := Vector3.ZERO
var pop_i := 0
var cloud_owner: Array[Entity] = []
var pulse_pos := PackedVector4Array()
var pulse_dir := PackedVector4Array()
var pulse_col := PackedVector4Array()
var pulse_i := 0
var pulse_clock := 0.0
var mood := NEON_PINK
var mood_target := NEON_PINK
var stock_farts := {}  # Sfx player name -> its stock AudioStreamRandomizer
var recording := false
var mic_frames := PackedVector2Array()
var browser_rec_pending := false
var fan_aps: Array[AnimationPlayer] = []
var fan_slice := 0
var fans_awake_until := 0  # web: fans only animate while cheering (msec)

@onready var player: Entity = $Player
@onready var opp: Entity = $Opp
@onready var ball: Entity = $Ball
@onready var ents: Array[Entity] = [player, opp, ball]
@onready var cam: Camera3D = $Camera
@onready var traj: MultiMesh = $Aim/Traj.multimesh
@onready var arrow: Node3D = $Aim/Arrow
@onready var ring: MeshInstance3D = $Aim/LandRing
@onready var arrow_mat: StandardMaterial3D = $Aim/Arrow/Shaft.material_override
@onready var traj_mat: StandardMaterial3D = ring.material_override
@onready var clouds: Array[Node] = $Clouds.get_children()
@onready var pops: Array[Node] = $HUD/UI/Pops.get_children()
@onready var neon_mats: Array[ShaderMaterial] = [$Arena/Dome.material_override, $Arena/Floor.material_override]


func _ready() -> void:
	for c in clouds:
		cloud_owner.append(null)
	for i in PULSE_N:
		pulse_pos.append(Vector4(0, 0, 0, -100))
		pulse_dir.append(Vector4.ZERO)
		pulse_col.append(Vector4.ZERO)
	if FileAccess.file_exists(RECORD_PATH):
		var rec := FileAccess.get_file_as_string(RECORD_PATH).split(" ")
		wins = int(rec[0])
		losses = int(rec[1]) if rec.size() > 1 else 0
	crowd_idle()
	if web:  # browser build: single-threaded wasm + WebGL, trim the costly bits
		$StadiumLight.shadow_enabled = false
		JavaScriptBridge.eval(BROWSER_REC_JS, true)
	for n in MY_FART_PITCH:
		stock_farts[n] = player.get_node("Sfx/" + n).stream
	if FileAccess.file_exists(MY_FART_PATH):
		use_my_fart(AudioStreamWAV.load_from_file(MY_FART_PATH))
	kickoff()


# ---------- helpers ----------
func gravity() -> float:
	return ProjectSettings.get_setting("physics/3d/default_gravity") * player.gravity_scale


func fwd() -> Vector3:
	return Vector3(cos(yaw), 0, sin(yaw))


func tilt(h: Vector3, el: float) -> Vector3:
	return Vector3(h.x * cos(el), sin(el), h.z * cos(el))


## launch elevation follows the camera: look up = lob, look down = drive (or dive when airborne)
func aim_el() -> float:
	var el := 0.75 - pitch * 1.1
	if player.grounded:
		el = maxf(0.08, el)
	return clampf(el, -0.9, 1.45)


func aim3() -> Vector3:
	return tilt(fwd(), aim_el())


func charge_level() -> float:
	return minf(1.0, (Time.get_ticks_msec() - charge_start) / 900.0)


func gas_cost(charge: float, burst: bool) -> float:
	return 12.0 if burst else 12.0 + 38.0 * charge


## Total delta-v of a fart. Exhaust leaves at a fixed (choked, sonic) speed, so the
## push is proportional to how much gas you vent: full charge ~26 m/s, burst ~6 m/s.
func fart_dv(charge: float, burst: bool) -> float:
	return GAS_DV * gas_cost(charge, burst)


# ---------- input ----------
func _input(event: InputEvent) -> void:
	var live := state == "play" or state == "goal" or state == "countdown"
	if event is InputEventMouseMotion:
		if live and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			yaw += event.relative.x * SENS
			pitch = clampf(pitch + event.relative.y * SENS, -0.6, 1.1)
	elif event is InputEventMouseButton and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		# first click only grabs the mouse; once captured, left click is the fart charge
		if live and event.pressed:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F3:
		%Fps.visible = not %Fps.visible
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("toggle_cam"):
		first_person = not first_person
	elif event.is_action_released("charge"):
		if charging:
			charging = false
			if state == "play":
				fart(player, aim3(), charge_level(), false)
	elif state == "play":
		if event.is_action_pressed("charge"):
			charging = true
			charge_start = Time.get_ticks_msec()
		elif event.is_action_pressed("burst"):
			fart(player, aim3(), 0.0, true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		charging = false


# ---------- fart! ----------
func fart(e: Entity, dir: Vector3, charge: float, burst: bool) -> bool:
	var cost := gas_cost(charge, burst)
	if e.gas < cost:
		if e == player:
			popup("out of gas…")
		return false
	e.gas -= cost
	if e.grounded:
		e.linear_velocity.y = maxf(e.linear_velocity.y, 1.5)  # pop off the floor so friction doesn't eat the burn
	e.vent(dir, fart_dv(charge, burst) * e.mass)  # thrust plays out in entity._integrate_forces
	e.squash = 1.0
	var origin := e.global_position - dir * e.r * 0.8
	origin.y = maxf(0.3, e.global_position.y - 0.3)
	# rear blast pushes whatever is behind you
	var reach := 3.0 if burst else 4.0 + 2.0 * charge
	for o in ents:
		if o == e:
			continue
		var to := o.global_position - origin
		var d := to.length()
		if d < reach and to.dot(dir) < 0.3 * d:
			var push := (1 - d / reach) * (5.0 if burst else 5.0 + 11.0 * charge) / o.mass * 0.5
			o.linear_velocity += to.normalized() * push + Vector3.UP * push * 0.3
			o.knock(push * 2)
			if o == ball:
				touch_ball(e)
	# neon band sweeps the arena the way you're flying
	arena_pulse(origin, NEON_YOU if e == player else NEON_BOT, 0.4 if burst else 0.6 + 0.8 * charge, dir, 16.0 + 14.0 * charge)
	if not burst and charge > 0.95:
		spawn_cloud(origin, e)
		arena_pulse(origin, NEON_TOXIC, 1.2)
		if e == player:
			popup("TOXIC CLOUD")
	if not burst and charge > 0.6:
		cam_shake = 0.25 + 0.35 * charge
	e.play_fart(charge, burst)
	return true


# ---------- contacts (signals wired in main.tscn) ----------
func touch_ball(by: Entity) -> void:
	var trail_col := NEON_TOUCH_YOU if by == player else NEON_TOUCH_BOT
	$Ball/Trail.process_material.color = trail_col
	$Ball/Trail/CPU.color = trail_col
	ball.last_toucher = by
	ball.touch_pos = by.global_position
	ball.wall_since_touch = false


func _on_ball_body_entered(body: Node) -> void:
	if body is Entity:
		touch_ball(body)
		var hit: float = (body.prev_vel - ball.prev_vel).length()
		if hit > 4:
			kick(hit)
			arena_pulse(ball.global_position, NEON_TOUCH_YOU if body == player else NEON_TOUCH_BOT, clampf(hit / 12, 0.4, 1.5))
	elif body == $Arena/Walls:
		ball.wall_since_touch = true
		if ball.prev_vel.length() > 5:
			thud(ball.prev_vel.length())
			arena_pulse(ball.global_position, NEON_WALL, clampf(ball.prev_vel.length() / 20, 0.3, 1.2))
	elif ball.prev_vel.y < -4:
		thud(-ball.prev_vel.y)


func _on_player_body_entered(body: Node) -> void:
	if body != opp:
		return
	var n := (opp.global_position - player.global_position).normalized()
	var you_in := player.peak_speed_along(n)  # your speed into the opponent
	var opp_in := opp.peak_speed_along(-n)  # its speed into you
	var slam := you_in + opp_in  # closing speed along the contact
	if slam > MOAN_SPEED and $MoanCooldown.is_stopped():
		# whoever was rammed harder moans; louder for bigger hits
		var victim := opp if you_in >= opp_in else player
		var moan: AudioStreamPlayer3D = victim.get_node("Sfx/Moan")
		moan.volume_db = linear_to_db(clampf(slam / 14.0, 0.6, 1.0))
		moan.play()
		hit_stop()
		$MoanCooldown.start()
	if slam > 9 and state == "play" and $SlamCooldown.is_stopped():
		popup("BODY SLAM")
		thud(slam)
		arena_pulse((player.global_position + opp.global_position) / 2, NEON_SLAM, 1.5)
		$SlamCooldown.start()


# ---------- AI ----------
func ai_update(dt: float) -> void:
	var o := opp
	var b := ball.global_position
	var op := o.global_position
	o.cd -= dt
	var target: Vector3
	if b.x > op.x + 0.5:  # ball is goal-side of the bot: get around it
		target = Vector3(b.x + ball.r + 1.8, 0, b.z + (1.8 if op.z > b.z else -1.8))
	else:
		var away := Vector3(b.x + W + 1, 0, b.z).normalized()
		target = Vector3(b.x, 0, b.z) + away * ball.r * 0.6
	if diff < 0.35 and b.x < -4:  # easy bot hangs back when the ball is far away
		target = Vector3(W - 4, 0, b.z * 0.4)
	var dir := Vector3(target.x - op.x, 0, target.z - op.z)
	var dist := dir.length()
	dir = dir.normalized()
	o.aim = dir
	o.walk = dir
	if o.cd <= 0 and o.grounded and o.stun <= 0:
		if dist <= 1.3:  # parked (easy bot at its post, or tucked behind the ball): take a pot-shot at the ball
			dir = Vector3(b.x - op.x, 0, b.z - op.z)
			dist = dir.length()
			dir = dir.normalized()
		var charge := minf(1, dist / 17) * (0.55 + 0.45 * diff)
		o.cd = 2.4 - 1.7 * diff + randf() * 0.6 if fart(o, tilt(dir, 0.38), charge, false) else 0.4
	if not o.grounded and o.linear_velocity.y < 0 and diff > 0.5 and o.gas > 40 and randf() < dt * diff * 1.5:
		fart(o, tilt(dir, 0.2), 0, true)


# ---------- fart gas + toxic clouds (particle nodes in the scenes) ----------
## Every effect is a GPUParticles3D with a CPUParticles3D "CPU" twin under it. Browsers
## compile GPU particle shaders on first use and that froze the whole browser at the
## first fart, so the web build drives the CPU twins; desktop keeps the GPU gas.
func fx(effect: Node) -> Node:
	return effect.get_node("CPU") if web else effect


## Exhaust gas leaves the nozzle opposite the thrust, at a rate proportional to it
## (thrust = mass flow x exhaust speed). The particle material does the gas physics:
## turbulence, buoyancy, drag, expansion, inherited velocity, floor/ceiling collision.
func update_exhaust(e: Entity) -> void:
	var nozzle: GPUParticles3D = e.get_node("Exhaust")
	var f := e.thrust.length()
	fx(nozzle).emitting = f > 0
	if f > 0:
		nozzle.amount_ratio = clampf(f / 140.0, 0.2, 1.0)
		var back := -e.thrust / f
		nozzle.look_at(nozzle.global_position + back, Vector3.UP if absf(back.y) < 0.95 else Vector3.RIGHT)


# ponytail: 3 cloud nodes; a 4th simultaneous cloud takes over the one closest to expiring
func spawn_cloud(pos: Vector3, owner: Entity) -> void:
	var best := 0
	for i in clouds.size():
		if cloud_life(i).time_left < cloud_life(best).time_left:
			best = i
	var c: GPUParticles3D = clouds[best]
	c.global_position = Vector3(pos.x, 1.4, pos.z)
	fx(c).emitting = true
	cloud_life(best).start()  # its timeout switches emitting off (wired in main.tscn)
	cloud_owner[best] = owner


func cloud_life(i: int) -> Timer:
	return clouds[i].get_node("Life")


func clouds_active() -> bool:
	for i in clouds.size():
		if not cloud_life(i).is_stopped():
			return true
	return false


func in_cloud(e: Entity) -> bool:
	for i in clouds.size():
		if not cloud_life(i).is_stopped() and cloud_owner[i] != e and e.global_position.distance_to(clouds[i].global_position) < 3.2:
			return true
	return false


# ---------- neon arena ----------
## Fire a neon pulse across the dome + pitch. `dir` = sweep direction (ZERO = ring
## spreading from `origin`). The arena's base glow also drifts to `color`.
func arena_pulse(origin: Vector3, color: Color, strength := 1.0, dir := Vector3.ZERO, speed := 20.0) -> void:
	var i := pulse_i % PULSE_N  # ponytail: 8 live pulses, oldest overwritten
	pulse_i += 1
	pulse_pos[i] = Vector4(origin.x, origin.y, origin.z, pulse_clock)
	pulse_dir[i] = Vector4(dir.x, dir.y, dir.z, speed)
	pulse_col[i] = Vector4(color.r, color.g, color.b, strength)
	mood_target = color
	for m in neon_mats:
		m.set_shader_parameter("pulse_pos", pulse_pos)
		m.set_shader_parameter("pulse_dir", pulse_dir)
		m.set_shader_parameter("pulse_col", pulse_col)


func update_neon(rdt: float) -> void:
	pulse_clock += rdt
	mood = mood.lerp(mood_target, minf(1, rdt * 3))
	mood_target = mood_target.lerp(NEON_PINK, minf(1, rdt * 0.4))
	for m in neon_mats:
		m.set_shader_parameter("now", pulse_clock)
		m.set_shader_parameter("mood", mood)


# ---------- record your own fart (menu buttons, Mic bus in default_bus_layout.tres) ----------
## The Mic bus uses AudioEffectCapture, not AudioEffectRecord: Record never fills its
## buffer in single-threaded web builds (Godot issue #102316). While recording, every
## frame drains the capture buffer into mic_frames; STOP turns them into a WAV.
func mic_capture() -> AudioEffectCapture:
	return AudioServer.get_bus_effect(AudioServer.get_bus_index("Mic"), 0)


func pull_mic() -> void:
	var cap := mic_capture()
	var n := cap.get_frames_available()
	if n > 0 and mic_frames.size() < MIC_MAX_SEC * AudioServer.get_mix_rate():
		mic_frames.append_array(cap.get_buffer(n))
	elif n > 0:
		cap.clear_buffer()  # past the cap: drop, keep the buffer from filling up


## Stereo float frames -> mono 16-bit PCM WAV.
func frames_to_wav(frames: PackedVector2Array) -> AudioStreamWAV:
	if frames.is_empty():
		return null
	var data := PackedByteArray()
	data.resize(frames.size() * 2)
	for i in frames.size():
		var f := frames[i]
		data.encode_s16(i * 2, clampi(int((f.x + f.y) * 0.5 * 32767.0), -32768, 32767))
	var wav := AudioStreamWAV.new()  # ponytail: runtime data from the mic, not a node
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = int(AudioServer.get_mix_rate())
	wav.stereo = false
	wav.data = data
	return wav


## Web: the browser records the mic itself (MediaRecorder), decodes it to 48 kHz mono and
## hands Godot base64 16-bit PCM. Godot's own web mic path loops tiny chunks of audio in
## single-threaded builds, so recordings came out as a few buzzy notes instead of a fart.
const BROWSER_REC_JS := """
window.fartRec = {
  rec: null, chunks: [], stream: null, state: 'idle', b64: '', rate: 0, err: '',
  async start(testTone) {
    this.state = 'starting'; this.chunks = []; this.b64 = ''; this.err = '';
    try {
      if (testTone) {
        const ctx = new AudioContext(); await ctx.resume();
        const osc = ctx.createOscillator(); osc.frequency.value = 220;
        const dest = ctx.createMediaStreamDestination(); osc.connect(dest); osc.start();
        this.stream = dest.stream; this.toneCtx = ctx;
      } else {
        this.stream = await navigator.mediaDevices.getUserMedia({audio: {echoCancellation: false, noiseSuppression: true, autoGainControl: true}});
      }
      this.rec = new MediaRecorder(this.stream);
      this.rec.ondataavailable = (e) => { if (e.data.size) this.chunks.push(e.data); };
      this.rec.start(); this.state = 'recording';
    } catch (e) { this.err = String(e); this.state = 'error'; }
  },
  stop() {
    if (!this.rec || this.state !== 'recording') { if (this.state !== 'error') { this.err = 'mic never started'; this.state = 'error'; } return; }
    this.state = 'processing';
    this.rec.onstop = async () => {
      try {
        this.stream.getTracks().forEach((t) => t.stop());
        if (this.toneCtx) { this.toneCtx.close(); this.toneCtx = null; }
        const buf = await new Blob(this.chunks).arrayBuffer();
        const audio = await new OfflineAudioContext(1, 1, 48000).decodeAudioData(buf);
        const ch = audio.getChannelData(0);
        const pcm = new Int16Array(ch.length);
        for (let i = 0; i < ch.length; i++) pcm[i] = Math.max(-32768, Math.min(32767, Math.round(ch[i] * 32767)));
        const bytes = new Uint8Array(pcm.buffer);
        let s = '';
        for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        this.b64 = btoa(s); this.rate = audio.sampleRate; this.state = 'done';
      } catch (e) { this.err = String(e); this.state = 'error'; }
    };
    this.rec.stop();
  }
};
"""


func _on_rec_fart_pressed() -> void:
	if not recording:
		if web:
			JavaScriptBridge.eval("fartRec.start(!!window.fartRecTestTone)", true)
		else:
			mic_capture().clear_buffer()
			mic_frames.clear()
			$Sfx/Mic.play()
		recording = true
		%RecFart.text = "STOP"
		%FartStatus.text = "Recording... fart into your mic, then press STOP"
		return
	recording = false
	%RecFart.text = "RECORD FART"
	if web:
		JavaScriptBridge.eval("fartRec.stop()", true)
		browser_rec_pending = true  # _process polls until the browser has decoded it
		%FartStatus.text = "Processing..."
		return
	pull_mic()
	$Sfx/Mic.stop()
	var got := mic_frames.size()
	var raw := frames_to_wav(mic_frames)
	mic_frames.clear()
	finish_recording(raw, "%d samples" % got)


func poll_browser_recording() -> void:
	var st: String = str(JavaScriptBridge.eval("fartRec.state", true))
	if st == "processing" or st == "recording" or st == "starting":
		return
	browser_rec_pending = false
	if st != "done":
		%FartStatus.text = "Couldn't record: %s. Allow microphone access for this page and try again" % str(JavaScriptBridge.eval("fartRec.err", true))
		return
	var wav := AudioStreamWAV.new()  # ponytail: runtime data from the mic, not a node
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = int(JavaScriptBridge.eval("fartRec.rate", true))
	wav.stereo = false
	wav.data = Marshalls.base64_to_raw(str(JavaScriptBridge.eval("fartRec.b64", true)))
	finish_recording(wav, "%.1f s from the browser" % wav.get_length())


func finish_recording(raw: AudioStreamWAV, got: String) -> void:
	if is_dead_silence(raw):
		# all zeros = no mic data at all: in a browser the mic permission was refused; on the
		# Windows desktop build, Godot's WASAPI driver can't read mics reporting >2 channels
		if web:
			%FartStatus.text = "Couldn't hear your mic (%s). Allow microphone access for this page and try again" % got
		else:
			%FartStatus.text = "Godot can't read this mic (%s, it reports more than 2 channels).\nSet it to 2 channels: Sound > Recording > Properties > Advanced" % got
		return
	var clip := trim_and_normalize(raw)
	if clip == null:
		%FartStatus.text = "Too quiet, didn't hear a fart. Get closer to the mic and try again"
		return
	clip.save_to_wav(MY_FART_PATH)
	use_my_fart(clip)
	$Sfx/FartPreview.stream = clip
	$Sfx/FartPreview.play()


func is_dead_silence(wav: AudioStreamWAV) -> bool:
	if wav == null or wav.data.is_empty():
		return true
	var d := wav.data
	for i in range(0, d.size(), 64):  # sampled scan: real input is never exactly zero for long
		if d[i] != 0:
			return false
	return true


func _on_clear_fart_pressed() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(MY_FART_PATH))
	for n in MY_FART_PITCH:
		var p: AudioStreamPlayer3D = player.get_node("Sfx/" + n)
		p.stream = stock_farts[n]
		p.pitch_scale = 1.0
	%ClearFart.hide()
	%FartStatus.text = "Back to the stock farts"


func use_my_fart(clip: AudioStream) -> void:
	if clip == null:
		return
	for n in MY_FART_PITCH:
		var p: AudioStreamPlayer3D = player.get_node("Sfx/" + n)
		p.stream = clip
		p.pitch_scale = MY_FART_PITCH[n]
	%ClearFart.show()
	%FartStatus.text = "Your fart is on (%.1f s)" % clip.get_length()


## Turn a raw 16-bit mic recording into a clean fart (mono), like the stock farts were
## processed: cut the silence before it, keep at most MY_FART_MAX s, low-pass away mic
## hiss, gate out the background noise (measured in the quiet before the fart), boost
## with a capped gain so hiss isn't blown up, and fade the ends. Null if nothing heard.
func trim_and_normalize(wav: AudioStreamWAV) -> AudioStreamWAV:
	if wav == null or wav.data.is_empty():
		return null
	var d := wav.data
	var stereo := wav.stereo
	var n := d.size() / (4 if stereo else 2)
	var sr := float(wav.mix_rate)
	var gate := MIC_GATE / 32768.0
	var x := PackedFloat32Array()
	x.resize(n)
	var first := -1
	var last := -1
	for i in n:
		var v: float
		if stereo:
			v = (d.decode_s16(i * 4) + d.decode_s16(i * 4 + 2)) / 65536.0
		else:
			v = d.decode_s16(i * 2) / 32768.0
		x[i] = v
		if absf(v) > gate:
			if first < 0:
				first = i
			last = i
	if first < 0:
		return null
	# work window: up to 0.5 s of lead-in (to measure the noise) + the fart itself
	var w0 := maxi(0, first - int(sr * 0.5))
	var a0 := maxi(0, first - int(sr * 0.02))
	var a1 := mini(n - 1, mini(last + int(sr * 0.08), a0 + int(sr * MY_FART_MAX)))
	# two one-pole low-passes at 4 kHz (12 dB/oct): fart energy sits well below, hiss above
	var k := exp(-TAU * 4000.0 / sr)
	var l1 := 0.0
	var l2 := 0.0
	var y := PackedFloat32Array()
	y.resize(a1 - w0 + 1)
	for i in y.size():
		l1 = (1.0 - k) * x[w0 + i] + k * l1
		l2 = (1.0 - k) * l1 + k * l2
		y[i] = l2
	# background noise level = RMS of the filtered lead-in (fallback: a quarter of the gate)
	var lead := a0 - w0
	var noise := gate * 0.25
	if lead > int(sr * 0.05):
		var s := 0.0
		for i in lead:
			s += y[i] * y[i]
		noise = sqrt(s / lead)
	# noise gate on an envelope follower: closed below 1.5x the noise, open from 4x
	var lo := noise * 1.5
	var hi := maxf(noise * 4.0, lo + 1e-4)
	var rel := exp(-1.0 / (sr * 0.06))
	var env := 0.0
	var m := a1 - a0 + 1
	var peak := 0.0
	for i in y.size():
		env = maxf(absf(y[i]), env * rel)
		var g := clampf((env - lo) / (hi - lo), 0.0, 1.0)
		y[i] *= g * g
		if i >= lead:
			peak = maxf(peak, absf(y[i]))
	if peak <= 0.0:
		return null
	var gain := minf(0.9 / peak, MY_FART_MAX_GAIN)
	var fade_in := maxi(1, int(sr * 0.005))
	var fade_out := maxi(1, int(m * 0.15))
	var out := PackedByteArray()
	out.resize(m * 2)
	for i in m:
		var f := 1.0
		if i < fade_in:
			f = float(i) / fade_in
		elif i > m - fade_out:
			f = float(m - i) / fade_out
		out.encode_s16(i * 2, clampi(int(y[lead + i] * gain * f * 32767.0), -32768, 32767))
	var clip := AudioStreamWAV.new()  # ponytail: runtime data from the mic, not a node
	clip.format = AudioStreamWAV.FORMAT_16_BITS
	clip.mix_rate = wav.mix_rate
	clip.stereo = false
	clip.data = out
	return clip


# ---------- sound ----------
func kick(v: float) -> void:
	$Sfx/Kick.volume_db = linear_to_db(clampf(v / 15.0, 0.4, 1.0))
	$Sfx/Kick.play()
	cam_shake = maxf(cam_shake, clampf(v / 40.0, 0.0, 0.45))
	if v > 12:
		hit_stop()


# ---------- game feel ----------
## Freeze-frame for ~70 ms on heavy impacts so hits land with weight.
func hit_stop() -> void:
	if state != "play":
		return
	Engine.time_scale = 0.05
	$HitStop.start()


func _on_hit_stop_timeout() -> void:
	if state != "goal":  # goal slow-mo owns the time scale
		Engine.time_scale = 1.0


## Rocket League style 3-2-1-GO: everyone frozen in place until GO.
func start_countdown() -> void:
	state = "countdown"
	$MatchTimer.paused = true
	for e in ents:
		e.freeze = true
	%CountdownAnim.stop()
	%CountdownAnim.play("count")


func _on_countdown_finished(_anim: StringName) -> void:
	if state != "countdown":
		return
	for e in ents:
		e.freeze = false
	state = "play"
	$MatchTimer.paused = false
	$Sfx/Whistle.play()
	banner("GO!")


## Fans (Kenney Mini Characters in main.tscn/Crowd) idle out of sync, cheer on goals.
## Perf: they don't cast shadows, and their skeletons update in FAN_SLICES staggered
## groups (each fan every FAN_SLICES-th frame) since 72 skinned fans were ~5 ms of CPU.
func crowd_idle() -> void:
	for fan in $Crowd.get_children():
		for m: MeshInstance3D in fan.find_children("*", "MeshInstance3D", true, false):
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ap: AnimationPlayer = fan.get_node("AnimationPlayer")
		ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		ap.get_animation("idle").loop_mode = Animation.LOOP_LINEAR
		ap.play("idle")
		ap.seek(randf() * ap.current_animation_length, true)
		fan_aps.append(ap)


func update_crowd(dt: float) -> void:
	if web and Time.get_ticks_msec() > fans_awake_until:
		return  # skeletons are expensive in wasm: fans hold their pose between cheers
	fan_slice = (fan_slice + 1) % FAN_SLICES
	for i in range(fan_slice, fan_aps.size(), FAN_SLICES):
		fan_aps[i].advance(dt * FAN_SLICES)


func crowd_cheer() -> void:
	fans_awake_until = Time.get_ticks_msec() + 3000
	for fan in $Crowd.get_children():
		var ap: AnimationPlayer = fan.get_node("AnimationPlayer")
		ap.play("emote-yes", 0.15)
		for i in 2:
			ap.queue("emote-yes")
		ap.queue("idle")


func thud(v: float) -> void:
	$Sfx/Thud.volume_db = linear_to_db(minf(0.3, v * 0.02) / 0.3)
	$Sfx/Thud.play()


# ---------- game state ----------
func apply_modifier(mod: String) -> void:
	modifier = mod
	for e in ents:
		e.gravity_scale = 9.0 / 22.0 if mod == "LOW GRAVITY" else 1.0
		e.ground_fric = (0.03 if e == ball else 0.5) if mod == "SLIPPERY PITCH" else (0.6 if e == ball else 2.5)
	ball.r = 2.0 if mod == "GIANT BALL" else 1.0
	ball.mass = 0.8 if mod == "GIANT BALL" else 0.5
	$Ball/Shape.shape.radius = ball.r
	$Ball/Mesh.scale = Vector3.ONE * ball.r
	%Mod.text = "⚠ " + mod if mod else ""


func place(e: Entity, pos: Vector3, face_yaw: float) -> void:
	e.global_transform = Transform3D(Basis(Vector3.UP, face_yaw), pos)
	e.linear_velocity = Vector3.ZERO
	e.angular_velocity = Vector3.ZERO
	e.stun = 0.0
	e.gas = 100


func kickoff() -> void:
	place(player, Vector3(-8, STAND_Y, 0), 0)
	place(opp, Vector3(8, STAND_Y, 0), PI)
	place(ball, Vector3(0, 6, 0), 0)
	arena_pulse(Vector3.ZERO, NEON_PINK, 1.0)
	opp.cd = 1.2
	ball.last_toucher = null
	ball.wall_since_touch = false
	for i in clouds.size():
		cloud_life(i).stop()
		fx(clouds[i]).restart()  # clears lingering gas
		fx(clouds[i]).emitting = false


func _on_go_pressed() -> void:
	yaw = 0.0
	pitch = 0.35
	goals_you = 0
	goals_bot = 0
	overtime = false
	diff = 0.25
	apply_modifier("")
	kickoff()
	$MatchTimer.start()
	start_countdown()
	%Overlay.hide()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func popup(text: String) -> void:
	var p: Label = pops[pop_i % pops.size()]
	pop_i += 1
	p.text = text
	p.get_node("Anim").stop()
	p.get_node("Anim").play("pop")


func banner(text: String) -> void:
	%Banner.text = text
	%Banner.pivot_offset = %Banner.size / 2
	%BannerAnim.stop()
	%BannerAnim.play("show")


func goal_scored(side: int) -> void:
	state = "goal"
	Engine.time_scale = 0.25
	$Sfx/Roar.play()
	$Sfx/Horn.play()
	crowd_cheer()
	var mouth := Vector3(signf(side) * W, 2, 0)
	var goal_col := NEON_GOAL if side > 0 else NEON_SLAM
	arena_pulse(mouth, goal_col, 2.5, Vector3.ZERO, 30.0)
	arena_pulse(mouth, goal_col, 1.5, Vector3.ZERO, 12.0)
	$GoalTimer.start()
	$MatchTimer.paused = true
	$Confetti.global_position = ball.global_position
	fx($Confetti).restart()
	%FlashAnim.play("flash")
	var goals_box: Control = %ScorePunch.get_parent()
	goals_box.pivot_offset = goals_box.size / 2
	%ScorePunch.play("punch")
	for e: Entity in [player, opp]:  # goal explosion: ragdoll everyone near the ball
		var away := e.global_position - ball.global_position
		var reach := 1.0 - away.length() / 16.0
		if reach > 0:
			e.linear_velocity += (away.normalized() + Vector3.UP * 0.7).normalized() * 24.0 * reach
			e.knock(20.0)
	if side > 0:
		goals_you += 1
		banner("GOLDEN GOAL!" if overtime else "GOAL!")
		# flavour callouts only; the match is decided by goals
		if ball.last_toucher == opp:
			popup("BOT OWN GOAL")
		elif ball.last_toucher == player and ball.touch_pos.distance_to(Vector3(W, 0, 0)) > 22:
			popup("LONG RANGE")
		elif ball.last_toucher == player and ball.wall_since_touch:
			popup("WALL REBOUND")
		if clouds_active():
			popup("IN THE CLOUD")
		diff = minf(1, diff + 0.15)
	else:
		goals_bot += 1
		banner("CONCEDED")


func _on_goal_timer_timeout() -> void:
	Engine.time_scale = 1.0
	if overtime:  # golden goal decided it
		end_match()
		return
	kickoff()
	apply_modifier(MODS.pick_random() if randf() < 0.6 else "")
	start_countdown()
	if modifier:
		popup(modifier)


func _on_match_timer_timeout() -> void:
	if goals_you == goals_bot:  # tied: Rocket League overtime, next goal wins
		overtime = true
		banner("OVERTIME")
		$Sfx/Whistle.play()
		return
	end_match()


func end_match() -> void:
	state = "over"
	charging = false
	$Sfx/Whistle.play()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var won := goals_you > goals_bot
	if won:
		wins += 1
	else:
		losses += 1
	FileAccess.open(RECORD_PATH, FileAccess.WRITE).store_string("%d %d" % [wins, losses])
	%EndTxt.text = "%s  %d : %d%s\nRecord %d W - %d L" % ["YOU WIN" if won else "YOU LOSE", goals_you, goals_bot, " (OT)" if overtime else "", wins, losses]
	%Go.text = "PLAY AGAIN"
	%Overlay.show()


# ---------- main loop ----------
func _physics_process(dt: float) -> void:
	if state != "play" and state != "goal":
		return
	var f := fwd()
	player.aim = f
	var mv := Input.get_vector("move_left", "move_right", "move_back", "move_forward")
	player.walk = (f * mv.y + Vector3(-f.z, 0, f.x) * mv.x).normalized()
	if state == "play":
		ai_update(dt)
	else:
		opp.walk = Vector3.ZERO
	for e in ents:
		e.in_cloud = in_cloud(e)
	for e: Entity in [player, opp]:
		e.gas = minf(100, e.gas + 16 * dt)
		update_exhaust(e)
	if state == "play":
		if ball.global_position.x > W + ball.r * 0.5:
			goal_scored(1)
		elif ball.global_position.x < -W - ball.r * 0.5:
			goal_scored(-1)


func _process(dt: float) -> void:
	var rdt := minf(dt / Engine.time_scale, 1.0 / 30)  # real (unscaled) frame time
	if recording and not web:
		pull_mic()
	if browser_rec_pending:
		poll_browser_recording()
	if state == "goal" and $GoalTimer.time_left < 1.2:
		Engine.time_scale = minf(1, Engine.time_scale + rdt * 2)
	var c := charge_level() if charging else 0.0
	update_characters(rdt, c)
	update_aim(c)
	update_neon(rdt)
	update_crowd(dt)
	update_camera(rdt)
	update_hud(c)


func update_characters(rdt: float, c: float) -> void:
	for e: Entity in [player, opp]:
		var sq := e.squash
		e.squash = maxf(0, e.squash - rdt * 4)
		var s := -sq * 0.35
		e.inner.position.x = 0
		if e == player and charging:
			s = c * 0.25
			e.inner.position.x = (randf() - 0.5) * 0.08 * c
		e.inner.scale = Vector3(1 - s * 0.5, 1 - s, 1 - s * 0.5)


func update_aim(c: float) -> void:
	var show := state == "play"
	var pp := player.global_position
	arrow.visible = show
	arrow.position = Vector3(pp.x, 0.05, pp.z)
	arrow.rotation.y = -atan2(player.aim.z, player.aim.x)
	arrow.scale = Vector3(0.8 + c * 1.6, 1, 1)
	var col := GREEN if c > 0.95 else YELLOW
	arrow_mat.albedo_color = Color(col, 0.75)
	traj_mat.albedo_color = Color(col, 0.95 if charging else 0.4)
	$Aim/Traj.visible = show
	ring.visible = false
	if show:
		update_traj(c)


func update_traj(charge: float) -> void:
	var d := aim3()
	var v := player.linear_velocity
	var p := player.global_position
	var g := gravity()
	var dv := fart_dv(charge, false)
	var tau := player.vent_tau
	if player.grounded:
		v.y = maxf(v.y, 1.5)
	var n := 0
	var t := 0.0
	while n < TRAJ_N:
		traj.set_instance_transform(n, Transform3D(Basis(), p))
		n += 1
		# same exponential burn as entity._integrate_forces (ignores mid-burn rotation)
		v += d * dv * (exp(-t / tau) - exp(-(t + 0.035) / tau))
		t += 0.035
		v.y -= g * 0.035
		p += v * 0.035
		v.x *= 0.995
		v.z *= 0.995
		if p.y < STAND_Y:
			ring.visible = true
			ring.position = Vector3(p.x, 0.06, p.z)
			break
		if absf(p.z) > D or absf(p.x) > W + POCKET:
			break
	traj.visible_instance_count = n


func update_camera(rdt: float) -> void:
	var speed := player.linear_velocity.length()
	cam.fov = lerpf(cam.fov, 50.0 + clampf((speed - 8.0) / 20.0, 0.0, 1.0) * 16.0, minf(1.0, rdt * 4.0))
	var cf := fwd()
	var pp := player.global_position
	player.inner.visible = not first_person
	if first_person:
		var eye := pp + Vector3(0, 1.45, 0) + cf * 0.35
		cam_pos = eye
		cam_look = eye + tilt(cf, 0.75 - pitch * 1.1) * 10
	else:
		var dist := 7.5
		var tgt := pp + Vector3(0, 1.2, 0)
		var want := tgt - cf * dist * cos(pitch) + Vector3(0, 1 + dist * sin(pitch), 0)
		want.x = clampf(want.x, -W - POCKET + 0.5, W + POCKET - 0.5)
		want.z = clampf(want.z, -D + 0.4, D - 0.4)
		want.y = maxf(0.6, want.y)
		cam_pos = cam_pos.lerp(want, minf(1, rdt * 12))
		cam_look = cam_look.lerp(tgt + cf * 4, minf(1, rdt * 14))
	cam_shake = maxf(0, cam_shake - rdt * 1.5)
	cam.position = cam_pos + Vector3((randf() - 0.5) * cam_shake, (randf() - 0.5) * cam_shake, 0)
	if not cam.position.is_equal_approx(cam_look):
		cam.look_at(cam_look)


func update_hud(c: float) -> void:
	%Record.text = "%d W - %d L" % [wins, losses]
	%GoalsYou.text = str(goals_you)
	%GoalsBot.text = str(goals_bot)
	var tl := 90 if state == "menu" else ceili($MatchTimer.time_left)
	%Time.text = "OVERTIME" if overtime else "%d:%02d" % [tl / 60, tl % 60]
	var urgent := overtime or (state == "play" and tl <= 10)
	%Time.modulate = Color.WHITE.lerp(Color(1, 0.3, 0.3), 0.5 + 0.5 * sin(Time.get_ticks_msec() / 120.0)) if urgent else Color.WHITE
	fx($Ball/Trail).emitting = ball.linear_velocity.length() > 9.0
	%LockHint.visible = state == "play" and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	%ChgLbl.text = "CHARGE · ANGLE %d°" % roundi(rad_to_deg(aim_el()))
	%Gas.value = player.gas
	if %Fps.visible:
		%Fps.text = "%d FPS" % Engine.get_frames_per_second()
	%Chg.value = c * 100
