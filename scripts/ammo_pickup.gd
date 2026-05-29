extends Interactable

var ammo_yield: int = 1

func _ready():
	# Generate random bullets when the box spawns
	ammo_yield = randi_range(1, 5)
	
	# Dynamically override the item_name from the parent class
	# Your prompt_text() will now automatically say "Press [E] to pick up 3 Mosin Rounds"
	item_name = str(ammo_yield) + " Mosin Rounds" 

# Override the parent's interact function[cite: 4]
func interact():
	# 1. Instantly find the Mosin anywhere in the game using the group we just made
	var mosin = get_tree().get_first_node_in_group("mosin_weapon")
	
	if mosin:
		mosin.add_reserve_ammo(ammo_yield)
	else:
		print("Must get my rifle first...")
		
	# 2. Call the original Interactable code!
	# This automatically handles emitting the signal, hiding the mesh, playing the sound, and queue_free()[cite: 4]
	super.interact()
