extends CharacterBody3D # Or whatever your root enemy node is

enum {IDLE, PATROL, FIRING, STUNNED}

const LOSE_SIGHT_TIME = 5.0  # seconds of grace period before giving up and going IDLE

var state = IDLE
var _last_state = -1  # forces the first play() call on the very first frame

@onready var sight = $Armature/Skeleton3D/vision/Sight
@onready var vrc = $Armature/Skeleton3D/vision/Sight/VisionRayCast
@onready var anim = $AnimationPlayer

var lose_sight_timer : Timer  # created in _ready, no need to add it in the editor

func _ready() -> void:
	# Stop the raycast from hitting the enemy's own body collider
	vrc.add_exception(self)

	# GLB/GLTF imports default every animation to Loop Mode: Disabled.
	# Force the locomotion cycles to loop here so it doesn't depend on
	# import settings (and survives re-importing the model later).
	_set_loop("idle_anim", true)
	_set_loop("walk_anim", true)
	# aim_hold / shot_when_aim are one-shot poses/reactions, not cycles —
	# left as non-looping. Flip these too if you want them to loop instead.

	# Cooldown timer: starts counting the moment sight of the player is lost.
	# If sight is regained before it fires, _on_vision_timer_timeout() stops it.
	lose_sight_timer = Timer.new()
	lose_sight_timer.wait_time = LOSE_SIGHT_TIME
	lose_sight_timer.one_shot = true
	lose_sight_timer.timeout.connect(_on_lose_sight_timer_timeout)
	add_child(lose_sight_timer)

func _set_loop(anim_name: String, should_loop: bool) -> void:
	if anim.has_animation(anim_name):
		var clip = anim.get_animation(anim_name)
		clip.loop_mode = Animation.LOOP_LINEAR if should_loop else Animation.LOOP_NONE

func _process(delta: float) -> void:
	if state != _last_state:
		_last_state = state
		match state:
			IDLE:
				anim.play("idle_anim")
			PATROL:
				anim.play("walk_anim")
			FIRING:
				anim.play("aim_hold")
			STUNNED:
				anim.play("shot_when_aim")

func _on_vision_timer_timeout() -> void:
	var player_seen = false

	var overlaps = sight.get_overlapping_bodies()
	if overlaps.size() > 0:
		for overlap in overlaps:
			if overlap.name == "PLAYER":
				if _check_line_of_sight(overlap):
					player_seen = true

	if player_seen:
		# Sight confirmed this tick — cancel any pending "give up" countdown
		lose_sight_timer.stop()
	elif state == FIRING and lose_sight_timer.is_stopped():
		# Just lost the player (left the cone OR got blocked by cover) —
		# start the grace period instead of dropping state immediately
		lose_sight_timer.start()


# Player is inside the cone — confirm nothing is blocking the shot before firing.
# Returns true only when there's a clear, unobstructed line of sight.
func _check_line_of_sight(player: Node3D) -> bool:
	# Aim roughly at chest height instead of the player's feet (origin)
	var player_pos = player.global_transform.origin + Vector3.UP * 1.0

	# Don't rotate the node with look_at() — RayCast3D's ray travels along
	# whatever local axis target_position points to (often Y-down by default,
	# not forward Z), so look_at() and the actual ray direction disagree.
	# Converting the player's world position into the raycast's own local
	# space sidesteps that entirely — it works no matter which axis or
	# length target_position was originally set to.
	vrc.target_position = vrc.to_local(player_pos)
	vrc.force_raycast_update()

	if vrc.is_colliding():
		var collider = vrc.get_collider()
		if collider == player or collider.name == "PLAYER":
			# Ray reached the player with nothing in the way — clear shot
			state = FIRING
			return true
		# else: ray hit a wall/cover first — blocked
	# else: ray didn't reach anything within its range

	return false


# Grace period expired with the player still out of sight — give up and reset.
# Eases out by playing the aim animation backwards (lowering the weapon)
# instead of snapping straight to idle_anim.
func _on_lose_sight_timer_timeout() -> void:
	# custom_speed = -1.0 plays it in reverse; from_end = true starts at the
	# last frame (the fully-aimed pose) and plays back toward frame 0
	anim.play("aim_hold", -1, -1.0, true)

	# Wait for the reverse clip to finish before changing `state` — otherwise
	# _process() would immediately stomp it with idle_anim the instant the
	# state changes, since that's what triggers play() in the match block
	await anim.animation_finished
	state = IDLE
