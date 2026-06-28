extends MeshInstance3D

const TRAIL_SLOTS  : int   = 32
const MAX_BODIES   : int   = 1
const TRAIL_LEN    : int   = TRAIL_SLOTS * MAX_BODIES
const MIN_MOVE_DIST: float = 0.25

const SplashScene = preload("res://Scenes/splash.tscn")


var _mat     : ShaderMaterial
var _elapsed : float = 0.0
var _bodies  : Dictionary = {}

var _trail_pos    : PackedVector3Array
var _trail_age    : PackedFloat32Array
var _trail_dir    : PackedVector2Array
var _trail_fade   : PackedFloat32Array
var _wake         : GPUParticles3D
var _bubbles      : GPUParticles3D

func _ready() -> void:
	var shader = load("res://Shaders/water shader 2.gdshader") as Shader
	_mat = ShaderMaterial.new()
	_mat.shader = shader
	# Copy saved parameter values from the .tres material so colors/waves stay intact
	var base := get_active_material(0) as ShaderMaterial
	if base:
		for param in base.shader.get_shader_uniform_list():
			var val = base.get_shader_parameter(param["name"])
			if val != null:
				_mat.set_shader_parameter(param["name"], val)
	_mat.render_priority = 1
	set_surface_override_material(0, _mat)

	_trail_pos = PackedVector3Array()
	_trail_age = PackedFloat32Array()
	_trail_dir = PackedVector2Array()
	for i in TRAIL_LEN:
		_trail_pos.append(Vector3(99999, 0, 99999))
		_trail_age.append(9999.0)
	for i in TRAIL_SLOTS:
		_trail_dir.append(Vector2(0, 1))
		_trail_fade.append(1.0)

	_mat.set_shader_parameter("trail_pos",     _trail_pos)
	_mat.set_shader_parameter("trail_age",     _trail_age)
	_mat.set_shader_parameter("trail_count",   20)
	_mat.set_shader_parameter("ripple_str",    0.4)
	_mat.set_shader_parameter("ripple_freq",   40.0)
	_mat.set_shader_parameter("ripple_speed",  4.0)
	_mat.set_shader_parameter("ripple_radius", 50.0)
	_mat.set_shader_parameter("ripple_decay",  3.0)
	_mat.set_shader_parameter("event_speed",   1.2)
	_mat.set_shader_parameter("event_radius",  6.0)
	_mat.set_shader_parameter("player_radius", 0.4)
	_init_wake()
	_init_bubbles()

func _init_wake() -> void:
	var mat := ParticleProcessMaterial.new()
	# Use SPHERE not RING — guaranteed available in all Godot 4 versions
	mat.emission_shape         = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 1.4
	mat.direction              = Vector3(0, 1, 0)
	mat.spread                 = 80.0
	mat.flatness               = 0.6
	mat.initial_velocity_min   = 0.5
	mat.initial_velocity_max   = 2.0
	mat.gravity                = Vector3(0, -9.5, 0)
	mat.scale_min              = 0.03
	mat.scale_max              = 0.09
	mat.angular_velocity_min  = -200.0
	mat.angular_velocity_max  =  200.0
	var grad     := Gradient.new()
	grad.colors   = PackedColorArray([Color(0.85, 0.97, 1.0, 0.5), Color(0.85, 0.97, 1.0, 0.0)])
	grad.offsets  = PackedFloat32Array([0.3, 1.0])
	var gtex     := GradientTexture1D.new()
	gtex.gradient = grad
	mat.color_ramp = gtex

	var wake_mesh     := SphereMesh.new()
	wake_mesh.radius   = 0.18
	wake_mesh.height   = 0.72
	wake_mesh.radial_segments = 10
	wake_mesh.rings    = 5
	var mmat     := ShaderMaterial.new()
	mmat.shader          = load("res://Shaders/bubble.gdshader")
	mmat.render_priority = 2
	wake_mesh.material = mmat

	_wake = GPUParticles3D.new()
	_wake.amount          = 200
	_wake.lifetime        = 1.0
	_wake.one_shot        = false
	_wake.explosiveness   = 0.0
	_wake.local_coords    = false
	_wake.emitting        = false
	_wake.visibility_aabb = AABB(Vector3(-60, -2, -60), Vector3(120, 10, 120))
	_wake.process_material = mat
	_wake.draw_pass_1     = wake_mesh
	add_child(_wake)

func _init_bubbles() -> void:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape        = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents  = Vector3(120.0, 1.0, 120.0)
	mat.direction             = Vector3(0, 1, 0)
	mat.spread                = 8.0
	mat.initial_velocity_min  = 0.1
	mat.initial_velocity_max  = 0.4
	mat.gravity               = Vector3(0, 0, 0)
	mat.scale_min             = 0.3
	mat.scale_max             = 0.8

	var grad     := Gradient.new()
	grad.colors   = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.6), Color(1, 1, 1, 0.0)])
	grad.offsets  = PackedFloat32Array([0.0, 0.4, 1.0])
	var gtex     := GradientTexture1D.new()
	gtex.gradient = grad
	mat.color_ramp = gtex

	var bubble_mesh     := SphereMesh.new()
	bubble_mesh.radius   = 0.08
	bubble_mesh.height   = 0.16
	bubble_mesh.radial_segments = 6
	bubble_mesh.rings    = 3
	var mmat     := ShaderMaterial.new()
	mmat.shader          = load("res://Shaders/bubble.gdshader")
	mmat.render_priority = 2
	bubble_mesh.material = mmat

	_bubbles = GPUParticles3D.new()
	_bubbles.amount           = 2000
	_bubbles.lifetime         = 5.0
	_bubbles.one_shot         = false
	_bubbles.explosiveness    = 0.0
	_bubbles.local_coords     = true
	_bubbles.emitting         = true
	_bubbles.visibility_aabb  = AABB(Vector3(-130, -4, -130), Vector3(260, 8, 260))
	_bubbles.process_material = mat
	_bubbles.draw_pass_1      = bubble_mesh
	call_deferred("_add_bubbles")

func _get_bodies_in_water() -> Array[RigidBody3D]:
	var result : Array[RigidBody3D] = []
	var water_y := global_position.y
	for child in get_parent().get_children():
		if child is RigidBody3D:
			var b := child as RigidBody3D
			if abs(b.global_position.y - water_y) < 3.0:
				result.append(b)
			if result.size() >= MAX_BODIES:
				break
	return result

func _spawn_splash(body: RigidBody3D) -> void:
	var s := SplashScene.instantiate()
	s.autoplay = false
	get_parent().add_child(s)
	s.global_position = Vector3(body.global_position.x, global_position.y + 0.5, body.global_position.z)
	s._follow = body
	s.finished.connect(s.queue_free)
	s.play()

func _reset_body(body: RigidBody3D) -> void:
	var pos_arr  : Array[Vector3] = []
	var time_arr : Array[float]   = []
	var dir_arr  : Array[Vector2] = []
	var fade_arr : Array[float]   = []
	for i in TRAIL_SLOTS:
		pos_arr.append(Vector3(99999, 0, 99999))
		time_arr.append(-9999.0)
		dir_arr.append(Vector2(0, 1))
		fade_arr.append(1.0)
	_bodies[body] = {
		"pos": pos_arr, "time": time_arr, "dir": dir_arr, "fade": fade_arr,
		"last": Vector3(99999, 0, 99999),
		"last_dir": Vector2(0, 1),
		"event_drift": Vector2(0.0, 0.0),
		"move_time": 0.0,
		"was_moving": false,
		"leaving": false, "leave_time": 0.0
	}

func _ensure_body(body: RigidBody3D) -> void:
	if not _bodies.has(body):
		_reset_body(body)
		_spawn_splash(body)
		_inject_event_rings(_bodies[body], body.global_position)
	elif _bodies[body]["leaving"]:
		_bodies[body]["leaving"] = false
		_spawn_splash(body)
		_inject_event_rings(_bodies[body], body.global_position)

func _inject_event_rings(d: Dictionary, pos: Vector3) -> void:
	d["event_drift"] = d["last_dir"]  # lock in direction at time of entry
	var fades := [1.0, 0.8, 0.6, 0.45]
	for j in fades.size():
		for i in range(TRAIL_SLOTS - 1, 0, -1):
			d["pos"][i]  = d["pos"][i - 1]
			d["time"][i] = d["time"][i - 1]
			d["dir"][i]  = d["dir"][i - 1]
			d["fade"][i] = d["fade"][i - 1] * 0.88
		d["pos"][0]  = pos
		d["time"][0] = _elapsed
		d["dir"][0]  = Vector2(0.0, 0.0)
		d["fade"][0] = fades[j]
	d["last"] = pos

func _physics_process(delta: float) -> void:
	if _mat == null:
		return
	_elapsed += delta

	var active := _get_bodies_in_water()

	# Mark bodies that left — record the exact time they left
	for b in _bodies.keys():
		if not active.has(b) and not _bodies[b]["leaving"]:
			_bodies[b]["leaving"]    = true
			_bodies[b]["leave_time"] = _elapsed

	# Remove leaving bodies after a fixed fade window (4 seconds)
	var fade_window : float = 4.0
	for b in _bodies.keys():
		if _bodies[b]["leaving"]:
			if (_elapsed - float(_bodies[b]["leave_time"])) > fade_window:
				_bodies.erase(b)

	for body in active:
		_ensure_body(body)
		var d : Dictionary = _bodies[body]
		if d["leaving"]:
			continue
		var h_vel := Vector2(body.linear_velocity.x, body.linear_velocity.z).length()
		var is_moving := h_vel > 0.3
		d["was_moving"] = is_moving
		if is_moving:
			d["move_time"] = minf(d["move_time"] + delta, 0.8)
		else:
			d["move_time"] = 0.0
		var ramp : float = d["move_time"] / 0.8
		var effective_dist : float = lerpf(MIN_MOVE_DIST * 2.5, MIN_MOVE_DIST, ramp)

		var pos : Vector3 = body.global_position
		if pos.distance_to(d["last"]) >= effective_dist:
			var move_vec := Vector2(pos.x - d["last"].x, pos.z - d["last"].z)
			if move_vec.length() > 0.001:
				d["last_dir"] = move_vec.normalized()
			for i in range(TRAIL_SLOTS - 1, 0, -1):
				d["pos"][i]  = d["pos"][i - 1]
				d["time"][i] = d["time"][i - 1]
				d["dir"][i]  = d["dir"][i - 1]
				d["fade"][i] = d["fade"][i - 1] * 0.88
			d["pos"][0]  = pos
			d["time"][0] = _elapsed
			d["dir"][0]  = d["last_dir"]
			d["fade"][0] = 1.0
			d["last"]    = pos

	# Wake particles: follow active body, only emit while moving
	var wake_active := false
	for b in _bodies.keys():
		if not _bodies[b]["leaving"]:
			_wake.global_position = Vector3(
				b.global_position.x,
				b.global_position.y - 0.8,
				b.global_position.z
			)
			wake_active = b.linear_velocity.length() > 0.4
			break
	_wake.emitting = wake_active

func _process(_delta: float) -> void:
	if _mat == null:
		return

	var bodies_list : Array[RigidBody3D] = []
	for b in _bodies.keys():
		bodies_list.append(b as RigidBody3D)
	for b_idx in range(min(bodies_list.size(), MAX_BODIES)):
		var d    : Dictionary = _bodies[bodies_list[b_idx]]
		var body : RigidBody3D = bodies_list[b_idx]
		var base : int        = b_idx * TRAIL_SLOTS
		var drift := d["event_drift"] as Vector2
		for i in TRAIL_SLOTS:
			var age := maxf(_elapsed - d["time"][i], 0.0)
			var p   : Vector3 = d["pos"][i]
			# Event rings drift in the locked entry direction, fading out over time
			if d["dir"][i].dot(d["dir"][i]) < 0.01 and p.x < 9000.0 and age < 1.8:
				var strength := (1.0 - age / 1.8) * 0.04
				p = Vector3(p.x + drift.x * strength, p.y, p.z + drift.y * strength)
				d["pos"][i] = p
			_trail_pos[base + i]  = p
			_trail_age[base + i]  = age
			_trail_dir[i]         = d["dir"][i]
			_trail_fade[base + i] = d["fade"][i]

	for b_idx in range(bodies_list.size(), MAX_BODIES):
		var base : int = b_idx * TRAIL_SLOTS
		for i in TRAIL_SLOTS:
			_trail_pos[base + i] = Vector3(99999, 0, 99999)
			_trail_age[base + i] = 9999.0

	_mat.set_shader_parameter("trail_pos",  _trail_pos)
	_mat.set_shader_parameter("trail_age",  _trail_age)
	_mat.set_shader_parameter("trail_dir",  _trail_dir)
	_mat.set_shader_parameter("trail_fade", _trail_fade)

func _add_bubbles() -> void:
	get_parent().add_child(_bubbles)
	_bubbles.global_position = Vector3(global_position.x, global_position.y - 0.5, global_position.z)
	var m := _bubbles.draw_pass_1.surface_get_material(0) as ShaderMaterial
	if m:
		m.set_shader_parameter("water_y", global_position.y)
