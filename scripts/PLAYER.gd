extends CharacterBody3D


#speed var
var speed 
@export_range(5,10,0.1) var CROUCH_SPEED : float = 7.0
@export var CROUCHED_SPEED = 1.0
@export var WALK_SPEED = 3.0
@export var SPRINT_SPEED = 5.0

var _is_crouching : bool = false
var _is_running : bool = false


var sensitivity = 0.05

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

# --- Weapon Bob Settings ---
const BOB_FREQ_IDLE = 1.5   # Lower frequency makes it feel like slow, heavy breathing
const BOB_AMP_IDLE = 0.006  # Turning this up increases the physical range of the drift

const BOB_FREQ_WALK = 12.0
const BOB_AMP_WALK = 0.015

const BOB_FREQ_RUN = 16.0
const BOB_AMP_RUN = 0.03

const BOB_FREQ_CROUCH = 6.0
const BOB_AMP_CROUCH = 0.005

var bob_timer: float = 0.0
 
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
@onready var anims= $AnimationPlayer
@onready var headbbonker = $HEADBONKER
@onready var footstep_player = $FootstepPlayer   # AudioStreamPlayer node
@onready var footstep_ray   = $FootstepRay      # RayCast3D — target (0, -1.2, 0)
@onready var interact_raycast = $Head/Camera3D/InteractionRay
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
		
	interact_raycast.collide_with_areas = true
	
	#item switch
	if event.is_action_pressed("interact"):
		try_interaction()


func _physics_process(delta):
	# Add the gravity.
	if not is_on_floor():
		velocity.y -= gravity * delta

	
	# Get the input vector direction
	var input_dir = Input.get_vector("left", "right","forward", "backward")
	
	# Determine if the player's intentional movement is strictly forward.
	# input_dir.y < -0.5 confirms forward tracking, while abs(input_dir.x) < 0.5 
	# ensures they aren't drastically strafing left or right.
	var moving_forward: bool = input_dir.y < -0.5 and abs(input_dir.x) < 0.5
	
	# speed and movement logic
	# Added check: cannot sprint if '_is_crouching' is true
	if Input.is_action_pressed("sprint") and moving_forward and not _is_crouching:
		speed = SPRINT_SPEED
	elif Input.is_action_just_pressed("crouch"):
		_toggle_crouch()
		# Speed assignment is safely decoupled here to let _toggle_crouch handle state transitions
	else:
		# Fallback movement speeds based on current stance state
		if _is_crouching:
			speed = CROUCHED_SPEED
		else:
			speed = WALK_SPEED 
	
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
	# --- FOV & ZOOM LOGIC ---
	var target_fov = fov_base
	var fov_speed = 8.0 # Default transition speed
	
	if Input.is_action_pressed("zoom"):
		target_fov = 55.0 
		fov_speed = 12.0 
		sensitivity = 0.02 
	else:
		# Only apply the movement FOV stretching if we are NOT aiming
		sensitivity = 0.05
		var vel_clamped = clamp(velocity.length(), 0.5, SPRINT_SPEED*2 )
		target_fov = fov_base + fov_change * vel_clamped

	# Smoothly transition the camera to whatever the target FOV is
	cam.fov = lerp(cam.fov, target_fov, delta * fov_speed)

	move_and_slide()
	
	#checking for _is_running 
	var wants_to_sprint = Input.is_action_pressed("sprint")
	var is_moving_input = input_dir.length() > 0.1
	
	# The player is running ONLY if they want to sprint, are moving, and aren't crouching
	if wants_to_sprint and is_moving_input and not _is_crouching:
		_is_running = true
	else:
		_is_running = false
		
	
	
	# ---- Camera bob + footsteps (after move_and_slide so velocity is final) ----
	var is_moving = velocity.length() > 0.5 and is_on_floor()
 
	# Bob frequency scales with movement state
	var bob_speed_mult = 1.0
	if speed == SPRINT_SPEED:
		bob_speed_mult = 1.6
	elif speed == CROUCHED_SPEED:
		bob_speed_mult = 0.7
 
	if is_moving:
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
	
	#gun sway
	
	# 1. Determine current speed state to pick the right bob intensity
	var current_freq: float = BOB_FREQ_IDLE
	var current_amp: float = BOB_AMP_IDLE

	

	if is_moving:
		if _is_crouching: # Check your existing crouch variable name
			current_freq = BOB_FREQ_CROUCH
			current_amp = BOB_AMP_CROUCH
		elif _is_running: # Check your existing sprint variable name
			current_freq = BOB_FREQ_RUN
			current_amp = BOB_AMP_RUN
		else:
			current_freq = BOB_FREQ_WALK
			current_amp = BOB_AMP_WALK

	# 2. Advance the timer based on the current frequency
	bob_timer += delta * current_freq

	# 3. Calculate the target position using Sine (Vertical) and Cosine (Horizontal)
	var target_bob_pos = Vector3.ZERO
	
	# The vertical jump (Sine wave)
	target_bob_pos.y = sin(bob_timer) * current_amp
	# The horizontal sway (Cosine wave runs at half speed for a natural figure-8 shape)
	target_bob_pos.x = cos(bob_timer / 2.0) * current_amp

	# 4. Smoothly blend (LERP) the hand container to the new bob position
	# This prevents the gun from snapping abruptly when you switch from sprinting to crouching
	item_manager.position.x = lerp(item_manager.position.x, target_bob_pos.x, 10.0 * delta)
	item_manager.position.y = lerp(item_manager.position.y, target_bob_pos.y, 10.0 * delta)
 
 
func try_interaction():
	if interact_raycast.is_colliding():
		var collider = interact_raycast.get_collider()
		
		# 1. DEBUG: Tell us exactly what the raycast just hit
		print("RayCast hit: ", collider.name) 
		
		# 2. DUCK TYPING: Bypass 'is Interactable' and just check if the function exists
		if collider.has_method("interact"):
			print("Interactable object confirmed. Running code...")
			
			# 3. Only attempt to equip the item to the hand if it is an actual equippable tool
			# (Ammo boxes will inherit an ID of 0, so this prevents the hand container from glitching)
			if "item_enum_id" in collider and collider.item_enum_id > 0:
				item_manager.unlock_and_equip_item(collider.item_enum_id)
			
			# Run the interact logic (whether it's ammo or a weapon)
			collider.interact()
		else:
			print("WARNING: This object does NOT have an interact() script attached.")
	else:
		print("RayCast didn't hit anything at all.")


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
