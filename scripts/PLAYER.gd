extends CharacterBody3D


#speed var
var speed 
@export_range(5,10,0.1) var CROUCH_SPEED : float = 7.0
@export var CROUCHED_SPEED = 1.0
@export var WALK_SPEED = 3.0
@export var SPRINT_SPEED = 5.0

#motion states
var _is_crouching : bool = false
var _is_running : bool = false

# --- Fall Damage Tracking ---
var _was_on_floor: bool = true
var _last_y_velocity: float = 0.0
const SAFE_FALL_SPEED: float = -12.0 # Anything faster than -12 m/s will cause damage

# --- Recoil System ---
var target_recoil: Vector3 = Vector3.ZERO
var current_recoil: Vector3 = Vector3.ZERO
const RECOIL_SNAP: float = 60.0    # How violently the camera kicks
const RECOIL_RETURN: float = 3.0   # How smoothly it centers back

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
 

var max_battery: float = 100.0
var current_battery: float = 100.0

var drain_rate: float = 1.5   # How fast it dies per second while ON
var charge_rate: float = 6.0 # How fast it charges per second while CRANKING

var max_energy: float = 5.0   # The maximum brightness
var min_energy: float = 0.05  # A pathetic, barely-visible glow when dead
var max_angle: float = 60.0   # Wide cone when fully charged
var min_angle: float = 15.0   # Tight, focused beam when dying
var has_flashlight : bool = false
var is_flashlight_on: bool = false
 
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


#UI
@onready var ammo_label: Label = $UI/AmmoContainer/Label
@onready var reload_ring: TextureProgressBar = $UI/Reticle/ReloadRing
var reload_tween: Tween
#Health Bar:
@onready var health_bar: TextureProgressBar = $UI/HealthContainer/HealthBar
@onready var health_comp = $HealthComponent

#	 --- Flashlight System ---
@onready var hand_light: SpotLight3D = $Head/Camera3D/HandContainer/FlashlightMesh/SpotLight3D
@onready var belt_light: SpotLight3D = $BeltPosition/FlashlightLight
@onready var flashlight_mesh = $Head/Camera3D/HandContainer/FlashlightMesh
# Update this path to exactly where your battery bar is:
@onready var battery_ui: TextureProgressBar = $UI/BatteryContainer/TextureProgressBar

var tex_full = preload("res://assets/textures/health_bar/full-removebg-preview.png")
var tex_low = preload("res://assets/textures/health_bar/low-removebg-preview.png")


# Get the gravity from the project settings to be synced with RigidBody nodes.
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

#camera rotation
func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	reload_ring.visible = false
	#headbonker exception is us!
	headbbonker.add_exception($".")
	
	# Hide the entire battery container on startup
	if $UI/BatteryContainer:
		$UI/BatteryContainer.visible = false
		
	health_comp.health_changed.connect(_update_health_ui)
	_update_health_ui(health_comp.current_hp, health_comp.max_hp)
	
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

func _input(event):
	if event.is_action_pressed("toggle_flashlight"): # Make sure this is mapped in Input Map!
		is_flashlight_on = !is_flashlight_on

func _physics_process(delta):
	# --- GRAVITY & FALL DAMAGE ---
	if not is_on_floor():
		velocity.y -= gravity * delta
		_was_on_floor = false
		_last_y_velocity = velocity.y # Constantly record how fast we are falling
	else:
		# We are on the floor. Did we JUST land this frame?
		if not _was_on_floor:
			# If we were falling faster than our safe speed, calculate the impact!
			if _last_y_velocity < SAFE_FALL_SPEED:
				# Subtract the safe speed so small jumps don't hurt, then multiply for lethality
				var fall_severity = abs(_last_y_velocity) - abs(SAFE_FALL_SPEED)
				var damage = int(fall_severity * 10.0) # Multiply by 5 for crunchy damage scaling
				
				if health_comp:
					health_comp.take_damage(damage)
					# Optional: violently shake the camera to sell the impact
					fire_recoil() 
					
			_was_on_floor = true

	
	# Get the input vector direction
	var input_dir = Input.get_vector("left", "right","forward", "backward")
	
	# Determine if the player's intentional movement is strictly forward.
	# input_dir.y < -0.5 confirms forward tracking, while abs(input_dir.x) < 0.5 
	# ensures they aren't drastically strafing left or right.
	var moving_forward: bool = input_dir.y < -0.5 and abs(input_dir.x) < 0.5
	
	# speed and movement logic
	# Get a quick reference to whether we are aiming right now
	var is_zooming: bool = Input.is_action_pressed("zoom")
	
	# speed and movement logic
	if Input.is_action_just_pressed("crouch"):
		_toggle_crouch()
		# Speed assignment is safely decoupled here to let _toggle_crouch handle state transitions
		
	# Added check: cannot sprint if '_is_crouching' OR 'is_zooming' is true
	if Input.is_action_pressed("sprint") and moving_forward and not _is_crouching and not is_zooming:
		speed = SPRINT_SPEED
	else:
		# Fallback movement speeds based on current stance state
		if _is_crouching or is_zooming:
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
		speed = CROUCHED_SPEED
		target_fov = 55.0 
		fov_speed = 12.0 
		sensitivity = 0.02 
	else:
		# Only apply the movement FOV stretching if we are NOT aiming
		speed = WALK_SPEED
		sensitivity = 0.05
		var vel_clamped = clamp(velocity.length(), 0.5, SPRINT_SPEED*2 )
		target_fov = fov_base + fov_change * vel_clamped

	# Smoothly transition the camera to whatever the target FOV is
	cam.fov = lerp(cam.fov, target_fov, delta * fov_speed)

	move_and_slide()
	
	#checking for _is_running 
	var wants_to_sprint = Input.is_action_pressed("sprint")
	var is_moving_input = input_dir.length() > 0.1
	
	# The player is running ONLY if they want to sprint, are moving, aren't crouching, AND aren't zooming
	if wants_to_sprint and is_moving_input and not _is_crouching and not is_zooming:
		_is_running = true
	else:
		_is_running = false
		
	# --- Flashlight Math ---
	if has_flashlight:
		# 1. Handle Charging 
		if flashlight_mesh.visible and Input.is_action_pressed("recharge"): 
			current_battery += charge_rate * delta
		
		# 2. Handle Draining 
		elif is_flashlight_on:
			current_battery -= drain_rate * delta
			
		# 3. Keep the battery within 0 to 100 bounds
		current_battery = clamp(current_battery, 0.0, max_battery)
		
	# 4. Update the visual lights
	_update_flashlight_visuals()
	
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
	
	# kick and recoil
	# 1. Constantly ease the target back to zero
	target_recoil = target_recoil.lerp(Vector3.ZERO, delta * RECOIL_RETURN)
	# 2. Rapidly snap the current recoil to the target
	current_recoil = current_recoil.lerp(target_recoil, delta * RECOIL_SNAP)
	# 3. Apply it to the camera
	cam.rotation = current_recoil
 
 
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
		
func fire_recoil():
	# Mosin is a heavy rifle, give it a hefty kick!
	# Positive X pitches the camera up. Random Y and Z add the "shake".
	var kick_up = randf_range(7.0,10.0)     # Degrees to violently kick up
	var shake_yaw = randf_range(-1.5, 3.5)  # Left/right chaotic shake
	var shake_roll = randf_range(-1.0, 4.0) # Screen tilt
	
	target_recoil += Vector3(deg_to_rad(kick_up), deg_to_rad(shake_yaw), deg_to_rad(shake_roll))

func update_ammo_ui(current: int, reserve: int):
	if ammo_label:
		ammo_label.text = str(current) + " / " + str(reserve)

func start_reload_ui(anim_duration: float):
	reload_ring.value = 0
	reload_ring.visible = true
	
	# Kill any previous tween so they don't fight
	if reload_tween:
		reload_tween.kill()
		
	reload_tween = create_tween()
	# Smoothly animate 'value' to 100 over the exact length of the animation
	reload_tween.tween_property(reload_ring, "value", 100.0, anim_duration)

func stop_reload_ui():
	if reload_tween:
		reload_tween.kill()
	reload_ring.visible = false

func _update_flashlight_visuals():
	if not has_flashlight:
		hand_light.visible = false
		belt_light.visible = false
		return
	# Get a percentage between 0.0 (empty) and 1.0 (full)
	var power_percent = current_battery / max_battery
	
	# Calculate the new brightness and cone size based on the battery percentage
	var current_energy = lerp(min_energy, max_energy, power_percent)
	var current_angle = lerp(min_angle, max_angle, power_percent)
	
	# Apply to the Hand Light
	hand_light.light_energy = current_energy
	hand_light.spot_angle = current_angle
	
	# Apply to the Belt Light
	belt_light.light_energy = current_energy
	belt_light.spot_angle = current_angle
	
	# Turn them on/off based on the player's toggle state and if it's equipped
	if is_flashlight_on and current_battery > 0:
		hand_light.visible = flashlight_mesh.visible
		belt_light.visible = not flashlight_mesh.visible
	else:
		hand_light.visible = false
		belt_light.visible = false
		
	# Update the UI Bar
	if battery_ui:
		battery_ui.value = current_battery

func pickup_flashlight():
	has_flashlight = true
	
	# Reveal the UI container!
	if $UI/BatteryContainer:
		$UI/BatteryContainer.visible = true

func _update_health_ui(current, maximum):
	if not health_bar: return
		
	health_bar.max_value = maximum
	health_bar.value = current
	
	# Calculate the percentage
	var health_percent = float(current) / float(maximum)
	
	# If health is at or below 30%, tint the white scribble red!
	if health_percent <= 0.30:
		# Using a gritty, dark blood red (R, G, B)
		health_bar.tint_progress = Color(0.8, 0.0, 0.0) 
	else:
		# Reset back to pure white if they heal
		health_bar.tint_progress = Color.WHITE
		
	# DEBUG PRINT: Watch the console to see your exact health math when you fall
	print("UI Updated - HP: ", current, " | Percent: ", health_percent)
