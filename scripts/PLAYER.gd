extends CharacterBody3D


#speed var
var speed 
@export_range(5,10,0.1) var CROUCH_SPEED : float = 7.0
@export var CROUCHED_SPEED = 1.0
@export var WALK_SPEED = 3.0
@export var SPRINT_SPEED = 5.0

var _is_crouching : bool = false

const sensitivity = 0.05

#fov
const fov_base = 90
const fov_change = 0.7

# --- Bob ---
const BOB_FREQ = 2.4
const BOB_AMP  = 0.06
var t_bob       = 0.0

# --- Footsteps ---
# t_step is independent from t_bob so step speed can be tuned freely
const STEP_FREQ  = 9.0   # increase to play steps faster, decrease to slow them down
var t_step        = 0.0
var _step_played := false
 
# Add one AudioStream per surface type in the Inspector.
# Tag your floor/terrain nodes with matching groups:
#   "surface_grass"  "surface_wood"  "surface_concrete"
#   "surface_metal"  "surface_gravel"
# Any surface with no matching group falls back to _default_steps.
@export var grass_steps    : Array[AudioStream] = []
@export var wood_steps     : Array[AudioStream] = []
@export var concrete_steps : Array[AudioStream] = []
@export var metal_steps    : Array[AudioStream] = []
@export var gravel_steps   : Array[AudioStream] = []
@export var default_steps  : Array[AudioStream] = []   # fallback

#references
@onready var head = $Head
@onready var cam = $Head/Camera3D
@onready var pcap = $CollisionShape3D
@onready var  anims= $AnimationPlayer
@onready var headbbonker = $HEADBONKER
@onready var footstep_player = $FootstepPlayer   # AudioStreamPlayer node
@onready var footstep_ray   = $FootstepRay       # RayCast3D — target (0, -1.2, 0)
@onready var interact_raycast = $Head/Camera3D/InteractionRayCast
@onready var item_manager = $Head/Camera3D/HandContainer



# Get the gravity from the project settings to be synced with RigidBody nodes.
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

#camera rotation
func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	#headbonker exception is us!
	headbbonker.add_exception($".")
	
func _unhandled_input(event):
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		head.rotate_x(deg_to_rad(-event.relative.y * sensitivity))
		self.rotate_y(deg_to_rad(-event.relative.x * sensitivity))
		head.rotation.x = clamp(head.rotation.x, deg_to_rad(-90), deg_to_rad(90))

	if Input.is_action_just_pressed("escape"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		
	#item switch
		if event.is_action_pressed("interact"):
			try_interaction()


func _physics_process(delta):
	
	#weapons

	# Add the gravity.
	if not is_on_floor():
		velocity.y -= gravity * delta

	
	#speed and movement
	if Input.is_action_pressed("sprint"):
		speed=SPRINT_SPEED
	elif Input.is_action_just_pressed("crouch"):
		speed=CROUCHED_SPEED
		_toggle_crouch()
			
	else:
		speed=WALK_SPEED 
	
	var input_dir = Input.get_vector("left", "right","forward", "backward")
	var direction = (self.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	#inertia
	if is_on_floor():
		if direction:
				velocity.x = direction.x * speed
				velocity.z = direction.z * speed
		else:
				velocity.x = lerp(velocity.x, direction.x*speed, delta*6.0)
				velocity.z = lerp(velocity.z, direction.z*speed, delta*6.0)
	else:
		velocity.x = lerp(velocity.x, direction.x*speed, delta*3.0)
		velocity.z = lerp(velocity.z, direction.z*speed, delta*3.0)
		
	#fov
	var vel_clamped = clamp(velocity.length(), 0.5, SPRINT_SPEED*2 )
	var target_fov = fov_base + fov_change*vel_clamped
	cam.fov = lerp(cam.fov, target_fov, delta*8.0)

	move_and_slide()
	
	# ---- Camera bob + footsteps (after move_and_slide so velocity is final) ----
	var is_moving = velocity.length() > 0.5 and is_on_floor()
 
	# Bob frequency scales with movement state
	var bob_speed_mult = 1.0
	if speed == SPRINT_SPEED:
		bob_speed_mult = 1.6
	elif speed == CROUCHED_SPEED:
		bob_speed_mult = 0.7
 
	if is_moving:
		# ACCUMULATE t_bob — this was the original bug (it was being set, not added)
		t_bob += delta * BOB_FREQ * bob_speed_mult * (velocity.length() / WALK_SPEED)
	else:
		# Smoothly ease back to the nearest full cycle so the cam settles at origin
		t_bob = lerp(t_bob, round(t_bob / TAU) * TAU, delta * 8.0)
 
	cam.transform.origin = _headbob(t_bob)

	# Step timer runs independently — tune STEP_FREQ without touching bob or speed
	# Step timer runs independently from headbob
	# Walking keeps normal pace, sprinting increases step frequency

	var step_speed_mult = 1.0

	if speed == SPRINT_SPEED:
		step_speed_mult = 1.6
	elif speed == CROUCHED_SPEED:
		step_speed_mult = 0.65

	if is_moving:
		t_step += delta * STEP_FREQ * step_speed_mult
	else:
		t_step = 0.0

	_handle_footsteps(t_step, is_moving)
 
 
func try_interaction():
	if interact_raycast.is_colliding():
		var collider = interact_raycast.get_collider()
		if collider is Interactable:
			# Connect the item picked up to your inventory/item manager
			item_manager.unlock_and_equip_item(collider.item_enum_id)
			collider.interact()


# Smooth figure-8 style bob: vertical on every step, lateral on every two steps
func _headbob(time: float) -> Vector3:
	var pos = Vector3.ZERO
	if is_on_floor():
		pos.y = sin(time)         * BOB_AMP
		pos.x = cos(time * 0.5)  * BOB_AMP * 0.5
	else:
		# In the air: ease the camera back to neutral
		pos = cam.transform.origin.lerp(Vector3.ZERO, 0.1)
	return pos
	
# Fires a footstep sound each time sin(t_bob) crosses below zero ("foot down")
func _handle_footsteps(time: float, is_moving: bool) -> void:
	if not is_moving:
		_step_played = false
		return
 
	var sin_val = sin(time)
 
	if sin_val < 0.0 and not _step_played:
		_step_played = true
		_play_footstep()
	elif sin_val >= 0.0:
		_step_played = false
 
 
func _play_footstep() -> void:
	if not footstep_player:
		return
 
	var pool := _get_surface_sounds()
	if pool.is_empty():
		return
 
	# Pick a random clip, slight pitch variation keeps steps from sounding robotic
	footstep_player.stream      = pool.pick_random()
	footstep_player.pitch_scale = randf_range(0.88, 1.12)
	footstep_player.play()
 
 
# Casts the ray straight down and returns the sound pool matching the surface group.
# Falls back to default_steps if nothing matches.
func _get_surface_sounds() -> Array[AudioStream]:
	if footstep_ray and footstep_ray.is_colliding():
		var body = footstep_ray.get_collider()
		if body:
			if body.is_in_group("surface_grass"):    return grass_steps
			if body.is_in_group("surface_wood"):     return wood_steps
			if body.is_in_group("surface_concrete"): return concrete_steps
			if body.is_in_group("surface_metal"):    return metal_steps
			if body.is_in_group("surface_gravel"):   return gravel_steps
 
	return default_steps
	
func _toggle_crouch():
	
	if _is_crouching==true and headbbonker.is_colliding()==false:
		anims.play("crouch",-1,-CROUCH_SPEED,true)
		speed=WALK_SPEED
	elif _is_crouching == false:
		anims.play("crouch",-1,CROUCH_SPEED)
		speed=CROUCHED_SPEED



func _on_animation_player_animation_started(anim_name):
	if anim_name == "crouch":
		_is_crouching=!_is_crouching
