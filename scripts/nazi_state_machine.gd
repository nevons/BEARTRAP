extends CharacterBody3D

# ── States ────────────────────────────────────────────────────────────────────
enum { IDLE, PATROL, PURSUE, TAKE_COVER, PEEK_FIRE, FIRING, RELOAD, STUNNED }

# ── Export vars ───────────────────────────────────────────────────────────────
@export_group("Model Alignment")
@export var mesh_rotation_offset: float = 90.0 # Change to -90 or 180 if he faces the wrong way!

@export_group("Movement")
@export var patrol_speed     : float = 1.5   # slow aimless wander
@export var pursue_speed     : float = 4.2   # chasing the player
@export var crouch_walk_speed: float = 1.1   # shuffling to a cover point

@export_group("Combat")
@export var max_ammo            : int   = 5
@export var shots_per_peek      : int   = 2     # rounds fired each time enemy peeks
@export var open_combat_shots   : int   = 3     # rounds per burst when in the open
@export var peek_wait_min       : float = 1.5   # min seconds hiding before peeking
@export var peek_wait_max       : float = 3.5   # max seconds hiding before peeking
@export var cover_search_radius : float = 12.0  # how far to look for cover nodes

@export_group("Detection")
@export var shoot_range     : float = 22.0   # beyond this the enemy won't fire
@export var lose_sight_secs : float = 5.0    # grace period before giving up

# ── Internal bookkeeping ──────────────────────────────────────────────────────
var state       = IDLE
var _last_state = -1       # used to gate anim calls to state-change frames only
var ammo        : int
var _player     : Node3D = null
var _cover_point: Node3D = null
var _last_known_player_pos := Vector3.ZERO
var _is_peeking := false   # true while standing up for a peek, used by take_hit()
var _gravity    : float

# ── Node refs ─────────────────────────────────────────────────────────────────
# NavigationAgent3D must be added as a child in the editor.
# Bake a NavigationMesh over your level so it can path through the cave.
@onready var sight     = $Armature/Skeleton3D/vision/Sight
@onready var vrc       = $Armature/Skeleton3D/vision/Sight/VisionRayCast
@onready var anim      = $AnimationPlayer
@onready var nav_agent = $NavigationAgent3D

# ── Timers (built in code — no extra nodes needed in the editor) ──────────────
var _lose_sight_timer : Timer
var _peek_timer       : Timer
var _patrol_timer     : Timer

# ═════════════════════════════════════════════════════════════════════════════
func _ready() -> void:
	ammo     = max_ammo
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

	vrc.add_exception(self)

	# Only locomotion cycles need looping — reactions/poses are left one-shot
	_set_loop("idle_anim",   true)
	_set_loop("walk_anim",   true)
	_set_loop("crouch_walk", true)

	_lose_sight_timer = _make_timer(lose_sight_secs,true, _on_lose_sight_timeout)
	_peek_timer       = _make_timer(peek_wait_min,true, _on_peek_timer_timeout)
	_patrol_timer     = _make_timer(randf_range(3.0, 6.0),true, _on_patrol_timer_timeout)
	_patrol_timer.start()

	nav_agent.navigation_finished.connect(_on_nav_finished)

# ─────────────────────────────────────────────────────────────────────────────
func _make_timer(wait: float, one_shot: bool, cb: Callable) -> Timer:
	var t       = Timer.new()
	t.wait_time = wait
	t.one_shot  = one_shot
	t.timeout.connect(cb)
	add_child(t)
	return t

func _set_loop(anim_name: String, looping: bool) -> void:
	if anim.has_animation(anim_name):
		anim.get_animation(anim_name).loop_mode = \
			Animation.LOOP_LINEAR if looping else Animation.LOOP_NONE

# ═════════════════════════════════════════════════════════════════════════════
#  PROCESS — only plays an animation on the frame the state actually changes
# ═════════════════════════════════════════════════════════════════════════════
func _process(_delta: float) -> void:
	if state != _last_state:
		_last_state = state
		match state:
			IDLE:    anim.play("idle_anim", -1, 1.0)
			PATROL:  anim.play("walk_anim", -1, 1.0)
			PURSUE:  anim.play("walk_anim", -1, 1.8) # Sped up for pursuit!
			FIRING:  anim.play("aim_hold")
			STUNNED: anim.play("shot_when_aim")

# ═════════════════════════════════════════════════════════════════════════════
#  PHYSICS — movement every tick
# ═════════════════════════════════════════════════════════════════════════════
func _physics_process(delta: float) -> void:
	
	if not is_on_floor():
		velocity.y -= _gravity * delta

	match state:
		PATROL:
			_move_along_nav(patrol_speed, delta, true) # Look where he is walking

		PURSUE:
			if _player:
				# 1. ALWAYS lock eyes with the player
				_face_target(_player.global_position, delta)
				
				var dist = global_position.distance_to(_player.global_position)
				
				# 2. Stop pushing! Brake if within 2.5 meters
				if dist > 2.5: 
					nav_agent.target_position = _player.global_position
					_move_along_nav(pursue_speed, delta, false) # False = don't face path
				else:
					_brake(delta)
					
				# 3. Transition into combat once close enough
				if dist <= shoot_range:
					_on_player_spotted()
			else:
				_brake(delta)

		TAKE_COVER:
			# If we are still far away, sprint to the cover point and face the path
			if _cover_point and global_position.distance_to(_cover_point.global_position) > 0.6:
				_move_along_nav(pursue_speed, delta, true) 
			else:
				_brake(delta)
				
				# We arrived! Start hiding and start the peek timer.
				if _peek_timer.is_stopped() and state == TAKE_COVER:
					anim.play("crouch_start") # Get down behind the cover
					_peek_timer.wait_time = randf_range(peek_wait_min, peek_wait_max)
					_peek_timer.start()

		FIRING:
			if _player:
				_face_target(_player.global_position, delta)
			_brake(delta)

		_:
			_brake(delta)

	move_and_slide()

func _move_along_nav(speed: float, delta: float, face_path: bool = true) -> void:
	if nav_agent.is_navigation_finished():
		return
	var next_pos = nav_agent.get_next_path_position()
	var dir      = (next_pos - global_position)
	dir.y        = 0.0
	dir          = dir.normalized()
	
	# Only rotate towards the path if we are allowed to!
	if face_path and dir.length() > 0.01:
		_face_target(global_position + dir, delta)
		
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed

func _face_target(target_pos: Vector3, delta: float) -> void:
	var dir = target_pos - global_position
	dir.y   = 0.0
	if dir.length() < 0.01:
		return
		
	# atan2 calculates the angle to the target. We add your offset to fix the Blender export!
	var target_angle = atan2(dir.x, dir.z) + deg_to_rad(mesh_rotation_offset)
	rotation.y = lerp_angle(rotation.y, target_angle, delta * 8.0)

func _brake(delta: float) -> void:
	velocity.x = lerp(velocity.x, 0.0, delta * 10.0)
	velocity.z = lerp(velocity.z, 0.0, delta * 10.0)

# ═════════════════════════════════════════════════════════════════════════════
#  VISION TIMER — wired to VisionTimer node in the editor
# ═════════════════════════════════════════════════════════════════════════════
func _on_vision_timer_timeout() -> void:
	var player_seen := false

	for body in sight.get_overlapping_bodies():
		if body.name == "PLAYER":
			_player = body
			if _check_line_of_sight(body):
				player_seen          = true
				_last_known_player_pos = body.global_position
			break

	if player_seen:
		_lose_sight_timer.stop()

		match state:
			IDLE, PATROL:
				_on_player_spotted()

			PURSUE:
				# Check if we're in range to transition from chasing to fighting
				var dist = global_position.distance_to(_player.global_position)
				if dist <= shoot_range:
					_on_player_spotted()

			# TAKE_COVER / PEEK_FIRE / FIRING: already in combat, let those
			# coroutines handle themselves — don't interrupt
	else:
		if state in [PURSUE, FIRING, TAKE_COVER, PEEK_FIRE] \
				and _lose_sight_timer.is_stopped():
			_lose_sight_timer.start()

# ═════════════════════════════════════════════════════════════════════════════
#  SPOTTING — decide cover vs open combat
# ═════════════════════════════════════════════════════════════════════════════
func _on_player_spotted() -> void:
	_lose_sight_timer.stop()
	_peek_timer.stop()

	# Only trigger the surprise sequence if we are just now spotting them
	if state in [IDLE, PATROL, PURSUE]:
		_do_surprise_attack()

func _do_surprise_attack() -> void:
	state = FIRING
	_last_state = FIRING
	
	# 1. Aim at the player
	anim.play("aim_hold")
	await get_tree().create_timer(0.4).timeout
	
	if not _player: return
	
	# 2. Take the initial shot
	if ammo > 0:
		anim.play("shoot_anim")
		_fire_at_player()
		await anim.animation_finished
		ammo -= 1
		
	# 3. NOW find cover and sprint to it!
	var cover = _find_best_cover()
	if cover:
		_cover_point = cover
		_enter_take_cover()
	else:
		_enter_open_firing()

# ═════════════════════════════════════════════════════════════════════════════
#  COVER SEARCH
# ═════════════════════════════════════════════════════════════════════════════
func _find_best_cover() -> Node3D:
	var best      : Node3D = null
	var best_dist := INF
	for point in get_tree().get_nodes_in_group("cover_point"):
		var d = global_position.distance_to(point.global_position)
		if d < cover_search_radius and d < best_dist \
				and _point_is_hidden(point.global_position):
			best      = point
			best_dist = d
	return best

# Returns true when the given position is blocked from the player's view
func _point_is_hidden(world_pos: Vector3) -> bool:
	if not _player:
		return false
	var space  = get_world_3d().direct_space_state
	var query  = PhysicsRayQueryParameters3D.create(
		world_pos         + Vector3.UP * 0.5,
		_player.global_position + Vector3.UP * 1.0)
	query.exclude = [self]
	var result = space.intersect_ray(query)
	# Valid cover = ray hits geometry before reaching player
	return result.is_empty() or result.collider != _player

# ═════════════════════════════════════════════════════════════════════════════
#  TAKE COVER
# ═════════════════════════════════════════════════════════════════════════════
func _enter_take_cover() -> void:
	state      = TAKE_COVER
	_last_state = TAKE_COVER
	nav_agent.target_position = _cover_point.global_position
	
	# SPRINT to cover (sped up walk animation), facing AWAY from the player
	anim.play("walk_anim", -1, 1.8)

func _on_peek_timer_timeout() -> void:
	if state != TAKE_COVER or not _player:
		return
	# Not at cover yet — give it another second before trying to peek
	if _cover_point and \
			global_position.distance_to(_cover_point.global_position) > 1.5:
		_peek_timer.wait_time = 1.0
		_peek_timer.start()
		return
	_do_peek_and_fire()   # runs as a coroutine — intentionally no await here

# ═════════════════════════════════════════════════════════════════════════════
#  PEEK-AND-FIRE CYCLE
# ═════════════════════════════════════════════════════════════════════════════
func _do_peek_and_fire() -> void:
	state       = PEEK_FIRE
	_is_peeking = true

	# ── Stand up (crouch_start reversed at 1.5× speed) ───────────────────────
	anim.play("crouch_start", -1, -1.5, true)
	await anim.animation_finished
	if state != PEEK_FIRE:
		return

	# ── Face player ───────────────────────────────────────────────────────────
	if _player:
		var dir = _player.global_position - global_position
		dir.y   = 0.0
		if dir.length() > 0.01:
			rotation.y = atan2(dir.x, dir.z)

	# ── Aim pause before firing ───────────────────────────────────────────────
	anim.play("aim_hold")
	await get_tree().create_timer(0.35).timeout
	if state != PEEK_FIRE:
		return

	# ── Fire shots_per_peek rounds ────────────────────────────────────────────
	for i in range(shots_per_peek):
		if ammo <= 0 or state != PEEK_FIRE:
			break
		anim.play("shoot_anim")
		_fire_at_player()
		await anim.animation_finished
		ammo -= 1
		if i < shots_per_peek - 1:
			await get_tree().create_timer(0.18).timeout

	# ── Reload if mag empty ───────────────────────────────────────────────────
	if ammo <= 0:
		await _do_reload()
		if state != PEEK_FIRE:
			return

	# ── Get back down ─────────────────────────────────────────────────────────
	_is_peeking = false
	anim.play("crouch_start")
	await anim.animation_finished
	if state != PEEK_FIRE:
		return

	# ── Re-evaluate cover, then queue next peek ───────────────────────────────
	if _cover_point and not _point_is_hidden(_cover_point.global_position):
		# Current cover no longer blocks LOS — find a new spot
		var new_cover = _find_best_cover()
		if new_cover:
			_cover_point = new_cover
		else:
			# No cover at all → open combat
			_enter_open_firing()
			return

	state      = TAKE_COVER
	_last_state = TAKE_COVER
	anim.play("idle_anim")   # crouching idle while waiting for next peek

	_peek_timer.wait_time = randf_range(peek_wait_min, peek_wait_max)
	_peek_timer.start()

# ═════════════════════════════════════════════════════════════════════════════
#  OPEN COMBAT (no cover available)
# ═════════════════════════════════════════════════════════════════════════════
func _enter_open_firing() -> void:
	state = FIRING
	_do_open_fire()   # coroutine — no await

func _do_open_fire() -> void:
	while state == FIRING and _player:
		# Aim briefly before each burst
		anim.play("aim_hold")
		await get_tree().create_timer(0.4).timeout
		if state != FIRING:
			return

		# Fire a burst
		for i in range(open_combat_shots):
			if state != FIRING or ammo <= 0:
				break
			anim.play("shoot_anim")
			_fire_at_player()
			await anim.animation_finished
			ammo -= 1
			await get_tree().create_timer(0.18).timeout

		# Reload if needed
		if ammo <= 0:
			await _do_reload()
			if state != FIRING:
				return

		# After each burst, check if cover has appeared nearby
		var cover = _find_best_cover()
		if cover:
			_cover_point = cover
			_enter_take_cover()
			return

		await get_tree().create_timer(0.5).timeout

# ═════════════════════════════════════════════════════════════════════════════
#  RELOAD (shared by peek and open-combat paths)
# ═════════════════════════════════════════════════════════════════════════════
func _do_reload() -> void:
	var prev = state
	state    = RELOAD
	anim.play("reload_anim")
	await anim.animation_finished
	ammo  = max_ammo
	state = prev   # return to whatever triggered the reload

# ═════════════════════════════════════════════════════════════════════════════
#  LOSE SIGHT
# ═════════════════════════════════════════════════════════════════════════════
func _on_lose_sight_timeout() -> void:
	if state == STUNNED:
		return

	# Head to the last place the player was seen
	if _last_known_player_pos != Vector3.ZERO:
		state = PURSUE
		nav_agent.target_position = _last_known_player_pos
		await get_tree().create_timer(3.5).timeout

	if state == STUNNED:
		return

	# Smoothly lower weapon before going idle
	if anim.current_animation in ["aim_hold", "shoot_anim"]:
		anim.play("aim_hold", -1, -1.0, true)
		await anim.animation_finished

	state                  = IDLE
	_player                = null
	_cover_point           = null
	_last_known_player_pos = Vector3.ZERO

	# Brief pause, then resume patrol
	await get_tree().create_timer(2.0).timeout
	if state == IDLE:
		state = PATROL
		_patrol_timer.wait_time = randf_range(3.0, 6.0)
		_patrol_timer.start()

# ═════════════════════════════════════════════════════════════════════════════
#  PATROL WANDER
# ═════════════════════════════════════════════════════════════════════════════
func _on_patrol_timer_timeout() -> void:
	# Toggle back and forth between IDLE and PATROL
	if state == IDLE:
		state = PATROL
		var random_pos = global_position + Vector3(randf_range(-8.0, 8.0), 0.0, randf_range(-8.0, 8.0))
		
		# FORCE the random point to snap to the nearest valid NavMesh location
		var safe_pos = NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), random_pos)
		nav_agent.target_position = safe_pos
		
		_patrol_timer.wait_time = randf_range(4.0, 8.0)
	elif state == PATROL:
		state = IDLE
		_patrol_timer.wait_time = randf_range(2.0, 5.0)
		
	_patrol_timer.start()

func _on_nav_finished() -> void:
	# Reached last known position in PURSUE but player still lost → give up
	if state == PURSUE and not _player:
		_on_lose_sight_timeout()

# ═════════════════════════════════════════════════════════════════════════════
#  HIT REACTION — call this from your health/damage system
# ═════════════════════════════════════════════════════════════════════════════
func take_hit() -> void:
	if _is_peeking or state == PEEK_FIRE:
		anim.play("shot_when_crouch")
	elif state in [FIRING, TAKE_COVER]:
		anim.play("shot_when_aim")
	else:
		anim.play("shot_when_passive")

# ═════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ═════════════════════════════════════════════════════════════════════════════
func _check_line_of_sight(player: Node3D) -> bool:
	vrc.target_position = vrc.to_local(player.global_transform.origin + Vector3.UP * 1.0)
	vrc.force_raycast_update()
	if vrc.is_colliding():
		var col = vrc.get_collider()
		return col == player or col.name == "PLAYER"
	return false

func _fire_at_player() -> void:
	if not _player: return
	
	# Add a slight random spread so the AI doesn't have 100% perfect aimbot
	var inaccuracy = Vector3(randf_range(-0.6, 0.6), randf_range(-0.6, 0.6), 0)
	var aim_point = _player.global_position + Vector3.UP * 1.0 + inaccuracy
	
	vrc.target_position = vrc.to_local(aim_point)
	vrc.force_raycast_update()
	
	if vrc.is_colliding():
		var hit = vrc.get_collider()
		if hit == _player or hit.name == "PLAYER":
			# If the raycast hits the player, deal damage to them!
			if hit.has_node("HealthComponent"):
				var player_hp = hit.get_node("HealthComponent")
				player_hp.take_damage(20) # 5 shots to kill the player
				print("Player was shot! HP left: ", player_hp.current_hp)
