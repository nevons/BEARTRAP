extends Node

@export var max_hp = 100
var current_hp = max_hp



# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func take_damage(amount):
	current_hp -= amount
	if current_hp == 0:
		emit_signal("died")
