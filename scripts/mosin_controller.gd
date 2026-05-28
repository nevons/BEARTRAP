extends Node3D

enum WeaponState { READY, NEED_BOLT, CYCLING, RELOADING, EMPTY }
var current_state: WeaponState = WeaponState.READY

const MAX_AMMO = 5
var current_ammo = MAX_AMMO

# Variables for the "Hold to Reload" logic
var reload_hold_timer: float = 0.0
const RELOAD_HOLD_THRESHOLD: float = 0.4 # How long the key must be held (in seconds)

# Node References based on your hierarchy
@onready var anim_player: AnimationPlayer = $AnimationPlayer

func _ready():
	current_state = WeaponState.READY
	print("Mosin Ready. Ammo: ", current_ammo, "/", MAX_AMMO)

func _process(delta):
	# 1. Listen for the initial "Hold to Reload" action ONLY when the gun is completely empty
	if current_state == WeaponState.EMPTY:
		if Input.is_action_pressed("reload"):
			reload_hold_timer += delta
			if reload_hold_timer >= RELOAD_HOLD_THRESHOLD:
				reload_hold_timer = 0.0 # Reset timer
				action_reload_clip()
		else:
			# Reset timer if the player lets go early
			reload_hold_timer = 0.0 

	# 2. Check if the player lets go MID-RELOAD
	elif current_state == WeaponState.RELOADING:
		if not Input.is_action_pressed("reload"):
			print("Reload canceled! Key released early.")
			
			anim_player.stop()
			if anim_player.has_animation("RESET"):
				anim_player.play("RESET") 
			
			# Revert state back to empty so they have to start over
			current_state = WeaponState.EMPTY

func action_fire():
	if current_state != WeaponState.READY:
		if current_state == WeaponState.NEED_BOLT:
			print("*Click* — You need to cycle the bolt! (Press R)")
		elif current_state == WeaponState.EMPTY:
			print("*Click* — Weapon is empty! (Hold R to reload)")
		return

	# Fire the weapon
	current_ammo -= 1
	print("BANG! Ammo left: ", current_ammo)
	
	# Temporarily set to CYCLING to block inputs while the recoil/fire anim plays
	current_state = WeaponState.CYCLING
	
	if anim_player.has_animation("fire"):
		anim_player.play("fire")
		await anim_player.animation_finished
	
	# After firing, the player MUST cycle the bolt to eject the spent casing
	current_state = WeaponState.NEED_BOLT

func action_reload_pressed():
	# This is triggered by a quick tap of the reload key from the Hand Container
	if current_state == WeaponState.NEED_BOLT:
		action_cycle_bolt()
	elif current_state == WeaponState.EMPTY:
		print("Hold 'reload' to insert a new clip!")

func action_cycle_bolt():
	current_state = WeaponState.CYCLING
	print("Cycling bolt...")
	
	if anim_player.has_animation("cycle_bolt"):
		anim_player.play("cycle_bolt")
		await anim_player.animation_finished
		
	# Determine the next state based on remaining ammo
	if current_ammo > 0:
		current_state = WeaponState.READY
		print("Round chambered. Ready to fire.")
	else:
		current_state = WeaponState.EMPTY
		print("Action is open. Weapon is empty!")

func action_reload_clip():
	# Backup check to ensure we only reload when empty
	if current_state != WeaponState.EMPTY:
		return
		
	current_state = WeaponState.RELOADING
	print("Inserting new stripper clip... Keep holding!")
	
	if anim_player.has_animation("reload"):
		anim_player.play("reload")
		await anim_player.animation_finished
		
	# CRITICAL CHECK: Replenish ammo ONLY if the animation wasn't canceled
	if current_state == WeaponState.RELOADING:
		current_ammo = MAX_AMMO
		current_state = WeaponState.READY
		print("Reload complete. Ammo: ", current_ammo, "/", MAX_AMMO)
