extends Node

# Emit this whenever health changes so the UI can update instantly
signal health_changed(current_hp, max_hp)
signal died

@export var max_hp = 100
var current_hp = max_hp

func _ready() -> void:
	# Announce the starting health on frame 1 so the UI fills up
	emit_signal("health_changed", current_hp, max_hp)

func take_damage(amount):
	current_hp -= amount
	current_hp = clamp(current_hp, 0, max_hp) # Prevent negative numbers
	
	emit_signal("health_changed", current_hp, max_hp)
	print("Hit! HP remaining: ", current_hp)
	
	if current_hp <= 0:
		emit_signal("died")
