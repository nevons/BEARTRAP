extends Node3D

# Define the weapon states
enum WeaponState {
	READY,         # Bullet chambered, ready to fire
	NEED_BOLT,     # Fired, but bolt hasn't been cycled yet
	CYCLING,       # Currently playing the bolt animation
	EMPTY          # Out of ammo completely
}

var current_state: WeaponState = WeaponState.READY

# Ammo parameters
const MAX_AMMO = 5
var current_ammo = MAX_AMMO

# PATH CHECK: Adjust this to point exactly to your new pivot container!
# You can also drag the BoltPivot node from the scene tree panel into the script while holding Ctrl.
@onready var bolt_mesh: Node3D = $low_poly_mosin/BoltPivot

func _ready():
	current_state = WeaponState.READY
	print("Mosin Ready. Ammo: ", current_ammo, "/", MAX_AMMO)

# Called by your player input handler when Left-Click is pressed
func action_fire():
	if current_state != WeaponState.READY:
		if current_state == WeaponState.NEED_BOLT:
			print("*Click* — You need to cycle the bolt! (Press R)")
			play_dry_click_sound()
		return

	# Deduct ammo and fire
	current_ammo -= 1
	print("BANG! Ammo left: ", current_ammo)
	
	play_fire_effects()
	
	# Transition state: The player MUST cycle the bolt now before firing again
	current_state = WeaponState.NEED_BOLT

# Called by your player input handler when 'R' (or your cycle key) is pressed
func action_cycle_bolt():
	if current_state != WeaponState.NEED_BOLT:
		return
		
	current_state = WeaponState.CYCLING
	print("Cycling bolt...")
	
	# Run the multi-step procedural animation sequence
	await play_procedural_bolt_animation()
	
	# Determine next state based on remaining ammo
	if current_ammo > 0:
		current_state = WeaponState.READY
		print("Round chambered. Ready to fire.")
	else:
		current_state = WeaponState.EMPTY
		print("Rifle is completely empty! Need full reload.")

# The Tween Animation Engine Logic
func play_procedural_bolt_animation():
	var tween = create_tween().set_parallel(false)
	
	# 1. Rotate bolt handle UP (Unlock)
	# NOTE: If your bolt rotates on a different axis (like Y or Z), change "rotation_degrees:x" below!
	tween.tween_property(bolt_mesh, "rotation_degrees:x", 75.0, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await tween.finished
	
	# 2. Slide bolt BACK (Eject spent brass casing)
	tween = create_tween().set_parallel(false)
	# NOTE: Adjust "position:z" and the value (0.15) depending on your model's forward/backward axis orientation
	tween.tween_property(bolt_mesh, "position:z", 0.15, 0.18).set_trans(Tween.TRANS_LINEAR)
	
	# --- ON THIS EXACT FRAME: This is where we will spawn physical brass shells flying out later! ---
	
	await tween.finished
	
	# Brief mechanical pause at the peak back-stroke for tactical weight
	await get_tree().create_timer(0.08).timeout
	
	# 3. Slide bolt FORWARD (Chamber new cartridge)
	tween = create_tween().set_parallel(false)
	tween.tween_property(bolt_mesh, "position:z", 0.0, 0.15).set_trans(Tween.TRANS_LINEAR)
	await tween.finished
	
	# 4. Rotate bolt handle DOWN (Lock weapon back into battery)
	tween = create_tween().set_parallel(false)
	tween.tween_property(bolt_mesh, "rotation_degrees:x", 0.0, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tween.finished

# --- Juice and Feedback Placeholders ---
func play_fire_effects():
	# Add camera kick, muzzle flash, and audio playback here later
	pass 

func play_dry_click_sound():
	# Add empty firing pin click sound here later
	pass
