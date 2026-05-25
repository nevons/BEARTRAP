extends Node3D

enum EquippedItem { NONE, MOSIN, FLASHLIGHT }
var current_item = EquippedItem.NONE

# Track what the player has actually found in the cabin
var has_mosin: bool = false
var has_flashlight: bool = false

@onready var mosin_mesh = $MosinMesh
@onready var flashlight_mesh = $FlashlightMesh
@onready var flashlight_light = $"../../../BeltPosition/FlashlightLight"

func _ready():
	# Turn everything off at the start of the game
	flashlight_light.visible = false
	update_item_visibility()

func _unhandled_input(event):
	# Only allow switching if the player actually owns the item
	if event.is_action_pressed("mosin") and has_mosin:
		switch_to(EquippedItem.MOSIN)
	elif event.is_action_pressed("flashlight") and has_flashlight:
		switch_to(EquippedItem.FLASHLIGHT)

# Called by the player script when interacting with the props in the cabin
func unlock_and_equip_item(item_id: int):
	if item_id == EquippedItem.MOSIN:
		has_mosin = true
		switch_to(EquippedItem.MOSIN)
		print("Mosin-Nagant acquired.")
	elif item_id == EquippedItem.FLASHLIGHT:
		has_flashlight = true
		flashlight_light.visible = true # The belt light can now function
		switch_to(EquippedItem.FLASHLIGHT)
		print("Flashlight acquired.")

func switch_to(new_item: EquippedItem):
	current_item = new_item
	update_item_visibility()
	
	# Light placement logic (Hand vs Belt)
	if current_item == EquippedItem.FLASHLIGHT:
		flashlight_light.position = Vector3(0.2, -0.2, -0.4)
	else:
		flashlight_light.position = Vector3(0.2, -0.8, -0.2)

func update_item_visibility():
	mosin_mesh.visible = (current_item == EquippedItem.MOSIN)
	flashlight_mesh.visible = (current_item == EquippedItem.FLASHLIGHT)
