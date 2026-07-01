extends Node3D

enum EquippedItem { NONE, MOSIN, FLASHLIGHT }
var current_item = EquippedItem.NONE

# Track what the player has actually found in the cabin
var has_mosin: bool = false
var has_flashlight: bool = false
var is_switching: bool = false


@onready var mosin_mesh = $MosinMesh
@onready var flashlight_mesh = $FlashlightMesh
@onready var flashlight_light_belt = $"../../../BeltPosition/FlashlightLight"
@onready var flashlight_light_hand = $FlashlightMesh/SpotLight3D

func _ready():
	# Turn everything off at the start of the game
	flashlight_light_belt.visible = false
	update_item_visibility()

func _unhandled_input(event):
	# Only allow switching if the player actually owns the item
	if event.is_action_pressed("mosin") and has_mosin:
		switch_to(EquippedItem.MOSIN)
	elif event.is_action_pressed("flashlight") and has_flashlight:
		switch_to(EquippedItem.FLASHLIGHT)
	
	# Pass Combat Inputs to the Mosin State Machine
	if current_item == EquippedItem.MOSIN:
		if event.is_action_pressed("fire"):
			mosin_mesh.action_fire()
		elif event.is_action_pressed("reload"):
			# Send the quick-press action to the Mosin.
			# The Mosin's _process() loop handles the "hold" calculation.
			mosin_mesh.action_reload_pressed()

# Called by the player script when interacting with the props in the cabin
func unlock_and_equip_item(item_id: int):
	if item_id == EquippedItem.MOSIN:
		has_mosin = true
		switch_to(EquippedItem.MOSIN)
	elif item_id == EquippedItem.FLASHLIGHT:
		has_flashlight = true
		flashlight_light_belt.visible = true # The belt light can now function
		switch_to(EquippedItem.FLASHLIGHT)

func switch_to(new_item: EquippedItem):
	# Block the code if we are already in the middle of an intense weapon swap,
	# or if we are already holding the requested item.
	if is_switching or current_item == new_item:
		return
		
	is_switching = true
	
	# If we are holding the Mosin and trying to put it away...
	if current_item == EquippedItem.MOSIN and new_item != EquippedItem.MOSIN:
		# ...tell the Mosin to pack up, and WAIT for it to finish!
		if mosin_mesh.has_method("prepare_to_stow"):
			await mosin_mesh.prepare_to_stow()

	# Once the Mosin is safely stowed (bolt closed), do the actual swap
	current_item = new_item
	update_item_visibility()
	
	# Light placement logic (Hand vs Belt)
	if has_flashlight:
		if current_item == EquippedItem.FLASHLIGHT:
			flashlight_light_hand.visible = true
			flashlight_light_belt.visible = false
		else:
			flashlight_light_hand.visible = false
			flashlight_light_belt.visible = true
	else:
		flashlight_light_hand.visible = false
		flashlight_light_belt.visible = false
		
	# Unblock the swapping mechanic
	is_switching = false

func update_item_visibility():
	mosin_mesh.visible = (current_item == EquippedItem.MOSIN)
	flashlight_mesh.visible = (current_item == EquippedItem.FLASHLIGHT)
