class_name Interactable
extends Area3D

# This signal tells whoever is listening that this specific item was picked up
signal interacted(item_type)

@export var item_name: String = "Item"
@export var item_enum_id: int = 0 # Matches the ItemManager's EquippedItem enum

func prompt_text() -> String:
	return "Press [E] to pick up " + item_name

func interact():
	emit_signal("interacted", item_enum_id)
	queue_free() # Remove the physical prop from the cabin world
