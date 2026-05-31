extends CenterContainer

@export var dot_radius : float=1.0
@export var dot_color :  Color = Color.FLORAL_WHITE

# Called when the node enters the scene tree for the first time.
func _ready():
	queue_redraw()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass

func _draw():
	# size / 2.0 perfectly calculates the mathematical center of the UI node
	draw_circle(size / 2.0, dot_radius, dot_color)
