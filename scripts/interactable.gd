class_name Interactable
extends Area3D

# This signal tells whoever is listening that this specific item was picked up
signal interacted(item_type)

@export var item_name: String = "Item"
@export var item_enum_id: int = 0 # Matches the ItemManager's EquippedItem enum
@onready var pickup_sound : AudioStreamPlayer3D = $pickup

func prompt_text() -> String:
	return "Press [E] to pick up " + item_name

func interact():
	emit_signal("interacted", item_enum_id)
	var player = get_tree().get_first_node_in_group("player")
	
	if pickup_sound and pickup_sound.stream:
		for child in get_children():
			if child is MeshInstance3D:
				child.visible = false
		
		if item_enum_id == 1:
			var mosin = get_tree().get_first_node_in_group("mosin_weapon")
			player.update_ammo_ui(mosin.current_ammo, mosin.reserve_ammo)
		
		# Disable collisions so the player can't interact with it twice
		monitorable = false
		monitoring = false
		
		# Play the sound and wait until it's finished before deleting the node
		pickup_sound.play()
		await pickup_sound.finished
	queue_free() # Remove the physical prop from the cabin world
