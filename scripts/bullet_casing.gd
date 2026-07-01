extends RigidBody3D

func _ready():
	# Despawn to save memory
	await get_tree().create_timer(6.0).timeout
	queue_free()
