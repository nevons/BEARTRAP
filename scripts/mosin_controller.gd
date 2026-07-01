extends Node3D

enum WeaponState { READY, NEED_BOLT, CYCLING, RELOADING, EMPTY }
var fire_interrupt: bool = false
var switch_interrupt: bool = false
var abort_reload: bool = false
var current_state: WeaponState = WeaponState.READY

const MAX_AMMO = 5
var current_ammo = 0 # Starting empty for testing!
var reserve_ammo = 0 # Starting with a small pool

@onready var anim_player: AnimationPlayer = $AnimationPlayer

func _ready():
	current_state = WeaponState.EMPTY if current_ammo == 0 else WeaponState.READY
	print("Mosin Ready. Ammo: ", current_ammo, "/", MAX_AMMO, " | Reserve: ", reserve_ammo)
	
	add_to_group("mosin_weapon")
	sync_ammo_to_ui()

func add_reserve_ammo(amount: int):
	reserve_ammo += amount
	print("Reserve ammo is now: ", reserve_ammo)

func action_fire():
	# 1. Soft Interrupt: Pressing fire mid-reload
	if current_state == WeaponState.RELOADING:
		fire_interrupt = true
		return

	# 2. THE NEGATIVE AMMO FIX: 
	# If the gun thinks it's READY but has 0 bullets, force it into EMPTY state.
	if current_state == WeaponState.READY and current_ammo <= 0:
		current_state = WeaponState.EMPTY

	if current_state != WeaponState.READY:
		if current_state == WeaponState.NEED_BOLT:
			pass
		elif current_state == WeaponState.EMPTY:
			if anim_player.has_animation("empty"): 
				anim_player.play("empty")
		return

	# Fire the weapon
	current_ammo -= 1
	sync_ammo_to_ui()
	print("BANG! Ammo left: ", current_ammo, " | Reserve: ", reserve_ammo)
	
	# recoil and kick
	var player = get_tree().get_first_node_in_group("player")
	if player and player.has_method("fire_recoil"):
		player.fire_recoil()
	
	current_state = WeaponState.CYCLING
	if anim_player.has_animation("fire"):
		anim_player.play("fire")
		await anim_player.animation_finished
	
	current_state = WeaponState.NEED_BOLT

func action_cycle_bolt():
	if current_state != WeaponState.NEED_BOLT:
		return
		
	current_state = WeaponState.CYCLING
	if anim_player.has_animation("cycle_bolt"):
		anim_player.play("cycle_bolt")
		await anim_player.animation_finished
		
	if current_ammo > 0:
		current_state = WeaponState.READY
	else:
		current_state = WeaponState.EMPTY

func action_reload_pressed():
	if current_state == WeaponState.NEED_BOLT:
		action_cycle_bolt()
	elif current_state == WeaponState.READY or current_state == WeaponState.EMPTY:
		
		# --- THE TACTICAL ROUTER ---
		# If the gun is totally empty AND we have enough for a full clip
		if current_ammo == 0 and reserve_ammo >= MAX_AMMO:
			start_clip_reload()
		else:
			# Otherwise, we use the single-bullet loop to top off
			start_looping_reload()

func start_clip_reload():
	current_state = WeaponState.RELOADING
	var player = get_tree().get_first_node_in_group("player")
	
	if anim_player.has_animation("reload"):
		# 1. Ask the animation player EXACTLY how long the animation takes
		var anim_length = anim_player.get_animation("reload").length
		
		# 2. Tell the UI to start filling for that duration
		if player and player.has_method("start_reload_ui"):
			player.start_reload_ui(anim_length)
			
		anim_player.play("reload")
		await anim_player.animation_finished
		
	# 3. Hide the ring when the animation finishes (or if it gets interrupted)
	if player and player.has_method("stop_reload_ui"):
		player.stop_reload_ui()
		
	# Check if they interrupted the animation by firing
	if current_state == WeaponState.RELOADING:
		reserve_ammo -= MAX_AMMO
		current_ammo = MAX_AMMO
		current_state = WeaponState.READY
		sync_ammo_to_ui()
		print("Clip loaded! Chamber: ", current_ammo, " | Reserve: ", reserve_ammo)


func start_looping_reload():
	var player = get_tree().get_first_node_in_group("player")
	if current_ammo == MAX_AMMO or reserve_ammo <= 0:
		return

	# Reset both interrupt flags before starting
	fire_interrupt = false
	switch_interrupt = false
	current_state = WeaponState.RELOADING
	print("Starting reload...")
	
	# Calculate UI Length
	if current_ammo == 0:
		var anim_length = anim_player.get_animation("reload_start").length + anim_player.get_animation("reload_insert").length * (reserve_ammo) + anim_player.get_animation("reload_end").length
		player.start_reload_ui(anim_length)
	else:
		var anim_length = anim_player.get_animation("reload_start").length + anim_player.get_animation("reload_insert").length * (MAX_AMMO - current_ammo) + anim_player.get_animation("reload_end").length
		player.start_reload_ui(anim_length)

	# 1. Open the bolt
	if anim_player.has_animation("reload_start"):
		anim_player.play("reload_start")
		await anim_player.animation_finished
		
	# 2. Loop the bullet insertion
	while current_ammo < MAX_AMMO and reserve_ammo > 0 and current_state == WeaponState.RELOADING:
		# Break the loop BEFORE inserting if they already pressed fire or switch
		if fire_interrupt or switch_interrupt:
			break

		if anim_player.has_animation("reload_insert"):
			anim_player.play("reload_insert")
			await anim_player.animation_finished
			
			# If they interrupt DURING the bullet slide, we still count the bullet that went in
			if fire_interrupt or switch_interrupt:
				current_ammo += 1
				reserve_ammo -= 1
				sync_ammo_to_ui()
				break
			
			# Normal load
			current_ammo += 1
			reserve_ammo -= 1
			sync_ammo_to_ui()
			print("Loaded 1 round. Chamber: ", current_ammo, " | Reserve: ", reserve_ammo)

	# 3. Close the bolt
	# This now plays in ALL scenarios: naturally, after firing, OR before switching items!
	if anim_player.has_animation("reload_end"):
		anim_player.play("reload_end")
		await anim_player.animation_finished
	
	if player and player.has_method("stop_reload_ui"):
		player.stop_reload_ui()
		
	# Finalize state, which frees the 'prepare_to_stow' while loop!
	current_state = WeaponState.READY if current_ammo > 0 else WeaponState.EMPTY
		
func sync_ammo_to_ui():
		var player = get_tree().get_first_node_in_group("player")
		if player and player.has_method("update_ammo_ui"):
			player.update_ammo_ui(current_ammo, reserve_ammo)	

func prepare_to_stow() -> void:
	# If they try to switch while reloading OR cycling the bolt...
	if current_state == WeaponState.RELOADING or current_state == WeaponState.CYCLING:
		print("Switching items! Forcing bolt to close...")
		switch_interrupt = true
		
		# Yield frame-by-frame until the reload/cycle loop finishes 
		# and sets the state back to READY or EMPTY
		while current_state == WeaponState.RELOADING or current_state == WeaponState.CYCLING:
			await get_tree().process_frame
