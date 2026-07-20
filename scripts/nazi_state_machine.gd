extends CharacterBody3D

# ── States ────────────────────────────────────────────────────────────────────
enum { IDLE, PATROL, PURSUE, TAKE_COVER, PEEK_FIRE, FIRING, RELOAD, STUNNED }

# ── Export vars ───────────────────────────────────────────────────────────────
@export_group("Model Alignment")
@export var mesh_rotation_offset: float = 90.0 # Fixes Blender's export alignment!

@export_group("Movement")
@export var patrol_speed     : float = 1.5   
@export var pursue_speed     : float = 5.0   # Fast sprint speed
@export var crouch_walk_speed: float = 1.1   

@export_group("Combat")
@export var max_ammo            : int   = 5
@export var shots_per_peek      : int   = 2     
@export var open_combat_shots   : int   = 3     
@export var peek_wait_min       : float = 1.5   
@export var peek_wait_max       : float = 3.5   
@export var cover_search_radius : float = 15.0  

@export_group("Detection")
@export var shoot_range     : float = 25.0   
@export var lose_sight_secs : float = 5.0    

# ── Internal bookkeeping ──────────────────────────────────────────────────────
var state       = IDLE
var _last_state = -1       
var ammo        : int
var _player     : Node3D = null
var _cover_point: Node3D = null
var _last_known_player_pos := Vector3.ZERO
var _is_peeking := false   
var _gravity    : float = ProjectSettings.get_setting("physics/3d/default_gravity")

# ── Node refs ─────────────────────────────────────────────────────────────────
@onready var sight     = $Armature/Skeleton3D/vision/Sight
@onready var vrc       = $Armature/Skeleton3D/vision/Sight/VisionRayCast
@onready var anim      = $AnimationPlayer
@onready var nav_agent = $NavigationAgent3D

# ── Timers ────────────────────────────────────────────────────────────────────
var _lose_sight_timer : Timer
var _peek_timer       : Timer
var _patrol_timer     : Timer

func _ready() -> void:
	ammo = max_ammo
	vrc.add_exception(self)

	# Setup Looping Animations
	_set_loop("idle_anim", true)
	_set_loop("walk_anim", true)
	_set_loop("crouch_walk", true)

	# Setup Timers
	_lose_sight_timer = _make_timer(lose_sight_secs, true, _on_lose_sight_timeout)
	_peek_timer       = _make_timer(peek_wait_min, true, _on_peek_timer_timeout)
	_patrol_timer     = _make_timer(randf_range(3.0, 6.0), true, _on_patrol_timer_timeout)
	
	nav_agent.navigation_finished.connect(_on_nav_finished)
	_patrol_timer.start()

func _make_timer(wait: float, one_shot: bool, cb: Callable) -> Timer:
	var t = Timer.new()
	t.wait_time = wait
	t.one_shot = one_shot
	t.timeout.connect(cb)
	add_child(t)
	return t

func _set_loop(anim_name: String, looping: bool) -> void:
	if anim.has_animation(anim_name):
		anim.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR if looping else Animation.LOOP_NONE

# ═════════════════════════════════════════════════════════════════════════════
#  PROCESS & PHYSICS
# ═════════════════════════════════════════════════════════════════════════════
func _process(_delta: float) -> void:
	if state != _last_state:
		_last_state = state
		match state:
			IDLE:    anim.play("idle_anim", -1, 1.0)
			PATROL:  anim.play("walk_anim", -1, 1.0)
			PURSUE:  anim.play("walk_anim", -1, 1.8) # Sped up for sprinting!
			FIRING:  anim.play("aim_hold")
			STUNNED: anim.play("shot_when_aim")

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta

	match state:
		PATROL:
			_move_along_nav(patrol_speed, delta, true) 

		PURSUE:
			if _player:
				_face_target(_player.global_position, delta)
				var dist = global_position.distance_to(_player.global_position)
				
				if dist > 3.0: 
					nav_agent.target_position = _player.global_position
					_move_along_nav(pursue_speed, delta, false) 
				else:
					_brake(delta)
					
				if dist <= shoot_range:
					_on_player_spotted()
			else:
				_brake(delta)

		TAKE_COVER:
			if not nav_agent.is_navigation_finished():
				_move_along_nav(pursue_speed, delta, true) 
				
				# Anti-Stuck Check
				if velocity.length() > 1.0 and get_real_velocity().length() < 0.5:
					_enter_open_firing() 
					
				# FIX: Remove the omniscient LOS check and drastically shrink the radius!
				# He will now confidently sprint to cover UNLESS you are literally 
				# breathing down his neck (under 2.5 meters), forcing him into a cornered panic.
				if _player and global_position.distance_to(_player.global_position) < 2.5:
					_enter_open_firing()
			else:
				# Safely arrived at cover
				_brake(delta)
				if _peek_timer.is_stopped() and state == TAKE_COVER:
					anim.play("crouch_start") 
					_peek_timer.wait_time = randf_range(peek_wait_min, peek_wait_max)
					_peek_timer.start()

		FIRING:
			if _player:
				_face_target(_player.global_position, delta)
			_brake(delta)
		_:
			_brake(delta)

	move_and_slide()

# ═════════════════════════════════════════════════════════════════════════════
#  MOVEMENT HELPERS
# ═════════════════════════════════════════════════════════════════════════════
func _move_along_nav(speed: float, delta: float, face_path: bool = true) -> void:
	if nav_agent.is_navigation_finished():
		_brake(delta) # <--- Add the brakes here!
		return
		
	var next_pos = nav_agent.get_next_path_position()
	var dir = (next_pos - global_position)
	dir.y = 0.0
	dir = dir.normalized()
	
	if face_path and dir.length() > 0.1:
		_face_target(global_position + dir, delta)
		
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed

func _face_target(target_pos: Vector3, delta: float) -> void:
	var dir = target_pos - global_position
	dir.y = 0.0
	if dir.length() < 0.1:
		return
		
	var target_angle = atan2(dir.x, dir.z) + deg_to_rad(mesh_rotation_offset)
	rotation.y = lerp_angle(rotation.y, target_angle, delta * 10.0)

func _brake(delta: float) -> void:
	velocity.x = lerp(velocity.x, 0.0, delta * 10.0)
	velocity.z = lerp(velocity.z, 0.0, delta * 10.0)

# ═════════════════════════════════════════════════════════════════════════════
#  VISION & SPOTTING
# ═════════════════════════════════════════════════════════════════════════════
func _on_vision_timer_timeout() -> void:
	var player_seen := false

	for body in sight.get_overlapping_bodies():
		if body.is_in_group("player") or body.name == "PLAYER":
			_player = body
			if _check_line_of_sight(body):
				player_seen = true
				_last_known_player_pos = body.global_position
			break

	if player_seen:
		_lose_sight_timer.stop()
		if state in [IDLE, PATROL, PURSUE]:
			var dist = global_position.distance_to(_player.global_position)
			if dist <= shoot_range:
				_on_player_spotted()
	else:
		if state in [PURSUE, FIRING, TAKE_COVER, PEEK_FIRE] and _lose_sight_timer.is_stopped():
			_lose_sight_timer.start()

func _check_line_of_sight(player: Node3D) -> bool:
	vrc.target_position = vrc.to_local(player.global_transform.origin + Vector3.UP * 1.0)
	vrc.force_raycast_update()
	if vrc.is_colliding():
		var col = vrc.get_collider()
		return col == player or col.name == "PLAYER"
	return false

# ═════════════════════════════════════════════════════════════════════════════
#  COMBAT SEQUENCES
# ═════════════════════════════════════════════════════════════════════════════
func _on_player_spotted() -> void:
	_lose_sight_timer.stop()
	_peek_timer.stop()
	if state in [IDLE, PATROL, PURSUE]:
		_do_surprise_attack()

func _do_surprise_attack() -> void:
	state = FIRING
	_last_state = FIRING
	
	anim.play("aim_hold")
	await get_tree().create_timer(0.4).timeout
	if not _player: return
	
	if ammo > 0:
		anim.play("shoot_anim")
		_fire_at_player()
		await anim.animation_finished
		ammo -= 1
		anim.play("cycle_anim")
		await anim.animation_finished
		
	var cover = _find_best_cover()
	if cover:
		_cover_point = cover
		_enter_take_cover()
	else:
		_enter_open_firing()

func _enter_take_cover() -> void:
	state = TAKE_COVER
	_last_state = TAKE_COVER
	
	# FIX 1: Snap the raw Node3D coordinates to the absolute closest SAFE point on the NavMesh.
	# This guarantees the target is actually reachable and not inside a physical wall.
	var safe_cover = NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), _cover_point.global_position)
	nav_agent.target_position = safe_cover
	
	anim.play("walk_anim", -1, 1.8)

func _on_peek_timer_timeout() -> void:
	if state != TAKE_COVER or not _player: return
	
	if _cover_point and global_position.distance_to(_cover_point.global_position) > 1.5:
		_peek_timer.wait_time = 1.0
		_peek_timer.start()
		return
	_do_peek_and_fire()

func _do_peek_and_fire() -> void:
	state = PEEK_FIRE
	_is_peeking = true

	anim.play("crouch_start", -1, -1.5, true)
	await anim.animation_finished
	if state != PEEK_FIRE: return

	if _player:
		var dir = _player.global_position - global_position
		dir.y = 0.0
		if dir.length() > 0.01:
			rotation.y = atan2(dir.x, dir.z) + deg_to_rad(mesh_rotation_offset)

	anim.play("aim_hold")
	await get_tree().create_timer(0.35).timeout
	if state != PEEK_FIRE: return

	for i in range(shots_per_peek):
		if ammo <= 0 or state != PEEK_FIRE: break
		anim.play("shoot_anim")
		_fire_at_player()
		await anim.animation_finished
		ammo -= 1
		anim.play("cycle_anim")
		await anim.animation_finished
		if i < shots_per_peek - 1:
			await get_tree().create_timer(0.18).timeout

	if ammo <= 0:
		await _do_reload()
		if state != PEEK_FIRE: return

	_is_peeking = false
	anim.play("crouch_start")
	await anim.animation_finished
	if state != PEEK_FIRE: return

	if _cover_point and not _point_is_hidden(_cover_point.global_position):
		var new_cover = _find_best_cover()
		if new_cover:
			_cover_point = new_cover
		else:
			_enter_open_firing()
			return

	state = TAKE_COVER
	_last_state = TAKE_COVER
	anim.play("idle_anim") 

	_peek_timer.wait_time = randf_range(peek_wait_min, peek_wait_max)
	_peek_timer.start()

func _enter_open_firing() -> void:
	state = FIRING
	_do_open_fire()

func _do_open_fire() -> void:
	while state == FIRING and _player:
		anim.play("aim_hold")
		await get_tree().create_timer(0.4).timeout
		if state != FIRING: return

		for i in range(open_combat_shots):
			if state != FIRING or ammo <= 0: break
			anim.play("shoot_anim")
			_fire_at_player()
			await anim.animation_finished
			ammo -= 1
			await get_tree().create_timer(0.18).timeout
			anim.play("cycle_anim")
			await anim.animation_finished

		if ammo <= 0:
			await _do_reload()
			if state != FIRING: return

		var cover = _find_best_cover()
		if cover:
			_cover_point = cover
			_enter_take_cover()
			return

		await get_tree().create_timer(0.5).timeout

func _do_reload() -> void:
	var prev = state
	state = RELOAD
	anim.play("reload_anim")
	await anim.animation_finished
	ammo = max_ammo
	state = prev

# ═════════════════════════════════════════════════════════════════════════════
#  DAMAGE & SHOOTING MATH
# ═════════════════════════════════════════════════════════════════════════════
func _fire_at_player() -> void:
	if not _player: return
	
	# Add slight random spread so the AI doesn't have 100% perfect aimbot
	var inaccuracy = Vector3(randf_range(-0.5, 0.5), randf_range(-0.5, 0.5), 0)
	var aim_point = _player.global_position + Vector3.UP * 1.0 + inaccuracy
	
	vrc.target_position = vrc.to_local(aim_point)
	vrc.force_raycast_update()
	
	if vrc.is_colliding():
		var hit = vrc.get_collider()
		if hit == _player or hit.name == "PLAYER":
			# If the raycast hits the player, deal damage to them!
			if hit.has_node("HealthComponent"):
				var player_hp = hit.get_node("HealthComponent")
				player_hp.take_damage(20) 
				print("Player was shot! HP left: ", player_hp.current_hp)

func take_hit() -> void:
	if _is_peeking or state == PEEK_FIRE:
		anim.play("shot_when_crouch")
	elif state in [FIRING, TAKE_COVER]:
		anim.play("shot_when_aim")
	else:
		anim.play("shot_when_passive")

# ═════════════════════════════════════════════════════════════════════════════
#  COVER MATH & NAVIGATION
# ═════════════════════════════════════════════════════════════════════════════
func _find_best_cover() -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	for point in get_tree().get_nodes_in_group("cover_point"):
		var d = global_position.distance_to(point.global_position)
		if d < cover_search_radius and d < best_dist and _point_is_hidden(point.global_position):
			best = point
			best_dist = d
	return best

func _point_is_hidden(world_pos: Vector3) -> bool:
	if not _player: return false
	var space = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(
		world_pos + Vector3.UP * 0.5,
		_player.global_position + Vector3.UP * 1.0)
	query.exclude = [self]
	var result = space.intersect_ray(query)
	return result.is_empty() or result.collider != _player

func _on_patrol_timer_timeout() -> void:
	if state == IDLE:
		state = PATROL
		# Snaps the random point to the nearest valid NavMesh location to prevent void-walking
		var random_pos = global_position + Vector3(randf_range(-10.0, 10.0), 0.0, randf_range(-10.0, 10.0))
		var safe_pos = NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), random_pos)
		nav_agent.target_position = safe_pos
		_patrol_timer.wait_time = randf_range(4.0, 8.0)
	elif state == PATROL:
		state = IDLE
		_patrol_timer.wait_time = randf_range(2.0, 5.0)
		
	_patrol_timer.start()

func _on_nav_finished() -> void:
	if state == PURSUE and not _player:
		_on_lose_sight_timeout()

func _on_lose_sight_timeout() -> void:
	if state == STUNNED: return

	if _last_known_player_pos != Vector3.ZERO:
		state = PURSUE
		nav_agent.target_position = _last_known_player_pos
		await get_tree().create_timer(3.5).timeout

	if state == STUNNED: return

	if anim.current_animation in ["aim_hold", "shoot_anim"]:
		anim.play("aim_hold", -1, -1.0, true)
		await anim.animation_finished

	state = IDLE
	_player = null
	_cover_point = null
	_last_known_player_pos = Vector3.ZERO

	await get_tree().create_timer(2.0).timeout
	if state == IDLE:
		state = PATROL
		_patrol_timer.wait_time = randf_range(3.0, 6.0)
		_patrol_timer.start()
